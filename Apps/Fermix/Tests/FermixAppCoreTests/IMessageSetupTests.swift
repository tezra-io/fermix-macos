import Foundation
import Testing

@testable import FermixAppCore

/// The owner's iMessage flow on the Mac (M54 §10): turning the switch on
/// installs Fermix Messages first, Permissions carries the helper's three rows,
/// and the Channels row names the first thing still missing.
///
/// Every probe is the contract's own `imessage_permissions_get` golden with
/// fields replaced, so a case varies what the helper reports and never the
/// shape the engine sends.
@Suite("iMessage setup")
@MainActor
struct IMessageSetupTests {

    // MARK: - The Channels row's status

    /// The order is the order a person fixes them in (M54 §10.1), so each fix
    /// walks the row to the next gap and the last one reads Connected.
    @Test("the status names the first missing thing, in the order a person fixes them")
    func statusWalksTheGapsInOrder() throws {
        let steps: [([String: Any], ProductStringKey)] = [
            (Self.notInstalled, .channelStatusHelperNotInstalled),
            (["full_disk_access": "denied", "db": "unreadable", "automation": "denied", "policy": "absent",
              "policy_matches_config": false, "signed_in": NSNull(), "user_session": false],
             .channelStatusNeedsFullDiskAccess),
            (["db": "unreadable", "automation": "denied", "policy": "absent", "policy_matches_config": false,
              "signed_in": NSNull(), "user_session": false],
             .channelStatusMessagesDataUnreadable),
            (["automation": "not_determined", "policy": "absent", "policy_matches_config": false,
              "signed_in": NSNull(), "user_session": false],
             .channelStatusNeedsMessagesAutomation),
            (["policy": "unconfirmed", "policy_matches_config": false, "signed_in": false, "user_session": false],
             .channelStatusAwaitingConfirmation),
            (["signed_in": false, "user_session": false], .channelStatusMessagesNotSignedIn),
            (["user_session": false], .channelStatusNeedsUserSession),
            ([:], .channelStatusConnected)
        ]

        for (changes, expected) in steps {
            let probe = try ManagementValueFixture.imessagePermissions(changes)

            #expect(
                IMessageChannelStatus.status(.loaded(probe), refusal: nil) == ProductStrings[expected],
                "\(changes) should read \(expected.rawValue)"
            )
        }
    }

    /// A policy the helper confirmed for other recipients than the saved ones
    /// is the daemon's "Awaiting confirmation", not Connected.
    @Test("a confirmed policy that no longer matches the settings awaits confirmation")
    func mismatchedPolicyAwaitsConfirmation() throws {
        let probe = try ManagementValueFixture.imessagePermissions(["policy_matches_config": false])

        #expect(IMessageChannelStatus.firstGap(in: probe) == .confirmation)
        #expect(
            IMessageChannelStatus.status(.loaded(probe), refusal: nil)
                == ProductStrings[.channelStatusAwaitingConfirmation]
        )
    }

    /// A confirmation the daemon refused, such as an owner that is this Mac's
    /// own address, is shown in the daemon's own sentence where "Awaiting
    /// confirmation" would stand, and never over an earlier gap.
    @Test("a refused confirmation shows the daemon's sentence at the confirmation step only")
    func refusalReplacesAwaitingConfirmation() throws {
        let unconfirmed = try ManagementValueFixture.imessagePermissions(["policy": "unconfirmed"])
        let noAccess = try ManagementValueFixture.imessagePermissions([
            "full_disk_access": "denied", "policy": "unconfirmed"
        ])

        #expect(IMessageChannelStatus.status(.loaded(unconfirmed), refusal: Self.ownerIsThisMac) == Self.ownerIsThisMac)
        #expect(
            IMessageChannelStatus.status(.loaded(noAccess), refusal: Self.ownerIsThisMac)
                == ProductStrings[.channelStatusNeedsFullDiskAccess]
        )
        #expect(
            IMessageChannelStatus.status(.loaded(try Self.golden()), refusal: Self.ownerIsThisMac)
                == ProductStrings[.channelStatusConnected],
            "a refusal the helper has since moved past is not a gap"
        )
    }

    /// Without an answer the row claims nothing: it says it is checking, or
    /// carries the daemon's own sentence for why the probe could not run.
    @Test("a probe with no answer is never Connected")
    func noAnswerIsNeverConnected() {
        #expect(IMessageChannelStatus.status(.unread, refusal: nil) == ProductStrings[.channelStatusChecking])
        #expect(IMessageChannelStatus.status(.loading, refusal: nil) == ProductStrings[.channelStatusChecking])
        #expect(IMessageChannelStatus.status(.unavailable("The probe could not run."), refusal: nil) == "The probe could not run.")
    }

    /// The probe is the single source (M54 §10.1): `configured` decides nothing
    /// for this row, the switch still decides Off, and every other channel keeps
    /// its own status words.
    @Test("the iMessage row reads the probe, not configured")
    func rowReadsTheProbe() throws {
        let notInstalled = IMessageChannelFacts(
            probe: .loaded(try ManagementValueFixture.imessagePermissions(Self.notInstalled)),
            refusal: nil
        )
        let ready = IMessageChannelFacts(probe: .loaded(try Self.golden()), refusal: nil)

        let configured = try Self.channel("imessage", enabled: true, configured: true)
        let unconfigured = try Self.channel("imessage", enabled: true, configured: false)
        let off = try Self.channel("imessage", enabled: false, configured: true)
        let telegram = try Self.channel("telegram", enabled: true, configured: true)

        #expect(
            ChannelRowProjection.status(of: configured, imessage: notInstalled)
                == ProductStrings[.channelStatusHelperNotInstalled]
        )
        #expect(ChannelRowProjection.status(of: unconfigured, imessage: ready) == ProductStrings[.channelStatusConnected])
        #expect(ChannelRowProjection.status(of: off, imessage: ready) == ProductStrings[.channelStatusOff])
        #expect(ChannelRowProjection.status(of: telegram, imessage: notInstalled) == ProductStrings[.channelStatusConnected])

        let rows = ChannelRowProjection.rows([configured, telegram], titledBy: [], imessage: notInstalled)
        #expect(rows.first { $0.name == "imessage" }?.status == ProductStrings[.channelStatusHelperNotInstalled])
    }

    // MARK: - Turning it on installs first

    @Test("the switch installs first exactly when the probe has not said the helper is there")
    func installDecision() throws {
        #expect(IMessageEnable.installsFirst(.loaded(try ManagementValueFixture.imessagePermissions(Self.notInstalled))))
        #expect(!IMessageEnable.installsFirst(.loaded(try Self.golden())))
        #expect(IMessageEnable.installsFirst(.unavailable("The probe could not run.")))
        #expect(IMessageEnable.installsFirst(.unread))
    }

    /// The order is the whole point: the channel turned on over a helper that
    /// is not there is a switch that reads on and receives nothing.
    @Test("turning it on with no helper installs Fermix Messages, then writes")
    func enableInstallsBeforeItWrites() async throws {
        let gateway = try SettingsFixture.gateway()
        gateway.imessagePermissionsScript = [
            try ManagementValueFixture.imessagePermissions(Self.notInstalled),
            try Self.golden()
        ]
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()

        await model.setIMessageEnabled(true, on: runner)

        let install = try #require(gateway.calls.firstIndex(of: .v2(.capabilitiesInstallStart)))
        let write = try #require(gateway.calls.firstIndex(of: .v2(.settingsApply)))
        #expect(install < write, "the write went out before the helper was there")
        #expect(gateway.installedTargets == [.imessageHelper])
        #expect(runner.completed)
        #expect(gateway.appliedSettings == [Self.enableWrite(true)])
        #expect(model.permissions.imessage.value?.installed == true, "the probe is read again once the helper is there")
    }

    @Test("turning it on with the helper installed writes without installing")
    func enableWithHelperWritesDirectly() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        await model.setIMessageEnabled(true, on: model.makeJobRunner())

        #expect(gateway.calls.contains(.v2(.imessagePermissionsGet)), "the decision is the probe's")
        #expect(!gateway.calls.contains(.v2(.capabilitiesInstallStart)))
        #expect(gateway.appliedSettings == [Self.enableWrite(true)])
    }

    /// A failed install writes nothing: the switch stays off and the daemon's
    /// sentence stands under it.
    @Test("a failed install leaves the switch off with the daemon's sentence")
    func aFailedInstallNeverWrites() async throws {
        let gateway = try SettingsFixture.gateway()
        gateway.imessagePermissionsScript = [try ManagementValueFixture.imessagePermissions(Self.notInstalled)]
        gateway.jobScript = [
            try ManagementValueFixture.job(
                kind: "capability_install",
                status: "failed",
                phase: "verifying",
                failure: (code: "refused", sentence: "The helper's signature did not verify.")
            )
        ]
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()

        await model.setIMessageEnabled(true, on: runner)

        #expect(gateway.appliedSettings.isEmpty, "the channel was turned on over a failed install")
        #expect(runner.failure == "The helper's signature did not verify.")
        #expect(!runner.completed)
        #expect(model.drafts[Self.enableKey] == nil, "the switch stays where the daemon has it")
    }

    @Test("turning it off writes directly and asks the helper nothing")
    func disableWritesDirectly() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)

        await model.setIMessageEnabled(false, on: model.makeJobRunner())

        #expect(!gateway.calls.contains(.v2(.imessagePermissionsGet)))
        #expect(!gateway.calls.contains(.v2(.capabilitiesInstallStart)))
        #expect(gateway.appliedSettings == [Self.enableWrite(false)])
    }

    // MARK: - The three Permissions rows

    @Test("a fully granted helper reads granted, confirmed, and offers nothing")
    func grantedRows() throws {
        let rows = IMessageRights.rows(try Self.golden())

        #expect(rows.map(\.right) == [.messagesData, .messagesAutomation, .messagesRecipients])
        #expect(rows.allSatisfy { $0.state == .granted && $0.action == nil })
        #expect(rows.allSatisfy { $0.principal == ProductStrings[.permissionPrincipalMessages] })
        #expect(rows.last?.stateWord == ProductStrings[.permissionStateConfirmed])
    }

    /// Each row offers the one act that clears it: the grant job where the
    /// helper can ask, the System Settings pane where macOS no longer will, and
    /// the confirmation where the recipients wait.
    @Test("each missing right offers the act that clears it")
    func missingRights() throws {
        let probe = try ManagementValueFixture.imessagePermissions([
            "full_disk_access": "denied", "automation": "not_determined", "policy": "unconfirmed",
            "policy_matches_config": false
        ])
        let rows = IMessageRights.rows(probe)

        #expect(rows[0].state == .notGranted)
        #expect(rows[0].action == .grantIMessage(.fullDiskAccess))
        #expect(rows[1].state == .unknown, "Automation has not been asked yet")
        #expect(rows[1].action == .grantIMessage(.automation))
        #expect(rows[2].stateWord == ProductStrings[.permissionStateAwaitingConfirmation])
        #expect(rows[2].action == .confirmIMessageRecipients)
    }

    /// macOS raises the Automation prompt once, so a denial is cleared in
    /// System Settings rather than by asking again.
    @Test("denied automation opens its System Settings pane")
    func deniedAutomationDeepLinks() throws {
        let rows = IMessageRights.rows(try ManagementValueFixture.imessagePermissions(["automation": "denied"]))

        #expect(rows[1].state == .notGranted)
        #expect(rows[1].action == .openSystemSettings(PermissionLedger.automationPane))
        #expect(PermissionLedger.automationPane == "com.apple.preference.security?Privacy_Automation")
        #expect(PermissionLedger.fullDiskAccessPane == "com.apple.preference.security?Privacy_AllFiles")
    }

    @Test("a mismatched policy awaits confirmation on its row")
    func mismatchedPolicyRow() throws {
        let rows = IMessageRights.rows(try ManagementValueFixture.imessagePermissions(["policy_matches_config": false]))

        #expect(rows[2].state == .notGranted)
        #expect(rows[2].stateWord == ProductStrings[.permissionStateAwaitingConfirmation])
        #expect(rows[2].action == .confirmIMessageRecipients)
    }

    /// With the helper absent nothing can be granted to it: the two rights
    /// deep-link as the computer-use rows do, and there is no record to confirm.
    @Test("a helper that is not installed is offered no job")
    func notInstalledRows() throws {
        let rows = IMessageRights.rows(try ManagementValueFixture.imessagePermissions(Self.notInstalled))

        #expect(rows[0].state == .unknown)
        #expect(rows[0].action == .openSystemSettings(PermissionLedger.fullDiskAccessPane))
        #expect(rows[1].action == .openSystemSettings(PermissionLedger.automationPane))
        #expect(rows[2].stateWord == ProductStrings[.permissionStateAwaitingConfirmation])
        #expect(rows[2].action == nil)
    }

    @Test("before the probe answers the rows are unknown and offer nothing")
    func unansweredRows() {
        let rows = IMessageRights.rows(nil)

        #expect(rows.allSatisfy { $0.state == .unknown && $0.action == nil })
    }

    /// A Mac that never used iMessage sees nothing new.
    @Test("the rows show only once the channel is on or its helper is installed")
    func rowVisibility() throws {
        let ledger = SettingsFixture.model(gateway: try SettingsFixture.gateway()).permissions
        let off = try Self.channel("imessage", enabled: false, configured: false)
        let on = try Self.channel("imessage", enabled: true, configured: false)
        let absent = try ManagementValueFixture.imessagePermissions(Self.notInstalled)

        #expect(!PermissionVisibility.showsMessages(channels: [off], probe: absent))
        #expect(!PermissionVisibility.showsMessages(channels: [], probe: nil))
        #expect(PermissionVisibility.showsMessages(channels: [on], probe: absent))
        #expect(PermissionVisibility.showsMessages(channels: [off], probe: try Self.golden()))

        let hidden = PermissionVisibility.rights(ledger.rows, requiresNewerEngine: false, showsMessages: false)
        #expect(hidden.allSatisfy { !$0.right.isMessages })
        #expect(hidden.contains { $0.right == .screenRecording }, "the computer-use rows are untouched")
        let shown = PermissionVisibility.rights(ledger.rows, requiresNewerEngine: false, showsMessages: true)
        #expect(shown.filter(\.right.isMessages).count == 3)
        let behind = PermissionVisibility.rights(ledger.rows, requiresNewerEngine: true, showsMessages: true)
        #expect(behind.allSatisfy { !$0.right.isMessages }, "a daemon that cannot answer draws none of its rows")
    }

    // MARK: - Reading and re-reading the probe

    /// The probe runs only against a daemon that publishes the channel, so an
    /// engine without it is never asked for a method it does not have.
    @Test("the probe is read only where the daemon publishes the channel")
    func probeOnlyWherePublished() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let golden = try Self.golden()

        await model.refreshIMessagePermissions()
        #expect(!gateway.calls.contains(.v2(.imessagePermissionsGet)), "nothing says the channel exists yet")

        await model.refreshSetupState()
        await model.refreshIMessagePermissions()
        #expect(gateway.calls.contains(.v2(.imessagePermissionsGet)))
        #expect(model.permissions.imessage.value == golden)
        #expect(model.permissions.row(.messagesData)?.state == .granted)
    }

    /// A grant waits on a person, and its end is what changes the rows, so the
    /// owner of the run re-reads the probe when it ends.
    @Test("a grant asks for its service and re-reads the probe when it ends")
    func grantReprobes() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()

        await model.startIMessageGrant(.fullDiskAccess, on: runner)

        #expect(gateway.imessageGrantServices == [.fullDiskAccess])
        let started = try #require(gateway.calls.firstIndex(of: .v2(.imessageGrantStart)))
        let reread = try #require(gateway.calls.lastIndex(of: .v2(.imessagePermissionsGet)))
        #expect(started < reread)
    }

    /// The owner pressing Confirm on a Mac signed in as their own address is a
    /// refusal with the daemon's sentence, and that sentence reaches the
    /// Channels row.
    @Test("a refused confirmation is the Channels row's status")
    func refusedConfirmationReachesTheRow() async throws {
        let gateway = try SettingsFixture.gateway()
        gateway.imessagePermissionsScript = [try ManagementValueFixture.imessagePermissions(["policy": "unconfirmed"])]
        gateway.imessageJobStarted = try ManagementValueFixture.job(
            id: "job:confirm-1", kind: "imessage_policy_confirm", status: "running", phase: nil
        )
        gateway.jobScript = [
            try ManagementValueFixture.job(
                id: "job:confirm-1",
                kind: "imessage_policy_confirm",
                status: "failed",
                phase: nil,
                failure: (code: "refused", sentence: Self.ownerIsThisMac)
            )
        ]
        let model = SettingsFixture.model(gateway: gateway)
        let runner = model.makeJobRunner()

        await model.confirmIMessageRecipients(on: runner)

        #expect(gateway.calls.contains(.v2(.imessagePolicyConfirm)))
        #expect(model.permissions.imessageRefusal == Self.ownerIsThisMac)
        #expect(runner.failure == Self.ownerIsThisMac)
        let facts = IMessageChannelFacts(probe: model.permissions.imessage, refusal: model.permissions.imessageRefusal)
        let row = try Self.channel("imessage", enabled: true, configured: true)
        #expect(ChannelRowProjection.status(of: row, imessage: facts) == Self.ownerIsThisMac)
    }

    /// A confirmation that completes clears an earlier refusal, whatever the
    /// owner decided in the helper's dialog.
    @Test("a completed confirmation clears an earlier refusal")
    func completedConfirmationClearsTheRefusal() async throws {
        let gateway = try SettingsFixture.gateway()
        let model = SettingsFixture.model(gateway: gateway)
        let refused = try ManagementValueFixture.job(
            kind: "imessage_policy_confirm",
            status: "failed",
            phase: nil,
            failure: (code: "refused", sentence: Self.ownerIsThisMac)
        )
        model.permissions.noteIMessageConfirmation(refused)
        #expect(model.permissions.imessageRefusal == Self.ownerIsThisMac)

        await model.confirmIMessageRecipients(on: model.makeJobRunner())

        #expect(model.permissions.imessageRefusal == nil)
        let reread = try #require(gateway.calls.lastIndex(of: .v2(.imessagePermissionsGet)))
        #expect(try #require(gateway.calls.firstIndex(of: .v2(.imessagePolicyConfirm))) < reread)
    }

    /// A timeout is not a refusal: the job row carries its sentence and the
    /// Channels row keeps reading "Awaiting confirmation".
    @Test("only a refusal becomes the status")
    func onlyRefusalsBecomeTheStatus() throws {
        let ledger = SettingsFixture.model(gateway: try SettingsFixture.gateway()).permissions
        let timedOut = try ManagementValueFixture.job(
            kind: "imessage_policy_confirm",
            status: "failed",
            phase: nil,
            failure: (code: "unavailable", sentence: "Nobody answered in time. Try again when you are at the Mac.")
        )

        ledger.noteIMessageConfirmation(timedOut)

        #expect(ledger.imessageRefusal == nil)
    }

    // MARK: - Fixtures

    static let ownerIsThisMac =
        "Messages on this Mac is signed in as this address. Sign Messages in with a separate Apple ID for Fermix, then confirm again."

    /// The schema's not-installed shape: every field but `installed` is null.
    static let notInstalled: [String: Any] = [
        "installed": false, "helper_version": NSNull(), "full_disk_access": NSNull(), "db": NSNull(),
        "automation": NSNull(), "messages_running": NSNull(), "signed_in": NSNull(), "user_session": NSNull(),
        "policy": NSNull(), "policy_matches_config": NSNull(), "probed_at": NSNull()
    ]

    static var enableKey: SettingsDraftKey {
        SettingsDraftKey(
            section: ChannelRowProjection.sectionId(for: IMessageChannelStatus.channel),
            key: ChannelRowProjection.enabledKey(for: IMessageChannelStatus.channel)
        )
    }

    static func enableWrite(_ isOn: Bool) -> SettingsWrite {
        SettingsWrite(section: enableKey.section, values: [enableKey.key: .flag(isOn)])
    }

    static func golden() throws -> ManagementIMessagePermissions {
        try ManagementValueFixture.imessagePermissions([:])
    }

    static func channel(_ name: String, enabled: Bool, configured: Bool) throws -> ManagementSetupChannel {
        try ManagementValueFixture.decode(
            """
            {"name": "\(name)", "enabled": \(enabled), "configured": \(configured), "status": null, "mode": null}
            """,
            as: ManagementSetupChannel.self
        )
    }
}

extension ManagementValueFixture {
    /// The golden `imessage.permissions.get` answer with some fields replaced.
    ///
    /// Built by editing the published record rather than by writing a probe in
    /// Swift, so every field a case does not vary is the one the engine sends,
    /// and a field the record does not carry is refused rather than added.
    static func imessagePermissions(_ changes: [String: Any]) throws -> ManagementIMessagePermissions {
        let fixture = try #require(
            try ManagementFixtures.load(.success, from: .management).first { $0.name == "imessage_permissions_get" }
        )
        var body = try #require(try fixture.object("response")["result"] as? [String: Any])
        for (key, value) in changes {
            try #require(body[key] != nil, "\(key) is not a field of the probe")
            body[key] = value
        }

        return try JSONDecoder().decode(
            ManagementIMessagePermissions.self,
            from: try JSONSerialization.data(withJSONObject: body)
        )
    }
}
