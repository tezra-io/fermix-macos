import Foundation
import Testing
@testable import FermixAppCore

@Suite("Native status presentation")
@MainActor
struct NativeStatusPresentationTests {
    @Test("pending restarts use the settings toolbar and preserve the daemon's reasons")
    func pendingRestartUsesToolbar() throws {
        let reasons = try ManagementValueFixture.setupState().restart.reasons
        let state = SettingsBannerState.restart(reasons)

        #expect(!state.showsInlineBanner)
        #expect(state.restartActionTitle == ProductStrings[.settingsRestartAction])
        #expect(state.restartDetail == reasons.map(\.sentence).joined(separator: " "))
    }

    @Test("configuration problems remain visible and do not add a competing restart action")
    func configurationProblemsKeepTheirBanner() {
        let states: [SettingsBannerState] = [.externalChange, .configUnreadable("Invalid setting"), .engineBehindApp]

        for state in states {
            #expect(state.showsInlineBanner)
            #expect(state.restartActionTitle == nil)
        }
        #expect(!SettingsBannerState.none.showsInlineBanner)
        #expect(SettingsBannerState.none.restartActionTitle == nil)
    }

    @Test("the settings restart action opens the existing confirmation sheet")
    func toolbarRestartAsksFirst() throws {
        let harness = try RouterHarness()
        harness.settings.restart = try ManagementValueFixture.setupState().restart
        let control = SettingsRestartControl(model: harness.settings, router: harness.router)

        control.requestRestart()

        #expect(harness.model.restartSheetShown)
        #expect(harness.lifecycle.calls.isEmpty)
        #expect(harness.windows.presented == [.main])
    }

    @Test("restart controls respect configuration and command availability")
    func unavailableRestartDoesNothing() {
        let model = SettingsFixture.model(gateway: FakeDaemonGateway())
        let router = FakeCommandRouter()
        let control = SettingsRestartControl(model: model, router: router)
        control.requestRestart()
        #expect(router.performed.isEmpty)

        model.restart = ManagementRestartState(required: true, reasons: [])
        router.refused.insert(.restartDaemon)
        control.requestRestart()
        #expect(router.performed.isEmpty)
    }

    @Test("the restart sheet retains reasons and explains an engine update without daemon reasons")
    func restartSheetKeepsDetails() throws {
        let model = SettingsFixture.model(gateway: FakeDaemonGateway())
        model.restart = try ManagementValueFixture.setupState().restart
        let pending = RestartSheet(model: model, restart: {}, isFinishingUpdate: false, refusal: nil, dismiss: {})
        #expect(pending.reasonSentences == model.restart.reasons.map(\.sentence))

        model.restart = ManagementRestartState(required: false, reasons: [])
        let updating = RestartSheet(model: model, restart: {}, isFinishingUpdate: true, refusal: nil, dismiss: {})
        #expect(updating.reasonSentences == [ProductStrings[.settingsRequiresNewerEngine]])
        #expect(!SettingsBannerState.finishUpdating.showsInlineBanner)
        #expect(SettingsBannerState.finishUpdating.restartActionTitle != nil)
    }
}
