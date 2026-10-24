import Foundation

/// What the update window says in one phase.
///
/// Read from the phase alone, so every sentence and every button the window
/// can show is provable without drawing anything, and the prompt can refuse a
/// press the window never offered.
public struct UpdateWindowContent: Equatable {
    public enum Progress: Equatable {
        case none
        case indeterminate
        case fraction(Double)
    }

    public enum Role: Equatable {
        /// The one thing to do: the monochrome capsule, and Return.
        case primary
        /// The way out beside it, which Escape takes.
        case cancel
        /// An alternative to the primary rather than a way out, drawn at the
        /// row's leading edge where macOS puts one.
        case alternative
    }

    public struct Button: Equatable {
        public let action: UpdatePromptAction
        public let title: String
        public let role: Role
    }

    public let title: String
    public let body: String?
    public let progress: Progress
    /// The line under the progress bar.
    public let status: String?
    /// Leading to trailing, as the row draws them.
    public let buttons: [Button]

    public init(phase: UpdatePromptPhase, installedVersion: String) {
        switch phase {
        case .permission:
            self.init(
                title: ProductStrings[.updateWindowPermissionTitle],
                body: ProductStrings[.updateWindowPermissionBody],
                buttons: [Self.button(.declineChecks, .cancel), Self.button(.allowChecks, .primary)]
            )
        case .checking:
            self.init(
                title: ProductStrings[.updateWindowCheckingTitle],
                progress: .indeterminate,
                buttons: [Self.button(.cancel, .cancel)]
            )
        case .offered(let offer):
            self = Self.offered(offer, installedVersion: installedVersion)
        case .downloading(let received, let expected):
            self.init(
                title: ProductStrings[.updateWindowDownloadingTitle],
                progress: expected.map { .fraction(min(Double(received) / Double($0), 1)) } ?? .indeterminate,
                status: Self.downloaded(received, of: expected),
                buttons: [Self.button(.cancel, .cancel)]
            )
        case .preparing(let fraction):
            self.init(title: ProductStrings[.updateWindowPreparingTitle], progress: .fraction(fraction))
        case .ready:
            self.init(
                title: ProductStrings[.updateWindowReadyTitle],
                body: ProductStrings[.updateWindowReadyBody],
                buttons: [Self.button(.relaunch, .primary)]
            )
        case .installing:
            self.init(
                title: ProductStrings[.updateWindowInstallingTitle],
                body: ProductStrings[.updateWindowInstallingBody],
                progress: .indeterminate
            )
        case .notFound(let reason):
            self = Self.notFound(reason, installedVersion: installedVersion)
        case .installed:
            self.init(title: ProductStrings[.updateWindowInstalledTitle], buttons: [Self.button(.done, .primary)])
        case .failed(let failure):
            self.init(
                title: ProductStrings[.updateWindowFailedTitle],
                body: Self.sentence(for: failure),
                buttons: [Self.button(.done, .primary)]
            )
        }
    }

    private init(
        title: String,
        body: String? = nil,
        progress: Progress = .none,
        status: String? = nil,
        buttons: [Button] = []
    ) {
        precondition(buttons.filter { $0.role == .primary }.count <= 1, "a phase has one primary action at most")

        self.title = title
        self.body = body
        self.progress = progress
        self.status = status
        self.buttons = buttons
    }

    public func offers(_ action: UpdatePromptAction) -> Bool {
        buttons.contains { $0.action == action }
    }

    // MARK: -

    /// A critical update has no Skip (M34 §6): it can wait, and it never
    /// installs by itself, but it cannot be dismissed for good. An
    /// information-only release installs from the website, so its one action
    /// opens that page.
    private static func offered(_ offer: UpdatePromptOffer, installedVersion: String) -> UpdateWindowContent {
        let skip = offer.isCritical ? [] : [button(.skip, .alternative)]
        let later = button(.later, .cancel)
        let body = String(
            format: ProductStrings[offer.isCritical ? .updateWindowCriticalBodyFormat : .updateWindowOfferBodyFormat],
            installedVersion
        )

        if offer.isInformationOnly {
            return UpdateWindowContent(
                title: String(format: ProductStrings[.updateWindowOfferTitleFormat], offer.version),
                body: String(format: ProductStrings[.updateWindowInformationBodyFormat], installedVersion),
                buttons: [later, button(.learnMore, .primary)]
            )
        }

        switch offer.stage {
        case .notDownloaded, .downloaded:
            // A downloaded update still has to be unpacked and made ready
            // before it relaunches, so it is offered as any other is: its
            // Install leads to Ready to install, not straight to a relaunch.
            let title: ProductStringKey = offer.isCritical ? .updateWindowCriticalTitleFormat : .updateWindowOfferTitleFormat
            return UpdateWindowContent(
                title: String(format: ProductStrings[title], offer.version),
                body: body,
                buttons: skip + [later, button(.install, .primary)]
            )
        case .installing:
            // Armed: the app is replaced when it next quits, whatever the
            // answer, and Install relaunches into the new version now.
            return UpdateWindowContent(
                title: String(format: ProductStrings[.updateWindowStagedTitleFormat], offer.version),
                body: ProductStrings[.updateWindowStagedBody],
                buttons: skip + [later, button(.relaunch, .primary)]
            )
        }
    }

    private static func notFound(_ reason: UpdateNotFoundReason, installedVersion: String) -> UpdateWindowContent {
        let done = [button(.done, .primary)]
        let current = ProductStrings[.updateWindowCurrentTitle]
        let unavailable = ProductStrings[.updateWindowUnavailableTitle]

        switch reason {
        case .onLatest:
            return UpdateWindowContent(
                title: current,
                body: String(format: ProductStrings[.updateWindowCurrentLatestFormat], installedVersion),
                buttons: done
            )
        case .newerThanLatest:
            return UpdateWindowContent(title: current, body: ProductStrings[.updateWindowCurrentNewer], buttons: done)
        case .unknown:
            return UpdateWindowContent(title: current, buttons: done)
        case .systemTooOld:
            return UpdateWindowContent(title: unavailable, body: ProductStrings[.updateWindowUnavailableSystemOld], buttons: done)
        case .systemTooNew:
            return UpdateWindowContent(title: unavailable, body: ProductStrings[.updateWindowUnavailableSystemNew], buttons: done)
        case .hardwareUnsupported:
            return UpdateWindowContent(title: unavailable, body: ProductStrings[.updateWindowUnavailableHardware], buttons: done)
        }
    }

    private static func sentence(for failure: UpdateFailure) -> String {
        switch failure {
        case .feedUnreachable: return ProductStrings[.updateWindowFailedFeed]
        case .downloadFailed: return ProductStrings[.updateWindowFailedDownload]
        case .notVerified: return ProductStrings[.updateWindowFailedSignature]
        case .installFailed: return ProductStrings[.updateWindowFailedInstall]
        case .busy: return ProductStrings[.updateWindowFailedBusy]
        case .recoveryPending: return ProductStrings[.updateWindowFailedRecovery]
        case .unownedDaemon: return ProductStrings[.updateWindowFailedUnowned]
        case .notInstallable: return ProductStrings[.updateWindowFailedNotInstallable]
        case .other: return ProductStrings[.updateWindowFailedOther]
        }
    }

    /// `12.4 MB of 132 MB`, or what has arrived where the size is unknown.
    private static func downloaded(_ received: UInt64, of expected: UInt64?) -> String? {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .file
        let got = bytes.string(fromByteCount: Int64(clamping: received))

        guard let expected else {
            return received > 0 ? String(format: ProductStrings[.updateWindowDownloadedFormat], got) : nil
        }

        let total = bytes.string(fromByteCount: Int64(clamping: max(received, expected)))
        return String(format: ProductStrings[.updateWindowDownloadedOfFormat], got, total)
    }

    private static func button(_ action: UpdatePromptAction, _ role: Role) -> Button {
        Button(action: action, title: ProductStrings[title(of: action)], role: role)
    }

    private static func title(of action: UpdatePromptAction) -> ProductStringKey {
        switch action {
        case .allowChecks: return .updateWindowPermissionAllow
        case .declineChecks: return .updateWindowPermissionDecline
        case .install: return .updateWindowInstall
        case .relaunch: return .updateWindowRelaunch
        case .later: return .updateWindowLater
        case .skip: return .updateWindowSkip
        case .learnMore: return .updateWindowLearnMore
        case .cancel: return .updateWindowCancel
        case .done: return .updateWindowDone
        }
    }
}
