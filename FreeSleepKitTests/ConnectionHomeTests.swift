import Foundation
import HomeKit
import Testing
@testable import FreeSleepKit

struct ConnectionHomeTests {
    @Test func originsAreCanonicalAndLocalHTTPRequiresAnActualPrivateAddress() throws {
        #expect(try ConnectionEndpoint.url(" HTTPS://POD.EXAMPLE:443/ ").absoluteString == "https://pod.example")
        for address in ["http://192.168.1.4:3000", "http://172.31.0.4", "http://10.1.2.3", "http://pod.local"] {
            #expect(throws: Never.self) { _ = try ConnectionEndpoint.url(address) }
        }
        for address in ["", "http://remote.example", "http://10.evil.0.0.1", "http://10..0.0.1", "http://172.32.0.4", "https://user:secret@pod.example",
                        "https://pod.example/api", "https://pod.example/%2F", "https://pod.example?token=secret", "https://pod.example#secret", "file:///tmp/x"] {
            #expect(throws: (any Error).self) { _ = try ConnectionEndpoint.url(address) }
        }
    }
    @MainActor @Test func demoSetupNeverReadsWritesOrProbesRealConnection() async {
        var reads = 0; var writes = 0; var probes = 0
        let setup = ConnectionSetup(demo: true) { reads += 1; return .init(address: "https://owner.example", token: "private") }
        #expect(reads == 0); #expect(setup.token.isEmpty)
        await setup.check { _ in probes += 1; return .demo }
        setup.save { _ in writes += 1 }
        #expect(probes == 0); #expect(writes == 0); #expect(setup.result == .demo)
        #expect(setup.message?.contains("unchanged") == true)
    }
    @MainActor @Test func editingCredentialsRetiresVerificationAndLateResultsCannotPublish() async {
        let setup = ConnectionSetup(demo: false) { .init(address: "https://first.example/", token: "old") }
        await setup.check { input in
            #expect(input.address == "https://first.example"); return .demo
        }
        #expect(setup.result == .demo)
        setup.address = "https://second.example"
        #expect(setup.token.isEmpty); #expect(setup.result == nil)
        setup.token = " new "
        await setup.check { input in
            #expect(input.token == "new"); setup.invalidate(); return .demo
        }
        #expect(setup.result == nil); #expect(!setup.testing)
        var persisted: ConnectionInput?
        setup.save { persisted = $0 }
        #expect(persisted == .init(address: "https://second.example", token: "new"))
        setup.save { _ in throw PodError.message("Keychain unavailable") }
        #expect(setup.failure == "Keychain unavailable"); #expect(setup.message == nil)
    }
    @Test func homeAccessDistinguishesPermissionLoadingAndEmptyHomes() {
        #expect(HomeAccessState.resolve([], loaded: false, homeCount: 0) == .waiting)
        #expect(HomeAccessState.resolve(.determined, loaded: false, homeCount: 0) == .denied)
        #expect(HomeAccessState.resolve(.restricted, loaded: true, homeCount: 1) == .restricted)
        #expect(HomeAccessState.resolve(.authorized, loaded: false, homeCount: 0) == .loading)
        #expect(HomeAccessState.resolve(.authorized, loaded: true, homeCount: 0) == .empty)
        #expect(HomeAccessState.resolve(.authorized, loaded: true, homeCount: 1) == .ready)
    }
    @MainActor @Test func sceneExecutionRejectsDuplicateActionsAndReportsFailure() async {
        let execution = HomeSceneExecution(); var calls = 0; let identifier = UUID()
        await execution.run(id: identifier, name: "Test scene") {
            calls += 1
            await execution.run(id: identifier, name: "Duplicate") { calls += 1 }
            #expect(execution.runningID == identifier)
        }
        #expect(calls == 1); #expect(execution.runningID == nil); #expect(execution.message == "Ran Test scene.")
        await execution.run(id: identifier, name: "Fail") { throw PodError.message("Accessory offline") }
        #expect(execution.failed); #expect(execution.message == "Accessory offline"); #expect(execution.runningID == nil)
    }
}
