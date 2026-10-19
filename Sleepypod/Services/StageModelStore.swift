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

        var id: String { rawValue }
        var kind: StageModelKind? {
            switch self {
            case .rules: nil
            case .personalLogistic: .logistic
            case .personalForest: .forest
            }
        }
        var title: String { kind?.title ?? "Rules" }
        /// A model badge for the UI: a brain for a trained model, a list for hand-written thresholds.
        var symbol: String { kind == nil ? "list.bullet.rectangle" : "brain" }

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
    var contract: StageFeatures.Contract {
        didSet { persistence.set(contract.rawValue, forKey: "stageContract") }
    }
    private(set) var personal: [StageModelKind: StageChallenger.Availability] = [:]
    private(set) var isTraining = false
    private(set) var trainingKind: StageModelKind?
    private(set) var trainingProgress: Double = 0
    private(set) var trainingStatus: String?
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
        reload()
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
    var active: (kind: StageModelKind, classifier: any SleepStageClassifying, contract: StageFeatures.Contract, version: String)? {
        guard let kind = source.kind, isEligible(kind), let card = card(for: kind), let classifier = classifier(for: kind),
              let contract = StageFeatures.Contract.matching(card.columns) else { return nil }
        return (kind, classifier, contract, card.version)
    }

    /// What `SleepAnalyzer.analyze` needs to stage a night with the active model.
    func staging(enteredBed: Date, leftBed: Date) -> SleepAnalyzer.ModelStaging? {
        active.map { SleepAnalyzer.ModelStaging(classifier: $0.classifier, contract: $0.contract, enteredBed: enteredBed, leftBed: leftBed) }
    }

    /// Folded into Health receipts so switching models rewrites synced nights.
    var activeVersion: String? { active?.version }

    func delete(_ kind: StageModelKind) {
        for url in [StageTrainer.modelURL(for: kind, in: directory), StageTrainer.cardURL(for: kind, in: directory)] {
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
            let result = try await StageTrainer.train(dataset: dataset, kind: kind, into: directory) { fraction in
                Task { @MainActor in self.trainingProgress = 0.5 + 0.5 * fraction }
            }
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
