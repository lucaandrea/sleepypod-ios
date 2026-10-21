import Foundation
import Observation
import UIKit

/// The personal stage models on this iPhone: loads them from Application Support, trains new ones, and holds
/// the one setting that says where the app's sleep stages come from.
@MainActor
@Observable
final class StageModelStore {
    /// Where the Night page, week view and Health sync get their stages.
    enum Source: String, Codable, CaseIterable, Sendable, Identifiable {
        case rules
        case personalLogistic
        case personalForest
        /// The model stored on the pod, trained on a Mac; fetched, validated and evaluated here.
        case pod

        var id: String { rawValue }
        var kind: StageModelKind? {
            switch self {
            case .rules, .pod: nil
            case .personalLogistic: .logistic
            case .personalForest: .forest
            }
        }
        var title: String {
            switch self {
            case .rules: "Rules"
            case .pod: "Pod model"
            case .personalLogistic, .personalForest: kind?.title ?? rawValue
            }
        }
        /// A model badge for the UI: a brain for a trained model, a list for hand-written thresholds.
        var symbol: String { self == .rules ? "list.bullet.rectangle" : "brain" }

        static func forKind(_ kind: StageModelKind) -> Source {
            switch kind {
            case .logistic: .personalLogistic
            case .forest: .personalForest
            }
        }
    }

    /// Pooled leave-one-night-out κ must clear both the rules and the challenger by this much.
    static let kappaMargin = 0.05
    static let minimumNights = StageDataset.minimumNights
    /// Retraining is offered once this many new labelled nights have accrued.
    static let retrainAfterNights = 3

    var source: Source {
        didSet { persistence.set(source.rawValue, forKey: "stageSource") }
    }
    /// Set once the user picks a source here; until then the phone follows whatever the pod stages with.
    private(set) var sourceChosenByUser: Bool {
        didSet { persistence.set(sourceChosenByUser, forKey: "stageSourceChosen") }
    }
    var contract: StageFeatures.Contract {
        didSet { persistence.set(contract.rawValue, forKey: "stageContract") }
    }
    private(set) var personal: [StageModelKind: StageChallenger.Availability] = [:]
    /// The pod's stored model after validation, and why there is none.
    private(set) var podModel: PortableStageModel?
    private(set) var podError: String?
    private(set) var podFetchedAt: Date?
    /// Whether the pod stages the side's nights with its stored model.
    private(set) var podActive = false
    private(set) var isTraining = false
    private(set) var trainingKind: StageModelKind?
    private(set) var trainingProgress: Double = 0 {
        didSet { writeTrainingStatus() }
    }
    private(set) var trainingStatus: String? {
        didSet { writeTrainingStatus() }
    }
    var trainingError: String?
    private(set) var lastReport: StageTrainingReport?

    let directory: URL
    private let persistence: UserDefaults

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        persistence = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageModel", isDirectory: true)
        source = defaults.string(forKey: "stageSource").flatMap(Source.init) ?? .rules
        contract = defaults.string(forKey: "stageContract").flatMap(StageFeatures.Contract.init) ?? .challenger
        sourceChosenByUser = defaults.bool(forKey: "stageSourceChosen")
        reload()
    }

    /// The user's pick from the settings picker, which stops the phone following the pod's switch.
    func choose(_ source: Source) {
        sourceChosenByUser = true
        self.source = source
    }

    /// A one-line status file beside the models, so a run can be followed from outside the app (the device log
    /// stream is not always reachable) and a crash mid-run leaves a trace.
    private func writeTrainingStatus() {
        let url = directory.appendingPathComponent("training-status.txt")
        guard isTraining, let kind = trainingKind else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let line = "\(Date().formatted(.iso8601)) \(kind.rawValue) \(Int((trainingProgress * 100).rounded()))% \(trainingStatus ?? "")\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }

    func reload() {
        var loaded: [StageModelKind: StageChallenger.Availability] = [:]
        for kind in StageModelKind.allCases {
            let modelURL = StageTrainer.modelURL(for: kind, in: directory)
            let cardURL = StageTrainer.cardURL(for: kind, in: directory)
            guard FileManager.default.fileExists(atPath: modelURL.path) else { continue }
            guard FileManager.default.fileExists(atPath: cardURL.path) else {
                loaded[kind] = .failed("The model's card is missing")
                continue
            }
            loaded[kind] = StageChallenger.load(modelURL: modelURL, cardURL: cardURL)
        }
        personal = loaded
        if let kind = source.kind, !isEligible(kind) { source = .rules }
    }

    /// Reads the side's model from the pod. A document that fails validation is refused and reported, and the
    /// source falls back to the rules if it was the pod.
    func refreshPodModel(api: SleepypodProtocol, side: Side) async {
        let response: PodStageModelResponse
        do {
            response = try await api.getStageModel(side: side)
        } catch {
            // Away from the pod's network: keep the last valid model and the user's choice; just say why.
            podError = error.localizedDescription
            Log.general.error("Pod stage model not reachable: \(error.localizedDescription, privacy: .public)")
            return
        }
        podFetchedAt = Date()
        podActive = response.active ?? false
        guard let model = response.model else {
            podModel = nil
            podError = nil
            podActive = false
            if source == .pod { source = .rules }
            return
        }
        do {
            try model.validate()
            podModel = model
            podError = nil
            Log.general.notice("Pod stage model \(model.version, privacy: .public) loaded, \(model.kind, privacy: .public)")
            if let active = response.active { followPod(active: active) }
        } catch {
            // The pod handed over something broken: refuse it rather than stage nights with it.
            podModel = nil
            podError = error.localizedDescription
            podActive = false
            if source == .pod { source = .rules }
            Log.general.error("Pod stage model refused: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Until the user picks a source on this phone, its stages come from wherever the pod's do: the pod's
    /// model when the pod has switched it on, the rules when it has switched it off again. A pod too old to
    /// say leaves the phone's setting alone.
    private func followPod(active: Bool) {
        guard !sourceChosenByUser else { return }
        if active, source == .rules {
            source = .pod
        } else if !active, source == .pod {
            source = .rules
        }
    }

    var podClassifier: (any SleepStageClassifying)? { podModel.map { PortableStageClassifier(model: $0) } }

    func card(for kind: StageModelKind) -> StageChallenger.Card? { personal[kind]?.card }
    func classifier(for kind: StageModelKind) -> (any SleepStageClassifying)? { personal[kind]?.classifier }

    /// A card clears the bar when its pooled leave-one-night-out κ beats the rules and the challenger by the
    /// margin, it won a majority of nights, and it saw enough nights. A missing challenger metric is not a blocker.
    static func isEligible(_ card: StageChallenger.Card) -> Bool {
        guard let metrics = card.metrics, let lono = metrics.lono, let kappa = lono.kappa,
              let nights = lono.nights, nights >= minimumNights,
              let rules = metrics.rules?.kappa else { return false }
        guard kappa >= rules + kappaMargin else { return false }
        if let challenger = metrics.challenger?.kappa, kappa < challenger + kappaMargin { return false }
        guard let won = metrics.nightsWon, won * 2 > nights else { return false }
        return true
    }

    func isEligible(_ kind: StageModelKind) -> Bool {
        guard let card = card(for: kind), classifier(for: kind) != nil else { return false }
        return Self.isEligible(card)
    }

    /// The classifier the app's stages come from, when the setting names an eligible, loaded model.
    var active: (kind: StageModelKind?, title: String, classifier: any SleepStageClassifying, contract: StageFeatures.Contract, version: String)? {
        if source == .pod {
            guard let model = podModel, let contract = model.contract else { return nil }
            return (nil, model.title, PortableStageClassifier(model: model), contract, model.version)
        }
        guard let kind = source.kind, isEligible(kind), let card = card(for: kind), let classifier = classifier(for: kind),
              let contract = StageFeatures.Contract.matching(card.columns) else { return nil }
        return (kind, kind.title, classifier, contract, card.version)
    }

    /// What `SleepAnalyzer.analyze` needs to stage a night with the active model.
    func staging(enteredBed: Date, leftBed: Date) -> SleepAnalyzer.ModelStaging? {
        active.map { SleepAnalyzer.ModelStaging(classifier: $0.classifier, contract: $0.contract, enteredBed: enteredBed, leftBed: leftBed) }
    }

    /// Folded into Health receipts so switching models rewrites synced nights.
    var activeVersion: String? { active?.version }

    /// The files to hand to the analysis container: the editable spec (when the trainer kept it) and the card.
    func shareableFiles(for kind: StageModelKind) -> [URL] {
        [StageTrainer.specURL(for: kind, in: directory), StageTrainer.cardURL(for: kind, in: directory)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func delete(_ kind: StageModelKind) {
        for url in [StageTrainer.modelURL(for: kind, in: directory), StageTrainer.specURL(for: kind, in: directory), StageTrainer.cardURL(for: kind, in: directory)] {
            try? FileManager.default.removeItem(at: url)
        }
        if source.kind == kind { source = .rules }
        reload()
    }

    /// Builds the dataset, trains the model and installs it. Returns false on failure, with `trainingError` set.
    @discardableResult
    func train(_ kind: StageModelKind, builder: StageDatasetBuilder) async -> Bool {
        guard !isTraining else { return false }
        isTraining = true
        trainingKind = kind
        trainingProgress = 0
        trainingError = nil
        // A locked phone suspends the app mid-fit; the screen stays on until the run ends.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isTraining = false
            trainingKind = nil
            trainingStatus = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            trainingStatus = "Reading nights"
            let dataset = try await builder.build(contract: contract) { done, total in
                self.trainingStatus = "Reading night \(min(done + 1, max(total, 1))) of \(total)"
                self.trainingProgress = total == 0 ? 0 : 0.5 * Double(done) / Double(total)
            }
            trainingStatus = "Training \(kind.title.lowercased())"
            let result = try await StageTrainer.train(dataset: dataset, kind: kind, into: directory, progress: { fraction in
                Task { @MainActor in self.trainingProgress = 0.5 + 0.5 * fraction }
            }, status: { text in
                Task { @MainActor in self.trainingStatus = "Training \(kind.title.lowercased()): \(text)" }
            })
            lastReport = result.report
            reload()
            Log.general.info("Trained \(kind.rawValue) on \(result.report.nights) nights, κ \(result.report.pooled?.kappa ?? -1)")
            return true
        } catch is CancellationError {
            return false
        } catch {
            trainingError = error.localizedDescription
            Log.general.error("Stage model training failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
