import Testing
import Foundation
@testable import Sleepypod

private final class FixtureAnchor {}

/// The pod's portable model form, evaluated on the phone exactly as sleepypod-core's TypeScript and the
/// Python exporter do, so a model trained on a Mac stages a night identically everywhere.
@Suite("Portable stage model")
struct PortableStageModelTests {
    private func decode(_ json: String) throws -> PortableStageModel {
        try JSONDecoder().decode(PortableStageModel.self, from: Data(json.utf8))
    }

    /// One tree: deep when hrZ <= -0.5, otherwise wake when motionZ > 1, else light.
    private let forestJSON = """
    {"version":"test-forest","kind":"forest","classes":["wake","light","deep","rem"],
     "featureContract":["hrZ","hrStdZ","motionZ","nightFraction"],
     "trees":[{"f":[0,-1,2,-1,-1],"t":[-0.5,0,1,0,0],"l":[1,-1,3,-1,-1],"r":[2,-1,4,-1,-1],
               "v":[[0,0,0,0],[0,1,9,0],[0,0,0,0],[1,8,1,0],[7,2,1,0]]}],
     "testVectors":[{"inputs":{"hrZ":-1,"hrStdZ":0,"motionZ":0,"nightFraction":0.5},"expected":2},
                    {"inputs":{"hrZ":0,"hrStdZ":0,"motionZ":2,"nightFraction":0.5},"expected":0}]}
    """

    @Test func forestWalksTreesAndAveragesVotes() throws {
        let model = try decode(forestJSON)
        try model.validate()
        #expect(model.contract == .challenger)
        #expect(model.title == "Pod forest")
        let deep = try model.predict(["hrZ": -1, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0.5])
        #expect(deep.classLabel == 2)
        #expect(deep.stage == .deep)
        #expect(abs(deep.probabilities[2]! - 0.9) < 1e-12)
        #expect(try model.predict(["hrZ": 0, "hrStdZ": 0, "motionZ": 2, "nightFraction": 0.5]).stage == .wake)
        #expect(try PortableStageClassifier(model: model).predict(["hrZ": 0, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0.5]).stage == .light)
        #expect(throws: StageChallenger.ModelError.missingInput("nightFraction")) {
            try model.predict(["hrZ": 0, "hrStdZ": 0, "motionZ": 0])
        }
    }

    @Test func validationRefusesBrokenDocuments() throws {
        let wrongVectors = try decode(forestJSON.replacingOccurrences(of: "\"expected\":2", with: "\"expected\":1"))
        #expect(throws: PortableStageModel.ModelError.failedVectors(1)) { try wrongVectors.validate() }
        let backwards = try decode(forestJSON.replacingOccurrences(of: "\"l\":[1,-1,3,-1,-1]", with: "\"l\":[0,-1,3,-1,-1]"))
        #expect(throws: PortableStageModel.ModelError.self) { try backwards.validate() }
        let unknownContract = try decode(forestJSON.replacingOccurrences(of: "\"nightFraction\"]", with: "\"nightFraction\",\"extra\"]"))
        #expect(throws: PortableStageModel.ModelError.self) { try unknownContract.validate() }
        let noTrees = try decode(forestJSON.replacingOccurrences(of: "\"kind\":\"forest\"", with: "\"kind\":\"logistic\""))
        #expect(throws: PortableStageModel.ModelError.self) { try noTrees.validate() }
    }

    @Test func twoClassLogisticUsesOneRow() throws {
        let model = try decode("""
        {"version":"two","kind":"logistic","classes":["wake","light","deep","rem"],
         "featureContract":["hrZ","hrStdZ","motionZ","nightFraction"],
         "logistic":{"mean":[0,0,0,0],"scale":[1,1,1,1],"coef":[[-3,0,0,0]],"intercept":[0],"classIndices":[1,2]},
         "testVectors":[{"inputs":{"hrZ":-1,"hrStdZ":0,"motionZ":0,"nightFraction":0},"expected":2}]}
        """)
        try model.validate()
        #expect(try model.predict(["hrZ": -1, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0]).stage == .deep)
        #expect(try model.predict(["hrZ": 1, "hrStdZ": 0, "motionZ": 0, "nightFraction": 0]).stage == .light)
    }

    /// A logistic model the Mac trained on real nights, replayed over the synthetic night's contract-B rows:
    /// every class must match what the Python evaluator (and hence the pod) produced.
    @Test func macTrainedLogisticMatchesThePythonEvaluatorOnEveryEpoch() throws {
        struct Fixture: Decodable {
            let model: PortableStageModel
            let rows: [[String: Double]]
            let expected: [Int64]
        }
        let url = try #require(Bundle(for: FixtureAnchor.self).url(forResource: "stage-model-logistic", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try fixture.model.validate()
        #expect(fixture.model.contract == .podNative)
        #expect(fixture.model.kind == "logistic")
        #expect(fixture.model.metrics?["lono"]?.nights == 10)
        #expect(fixture.rows.count == fixture.expected.count)
        for (row, expected) in zip(fixture.rows, fixture.expected) {
            #expect(try fixture.model.predict(row).classLabel == expected)
        }
        let response = try JSONDecoder().decode(PodStageModelResponse.self, from: Data("{\"model\":null,\"uploadedAt\":null}".utf8))
        #expect(response.model == nil)
    }
}
