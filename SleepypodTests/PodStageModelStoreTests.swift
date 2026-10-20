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

    private func store() throws -> StageModelStore {
        let defaults = try #require(UserDefaults(suiteName: "pod-store-\(UUID().uuidString)"))
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
}
