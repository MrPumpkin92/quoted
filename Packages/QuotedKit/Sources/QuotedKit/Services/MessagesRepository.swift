import Foundation
import QuotedCore
import Supabase

/// Conversations and messages: 1:1, between accepted friends, read only by the two members.
/// Messages are ``ConversationMessage`` here (QuotedCore's `Message`; supabase-swift's Realtime
/// still exports a deprecated `Message` of its own).
///
/// Sending is a social write (terms, no suspension) into an open conversation. A quote travels by
/// reference (``QuoteRef``) and the server builds the snapshot; the client never sends words for a
/// quote. There is no push or Realtime: the app polls an open conversation and refreshes the Inbox.
public struct MessagesRepository: Sendable {
    let client: SupabaseClient

    /// Messages per conversation page.
    public static let pageSize = 50

    // MARK: Conversations

    /// Your conversation with an accepted friend, created if missing and reopened if it was closed
    /// (`public.open_conversation`). Throws ``QuotedError/unavailable(_:)`` for anyone who is not an
    /// accepted friend (or across a block), and ``QuotedError/termsRequired`` before the terms.
    public func openConversation(with friendID: UUID) async throws -> Conversation {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.rpc(RPC.openConversation, params: FriendParam(friend: friendID))
                .select(Columns.conversationRow)
                .single()
                .execute()
                .value
        }
    }

    /// One conversation you may read, with both members' profiles (the other one's
    /// `acceptsTextMessages` and whether it is closed are what a poll checks), or nil when it isn't
    /// available to you (the other member blocked you).
    public func conversation(id: UUID) async throws -> Conversation? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.conversations)
                .select(Columns.conversation)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// The Inbox (`public.inbox_conversations()`): one row per conversation you may read, newest
    /// first, with the other member, the latest message you can see, your unread count and your
    /// read mark. Feed it to ``InboxBadge`` for the tab badge. A GET, so the SDK retries it.
    public func inbox() async throws -> [InboxConversation] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.readRPC(RPC.inboxConversations)
                .execute()
                .value
        }
    }

    // MARK: Messages

    /// A page of a conversation, newest first (`created_at desc, id`): the newest `limit` messages,
    /// or those after `cursor` (the oldest message loaded) for the page before. Only what you may
    /// read: nothing before your "Delete Conversation", and nothing you reported.
    public func messages(
        in conversationID: UUID,
        after cursor: PageCursor? = nil,
        limit: Int = MessagesRepository.pageSize
    ) async throws -> [ConversationMessage] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            var query = client.from(Table.messages)
                .select(Columns.message)
                .eq("conversation_id", value: conversationID)
            if let cursor { query = query.or(Keyset.after(cursor)) }
            return try await query
                .order("created_at", ascending: false)
                .order("id")
                .limit(limit)
                .execute()
                .value
        }
    }

    /// "Shared with you": every quote message someone sent you that you may read, across all your
    /// conversations, newest first (`created_at desc, id`). Read in keyset pages to the end, so an
    /// older quote is never cut off by a busy conversation; text and playlist messages and your own
    /// messages are left out. Row-level security limits it to what you may read (nothing before your
    /// "Delete Conversation", nothing you reported, nothing from someone who blocked you).
    ///
    /// Each page is `public.received_quotes` (a GET, retried by the SDK), which starts from your own
    /// conversations so the server reads them through the messages index; the same filter on the
    /// `messages` table has no index to start from and reads every message on the service.
    public func receivedQuotes() async throws -> [ConversationMessage] {
        try await receivedQuotes(pageSize: Paging.pageSize)
    }

    func receivedQuotes(pageSize: Int) async throws -> [ConversationMessage] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            var all: [ConversationMessage] = []
            var seen: Set<UUID> = []
            var cursor: PageCursor?
            while true {
                let page: [ConversationMessage] = try await client
                    .readRPC(RPC.receivedQuotes, params: ReceivedQuotesParams(cursor: cursor, limit: pageSize))
                    .execute()
                    .value
                for message in page where seen.insert(message.id).inserted {
                    all.append(message)
                }
                guard page.count >= pageSize, let last = page.last else { return all }
                cursor = last.cursor
            }
        }
    }

    /// One message you may read, or nil.
    public func message(id: UUID) async throws -> ConversationMessage? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.messages)
                .select(Columns.message)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// Sends a message. Keep the same `id` when retrying after a lost answer: the retry returns the
    /// message the first try sent instead of sending it twice.
    ///
    /// Throws ``QuotedError/termsRequired``, ``QuotedError/suspended``,
    /// ``QuotedError/conversationClosed`` (unfriended or blocked), ``QuotedError/unavailable(_:)``
    /// (not your conversation, or a quote or playlist you can't send), ``QuotedError/textsOff``
    /// (QR004: text to a friend who receives quotes only), ``QuotedError/blockedWords(_:)`` (QR003)
    /// and ``QuotedError/validation(_:)`` for text over the limits or the daily limit.
    @discardableResult
    public func send(_ draft: MessageDraft, in conversationID: UUID, id: UUID = UUID()) async throws -> ConversationMessage {
        let me = try client.requireUserID()
        let insert = MessageInsert(id: id, conversationID: conversationID, draft: try Self.validated(draft))
        return try await mappingErrors(postgrest: Self.sendError) {
            do {
                return try await client.from(Table.messages)
                    .insert(insert, returning: .representation)
                    .select(Columns.message)
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError where error.mayHideEarlierInsert {
                // A retry whose first try landed: that message is the result (23505, or 42501 when
                // its source changed since, for example the quote was deleted). An id whose
                // message was unsent can't be reused; it isn't readable, so the error stands.
                let existing: ConversationMessage? = try await client.from(Table.messages)
                    .select(Columns.message)
                    .eq("id", value: id)
                    .eq("sender_id", value: me)
                    .maybeSingle()
                    .execute()
                    .value
                guard let existing else { throw error }
                return existing
            }
        }
    }

    /// Unsends one of your messages, for both of you. The server keeps a hidden copy for 30 days, and
    /// the message still counts toward today's limit. Unsending one that is already gone succeeds.
    public func unsend(messageID: UUID) async throws {
        _ = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.messages)
                .delete(returning: .minimal)
                .eq("id", value: messageID)
                .execute()
        }
    }

    // MARK: Your read mark and Delete Conversation

    /// Marks the conversation read up to `time`: pass the time of the newest message you have shown
    /// (``InboxConversation/lastMessageAt`` or a message's `createdAt`), so a message that arrived
    /// since your last refresh stays unread. The server keeps that time, but never later than its
    /// clock and never earlier than the current mark. Returns your member row, or nil when the
    /// conversation isn't available.
    @discardableResult
    public func markRead(conversationID: UUID, upTo time: Date) async throws -> ConversationMember? {
        try await updateMembership(conversationID, LastReadUpdate(lastReadAt: time))
    }

    /// "Delete Conversation": hides the messages so far, for you only (the server's clock). New
    /// messages still arrive. Returns your member row, or nil when the conversation isn't available.
    @discardableResult
    public func clear(conversationID: UUID) async throws -> ConversationMember? {
        try await updateMembership(conversationID, ClearedUpdate(clearedAt: Date()))
    }

    private func updateMembership(_ conversationID: UUID, _ update: some Encodable & Sendable) async throws -> ConversationMember? {
        let me = try client.requireUserID()
        return try await mappingErrors {
            let rows: [ConversationMember] = try await client.from(Table.conversationMembers)
                .update(update, returning: .representation)
                .eq("conversation_id", value: conversationID)
                .eq("user_id", value: me)
                .select(Columns.conversationMember)
                .execute()
                .value
            return rows.first
        }
    }

    // MARK: Helpers

    static func validated(_ draft: MessageDraft) throws(QuotedError) -> MessageDraft {
        do {
            return try draft.validated()
        } catch {
            throw .validation(error.errorDescription ?? "Check the message and try again.")
        }
    }

    /// The quote you picked was deleted meanwhile (the server refuses a quote that isn't yours).
    static let sendError: QuotedError.PostgrestOverride = { error in
        if error.code == "42501", error.message == "You can send only quotes from your Library or the Quoted Catalog." {
            return .unavailable("That quote is no longer in your library.")
        }
        return nil
    }
}
