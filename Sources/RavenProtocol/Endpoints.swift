import Foundation

/// Server routes Nevermore uses, per docs/RAVEN-RESEARCH.md at the pinned
/// revisions. A name's presence documents a reviewed contract; it is not a
/// promise that every deployment exposes it. No unverified routes are added.
public enum RavenEndpoints {
    /// OAuth 2 authorization-code + PKCE flow (Frappe integrations).
    public static let authorizePath = "/api/method/frappe.integrations.oauth2.authorize"
    public static let tokenPath = "/api/method/frappe.integrations.oauth2.get_token"
    public static let revokePath = "/api/method/frappe.integrations.oauth2.revoke_token"

    /// Frappe Desk's list of OAuth Client registrations (the OAuth Client
    /// doctype in the Integrations module), where an administrator reads a
    /// registration's client ID. Frappe 16 routes `/desk/<module>/<doctype>`
    /// to that list. Frappe 15 redirects `/desk` to `/app` and opens the
    /// Integrations workspace instead, which lists OAuth Client. It is a
    /// browser page behind the Desk login: Nevermore links to it and never
    /// requests it. Evidence: docs/RAVEN-RESEARCH.md section 3.
    public static let oauthClientListPath = "/desk/integrations/oauth-client"

    /// The OAuth Client list of the site at `origin`. Only the origin's
    /// scheme, host and port are kept, so nothing else it carried reaches
    /// the browser. Nil when `origin` is not a hierarchical URL.
    public static func oauthClientListURL(origin: URL) -> URL? {
        guard let source = URLComponents(url: origin, resolvingAgainstBaseURL: true), source.encodedHost?.isEmpty == false else { return nil }
        var components = URLComponents()
        components.scheme = source.scheme
        components.encodedHost = source.encodedHost
        components.port = source.port
        components.path = oauthClientListPath
        return components.url
    }

    /// Frappe RPC mount: `/api/method/` + dotted method name.
    public static func methodPath(_ method: String) -> String { "/api/method/" + method }

    /// Generic DocType REST mount.
    public static func resourcePath(_ doctype: String, _ name: String? = nil) -> String {
        var path = "/api/resource/" + doctype
        if let name { path += "/" + name }
        return path
    }

    /// Raven/Frappe RPCs the app layer calls today (reads and mutations).
    /// Reads marked GET-only on the server are called with `mutation: false`.
    public static let methods: Set<String> = [
        "raven.api.native.boot",
        "raven.api.raven_mobile.get_client_id",
        "raven.api.raven_users.get_current_raven_user",
        "raven.api.raven_users.get_list",
        "raven.api.raven_users.update_raven_user",
        "raven.api.raven_channel.get_all_channels",
        "raven.api.raven_channel.create_direct_message_channel",
        "raven.api.raven_channel.create_channel",
        "raven.api.raven_channel.leave_channel",
        "raven.api.raven_channel.toggle_pin_message",
        "raven.api.raven_channel.toggle_pinned_channel",
        "raven.api.user_availability.get_active_users",
        "raven.api.user_availability.refresh_user_active_state",
        "raven.api.raven_channel_member.get_channel_members",
        "raven.api.raven_channel_member.track_visit",
        "raven.api.raven_channel_member.mark_channel_as_unread",
        "raven.api.preview_links.get_previews",
        "raven.api.chat_stream.get_messages",
        "raven.api.chat_stream.get_older_messages",
        "raven.api.chat_stream.get_newer_messages",
        "raven.api.raven_message.send_message_with_attachments",
        "raven.api.raven_message.delete_messages",
        "raven.api.raven_message.get_unread_count_for_channels",
        "raven.api.raven_message.get_saved_messages",
        "raven.api.raven_message.get_pinned_messages",
        "raven.api.raven_message.save_message",
        "raven.api.reactions.react",
        "raven.api.reactions.most_used_reactions",
        "raven.api.threads.create_thread",
        "raven.api.threads.get_all_threads",
        "raven.api.search.sqlite_search",
        "raven.api.search.get_channel_files",
        "raven.api.notifications.get_notifications",
        "raven.api.notifications.mark_message_notifications_read",
        "raven.api.reminders.create_reminder",
        "raven.api.reminders.get_reminders",
        "raven.api.reminders.snooze_reminder",
        "raven.api.reminders.update_reminder",
        "raven.api.reminders.delete_reminder",
        "raven.api.scheduled_message.create_scheduled_message",
        "raven.api.scheduled_message.get_scheduled_messages",
        "raven.api.scheduled_message.send_now",
        "raven.api.raven_poll.create_poll",
        "raven.api.raven_poll.get_poll",
        "raven.api.raven_poll.add_vote",
        "raven.api.raven_poll.retract_vote",
        "raven.api.raven_poll.close_poll",
        "upload_file",
    ]

    /// Socket.IO room membership traffic (client → server emits).
    public static let roomDoctype = "Raven Channel"
    public static let doctypeSubscriptions = ["Raven User", "Raven Channel"]
    /// Server → client event names forwarded to the session. Forwarding is
    /// unfiltered (onAny); this list only documents the reviewed names.
    public static let realtimeEvents: Set<String> = [
        "message_created", "message_edited", "message_deleted",
        "message_reacted", "message_saved",
        "raven:unread_channel_count_updated", "raven:unread_thread_count_updated",
        "raven_mention", "raven_reaction_notification",
        "raven_channel_typers", "raven:user_active_state_updated",
        "raven_scheduled_message_updated",
    ]
}
