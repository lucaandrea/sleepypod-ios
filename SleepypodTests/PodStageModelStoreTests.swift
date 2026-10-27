import Testing
import Foundation
@testable import Sleepypod

@Suite("Pod stage model in the store")
@MainActor
struct PodStageModelStoreTests {
    private let forestJSON = """
    {"version":"container-forest-test","kind":"forest","classes":["wake","light","deep","rem"],
     "featureContract":["hrZ","hrStdZ","motionZ","nightFraction"],
     "trees":[{"f":[0,-1,-1],"t":[-0.5,0,0],"l":[1,-1,-1],"r":[2,-1,-1],"v":[[0,0,0,0],[0,1,9,0],[1,8,1,0]]}],
     "metrics":{"lono":{"epochs":700,"kappa":0.2,"accuracy":0.48,"nights":10}},
     "testVectors":[{"inputs":{"hrZ":-1,"hrStdZ":0,"motionZ":0,"nightFraction":0.5},"expected":2}]}
    """

    private func store(defaults: UserDefaults? = nil) throws -> StageModelStore {
        let defaults = try defaults ?? #require(UserDefaults(suiteName: "pod-store-\(UUID().uuidString)"))
        return StageModelStore(defaults: defaults, directory: FileManager.default.temporaryDirectory.appendingPathComponent("pod-store-\(UUID().uuidString)"))
    }

    @Test func aValidPodModelBecomesASelectableSourceAndStagesNights() async throws {
        let store = try store()
        let api = MockAPIClient()
        api.stageModelResponse = .success(PodStageModelResponse(model: try JSONDecoder().decode(PortableStageModel.self, from: Data(forestJSON.utf8)), uploadedAt: 1))
        await store.refreshPodModel(api: api, side: .left)
        #expect(api.getStageModelCalls == 1)
        #expect(store.podError == nil)
        #expect(store.podModel?.version == "container-forest-test")
        #expect(store.active == nil, "not in use until chosen")
        store.source = .pod
        let active = try #require(store.active)
        #expect(active.kind == nil)
        #expect(active.title == "Pod forest")
        #expect(active.version == "container-forest-test")
        #expect(active.contract == .challenger)
        #expect(store.activeVersion == "container-forest-test")
        let staging = try #require(store.staging(enteredBed: Date(), leftBed: Date().addingTimeInterval(3600)))
        #expect(try staging.classifier.predict(["hrZ": -1, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0.5]).stage == .deep)
    }

    @Test func aLateModelReadCannotReplaceTheLatestSidesResult() async throws {
        let store = try store(), probe = HeldPodModelRead()
        let older = Task { await store.refreshPodModel(api: HeldPodModelClient(probe: probe, model: try model()), side: .left) }
        await probe.waitHeld()
        let newer = MockAPIClient()
        newer.stageModelResponse = .success(.init(model: nil, uploadedAt: nil))
        await store.refreshPodModel(api: newer, side: .right)
        await probe.release(); try await older.value
        #expect(store.podModel == nil); #expect(store.podActive == false)
    }

    @Test func unsupportedControllersShowAnActionableExplanation() async throws {
        let store = try store(), api = MockAPIClient()
        api.stageModelResponse = .failure(URLError(.unsupportedURL))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podError?.contains("Local analysis remains available") == true)
        #expect(store.podModel == nil)
    }

    @Test func aMissingOrBrokenPodModelFallsBackToRules() async throws {
        let store = try store()
        let api = MockAPIClient()
        api.stageModelResponse = .success(PodStageModelResponse(model: try JSONDecoder().decode(PortableStageModel.self, from: Data(forestJSON.utf8)), uploadedAt: 1))
        await store.refreshPodModel(api: api, side: .left)
        store.source = .pod
        // The pod no longer has a model.
        api.stageModelResponse = .success(PodStageModelResponse(model: nil, uploadedAt: nil))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podModel == nil)
        #expect(store.source == .rules)
        #expect(store.active == nil)
        // A document that fails its own vectors is refused and reported.
        let broken = try JSONDecoder().decode(PortableStageModel.self, from: Data(forestJSON.replacingOccurrences(of: "\"expected\":2", with: "\"expected\":0").utf8))
        api.stageModelResponse = .success(PodStageModelResponse(model: broken, uploadedAt: 2))
        store.source = .pod
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podModel == nil)
        #expect(store.podError?.contains("test vectors") == true)
        #expect(store.source == .rules)
        // The pod being unreachable keeps the last valid model and the user's choice, and only reports why.
        api.stageModelResponse = .success(PodStageModelResponse(model: try JSONDecoder().decode(PortableStageModel.self, from: Data(forestJSON.utf8)), uploadedAt: 3))
        await store.refreshPodModel(api: api, side: .left)
        store.source = .pod
        api.stageModelResponse = .failure(APIError.noBaseURL)
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podModel?.version == "container-forest-test")
        #expect(store.source == .pod)
        #expect(store.podError != nil)
    }

    private func model() throws -> PortableStageModel { try JSONDecoder().decode(PortableStageModel.self, from: Data(forestJSON.utf8)) }

    @Test func thePhoneFollowsThePodsSwitchUntilTheUserChooses() async throws {
        let store = try store()
        let api = MockAPIClient()
        // The pod stages nights with its model: so does the phone, with nothing chosen here.
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1, active: true))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podActive)
        #expect(store.source == .pod)
        #expect(store.sourceChosenByUser == false)
        // The pod switches it off again: the phone goes back to the rules.
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1, active: false))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podActive == false)
        #expect(store.source == .rules)
        #expect(store.podModel != nil, "the model stays selectable")
        // Being unreachable changes nothing.
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1, active: true))
        await store.refreshPodModel(api: api, side: .left)
        api.stageModelResponse = .failure(APIError.noBaseURL)
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.source == .pod)
        #expect(store.podActive)
    }

    @Test func aChoiceMadeOnThePhoneIsNotOverriddenByThePod() async throws {
        let defaults = try #require(UserDefaults(suiteName: "pod-store-\(UUID().uuidString)"))
        let store = try store(defaults: defaults)
        let api = MockAPIClient()
        store.choose(.rules)
        #expect(store.sourceChosenByUser)
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1, active: true))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podActive)
        #expect(store.source == .rules)
        // And the other way round: chosen on the phone, kept when the pod switches off.
        store.choose(.pod)
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1, active: false))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.source == .pod)
        // The choice survives a relaunch.
        let again = StageModelStore(defaults: defaults, directory: store.directory)
        #expect(again.sourceChosenByUser)
        #expect(again.source == .pod)
    }

    @Test func aPodWithoutTheSwitchLeavesTheSourceAlone() async throws {
        let store = try store()
        let api = MockAPIClient()
        api.stageModelResponse = .success(PodStageModelResponse(model: try model(), uploadedAt: 1))
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.podModel != nil)
        #expect(store.podActive == false)
        #expect(store.source == .rules)
        store.source = .pod
        await store.refreshPodModel(api: api, side: .left)
        #expect(store.source == .pod, "a programmatic choice on an older pod is left as is")
    }
}

private actor HeldPodModelRead {
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func waitHeld() async { while continuation == nil { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class HeldPodModelClient: MockAPIClient, @unchecked Sendable {
    let probe: HeldPodModelRead
    let model: PortableStageModel
    init(probe: HeldPodModelRead, model: PortableStageModel) { self.probe = probe; self.model = model; super.init() }
    override func getStageModel(side: Side) async throws -> PodStageModelResponse {
        await probe.hold()
        return .init(model: model, uploadedAt: 1, active: true)
    }
}
