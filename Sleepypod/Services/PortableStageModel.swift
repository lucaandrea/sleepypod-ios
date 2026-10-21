import Foundation

/// A personal stage model in the pod's portable form: a random forest as plain trees or a logistic regression as
/// weights, trained on a Mac (sleepypod-core `scripts/train-personal-models.py`) and stored on the pod. The phone
/// evaluates it directly, so a model trained in seconds on a Mac stages nights here without Core ML or on-device
/// training. The document is the one sleepypod-core `personal-stage-model.ts` validates; the feature contract and
/// test vectors are the same, so the pod, the web and the phone must agree on every epoch.
struct PortableStageModel: Codable, Sendable, Equatable {
    struct Tree: Codable, Sendable, Equatable {
        /// Split feature index per node, -1 for a leaf.
        let f: [Int]
        let t: [Double]
        let l: [Int]
        let r: [Int]
        /// Leaf class votes, four per node, in StageScore order.
        let v: [[Double]]
    }
    struct Logistic: Codable, Sendable, Equatable {
        let mean: [Double]
        let scale: [Double]
        let coef: [[Double]]
        let intercept: [Double]
        let classIndices: [Int]
    }
    struct TestVector: Codable, Sendable, Equatable {
        let inputs: [String: Double]
        let expected: Int64
    }
    struct Evaluation: Codable, Sendable, Equatable {
        let epochs: Int?
        let kappa: Double?
        let accuracy: Double?
        let nights: Int?
    }

    let version: String
    let kind: String
    let featureContract: [String]
    let trees: [Tree]?
    let logistic: Logistic?
    let hyperparameters: [String: Double]?
    let metrics: [String: Evaluation]?
    let trainedAt: String?
    let source: String?
    let testVectors: [TestVector]

    enum ModelError: Error, LocalizedError, Equatable {
        case malformed(String)
        case failedVectors(Int)

        var errorDescription: String? {
            switch self {
            case .malformed(let reason): "The pod's model is malformed: \(reason)"
            case .failedVectors(let count): "The pod's model fails \(count) of its own test vectors"
            }
        }
    }

    var contract: StageFeatures.Contract? { StageFeatures.Contract.matching(featureContract) }
    var title: String { kind == "logistic" ? "Pod logistic" : "Pod forest" }

    /// Structural checks the pod also makes, so a document that slipped past it is still refused here.
    func validate() throws {
        guard contract != nil else { throw ModelError.malformed("unknown feature contract \(featureContract.joined(separator: ","))") }
        let n = featureContract.count
        switch kind {
        case "forest":
            guard let trees, !trees.isEmpty else { throw ModelError.malformed("a forest needs trees") }
            for tree in trees {
                let count = tree.f.count
                guard count > 0, tree.t.count == count, tree.l.count == count, tree.r.count == count, tree.v.count == count else {
                    throw ModelError.malformed("tree arrays differ in length")
                }
                for i in 0..<count {
                    if tree.f[i] >= 0 {
                        guard tree.f[i] < n, tree.l[i] > i, tree.l[i] < count, tree.r[i] > i, tree.r[i] < count else {
                            throw ModelError.malformed("node \(i) is inconsistent")
                        }
                    }
                    guard tree.v[i].count == 4 else { throw ModelError.malformed("leaf votes must have four classes") }
                }
            }
        case "logistic":
            guard let lr = logistic else { throw ModelError.malformed("a logistic model needs weights") }
            let rows = lr.classIndices.count == 2 ? 1 : lr.classIndices.count
            guard lr.mean.count == n, lr.scale.count == n, lr.coef.count == rows, lr.coef.allSatisfy({ $0.count == n }),
                  lr.intercept.count == rows, lr.classIndices.allSatisfy({ (0..<4).contains($0) }) else {
                throw ModelError.malformed("logistic weights do not match the contract and classes")
            }
        default:
            throw ModelError.malformed("unknown kind \(kind)")
        }
        guard !testVectors.isEmpty else { throw ModelError.malformed("no test vectors") }
        let failing = failingVectors()
        if !failing.isEmpty { throw ModelError.failedVectors(failing.count) }
    }

    func failingVectors() -> [Int] {
        testVectors.indices.filter { (try? predict(testVectors[$0].inputs).classLabel) != testVectors[$0].expected }
    }

    /// One epoch's named inputs in, a class and per-class probabilities out, as the pod computes them.
    func predict(_ values: [String: Double]) throws -> StageChallenger.Prediction {
        let x = try featureContract.map { column -> Double in
            guard let v = values[column], v.isFinite else { throw StageChallenger.ModelError.missingInput(column) }
            return v
        }
        var probabilities = [Double](repeating: 0, count: 4)
        if kind == "forest" {
            let trees = self.trees ?? []
            for tree in trees {
                var node = 0
                while tree.f[node] >= 0 { node = x[tree.f[node]] <= tree.t[node] ? tree.l[node] : tree.r[node] }
                let votes = tree.v[node]
                let total = votes.reduce(0, +)
                for c in 0..<4 { probabilities[c] += total > 0 ? votes[c] / total : 0.25 }
            }
            let count = Double(max(trees.count, 1))
            probabilities = probabilities.map { $0 / count }
        } else if let lr = logistic {
            var zed = [Double](repeating: 0, count: x.count)
            for i in x.indices where lr.scale[i] != 0 { zed[i] = (x[i] - lr.mean[i]) / lr.scale[i] }
            var scores = [Double](repeating: 0, count: lr.coef.count)
            for k in lr.coef.indices {
                var sum = lr.intercept[k]
                for i in zed.indices { sum += lr.coef[k][i] * zed[i] }
                scores[k] = sum
            }
            if lr.classIndices.count == 2 {
                let p = 1 / (1 + exp(-scores[0]))
                probabilities[lr.classIndices[1]] = p
                probabilities[lr.classIndices[0]] = 1 - p
            } else {
                let top = scores.max() ?? 0
                let exps = scores.map { exp($0 - top) }
                let total = exps.reduce(0, +)
                for (k, c) in lr.classIndices.enumerated() { probabilities[c] = exps[k] / total }
            }
        } else {
            throw StageChallenger.ModelError.missingOutput("weights")
        }
        var best = 0
        for c in 1..<4 where probabilities[c] > probabilities[best] { best = c }
        var byClass: [Int64: Double] = [:]
        for (index, p) in probabilities.enumerated() { byClass[Int64(index)] = p }
        return StageChallenger.Prediction(classLabel: Int64(best), probabilities: byClass)
    }
}

/// The portable model as a stage classifier, so the comparison lanes, the analyzer and Health sync use it like any other.
struct PortableStageClassifier: SleepStageClassifying {
    let model: PortableStageModel
    func predict(_ features: [String: Double]) throws -> StageChallenger.Prediction { try model.predict(features) }
}

/// What the pod returns for `sleepStages.getModel`.
struct PodStageModelResponse: Decodable, Sendable {
    let model: PortableStageModel?
    let uploadedAt: Double?
    /// Whether the pod itself stages the side's nights with this model. Pods before the switch omit it.
    let active: Bool?

    init(model: PortableStageModel?, uploadedAt: Double?, active: Bool? = nil) {
        self.model = model
        self.uploadedAt = uploadedAt
        self.active = active
    }
}
