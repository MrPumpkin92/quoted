import Foundation
import QuotedCore
import Supabase

/// Your account (profile, private settings, terms) and other people's profiles and profile pages.
///
/// Clients read only `id, username, display_name, accepts_text_messages` of any profile (column
/// grant); your own private fields come from `public.my_account()`. A stranger is reached only by
/// exact username (``findProfile(username:)``, ``profileView(username:before:)``).
public struct ProfilesRepository: Sendable {
    let client: SupabaseClient

    // MARK: Your account

    /// Your own account with its private fields (favorites visibility, terms, suspension, the
    /// publishing gate), or nil before a username is chosen.
    ///
    /// A GET, retried by the SDK after a dropped connection (1 + 2 + 4 s). Pass `retry: false` when
    /// a write waits on the answer (the terms check before a send), so offline fails at once.
    public func myAccount(retry: Bool = true) async throws -> MyAccount? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            let rows: [MyAccount] = try await client.readRPC(RPC.myAccount)
                .retry(enabled: retry)
                .execute()
                .value
            return rows.first
        }
    }

    /// Your public profile, or nil before a username is chosen.
    public func myProfile() async throws -> Profile? {
        let me = try client.requireUserID()
        return try await profile(id: me)
    }

    /// Creates your profile, sending only `id`, `username` and `display_name`. Throws
    /// ``QuotedError/usernameTaken`` when the username is in use (or reserved or retired),
    /// ``QuotedError/blockedWords(_:)`` for a word Quoted doesn't allow, and
    /// ``QuotedError/validation(_:)`` for an invalid username or name.
    public func createProfile(username: String, displayName: String? = nil) async throws -> Profile {
        let me = try client.requireUserID()
        let insert = ProfileInsert(
            id: me,
            username: try Self.validUsername(username),
            displayName: try Self.validDisplayName(displayName)
        )
        return try await mappingErrors(postgrest: Self.profileError) {
            do {
                return try await client.from(Table.profiles)
                    .insert(insert, returning: .representation)
                    .select(Columns.profile)
                    .single()
                    .execute()
                    .value
            } catch let error as PostgrestError
                where error.code == "23505" && (error.constraintName == "profiles_pkey" || error.mentions("profiles_pkey")) {
                // You already have a profile: most likely an earlier Continue whose answer was lost.
                // That profile is the result, so onboarding goes on instead of sticking here.
                guard let existing = try await myProfile() else { throw error }
                return existing
            }
        }
    }

    /// Changes your display name. Nil or blank clears it (the username is shown).
    public func updateDisplayName(_ displayName: String?) async throws -> Profile {
        let me = try client.requireUserID()
        let update = DisplayNameUpdate(displayName: try Self.validDisplayName(displayName))
        return try await updateMine(update, me: me)
    }

    /// Turns "Friends can text me" on or off. Off, friends can still send quotes and playlists.
    public func setAcceptsTextMessages(_ accepts: Bool) async throws -> Profile {
        let me = try client.requireUserID()
        return try await updateMine(AcceptsTextMessagesUpdate(acceptsTextMessages: accepts), me: me)
    }

    /// Shows your favorites to friends, or keeps them to yourself. Read it back with ``myAccount()``:
    /// the column is not readable through `profiles`.
    public func setFavoritesVisibility(_ visibility: FavoritesVisibility) async throws {
        let me = try client.requireUserID()
        try await mappingErrors {
            try await client.from(Table.profiles)
                .update(FavoritesVisibilityUpdate(favoritesVisibility: visibility), returning: .minimal)
                .eq("id", value: me)
                .execute()
        }
    }

    /// Accepts the Terms of Use `version` (``MyAccount/currentTermsVersion``). Every social write
    /// needs the current version. Throws ``QuotedError/validation(_:)`` when the version is no longer
    /// current (read ``myAccount()`` again and show the new terms).
    public func acceptTerms(version: Int) async throws {
        _ = try client.requireUserID()
        try await mappingErrors(postgrest: Self.termsError) {
            try await client.rpc(RPC.acceptTerms, params: AcceptTermsParams(version: version))
                .execute()
        }
    }

    // MARK: Other people

    /// A linked person's profile as it is now (yourself, a friend or requester, a conversation
    /// member, or someone you blocked), or nil when you can no longer see it.
    public func profile(id: UUID) async throws -> Profile? {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.from(Table.profiles)
                .select(Columns.profile)
                .eq("id", value: id)
                .maybeSingle()
                .execute()
                .value
        }
    }

    /// One profile page by exact username (after normalizing "@Name" to "name"): the person, how you
    /// stand with them, and the posts (30 per page, older than `before`), playlists and favorites you
    /// may see. Nil when there is no such profile or that person blocked you ("This profile isn't
    /// available"), and for a string that is not a valid username. A GET, so the SDK retries it.
    ///
    /// The page's `profile` carries no `acceptsTextMessages` (nil): `profile_view` reaches strangers
    /// too and leaves that setting out.
    public func profileView(username: String, before: Date? = nil) async throws -> ProfilePage? {
        _ = try client.requireUserID()
        guard let name = try? Username.validate(username) else { return nil }
        return try await mappingErrors {
            try await client.readRPC(RPC.profileView, params: ProfileViewParams(username: name, before: before))
                .execute()
                .value
        }
    }

    /// A friend's favorite quotes, newest first (at most 100). Empty unless you are accepted friends,
    /// neither has blocked the other, and they share favorites with friends.
    public func favorites(of userID: UUID) async throws -> [FriendFavorite] {
        _ = try client.requireUserID()
        return try await mappingErrors {
            try await client.rpc(RPC.friendFavorites, params: FriendFavoritesParam(user: userID))
                .execute()
                .value
        }
    }

    /// Whether nobody has `username` yet (reserved and retired names count as taken). Throws
    /// ``QuotedError/validation(_:)`` if it is not a valid username.
    ///
    /// Asks `public.is_username_available`: profiles are readable only between linked people, so a
    /// plain select could not see a stranger's username.
    public func isUsernameAvailable(_ username: String) async throws -> Bool {
        _ = try client.requireUserID()
        let name = try Self.validUsername(username)
        return try await mappingErrors {
            try await client.rpc(RPC.isUsernameAvailable, params: UsernameParam(username: name))
                .execute()
                .value
        }
    }

    /// The profile with exactly this username (after normalizing "@Name" to "name"), or nil. Nil
    /// too for your own username and for anyone you have blocked or who has blocked you
    /// (`public.find_profile`), so a block can't be detected from a lookup.
    public func findProfile(username: String) async throws -> Profile? {
        try await findProfile(username: username, retrying: true)
    }

    /// `retrying: false` skips the SDK's retries, for a lookup that runs before a write.
    func findProfile(username: String, retrying: Bool) async throws -> Profile? {
        _ = try client.requireUserID()
        guard let name = try? Username.validate(username) else { return nil }
        return try await mappingErrors {
            let rows: [Profile] = try await client.rpc(RPC.findProfile, params: UsernameParam(username: name))
                .select(Columns.foundProfile)
                .retry(enabled: retrying)
                .execute()
                .value
            return rows.first
        }
    }

    /// Records that this account is in use (`public.touch_activity`, which the server throttles to
    /// one write per 12 hours). Anonymous accounts unused for a year are deleted, so the app calls
    /// this when it comes to the foreground and from background refresh. Never throws.
    public func touchActivity() async {
        guard client.signedInUserID != nil else { return }
        do {
            try await client.rpc(RPC.touchActivity).execute()
        } catch {
            // Best effort: the next foreground or background refresh tries again.
        }
    }

    // MARK: Helpers

    private func updateMine(_ update: some Encodable & Sendable, me: UUID) async throws -> Profile {
        try await mappingErrors(postgrest: Self.profileError) {
            try await client.from(Table.profiles)
                .update(update, returning: .representation)
                .eq("id", value: me)
                .select(Columns.profile)
                .single()
                .execute()
                .value
        }
    }

    static func validUsername(_ username: String) throws(QuotedError) -> String {
        do {
            return try Username.validate(username)
        } catch {
            throw .validation(error.errorDescription ?? "Choose a different username.")
        }
    }

    static func validDisplayName(_ name: String?) throws(QuotedError) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            return try DisplayName.validate(name)
        } catch {
            throw .validation(error.errorDescription ?? "Choose a different name.")
        }
    }

    static let profileError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "23505":
            error.constraintName == "profiles_pkey" || error.mentions("profiles_pkey")
                ? .validation("You already have a username.")
                : .usernameTaken
        case "23514":
            error.mentions("display_name")
                ? .validation("Names can be 1–50 characters.")
                : .validation("Usernames are 3–20 characters: letters a–z, numbers, underscores and periods.")
        case "QR003":
            .blockedWords(QuotedError.blockedWordsInNames)
        default:
            nil
        }
    }

    static let termsError: QuotedError.PostgrestOverride = { error in
        switch error.code {
        case "22023": .validation("The Terms of Use were just updated. Read them again, then accept.")
        case "P0002": .validation("Choose a username first.")
        default: nil
        }
    }
}
