# Raven: client and protocol research

**Reviewed:** 7 November 2026. **Purpose:** establish the constraints for [Nevermore](NEVERMORE-PLAN.md), not design a new chat server.

## 1. Scope and confidence

Reviewed the public repository, current client source, representative server controllers and permissions, message stores, native bridges, and upstream screenshots. Also inspected Frappe's OAuth and realtime implementations on the supported stable branches and Apple's relevant framework documentation.

| Snapshot | Revision | Meaning |
| --- | --- | --- |
| Raven `develop` | `9b01029a92f790e999aab8973e428601261615d1` | Default branch; primary source references below |
| Raven `main` | `1771d07e04337d083973f518a938b1c60afa25c6` | Stable branch; compared with `develop` |
| Raven `v3.2.0` | `5a5e4c48e477831d82943ba241e20cc9fb6ce578` | Latest published release, published 28 October 2026 |
| Frappe `version-15` | `53bae3ef2550ca96320f036f581446783cd11b72` | Inspected OAuth and realtime code |
| Frappe `version-16` | `3d1284c5fdb52207a516a49bbf2fd186cb43b3ab` | Inspected OAuth and realtime code |

At these revisions, Raven `develop` differs from `main` only by a profile-status wrapping fix. The release tag predates additional fixes in `main`, including changes to OAuth-client handling. “Raven 3.2” is therefore not a sufficient integration-test identifier: record the installed commit as well as the advertised version.

The [root README][overview] identifies stable compatibility as Frappe **15.111 or later, and version 16**. The mobile app requires Raven **3.1.0 or later**. This does **not** establish Nevermore compatibility with every 3.1 deployment: test the specific contracts before claiming support.

**Not performed:** running a Raven/Frappe server, installing the store apps, exercising an authenticated site, measuring performance, or conducting a complete security audit. Screenshots establish layout, not runtime correctness. Findings below are source observations; recommendations and proposed additions are explicitly labeled.

## 2. What the existing clients actually are

### Repository map

| Area | Actual role |
| --- | --- |
| `apps/web` | React/TypeScript SPA; desktop and responsive mobile interface; installable PWA |
| `apps/native` | Capacitor iOS/Android shells bundling a native-mode build of `apps/web` |
| `apps/web/src/native` | Site selection, OAuth, boot, secure storage, socket bridge, push, media, downloads, sharing, and platform behavior |
| `apps/web/src/stores` | Message windows, outbox, read state, presence, threads, notifications, and reconnect reconciliation |
| `packages/lib` | Shared hooks and utilities; some are legacy and are not the v3 path |
| `packages/types` | Generated DocType types and handwritten response/message types; useful evidence, not a versioned wire specification |
| `raven/api` | Whitelisted Python RPC methods |
| `raven/**/doctype` | Documents, validation, hooks, permissions-related behavior, and realtime publishers |
| `realtime/handlers.js` | Raven-specific Socket.IO typing handlers |

Sources: [workspace manifest][manifest], [native README][native-readme], [web dependencies][web-package].

### Consequences for Nevermore

- The current phone apps are **not a SwiftUI iOS application and a separate Kotlin messaging UI**. They share Raven's React interface through Capacitor. The native README mentions an earlier React Native app; that is not the current client architecture.
- There is useful Swift precedent for authenticating a Socket.IO connection, but most reusable application logic is TypeScript. A genuinely Mac-native client should reimplement the protocol and behavior, not try to reuse the React UI or migrate the phone shell to Catalyst.
- The desktop interface already has a workspace/channel sidebar, DMs, thread pane, search, files, notifications, Later, and a rich composer. Nevermore should retain the information model, not reproduce the web navigation chrome.
- The mobile shell supports saved sites, but much of its application state is scoped to **one active site**. Simultaneous accounts/windows in Nevermore need an explicit account-scoped architecture rather than this global-active-site pattern. See [site state][site-state] and [site selection][sites].

Visual references inspected: [channel][screenshot-channel] and [threads/documents][screenshot-threads]. These are upstream reference images, not proposed Nevermore artwork.

### Implemented messaging surface

The source contains channels, one-to-one/self DMs, replies, separate thread conversations, rich-text composition/editing, attachments, grouped file sends, reactions/custom emoji, saved and pinned messages, forwarding, search, notifications, reminders, scheduled text messages, polls, document cards/workflows, message actions, presence/status, and bot/AI-related interfaces.

Important details:

- The shared [editor configuration][editor] enables bold, italic, underline, strike, inline/fenced code, lists, blockquotes, links, highlights, tables, mentions, custom emoji, and spoilers. Installed Tiptap packages alone are **not** proof of enabled features: headings, task lists, and details blocks are explicitly not enabled there.
- Desktop and mobile use the same editor with platform-specific focus, keyboard, toolbar, and suggestion behavior. There is no separate mobile message protocol.
- File/image messages and a caption can be **separate message documents in one logical send**. The UI groups them using `message_batch_id`; they must not become several unrelated bubbles or duplicate unread counts.
- `is_reply`/`linked_message` represent a quoted reply. A thread is a separate `Raven Channel` associated with a root message. They are not interchangeable.
- The reviewed meeting endpoint creates a **Google Meet event/link**, not a native Raven voice/video-call transport. Do not infer a WebRTC calling stack or promise native calls from it. See [events][events].

## 3. Authentication, discovery, and site identity

### Existing discovery

`GET /api/method/raven.api.raven_mobile.get_client_id` is guest-accessible and returns a Frappe `message` object containing:

- `client_id`, or null when the configured mobile client is unsuitable;
- `system_timezone`, `sitename`, `app_name`, and optional site `logo`;
- `raven_version`, `frappe_version`, and `min_app_version`.

**Crucial limitation:** this is discovery for **Raven Mobile**, not arbitrary native clients. It validates that the configured OAuth client permits `raven.thecommit.company://oauth`. The repair/creation method sets the mobile redirect URIs and saves its ID in Raven Settings. It is not a general Nevermore registration endpoint. See [mobile API][mobile-api].

Nevermore cannot simply obtain this ID and substitute its own redirect URI. Frappe checks registered redirect URIs. Nor should it register Raven's scheme and compete with the official phone app.

**Recommended integration:** a separate administrator-created OAuth Client for Nevermore, with its own exact redirect URI. The initial client accepts that client ID in advanced onboarding or a configuration file. A future upstream discovery method could advertise independent clients without changing the mobile registration. This addition does not currently exist.

### Existing OAuth flow

The current [native auth implementation][native-auth] uses:

1. `frappe.integrations.oauth2.authorize` with `response_type=code`, client ID, redirect URI, `scope=all openid`, random state, and an S256 PKCE challenge.
2. System-browser authorization, allowing the site's existing password, two-factor, and social/SSO login flow to run there.
3. Form-encoded `POST` to `frappe.integrations.oauth2.get_token` with the authorization code and verifier.
4. Bearer authorization for API requests; refresh-token grants at the same token endpoint.
5. Best-effort revocation at `frappe.integrations.oauth2.revoke_token` on sign-out.

Tokens are kept in secure storage, scoped per site, with refresh handling separated from network outages. Unlike normal Raven RPC responses, the token endpoint returns **top-level OAuth fields**, not `{ "message": ... }`. See [Frappe OAuth routes][frappe-oauth-routes] and [validator][frappe-oauth-validator].

Nevermore should use `ASWebAuthenticationSession`, not an embedded login form or a WebView that collects passwords. Apple's [documentation][apple-auth] explicitly supports the default compatible browser on macOS. Check exact callback, state, pending transaction, and PKCE verifier before accepting a code. Never bundle a client secret. The site's available roles/scopes are the limit; do not invent narrow Raven-only OAuth scopes that the server does not expose.

### OAuth Client list in Desk

Add Account links to `<origin>/desk/integrations/oauth-client` so an administrator can read a registration's client ID. This is a Desk page for a signed-in browser, not an API: Nevermore builds the link and never requests it.

- **Frappe 16:** OAuth Client belongs to the [Integrations module][frappe-oauth-client-doctype], and the [Desk router][frappe-desk-router] takes a leading module segment off `/desk/<module>/<doctype>` and shows that doctype's list. `/desk/oauth-client` reaches the same list.
- **Frappe 15:** Desk lives under `/app`. A [site redirect][frappe15-desk-redirect] turns `/desk/...` into `/app/...`, and the [version 15 router][frappe15-desk-router] opens a workspace when the first segment names one. The address therefore opens the public [Integrations workspace][frappe15-integrations-workspace], which lists OAuth Client under Authentication: one more click, not the list itself.

Source observation only: not exercised on a running site of either version.

### Boot and origin rules

`raven.api.native.boot` returns an authenticated boot object with user/site/version/timezone/configuration information; it constructs a lighter app boot when Desk's cached boot is absent. It also exposes read-only state. See [native server support][native-api].

Its CORS hooks exist because the Capacitor page runs at `capacitor://localhost` or `https://localhost`. `X-Raven-App` is a marker, **not authentication**. A Foundation `URLSession` client is not subject to browser CORS and does not need these exceptions, wildcard CORS, cookies copied from Safari, or disabled CSRF protection.

Treat these as distinct values:

- network origin, including scheme/host/port;
- Frappe `sitename`, used as the socket namespace;
- authenticated user ID;
- Raven workspace ID inside that site;
- display name/branding.

Never use a workspace's display name as an account or database key.

## 4. API contract inventory

### Transport conventions

Most Raven endpoints are Frappe RPCs at `/api/method/<dotted.method>`, returning `{ "message": <result> }`. Generic document REST routes use `/api/resource/<DocType>[/<name>]`, with `data` envelopes. OAuth responses and binary downloads are separate transports. Encode path components and arguments, including spaces in DocType names.

Use authenticated reads and **POST for mutations**, even where a legacy decorator also allows GET. Parse Frappe exceptions into structured errors; never show raw server tracebacks as user-facing error copy. The API needs contract fixtures, not TypeScript-to-Swift type generation alone.

The table omits the common `raven.api.` prefix. `resource:` denotes a Frappe DocType operation, not a new Raven RPC.

| Concern | Existing method/route | Relevant behavior |
| --- | --- | --- |
| Boot | `native.boot` | User/site/configuration subset; authenticated |
| Current user / directory | `raven_users.get_current_raven_user`, `raven_users.get_list` | Current Raven User and user records; lazy-load optional HR data |
| Workspaces | `workspaces.get_list` | Accessible workspace information; membership/admin operations have separate methods |
| Channels and DMs | `raven_channel.get_all_channels(hide_archived)` | Returns `{channels, dm_channels}`; includes visible non-private workspace channels, not only explicit channel memberships |
| Start a DM | `raven_channel.create_direct_message_channel(user_id)` | Server resolves/creates the correct DM; do not synthesize IDs |
| Channel creation/membership | `raven_channel.create_channel`, `leave_channel`; `raven_channel_member.add_channel_members`, `remove_channel_member`, `get_channel_members` | Use server rules for Open/Public/Private and workspace access |
| Initial/context history | `chat_stream.get_messages(channel_id, limit, base_message, update_last_visit, anchor_to_unread)` | Latest page, a context window around a message, or first-unread anchoring |
| Older history | `chat_stream.get_older_messages(channel_id, from_message, limit)` | Server cursor is a message ID; includes complete boundary batches |
| Newer/reconciliation | `chat_stream.get_newer_messages(channel_id, from_message, limit, update_last_visit, include_from_message)` | Can refresh an existing span including its first message |
| Send text/files | `raven_message.send_message_with_attachments(channel_id, content, files, client_id, ...)` | HTML in `content`; uploads happen first; returns an array of created messages |
| Legacy text send | `raven_message.send_message(channel_id, text, ..., json_content, ...)` | Exists, but lacks the v3 send's client retry key |
| Edit | `resource: Raven Message` update `{text: html}` | Current client uses the SDK's document-update operation; server derives edited/plain-text fields |
| Delete / batch lookup | `raven_message.delete_messages(message_ids)`, `get_message_batch(message_id)` | Logical batch may contain several documents |
| Reactions | `reactions.react(message_id, reaction, is_custom, emoji_name)`; `reactions.most_used_reactions(limit)` | **Toggle**, not idempotent “set reaction”. The GET read returns the caller's most-used reactions of the past three months (`reaction`, `is_custom`, `reaction_escaped`, `uses`), clamped to 1–6 rows; removed reactions do not count. Raven web's quick emoji are a per-browser setting, not server state |
| Quoted reply | Send with `is_reply=true, linked_message=<message id>` | Reply metadata attaches to the last message in a multi-part send |
| Threads | `threads.create_thread(message_id)`, `get_thread_details`, `get_all_threads`, `get_other_threads`, `get_unread_threads` | Thread channel name is its root-message ID; replies use ordinary stream/send APIs on that channel |
| Channel read state | `raven_channel_member.track_visit(channel_id, last_visit)` | Explicit timestamp watermark; returns false in read-only mode |
| Mark unread / all read | `raven_channel_member.mark_channel_as_unread`; `raven_channel.mark_all_messages_as_read` | Intentional unread is a separate operation, not a backward normal visit |
| Unread counts | `raven_message.get_unread_count_for_channels`, `get_unread_count_for_channel` | Counts logical batches and excludes System/own messages according to server rules |
| Personal saves | `raven_message.save_message(message_id, add)`; `get_saved_messages(limit, start, search, channel_id)` | `add` expresses desired saved state; `_liked_by` is the underlying personal-save field |
| Message readers | `raven_message.get_message_readers(message_id)` | Returns reader user IDs from channel-member `last_visit >= message.creation`, excluding the author and users hiding receipts; viewer opt-out and anonymous-poll restrictions apply; no per-message read timestamps |
| Forward | `raven_message.forward_message(message_receivers, message_id)` | POST; source is read from the server, including batch members; new copies/batch per destination; no reviewed retry key, so reconcile uncertain results rather than replaying blindly |
| Message web link | `<site origin>/<validated web base>/message/<encoded message ID>` | Existing web resolver route, not an RPC; resolves channel/DM/thread context after authorized fetches; native client uses `raven` as the web base, while web builds can configure it |
| Pins/favorites | `raven_channel.toggle_pin_message`, `toggle_pinned_channel`; `raven_message.get_pinned_messages` | Separate shared message pins from personal channel favorites; toggles need care on retry |
| Main search | `search.sqlite_search(query, filters, limit)` | `filters` is a JSON-encoded string; indexed search with validated metadata keys and server access filtering; no general offset/cursor argument |
| Other search | `search.get_search_result(...)`, `search.search_links(...)` | Different filter/response semantics; do not substitute blindly |
| Channel files | `search.get_channel_files(channel_id, search_text, limit, cursor_creation, cursor_id)` | Reads current database; keyset pagination avoids search-index lag |
| Upload | `/api/method/upload_file` | Current composer uploads privately first, obtaining a File name/URL/size |
| Download | Private file URLs; `raven_message.download_batch_files(message_ids)` | Authenticated file fetch or binary ZIP response, not JSON |
| Link previews | `preview_links.get_previews(urls)` | POST read of server-stored previews keyed by raw URL; stream responses also include a preview sidecar |
| Notification inbox | `notifications.get_notifications`, `get_unread_notification_message_ids`, `mark_message_notifications_read`, `mark_all_notifications_read` | Mentions/reactions have their own unread-message set, separate from channel read state |
| Push registration | `notification.subscribe(fcm_token, environment, device_information)`, `unsubscribe(fcm_token)` | Existing FCM-based registration, not generic APNs support |
| Reminders | `reminders.create_reminder`, `get_reminders`, `snooze_reminder`, `update_reminder`, `delete_reminder`, `mark_reminder_read` | Server-owned, permission/ownership-filtered reminders |
| Schedule send | `scheduled_message.create_scheduled_message(channel_id, text, scheduled_time)`, `get_scheduled_messages`, `send_now` | Scheduled **text**; edit/delete through its DocType; server rounds to five-minute slots |
| Polls | `raven_poll.create_poll`, `get_poll`, `add_vote`, `retract_vote`, `get_all_votes`, `close_poll` | Server owns vote/privacy rules; fetch only authorized detail |
| Document cards | `document_link.get_preview_data(doctype, docname)`, `document_link.get(...)` | Permission-filtered fields, formatted values, server-resolved application links |
| Workflow actions | `frappe.model.workflow.get_transitions`, `frappe.model.workflow.apply_workflow` | Frappe methods used by Raven's document card; separate from message actions |
| Message actions | `message_actions.get_action_defaults`, `execute_action` | Configured server actions, potentially creating documents or running server-side functions |
| Presence/status | `user_availability.get_active_users`, `refresh_user_active_state`; `raven_users.update_raven_user` | Activity is separate from explicit user availability/custom status/quiet-hours settings |

Evidence: [message readers][message-readers], [forwarding][forwarding], [message copy links][copy-message-link], [channel APIs][channels], [workspace APIs][workspaces], [message APIs][messages], [history][history], [threads][threads], [read tracking][read-api], [search][search], [composer uploads][uploads], [editing][editing], [reactions][reactions], [notification inbox][inbox], [push][push-api], [reminders][reminders], [scheduling][scheduling], [schedule validation][schedule-model], [polls][polls], [previews][previews], [document cards][documents], [workflow client][workflow-client], [message actions][actions], [presence][presence].

### Later, read receipts, and message permalinks: review follow-up

The initial inventory omitted contracts that are present in the pinned source. These are source observations, not live deployment tests, and do not establish availability on every 3.2 installation.

- **Later** combines Saved, In Progress, and Completed views: personal saves use `save_message` / `get_saved_messages`; in-progress/completed items use the reminder APIs. It does not require a new Nevermore task protocol. See the [Later view][later-view].
- **Read receipts** have a dedicated [message-reader endpoint][message-readers], also present in the inspected stable-branch snapshot. The endpoint returns user IDs derived from current channel watermarks, not exact read times or immutable receipt events. It checks channel access, excludes the author and hidden readers, refuses viewers who hide their own receipts, and refuses anonymous-poll receipts. Open-channel readers without a membership record are absent. Test these privacy and incompleteness rules; never reconstruct hidden reader lists from another endpoint.
- **Message links** are built by the [existing copy action][copy-message-link] from the site origin, web base, and `/message/${encodeURIComponent(message.name)}`. The [web resolver][message-permalink] locates channel/DM/thread context; this is not `document_link.get` or a message-link RPC. The [site helper][web-site-base] uses `raven` for native links and a configurable base for web builds. Validate the deployed base/route, deleted or inaccessible targets, encoded IDs, thread replies, and login handoff before enabling Copy Message Link. Sharing a link grants no access. Keep document-card links server-resolved independently.

### A representative v3 send

Illustrative request, using the inspected contract, not a captured/live-tested exchange:

```http
POST /api/method/raven.api.raven_message.send_message_with_attachments
Authorization: Bearer <access token>
Content-Type: application/json

{
  "channel_id": "<opaque channel id>",
  "content": "<p>Hello from Nevermore.</p>",
  "files": [],
  "client_id": "<new UUID persisted for this send>"
}
```

The result is `{ "message": [<Raven Message>, ...] }`. A multi-file send creates file messages before the caption, with the shared client ID stored as `message_batch_id`.

The retry lookup is explicitly **not locked** against concurrent identical submissions. It offers practical sequential retry deduplication, not transactional exactly-once delivery across independent writers. Nevermore must serialize retries per persisted send, retain the same UUID, and never replay a timed-out mutation indiscriminately. Reactions and pin toggles are a different case: re-read state after an ambiguous result instead of toggling again.

## 5. Message representation and rendering hazards

[Message types][message-types] and [server parsing][message-model] establish:

- `message_type` currently covers `Text`, `Image`, `File`, `Poll`, and `System`.
- `text` is HTML. `content` is derived, lossy plain text for previews/search, **not a replacement rich body**.
- `json` exists, but is not a consistently populated canonical Tiptap document. System events use structured payloads, and response types allow a JSON string or object.
- `message_reactions`, `_liked_by`, and `replied_message_details` can contain JSON serialized **inside string fields**. Parse them deliberately and tolerate empty/null values.
- User mentions use `span[data-type="userMention"][data-id]`; the server extracts notification recipients from this markup. Sending only `@Display Name` is not equivalent.
- Inline custom emoji use `img[data-type="customEmoji"]`. Spoilers use `data-spoiler`; their body is intentionally masked in derived previews. Do not reveal it in notifications or local search snippets.
- System messages, linked documents, polls, bot attribution, previews, and file batches are structured UI, not just an attributed string.
- Preserve raw unknown data for forward compatibility. An unknown message type needs a visible fallback, not a decoding failure for the whole channel.

**Implication:** the largest native UI risk is a safe, compatible rich-text importer/exporter plus a Mac-quality editor. Avoid Foundation's HTML importer as an unquestioned network/content sandbox; use an explicit supported element/attribute allowlist and controlled media fetching. Editing must preserve supported semantics and must not silently strip unknown constructs from someone else's client. Apple's [NSTextView reference][apple-text] also notes that unsupported TextKit 2 content, including `NSTextTable`, can switch a text view into TextKit 1 compatibility mode; the native layout choice needs a prototype, not a blanket framework assumption.

## 6. Realtime is Socket.IO, not raw WebSocket

The [iOS socket bridge][swift-socket] already uses `socket.io-client-swift`. It sets:

```text
Origin: <site origin>
Authorization: Bearer <access token>
X-Frappe-Site-Name: <Frappe sitename>
namespace: /<Frappe sitename>
```

Hosted deployments normally proxy `/socket.io` on the site's origin; local benches can use a separate socket port. Site identity and external hostname can differ. Frappe checks namespace/site routing and origin, then authenticates through the site. A raw `URLSessionWebSocketTask` implementation alone cannot speak Socket.IO/Engine.IO. See [Frappe authentication][frappe-socket-auth] and [server setup][frappe-socket-server].

The reviewed [Frappe 15 realtime bootstrap][frappe15-socket-server] does not load per-app handler files as Frappe 16 does. Therefore Raven's custom typing events must be tested on each supported framework, and should degrade gracefully rather than block messaging.

### Subscriptions and events to implement

| Direction | Names | Purpose |
| --- | --- | --- |
| Client → server | `doc_subscribe` / `doc_unsubscribe` with `"Raven Channel", channelID` | Message room for visible/warm channels, including threads |
| Client → server | `doc_open` / `doc_close` | Open-document/viewer room; only actively viewed channels, not every cached channel |
| Client → server | `doctype_subscribe` | Relevant permission-checked DocType change streams, including Raven User updates |
| Client → server | `raven_channel_get_typers`, `raven_channel_typing`, `raven_channel_typing_stopped` | Optional Raven typing handlers |
| Server → client | `message_created`, `message_edited`, `message_deleted` | Message changes; payloads are not all full documents |
| Server → client | `message_reacted`, `message_saved` | Reaction aggregate / personal-save changes |
| Server → client | `raven:unread_channel_count_updated`, `raven:unread_thread_count_updated` | Read/unread and sidebar changes; event type matters |
| Server → client | `raven_mention`, `raven_reaction_notification` | Notification-inbox invalidation/update hints |
| Server → client | `raven_channel_typers`, `raven:user_active_state_updated` | Typing/activity |
| Server → client | `raven_scheduled_message_updated` and document-specific invalidations | Re-fetch owner-specific lists or metadata |

Sources: [Frappe handlers][frappe-socket-handlers], [Raven typing handlers][typing], [client subscriptions][subscriptions], [message dispatcher][message-events], [message publishers][message-model], [reactions][reactions], [read tracking][read-utils], [scheduling][schedule-model]. This is the core inventory, not a claim that these are the repository's only events.

**No reviewed durable replay cursor or comprehensive deletion feed exists.** Reconnecting and fetching only messages newer than the last ID does not recover old edits, deletions, missed reactions, membership changes, or read updates from another device. The existing [window reconciliation][loaders] explicitly re-fetches loaded spans after a connection break.

History responses are generally newest-first, including the newer-page response after server-side reversal. Ordering uses `(creation, name)`, and boundary pages can exceed the nominal limit to include a whole batch. Keep timestamp precision and raw server values; do not assume strict page sizes or timestamp-only cursors.

Specific edge cases to contract-test: a nonexistent `base_message` silently falls back to the latest page; older paging lacks the newer endpoint's explicit deleted-cursor guard; and the initial page's `has_old_messages` probe checks only earlier creation timestamps, although the actual ordering also uses `name`. Same-timestamp boundary rows can therefore make that flag misleading. These observations come from [the stream implementation][history], not runtime tests.

## 7. Offline behavior already worth learning from

The current client is not merely a live socket view:

- Message windows are kept warm in memory. The reviewed Dexie schema persists **users, the send outbox, and the visit outbox—not received message history**. Offline reopening of previously received history after a restart is therefore new work for Nevermore, not existing parity.
- A logical send has optimistic placeholders; the HTTP acknowledgement settles it, rather than assuming its realtime echo is the acknowledgement.
- Reconnect/focus reconciliation refreshes loaded windows, including edits and deletions.
- The v3 history fetch explicitly disables the deprecated GET-time read-state write.
- A separate visit outbox retains failed read watermarks, including a `false` maintenance response.
- Message subscriptions cover hydrated/warm channels, with explicit rejoining after reconnect.
- Native boot can use the last good per-site boot on a network failure, while distinguishing an actual HTTP rejection/maintenance response.

There are policies Nevermore should **not** copy blindly: the current message-outbox persistence is best-effort, and its seven-day expiry deletes old queued sends. A Mac client should make persistence failures visible and retain old unsent text for user recovery rather than silently discard it. See [database schema][database], [outbox][outbox], [loaders][loaders], [subscriptions][subscriptions], [native README][native-readme].

### Read state is a protocol, not a local badge

`track_visit(channel_id, last_visit)` accepts the creation timestamp of the newest actually seen message. The server clamps ordinary visits against future/backward movement and broadcasts changes to the user's other sessions. `mark_channel_as_unread` is the intentional backward operation. The server's read rule is timestamp-based; it is not an arbitrary client-generated sequence number.

Nevermore must not mark channels read by prefetching them, fetching search results, handling notifications, or opening background windows. Distinguish channel read state from notification-inbox read IDs and thread unread state. Test queued visits against explicit Mark Unread actions so an old queue cannot immediately undo the user's intent. Sources: [read API][read-api], [read implementation][read-utils], [inbox][inbox].

## 8. Notifications: an actual integration gap

The current [push API][push-api] registers **FCM tokens** and the native app uses Firebase Messaging. Raven/Frappe Cloud push services have their own site credentials and application routing.

This is **not** evidence that a new Nevermore bundle ID can receive background notifications automatically:

- Apple's APNs device token is specific to an app/device, and is not an FCM registration token.
- A different app needs its own signing entitlement and provider-side topic/credentials/routing.
- A bare APNs token cannot simply be posted as `fcm_token` to the existing method.
- The official mobile Firebase configuration and signing material are not reusable Nevermore credentials.

Apple documents the app-specific token and provider relationship in [APNs registration][apple-apns].

**Two honest delivery tiers:**

1. While Nevermore runs, receive realtime updates and present local `UNUserNotificationCenter` notifications. Closing the last window is not Quit. A fully quit or sleeping app cannot rely on an open socket.
2. For background/quit delivery, agree on a real macOS provider route: an upstream extension or an explicit opt-in relay/server integration supporting Nevermore's APNs topic. This is separate engineering and operations work. Do not claim it until end-to-end tested on a signed app and real deployments.

Neither tier is a complete offline message-sync mechanism. On notification activation, reauthorize/refetch and navigate to the canonical account/channel/message.

## 9. Other constraints that affect the design

- **Permission boundaries:** workspace membership matters even for Open/Public channels; private channels/DMs/threads have additional rules. Generic document endpoints do not excuse local permission assumptions. Revalidate after reconnect and remove access-revoked content from local displays/caches once known. An offline cache cannot guarantee immediate remote revocation. See [channel visibility][channels], [search access condition][search], [permissions][permissions].
- **Search:** the SQLite index is background-maintained; the channel-files API was added specifically to avoid its lag. There is no complete server-side cursor pagination contract on `sqlite_search`. Do not market cached/local results as a complete server archive.
- **Scheduling:** the current API is text-only and scheduled times are aligned to five-minute slots by the server. Exact-to-the-second sends or scheduled attachment batches would require a new contract.
- **Document cards:** `get_preview_data` returns server-formatted values, which may include markup. Render safely, respect permissions, and use server-resolved links because installed Frappe applications can override routes. Never evaluate server-provided JavaScript/Jinja locally.
- **Mutations:** several useful methods are toggles or actions without an idempotency key. Nevermore's message-send retry policy cannot be applied wholesale to polls, thread creation, workflows, scheduled-message creation, or ERP actions.
- **Uneven contracts:** normal message history must use Raven's stream APIs, not a generic Frappe resource-list query; the latter has different query-permission behavior. Authorization checks, mutation responses, and legacy methods are not uniform. Test access revocation against each used endpoint and report server defects upstream; a client-side check cannot repair a server authorization flaw.
- **License:** Raven's manifest specifies AGPL-3.0-only; this repository uses the Unlicense. Reimplementing a public protocol and copying upstream source/assets are different activities. Keep the implementation independent, inventory dependency licenses, and obtain legal advice before any code/artwork reuse or App Store strategy. This document is not legal advice.

## 10. Evidence index

All Raven links are pinned to the inspected `develop` revision unless explicitly marked otherwise. Frappe links are pinned to the inspected framework revisions. Apple pages describe framework contracts, not Nevermore implementation decisions.

[overview]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/README.md
[manifest]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/package.json
[native-readme]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/native/README.md
[web-package]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/package.json
[site-state]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/lib/site.ts
[sites]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/native/sites.ts
[screenshot-channel]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/.github/readme/raven-light.png
[screenshot-threads]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/.github/readme/threads-documents-light.png
[editor]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/editor/useRavenEditor.ts#L1-L169
[events]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/events.py
[mobile-api]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_mobile.py#L6-L90
[native-auth]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/native/auth.ts#L1-L161
[native-api]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/native.py
[channels]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_channel.py
[workspaces]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/workspaces.py
[messages]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_message.py#L13-L365
[history]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/chat_stream.py#L130-L464
[threads]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/threads.py
[read-api]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_channel_member.py#L26-L72
[read-utils]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/utils.py#L19-L203
[search]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/search.py#L258-L377
[uploads]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/ChatInput/useFileInput.ts#L145-L221
[editing]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/message/renderers/EditMessageComposer.tsx#L23-L110
[reactions]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/reactions.py#L9-L162
[inbox]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/notifications.py
[push-api]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/notification.py#L8-L134
[reminders]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/reminders.py
[scheduling]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/scheduled_message.py#L10-L74
[schedule-model]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/raven_messaging/doctype/raven_scheduled_message/raven_scheduled_message.py#L33-L103
[polls]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_poll.py
[previews]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/preview_links.py#L81-L151
[documents]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/document_link.py#L19-L95
[workflow-client]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/message/renderers/DocumentLinkRenderer.tsx#L671-L751
[actions]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/message_actions.py#L44-L143
[presence]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/user_availability.py
[message-types]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/packages/types/common/Message.ts
[message-model]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/raven_messaging/doctype/raven_message/raven_message.py
[swift-socket]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/native/ios/App/App/RavenSocketPlugin.swift#L1-L102
[typing]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/realtime/handlers.js
[subscriptions]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/stores/messages/useMessageRoomSubscriptions.ts
[message-events]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/stores/messages/useMessagesRealtime.ts
[loaders]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/stores/messages/loaders.ts#L214-L325
[outbox]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/stores/messages/outbox.ts
[database]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/db/db.ts#L63-L97
[permissions]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/permissions.py
[frappe-oauth-routes]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/frappe/integrations/oauth2.py#L167-L207
[frappe-oauth-validator]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/frappe/oauth.py#L17-L186
[frappe-oauth-client-doctype]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/frappe/integrations/doctype/oauth_client/oauth_client.json#L207-L208
[frappe-desk-router]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/frappe/public/js/frappe/router.js#L839-L880
[frappe15-desk-redirect]: https://github.com/frappe/frappe/blob/53bae3ef2550ca96320f036f581446783cd11b72/frappe/hooks.py#L60-L61
[frappe15-desk-router]: https://github.com/frappe/frappe/blob/53bae3ef2550ca96320f036f581446783cd11b72/frappe/public/js/frappe/router.js#L172-L185
[frappe15-integrations-workspace]: https://github.com/frappe/frappe/blob/53bae3ef2550ca96320f036f581446783cd11b72/frappe/integrations/workspace/integrations/integrations.json#L183
[frappe-socket-auth]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/realtime/middlewares/authenticate.js
[frappe-socket-server]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/realtime/index.js
[frappe15-socket-server]: https://github.com/frappe/frappe/blob/53bae3ef2550ca96320f036f581446783cd11b72/realtime/index.js
[frappe-socket-handlers]: https://github.com/frappe/frappe/blob/3d1284c5fdb52207a516a49bbf2fd186cb43b3ab/realtime/handlers.js
[apple-auth]: https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession
[apple-apns]: https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns
[apple-text]: https://developer.apple.com/documentation/appkit/nstextview

[later-view]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/pages/later/Later.tsx
[message-readers]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_message.py#L616-L672
[copy-message-link]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/message/actions/useMessageActions.tsx#L272-L296
[message-permalink]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/pages/message/MessagePermalink.tsx
[web-site-base]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/lib/site.ts#L24-L25

## macOS completion follow-up · 8 November 2026

The pinned Raven revision also establishes the previously open channel-control contracts:

- `Raven Channel.is_archived` is updated through Frappe's document REST API. The [controller validation](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/raven_channel_management/doctype/raven_channel/raven_channel.py#L219-L252) requires a channel administrator, a Raven Admin with membership, or Administrator. The client must not infer this permission from document ownership alone.
- `Raven Channel Member.muted` is an explicit value on the caller's membership. The channel list returns `member_id`, `is_admin`, `muted`, and `allow_notifications`; [membership permissions](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/permissions.py#L207-L214) permit reading/writing one's own membership. Never use another member's record for a local mute change.
- Joining uses `raven_channel_member.add_channel_members(channel_id, members)` with the current user. Administrative add/remove controls use the same existing membership APIs and retain server permission checks. Open-channel membership follows workspace membership, so removing a workspace member through channel membership is not offered.
- Workspace search must use `channel_id` values resolved from known workspace channels. Both Raven's `get_list` and [Frappe 16.53's query path](https://github.com/frappe/frappe/blob/v16.53.0/frappe/search/sqlite_search.py#L261-L268) merge the account-wide permission filter over client filters, replacing `parent_channel_id`. That key cannot safely express a narrower workspace scope. Workspace channel searches exclude thread replies; account search includes them. `workspace` itself is not an indexed filter. Verified filters also include `owner`, `message_type`, and the endpoint's special `saved`/`mentions_me` keys; search has no offset argument.
- `get_unread_count_for_channels` returns rows keyed by `name`, with `unread_count` counting distinct logical sends/batches. The [unread attention-ID endpoint](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/notifications.py#L188-L250) supplies a distinct mention/reaction message-ID set. A Dock attention dot avoids presenting this set as a combined numeric count with DM unreads.

These are source-verified contracts. Live mutation, permission-transition, and deployment-version validation remain separate acceptance work.

The pinned send endpoints check message/channel permission but do not enforce `is_archived`. Nevermore therefore checks canonical channel and thread-ancestor archive state before outbox transmission and pauses archived operations for review. A client-side check cannot make an external archive change and a subsequent send atomic; a server precondition would be needed for that guarantee.

[forwarding]: https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_message.py#L951-L982
