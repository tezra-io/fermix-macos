import SwiftUI

/// Why the section cannot list the logins. Three causes, each with its own
/// sentence, because each asks for something different of the owner.
enum LoginsUnavailable: Equatable, Sendable {
    /// This build has no store: a dev or ad-hoc build without the access group.
    case noStore
    /// The keychain refused, with its `OSStatus`.
    case refused(status: Int32)
    /// The keychain did not answer within the store's bound.
    case timedOut

    /// The cause a store error names, or nil for a refusal of what was typed.
    init?(_ error: LoginStoreError) {
        switch error {
        case .unavailable(status: nil): self = .noStore
        case .unavailable(status: let status?): self = .refused(status: status)
        case .timedOut: self = .timedOut
        case .site, .siteTaken, .usernameRequired, .passwordTooShort, .full, .notFound: return nil
        }
    }

    var sentence: String {
        switch self {
        case .noStore:
            return ProductStrings[.settingsBrowserLoginsUnavailable]
        case .refused(let status):
            return String(format: ProductStrings[.settingsBrowserLoginStoreUnavailable], String(status))
        case .timedOut:
            return ProductStrings[.settingsBrowserLoginStoreTimedOut]
        }
    }
}

/// What the section draws.
enum WebsiteLoginsState: Equatable, Sendable {
    /// Before the store's first answer.
    case loading
    case listed([SavedLogin])
    case unavailable(LoginsUnavailable)
}

/// The website logins, as Settings shows and changes them (M84 §11).
///
/// It holds the one store the composition built, passed in, and nothing
/// else: no daemon, no log. It reads attributes only; the one call that reads
/// a password is the browser host's, never this model's. Every store call is
/// awaited from here and runs off the main actor, so the window keeps drawing
/// while the keychain answers.
@MainActor
final class WebsiteLoginsModel: ObservableObject {
    @Published private(set) var state: WebsiteLoginsState = .loading

    private let store: any LoginStore
    /// Numbers each read, so only the newest one's answer is drawn.
    private var reads = 0

    init(store: any LoginStore) {
        self.store = store
    }

    /// The logins drawn now, or none while there is no list.
    var listed: [SavedLogin] {
        guard case .listed(let logins) = state else { return [] }

        return logins
    }

    /// Reads the list again, in the order every store lists in. The answer
    /// replaces what is drawn only when it lands, so a re-read never puts the
    /// section back to loading, and a read that a newer one overtook is
    /// dropped.
    func refresh() async {
        reads += 1
        let read = reads
        let answer: WebsiteLoginsState

        do {
            answer = .listed(try await store.list())
        } catch let error as LoginStoreError {
            guard let reason = LoginsUnavailable(error) else {
                preconditionFailure("a login list refused with \(error), which is no cause a list can have")
            }
            answer = .unavailable(reason)
        } catch is CancellationError {
            // The pane went away before the store answered; nothing to draw.
            return
        } catch {
            preconditionFailure("a LoginStore throws only LoginStoreError, got \(type(of: error))")
        }

        guard read == reads else { return }

        state = answer
    }

    /// Checks every rule first, against the list drawn now, so each refused
    /// field says so at once; the store then checks them again, and refuses
    /// what only it can see. The list is read again after anything reached
    /// the store, whether it took the write or not.
    func save(_ request: LoginSaveRequest) async -> LoginSaveOutcome {
        let refused = refusals(for: request)
        guard refused.isEmpty else { return .refused(LoginRefusals(refused)) }

        do {
            let saved = try await write(request)
            await refresh()
            return .saved(saved)
        } catch let error as LoginStoreError {
            await refresh()
            return .refused(LoginRefusals([error]))
        } catch {
            preconditionFailure("a LoginStore throws only LoginStoreError, got \(type(of: error))")
        }
    }

    /// Deletes one login: nil when it is gone, or the sentence saying why not.
    func delete(_ login: SavedLogin) async -> String? {
        do {
            try await store.delete(id: login.id)
            await refresh()
            return nil
        } catch let error as LoginStoreError {
            await refresh()
            return LoginRefusals.sentence(for: error)
        } catch {
            preconditionFailure("a LoginStore throws only LoginStoreError, got \(type(of: error))")
        }
    }

    private func refusals(for request: LoginSaveRequest) -> [LoginStoreError] {
        switch request {
        case .add(let site, let username, let password):
            return LoginStoreRules.refusals(site: site, username: username, password: password, existing: listed)
        case .edit(_, let username, let password):
            return LoginStoreRules.refusals(username: username, password: password)
        }
    }

    private func write(_ request: LoginSaveRequest) async throws -> SavedLogin {
        switch request {
        case .add(let site, let username, let password):
            return try await store.add(site: site, username: username, password: password)
        case .edit(let login, let username, let password):
            return try await store.update(id: login.id, username: username, password: password)
        }
    }
}

/// Website logins, in Settings > Browser (M84 §11).
///
/// One row per login with its site, its username and `Edit…`, then
/// `Add login…`; an empty list says so in D8's words. A build with no store
/// and a keychain that refused each say why in place of the list, with no
/// way to add. The pane presents the sheet, so this only names which one.
struct WebsiteLoginsSection: View {
    /// How long the first read may take before its progress shows, so a
    /// keychain that answers at once never flashes a spinner.
    static let loadingGrace: Duration = .milliseconds(400)

    @ObservedObject var model: WebsiteLoginsModel
    let open: (LoginSheetMode) -> Void

    var body: some View {
        Section {
            rows
        } header: {
            Text(ProductStrings[.settingsBrowserLoginsSection])
        } footer: {
            Text(ProductStrings[.settingsBrowserLoginsFooter])
                .fermixType(Typography.style(.calloutSmall))
                .foregroundStyle(Palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch model.state {
        case .loading:
            LoginsLoadingRow()
        case .listed(let logins):
            if logins.isEmpty {
                Text(ProductStrings[.settingsBrowserLoginsEmpty])
                    .foregroundStyle(Palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(logins) { login in
                WebsiteLoginRow(login: login) { open(.edit(login)) }
            }

            HStack {
                Spacer(minLength: 0)

                Button(ProductStrings[.settingsBrowserLoginsAdd]) { open(.add) }
            }
        case .unavailable(let reason):
            LoginsUnavailableRow(reason: reason)
        }
    }
}

/// One saved login: its site over its username, and the way into its sheet.
struct WebsiteLoginRow: View {
    let login: SavedLogin
    let edit: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: SettingsRowMetrics.captionGap) {
                Text(login.site)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.ink.color)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(login.username)
                    .fermixType(Typography.style(.calloutSmall))
                    .foregroundStyle(Palette.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // One element for VoiceOver, read as site then username.
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            // Named with its site, so a list of them is not a column of
            // identical `Edit…` buttons to VoiceOver.
            Button(ProductStrings[.settingsBrowserLoginsEdit], action: edit)
                .accessibilityLabel(ProductStrings.commaPair(ProductStrings[.settingsBrowserLoginsEdit], login.site))
        }
    }
}

/// Why there is no list. A build without a store is a fact about the build,
/// drawn quietly; a keychain that refused is a warning.
struct LoginsUnavailableRow: View {
    let reason: LoginsUnavailable

    var body: some View {
        Label {
            Text(reason.sentence)
                .foregroundStyle(reason == .noStore ? Palette.secondary.color : Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: reason == .noStore ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(reason == .noStore ? Palette.secondary.color : Palette.warning.color)
                .accessibilityHidden(true)
        }
    }
}

/// The first read, before the store answers. It keeps a row's room and shows
/// its progress only once the grace has passed, so a quick answer replaces an
/// empty row rather than a spinner that was there for a frame.
struct LoginsLoadingRow: View {
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(shown ? 1 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .task {
                do {
                    try await Task.sleep(for: WebsiteLoginsSection.loadingGrace)
                } catch {
                    // Cancelled: the answer came first and this row is gone.
                    return
                }

                shown = true
            }
    }
}
