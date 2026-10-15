import Foundation

/// What the chat does with each server event and each request, as values: no
/// socket, no clock, no main actor.
///
/// Every step changes the chat and returns the events to send in answer. The
/// session sends them only on a negotiated connection: a request that must
/// arrive waits in the outbox for the next handshake instead.
enum CompanionReducer {
    /// The `before_seq` a cold start pulls below. `before_seq` pages backward
    /// from a cursor and the newest page sits below every seq, so the cursor is
    /// one no seq reaches; `after_seq: 0` would read the oldest page instead.
    static let newestPageBound = Int.max

    // MARK: - The connection

    /// A handshake completed. The catch-up read goes first, then every request
    /// the daemon has not accepted, again, in the order it was made.
    ///
    /// A client that holds rows reads on from its cursor. One that holds none
    /// has nothing to read on from and asks for the newest page; its head is
    /// then the cursor, and older rows are read on demand.
    ///
    /// The notices sent while this client was away are lost, so the held rows
    /// on screen, which the transcript reported last, are read again once the
    /// catch-up read has drained (M66 §3.6): they wait behind it.
    static func negotiated(_ chat: inout CompanionChat, onScreen: Set<Int>) -> [CompanionClientEvent] {
        let catchUp: CompanionHistoryCursor = chat.rows.isEmpty
            ? .before(seq: newestPageBound)
            : .after(seq: chat.cursor)
        readAgain(onScreen, in: &chat)

        return send(.catchUp(catchUp), into: &chat) + chat.pending.map(\.event)
    }

    /// The connection ended. Nothing asked on it will be answered, and a draft
    /// cannot be kept: a connection that rejoins a turn receives its text so
    /// far as the first delta.
    ///
    /// Rows being read again wait for the next connection, behind its
    /// catch-up read. A page the reader scrolled to is not kept: they ask
    /// again when they next reach the top, so a page landing late cannot move
    /// a reader who has scrolled on.
    ///
    /// No notice about a held row reaches a client that is away, so every
    /// held row is marked as read before the disconnect, to be read again as
    /// it comes on screen (M66 §3.6).
    static func disconnected(_ chat: inout CompanionChat) {
        if case .rows(let read) = chat.historyPull {
            chat.rowsToRead.formUnion(read.seqs)
        }
        chat.readBeforeDisconnect = Set(chat.rows.map(\.serverSeq))
        chat.historyPull = nil
        chat.olderWaiting = nil
        chat.turn = nil
        chat.search?.olderHitsAsked = nil
        if chat.search?.hits == nil {
            chat.search = nil
        }
    }

    // MARK: - Requests

    /// A message to the agent. Blank text is never a message.
    static func send(_ text: String, clientMsgId: String, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        return enqueue(CompanionOutboxEntry(clientMsgId: clientMsgId, request: .message(text: text)), into: &chat)
    }

    /// Answers an approval with the route it named, sent as a command.
    static func answer(
        _ approvalId: String,
        approve: Bool,
        clientMsgId: String,
        into chat: inout CompanionChat
    ) -> [CompanionClientEvent] {
        guard
            let approval = chat.approvals.first(where: { $0.approvalId == approvalId }),
            let route = CompanionCommandRoute(approve ? approval.approveCommand : approval.denyCommand)
        else { return [] }

        let request = CompanionRequest.command(name: route.name, args: route.args)
        return enqueue(CompanionOutboxEntry(clientMsgId: clientMsgId, request: request), into: &chat)
    }

    /// Stops the turn of one request, running or waiting. A request still in
    /// the outbox is never sent again, so a reconnect cannot run what was
    /// cancelled.
    static func cancel(_ clientMsgId: String, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        chat.pending.removeAll { $0.clientMsgId == clientMsgId }

        return [.cancel(profileId: CompanionProtocol.profileId, clientMsgId: clientMsgId)]
    }

    /// The page before the oldest held row, when one exists. It waits for a
    /// read out, and asked again while it is waiting or out it is the same
    /// read: the transcript asks on every scroll while the top is on screen.
    static func pullOlder(_ chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard chat.hasOlder, let oldest = chat.rows.first?.serverSeq,
              chat.historyPull != .older(beforeSeq: oldest)
        else { return [] }

        chat.olderWaiting = oldest
        return sendWaiting(&chat)
    }

    /// Searches the timeline. A query the daemon would refuse is not sent: the
    /// refusal closes the connection.
    static func search(_ query: String, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        let length = query.unicodeScalars.count
        guard length > 0, length <= CompanionProtocol.maximumSearchQueryLength else { return [] }

        chat.search = CompanionSearch(query: query, hits: nil, nextBeforeSeq: nil)
        return [
            .historySearch(
                profileId: CompanionProtocol.profileId,
                query: query,
                limit: CompanionProtocol.searchLimit,
                beforeSeq: nil
            )
        ]
    }

    /// The hits older than the ones shown, when the daemon said older ones
    /// exist and none are asked for already.
    static func searchOlder(_ chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard var search = chat.search, search.hits != nil, search.olderHitsAsked == nil,
              let before = search.nextBeforeSeq
        else { return [] }

        search.olderHitsAsked = before
        chat.search = search
        return [
            .historySearch(
                profileId: CompanionProtocol.profileId,
                query: search.query,
                limit: CompanionProtocol.searchLimit,
                beforeSeq: before
            )
        ]
    }

    static func clearSearch(_ chat: inout CompanionChat) {
        chat.search = nil
    }

    /// The held rows the transcript shows now. Those read before a disconnect
    /// are read again, in one read for what came on screen together, behind
    /// any read out or waiting ahead of it (M66 §3.6).
    static func rowsOnScreen(_ seqs: Set<Int>, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard readAgain(seqs, in: &chat) else { return [] }

        return sendWaiting(&chat)
    }

    /// Moves the rows read before a disconnect among `seqs` to the rows to
    /// read, and says whether there were any.
    @discardableResult
    private static func readAgain(_ seqs: Set<Int>, in chat: inout CompanionChat) -> Bool {
        let due = chat.readBeforeDisconnect.intersection(seqs)
        guard !due.isEmpty else { return false }

        chat.readBeforeDisconnect.subtract(due)
        chat.rowsToRead.formUnion(due)
        return true
    }

    /// The newest held row was seen. The frontier moves once per row, and never
    /// behind where the daemon already has it.
    static func newestRowSeen(_ chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard chat.cursor > chat.readUpToSeq else { return [] }

        chat.readUpToSeq = chat.cursor
        return [.readState(profileId: CompanionProtocol.profileId, readUpToSeq: chat.cursor)]
    }

    private static func enqueue(
        _ entry: CompanionOutboxEntry,
        into chat: inout CompanionChat
    ) -> [CompanionClientEvent] {
        // A line past the cap is refused with `line_too_large` and closes the
        // connection, and the outbox would send it again after every reconnect.
        guard fitsOneLine(entry.event) else {
            chat.lastError = ProductStrings[.companionErrorMessageTooLong]
            return []
        }

        chat.lastError = nil
        chat.pending.append(entry)
        return [entry.event]
    }

    private static func fitsOneLine(_ event: CompanionClientEvent) -> Bool {
        do {
            _ = try event.line()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Server events

    static func receive(_ event: CompanionServerEvent, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        switch event {
        case .accepted(let receipt):
            // Duplicate or not, the daemon holds the request now.
            chat.pending.removeAll { $0.clientMsgId == receipt.clientMsgId }
        case .turnStarted(_, let turnId, let inReplyTo):
            chat.turn = CompanionTurn(turnId: turnId, inReplyTo: inReplyTo, text: "", tool: nil)
        case .textDelta(let turnId, let text):
            var turn = held(turnId, in: chat)
            turn.text += text
            chat.turn = turn
        case .toolEvent(let tool):
            var turn = held(tool.turnId, in: chat)
            turn.tool = tool
            chat.turn = turn
        case .textDone(let turnId, let serverSeq, let text):
            return finish(turnId, at: serverSeq, text: text, into: &chat)
        case .turnError(let turnId, let code, let message):
            end(turnId, in: &chat)
            chat.lastError = sentence(forTurnError: code, message: message)
        case .turnDone(let turnId):
            // The turn wrote no reply: its draft goes with it.
            end(turnId, in: &chat)
        case .row(let row):
            return announce(row, into: &chat)
        case .approval(let approval):
            hold(approval, in: &chat)
        case .approvalResolved(let approvalId, _):
            chat.approvals.removeAll { $0.approvalId == approvalId }
        case .readState(_, let readUpToSeq):
            chat.readUpToSeq = max(chat.readUpToSeq, readUpToSeq)
        case .historyPage(let page):
            return merge(page, into: &chat)
        case .searchResults(let results):
            show(results, in: &chat)
        case .error(let error):
            refuse(error, in: &chat)
        case .rowUpdated(_, let serverSeq):
            return updated(serverSeq, into: &chat)
        case .serverHello, .mediaPath, .mediaMissing, .unrecognized:
            // The handshake and the grants are the session's, never the chat's.
            break
        }

        return []
    }

    /// The turn an event names: the one held, or one this connection joined
    /// midway, whose first event carries no request.
    private static func held(_ turnId: String, in chat: CompanionChat) -> CompanionTurn {
        guard let turn = chat.turn, turn.turnId == turnId else {
            return CompanionTurn(turnId: turnId, inReplyTo: nil, text: "", tool: nil)
        }

        return turn
    }

    /// A reply part at its row. The turn is over and its draft is replaced by
    /// the row, which follows the cursor rule like every live row.
    private static func finish(
        _ turnId: String,
        at serverSeq: Int,
        text: String,
        into chat: inout CompanionChat
    ) -> [CompanionClientEvent] {
        let inReplyTo = chat.turn?.turnId == turnId ? chat.turn?.inReplyTo : nil
        end(turnId, in: &chat)

        return applyLive(CompanionRow(reply: turnId, serverSeq: serverSeq, text: text, inReplyTo: inReplyTo), into: &chat)
    }

    private static func end(_ turnId: String, in chat: inout CompanionChat) {
        guard chat.turn?.turnId == turnId else { return }

        chat.turn = nil
    }

    /// `cancelled` and `interrupted` are the contract's own codes; any other is
    /// the failure's, told in the daemon's words.
    private static func sentence(forTurnError code: String, message: String) -> String {
        switch code {
        case "cancelled": return ProductStrings[.companionErrorReplyStopped]
        case "interrupted": return ProductStrings[.companionErrorReplyInterrupted]
        default: return String(format: ProductStrings[.companionErrorReplyFailedFormat], message)
        }
    }

    private static func hold(_ approval: CompanionApproval, in chat: inout CompanionChat) {
        guard let index = chat.approvals.firstIndex(where: { $0.approvalId == approval.approvalId }) else {
            chat.approvals.append(approval)
            return
        }

        chat.approvals[index] = approval
    }

    /// Results for the query on screen. An answer to a query since replaced or
    /// cleared is not shown, and the answer to older hits extends the ones
    /// shown, which are newer.
    private static func show(_ results: CompanionSearchResults, in chat: inout CompanionChat) {
        guard let search = chat.search, search.query == results.query else { return }

        let shown = search.olderHitsAsked == nil ? [] : search.hits ?? []
        chat.search = CompanionSearch(
            query: results.query,
            hits: shown + results.hits,
            nextBeforeSeq: results.nextBeforeSeq
        )
    }

    /// A refusal naming a request ends that request's delivery: it can never
    /// be accepted, so it leaves the outbox.
    private static func refuse(_ error: CompanionServerError, in chat: inout CompanionChat) {
        if let clientMsgId = error.clientMsgId {
            chat.pending.removeAll { $0.clientMsgId == clientMsgId }
        }

        chat.lastError = String(format: ProductStrings[.companionErrorRefusedFormat], error.reason)
    }

    // MARK: - The cursor rule

    /// A row announced live, held by the cursor rule. It carries its files and
    /// previews (version 3), so it is never read for them; what is stored on
    /// it later is announced as `row_updated`.
    private static func announce(
        _ announced: CompanionAnnouncedRow,
        into chat: inout CompanionChat
    ) -> [CompanionClientEvent] {
        applyLive(CompanionRow(announced), into: &chat)
    }

    /// A held row changed after it was written: its transcript, its files or
    /// a link preview was stored (M66 §3.6). It joins the rows to read, which
    /// the next read serves however many notices name them. A row not held is
    /// read as it stands when a page brings it.
    private static func updated(_ seq: Int, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard chat.rows.contains(where: { $0.serverSeq == seq }) else { return [] }

        chat.rowsToRead.insert(seq)
        return sendWaiting(&chat)
    }

    /// A live row is shown when it is the next seq, dropped at or below the
    /// cursor, and on a gap not shown but pulled from the cursor, once: live
    /// announcements can arrive out of seq order, and the pull brings every row
    /// the gap hides. With a read already out, the gap is that read's page's to
    /// close: the row was written before the page was read, so the page's head
    /// is past the cursor.
    private static func applyLive(_ row: CompanionRow, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard row.serverSeq > chat.cursor else { return [] }
        guard row.serverSeq == chat.cursor + 1 else { return send(.catchUp(.after(seq: chat.cursor)), into: &chat) }

        chat.rows.append(row)
        chat.cursor = row.serverSeq
        return []
    }

    /// A page answers the read out. Its rows merge by seq, so a row already
    /// held from a live event is held once, and every page is contiguous with
    /// what is held: a forward page starts at or below the cursor, a backward
    /// one ends at the oldest held row, and a cold start holds nothing a newest
    /// page lacks. The cursor moves to the page's newest row, and while it is
    /// still below the head the read goes on from it, ahead of any read
    /// waiting.
    ///
    /// A row the page brings again replaces the held one at its seq, and a
    /// row that now draws differently is a change of height the transcript
    /// holds the reader against. A row the page brings is as history has it
    /// now, so it is no longer one read before a disconnect; a notice that
    /// arrived while the read was out stays to be read, since the page may
    /// have been read before the change was stored.
    private static func merge(_ page: CompanionHistoryPage, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        let answered = chat.historyPull
        chat.historyPull = nil

        let pageRows = page.messages.map(CompanionRow.init)
        let (rows, replaced) = merged(chat.rows, pageRows)
        chat.rows = rows
        chat.cursor = max(chat.cursor, page.messages.map(\.serverSeq).max() ?? chat.cursor)
        chat.historyHeadSeq = page.historyHeadSeq
        if case .before = answered?.cursor {
            chat.hasOlder = page.nextBeforeSeq != nil
        }
        chat.readBeforeDisconnect.subtract(pageRows.map(\.serverSeq))
        if case .rows(let read) = answered {
            chat.rowsToRead.formUnion(read.unreached(by: page))
        }
        if !replaced.isEmpty {
            reshape(replaced, in: &chat)
        }

        guard chat.cursor < page.historyHeadSeq else { return sendWaiting(&chat) }

        return send(.catchUp(.after(seq: chat.cursor)), into: &chat)
    }

    /// The held rows with a page's rows put over them by seq, and the seqs
    /// where the page's row draws differently from the one it replaced.
    private static func merged(
        _ held: [CompanionRow],
        _ page: [CompanionRow]
    ) -> (rows: [CompanionRow], replaced: Set<Int>) {
        var bySeq = Dictionary(held.map { ($0.serverSeq, $0) }, uniquingKeysWith: { _, latest in latest })
        var replaced: Set<Int> = []
        for row in page {
            if let previous = bySeq.updateValue(row, forKey: row.serverSeq), !previous.drawsAlike(row) {
                replaced.insert(row.serverSeq)
            }
        }

        return (bySeq.values.sorted { $0.serverSeq < $1.serverSeq }, replaced)
    }

    /// Publishes held rows whose height changed in place, as a change of its
    /// own (M66 §3.8).
    private static func reshape(_ seqs: Set<Int>, in chat: inout CompanionChat) {
        chat.reshape = CompanionReshape(id: (chat.reshape?.id ?? 0) + 1, seqs: seqs)
    }

    // MARK: - The reads

    /// Sends a read when none is out. Every read is asked here, so at most one
    /// is ever out.
    private static func send(_ pull: CompanionPull, into chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard chat.historyPull == nil else { return [] }

        chat.historyPull = pull
        return [pull.event]
    }

    /// Sends the read waiting first when none is out: the page the reader
    /// scrolled to, then the rows to read again. The catch-up read never
    /// waits: a gap found while a read is out is that read's page's to close,
    /// and a page that stops below the head asks it before anything waiting
    /// is served.
    private static func sendWaiting(_ chat: inout CompanionChat) -> [CompanionClientEvent] {
        guard chat.historyPull == nil else { return [] }

        if let oldest = chat.olderWaiting {
            chat.olderWaiting = nil
            return send(.older(beforeSeq: oldest), into: &chat)
        }
        guard let read = CompanionRowRead(chat.rowsToRead) else { return [] }

        chat.rowsToRead = []
        return send(.rows(read), into: &chat)
    }
}
