import AppIntents
import Foundation
import Testing
@testable import FreeSleepKit

@MainActor struct CoreShortcutTests {
    @Test func appInitializationRegistersTheNativeBridgeBeforeAWindowAction() async {
        await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            let intent = SetTemperatureIntent(); intent.temperature = 54
            do { let _: Void = try await intent.callAsFunction(donate: false); Issue.record("Invalid temperature cannot dispatch") }
            catch {
                #expect(!error.localizedDescription.contains("initialize your native actions"))
                #expect(error.localizedDescription.contains("whole temperature") || error.localizedDescription.contains("real sleepypod controller"))
            }
        }
    }
    @Test func coreActionsUseTheRegisteredNativeContractAndChosenSide() async throws {
        let recorded = CoreActionCapture()
        let bridge = NativePodActionBridge { action in recorded.actions.append(action); return .message("Controller acknowledged; physically unverified") }
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            let temperature = SetTemperatureIntent(); temperature.nativeActions = bridge; temperature.side = .right; temperature.temperature = 68
            _ = try await temperature.perform()
            let power = SetPowerIntent(); power.nativeActions = bridge; power.side = .left; power.enabled = false
            _ = try await power.perform()
            let angles = SetBaseAnglesIntent(); angles.nativeActions = bridge; angles.head = 30; angles.feet = 15
            _ = try await angles.perform()
            let preset = SetBasePresetIntent(); preset.nativeActions = bridge; preset.preset = .read
            _ = try await preset.perform()
            let stop = StopBaseIntent(); stop.nativeActions = bridge; _ = try await stop.perform()
            let dismiss = DismissAlarmIntent(); dismiss.nativeActions = bridge; dismiss.side = .right; _ = try await dismiss.perform()
            let away = SetAwayModeIntent(); away.nativeActions = bridge; away.side = .right; away.away = true; _ = try await away.perform()
            let prime = PrimePodIntent(); prime.nativeActions = bridge; _ = try await prime.perform()
            let comfort = SetComfortIntent(); comfort.nativeActions = bridge; comfort.side = .right; comfort.mode = .preview; _ = try await comfort.perform()
            let time = ChangeNextAlarmIntent(); time.nativeActions = bridge; time.side = .left; time.time = "08:00"; _ = try await time.perform()
            let skip = SkipNextAlarmIntent(); skip.nativeActions = bridge; skip.side = .right; _ = try await skip.perform()
            let restore = RestoreAlarmRoutineIntent(); restore.nativeActions = bridge; restore.side = .left; _ = try await restore.perform()
        }
        #expect(recorded.actions == [.temperature(side: "right", value: 68), .power(side: "left", enabled: false), .position(head: 30, feet: 15), .preset("read"),
            .stopBase, .dismissAlarm(side: "right"), .away(side: "right", enabled: true), .prime, .comfort(side: "right", mode: "preview"),
            .changeAlarm(side: "left", action: "time", time: "08:00"), .changeAlarm(side: "right", action: "skip", time: nil), .changeAlarm(side: "left", action: "restore", time: nil)])
    }
    @Test func readsReturnComposableValuesAndRejectUnexpectedReplyTypes() async throws {
        let recorded = CoreActionCapture()
        let bridge = NativePodActionBridge { action in
            recorded.actions.append(action)
            if case .readTemperature = action { return .number(68.5) }
            return .message("Right side · Europe/London. Skipped once; following routine alarm tomorrow.")
        }
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            let temperature = GetTemperatureIntent(); temperature.nativeActions = bridge; temperature.side = .right; temperature.reading = .target
            let reading = try await temperature.perform().value
            #expect(reading == 68.5)
            let alarm = GetNextAlarmIntent(); alarm.nativeActions = bridge; alarm.side = .right
            let summary = try await alarm.perform().value
            #expect(summary?.contains("Europe/London") == true)
            temperature.nativeActions = .init { _ in .message("Wrong type") }
            do { _ = try await temperature.perform(); Issue.record("A missing reading cannot be zero") } catch {}
        }
        #expect(recorded.actions == [.readTemperature(side: "right", current: false), .nextAlarm(side: "right")])
    }
    @Test func healthShortcutUsesTheRegisteredWriterAndPreservesErrors() async throws {
        let recorded = CoreActionCapture()
        try await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            let intent = SyncHealthIntent()
            intent.nativeActions = .init { action in recorded.actions.append(action); return .healthSamples(17) }
            let count = try await intent.perform().value
            #expect(count == 17)
            intent.nativeActions = .init { _ in throw PodError.message("Consent changed") }
            do { _ = try await intent.perform(); Issue.record("A failed sync cannot become zero or success") }
            catch { #expect(error.localizedDescription == "Consent changed") }
        }
        #expect(recorded.actions == [.syncHealth])
    }
    @Test func demoCancellationAndNativeErrorsCannotBecomeSuccessOrRetry() async throws {
        let recorded = CoreActionCapture(), bridge = NativePodActionBridge { action in recorded.actions.append(action); throw PodError.message("Uncertain receipt") }
        await AppMode.$suppliedBackend.withValue("sleepypod-core") {
            let stop = StopBaseIntent(); stop.nativeActions = bridge
            do { _ = try await stop.perform(); Issue.record("Native failure must surface") } catch { #expect(error.localizedDescription == "Uncertain receipt") }
            let operation = Task { try Task.checkCancellation(); _ = try await stop.perform() }
            operation.cancel(); do { try await operation.value; Issue.record("Cancelled action cannot dispatch") } catch {}
        }
        await AppMode.$suppliedBackend.withValue("demo") {
            do { _ = try await bridge.perform(.stopBase); Issue.record("Demo cannot dispatch") } catch {}
        }
        #expect(recorded.actions == [.stopBase])
    }
}
@MainActor private final class CoreActionCapture { var actions: [NativePodAction] = [] }
