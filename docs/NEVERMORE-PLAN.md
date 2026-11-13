# Nevermore
## A fully Mac-assed Mac client for Raven

**Status:** implementation baseline; release acceptance remains evidence-gated. See [implementation decisions](implementation/DECISIONS.md) and [validation status](implementation/VALIDATION.md).

**Research date:** 7 November 2026.

**Companion:** [Raven source and API research](RAVEN-RESEARCH.md).

> A Mac app that speaks Raven, not Raven in a Mac-shaped window.

## 1. Recommendation

Build Nevermore as an **independent Swift/AppKit application**, using Raven's existing Frappe HTTP APIs and Socket.IO events. Use SwiftUI selectively for peripheral interfaces where it helps, not as a reason to compromise the transcript, editor, menus, or window behavior.

The app should feel closer to a carefully made combination of Messages, Mail, and a good Mac IRC client than a desktop port of a phone app. Its identity should come from excellent typography, interaction, and restraint—not a permanently visible rack of custom icons.

### Decisions to start with

| Question | Recommendation |
| --- | --- |
| Native technology | Swift 6, AppKit shell, native text system; small SwiftUI islands are acceptable |
| Minimum OS | macOS 15 initially; confirm audience in the first milestone |
| Hardware | Universal Apple silicon/Intel build while the chosen OS and dependencies support both |
| Server baseline | Raven 3.2 stable branch/release builds that pass the contract suite; record the installed commit alongside the advertised version; Frappe 15.111+ and 16 tested separately |
| Accounts | Multiple sites and multiple users on one site; independent live sessions |
| Storage | Per-account SQLite through GRDB; durable drafts/outbox; bounded local history and media |
| Distribution | Signed, hardened, notarized direct download first; sandbox from the outset |
| UI reuse | Reuse Raven's concepts and protocol, **not** its React interface or phone shell |
| Web content | No WebView for chat, composition, navigation, or settings; open external/admin pages in the browser |
| Scope | A daily-driver messaging client before a complete Frappe administration tool |

“Mac OS X” here means a Mac-native application for modern macOS, not support for historical OS X 10.x releases.

### What the research changes

The current iOS/Android apps are Capacitor shells around the React client, not an existing native messaging UI we can port. The backend already supplies most daily-driver features. The hard work is native rich text, reliable state reconciliation, and Mac interaction quality—not inventing a new chat protocol.

Two integrations are **not automatic**:

1. Nevermore needs its **own OAuth Client and callback registration**; the mobile discovery API advertises the official mobile client's redirect.
2. Notifications while Nevermore is quit need a **real provider-side macOS push integration**; the existing FCM-token endpoint does not magically accept a new app's APNs token.

See [authentication research](RAVEN-RESEARCH.md#3-authentication-discovery-and-site-identity) and [notification research](RAVEN-RESEARCH.md#8-notifications-an-actual-integration-gap).

## 2. Product principles

1. **The Mac owns the interaction.** Standard menus, responder chain, keyboard navigation, text selection, system settings, and window behavior are the foundation—not polish added after feature parity.
2. **Reading and writing are the product.** A smooth transcript, dependable editor, recoverable drafts, and correct unread state outrank elaborate administrative settings or animated media stacks.
3. **Never lose the user's work.** A failed connection, restart, expired login, or full disk must not silently erase a draft or pretend a message was delivered.
4. **Respect the server without imitating the website.** Preserve Raven's permissions, workspace model, message semantics, and server-owned actions. Translate presentation into Mac conventions.
5. **Be a considerate citizen.** No surprise login item, global shortcuts, telemetry, Spotlight indexing, unsolicited attention requests, or forwarding chat content to Nevermore-operated services.
6. **Make limitations legible.** Distinguish cached history from a complete archive, a live connection from working realtime, a queued send from a sent message, and running-app notifications from background push.

### Three experiences that should sell the app

- Open a conversation with the keyboard, select a passage across several messages, copy it into Mail, and receive sensible attributed text—with no screenshotting or browser-selection wrestling.
- Drag files from Finder into a conversation, add a caption, preview them with Space, send, and see one stable logical message group even if the network drops after the server accepts it.
- Keep a thread in its own window beside an ERP document and a DM on another Space. Each window restores its place; they share one coherent account session rather than opening three sockets for the same account.

## 3. Scope and feature parity

**Alpha** proves the read/write loop. **Public beta** must be usable for ordinary team chat. **1.0** completes the daily-driver experience and passes the quality gates. “Later” is an explicit deferral, not a hidden dependency of the main app.

| Capability | Alpha | Public beta | 1.0 / later |
| --- | --- | --- | --- |
| Add site, browser login, Keychain, refresh/logout | Yes | Multiple accounts | Enterprise configuration polish in 1.0 |
| Workspaces; Open/Public/Private channels; DMs/self-DM | Read and send | Browse/join/create/leave where permitted | Channel membership/info and archive controls in 1.0 |
| Transcript/history/context jumps/unread boundary | Yes | Reliable reconnect and cached reopening | Large-history and accessibility gates in 1.0 |
| Native composer; drafts; basic rich text | Yes | Mentions, code, lists, spoilers, emoji | Full supported rich-text interoperability in 1.0 |
| Replies, threads, separate conversation windows | Basic | Yes | Native window/tab restoration in 1.0 |
| Images/files; paste/drop; private downloads | Basic | Yes, including batches and offline staging | Quick Look, Save As, reveal/share in 1.0 |
| Edit/delete; reactions; personal saves; pins | Basic subset | Yes | Forwarding, batch actions, read receipts in 1.0 |
| Search | Basic server search | Native scoped search + cached fallback | Files/links/people filters and saved searches in 1.0 if supported without misleading completeness |
| Notifications/inbox; channel mute; Dock badge | Basic while running | Yes, with privacy controls | Background push only on validated provider integration |
| Presence, custom status, quiet hours | Display | Read/write supported settings | Cross-device behavior and restraint in 1.0 |
| Reminders and scheduled messages | — | Read existing items | Create/edit/snooze/cancel in 1.0; scheduling is server-supported text only |
| Polls | Safe display/fallback | Vote/retract | Create/close and authorized results in 1.0 |
| Linked Frappe documents | Safe link/card | Read-only native card | Supported workflow transitions and common message actions in 1.0 |
| Bot messages and AI conversations | Read safely | Normal messaging where supported | Streaming/specialized AI controls after core; no separate Nevermore AI service |
| Site setup, bots/webhooks/AI administration | Browser handoff | Browser handoff | Not required for 1.0; selected admin tools later |
| Mac Share extension | — | Prototype | 1.0 if extension lifecycle/security gates pass; ordinary drag/drop never depends on it |
| Spotlight, Shortcuts/App Intents, Services | — | Basic Services where inexpensive | Opt-in, narrowly scoped integrations after 1.0 |
| Native audio/video calls | — | — | Out of scope until Raven exposes a supported calling contract; meeting links open normally |

**Contract verification.** Final source review additionally confirmed `raven_message.forward_message(message_receivers, message_id)`, `raven_message.get_message_readers(message_id)`, and the `/raven/message/<encoded-id>` resolver in the pinned message-actions implementation. These remain subject to real-deployment tests. Archive/mute controls and broader batch actions still require verified permissions/contracts before release; no endpoint should be guessed.

**Do not broaden “DMs” into a made-up group-DM protocol.** Implement the conversation types the deployed Raven server actually supports. Small private channels are still channels.

**Rich-text compatibility is not optional.** We may limit what the early composer creates, but existing messages must remain readable. An unsupported construct must never be silently destroyed by editing: preserve it, show a clear limitation, or offer “Edit in Raven on the Web.”

Reminders and scheduled sends remain server-owned jobs, not timers that require the Mac to stay awake. Native date/time pickers must show the site's accepted time (including five-minute rounding), and creation is confirmed only after the server accepts it.

## 4. The Mac application

### 4.1 Main window and navigation

Use a standard resizable window with a unified toolbar, real sidebar, and optional trailing inspector/thread pane.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Sidebar  ‹ ›   # engineering             Search       Info       │
├──────────────────┬────────────────────────────────────┬──────────────────┤
│ Acme ▾           │                                    │ Thread / Info    │
│                  │  Alex                 10:42        │                  │
│ Inbox        3   │  Native, selectable message text.   │ Root message     │
│ Threads      2   │                                    │ Replies          │
│ Later            │  Files, code and document cards    │                  │
│                  │  belong to the transcript.         │                  │
│ Workspace ▾      │                                    │                  │
│ Favorites        │  ─────── New messages ──────────    │                  │
│   # engineering  │                                    │                  │
│ Channels         ├────────────────────────────────────┤                  │
│   # general      │ Replying to Alex       [×]          │                  │
│   🔒 finance     │ Write a message…                   │                  │
│ Direct Messages  │                                    │                  │
│   Morgan         │ Attach  Format              Send   │                  │
└──────────────────┴────────────────────────────────────┴──────────────────┘
```

This is an information-layout sketch, not final iconography or a pixel specification.

- Account selection in a labeled sidebar control; show site/user clearly when confusion is possible. Do not confuse Raven workspaces with separate server accounts.
- Standard outline groups for Favorites, Channels, and Direct Messages. Inbox combines the account's mentions/reaction notifications; Threads and Later are native collection views, not web pages. Later groups personal saved messages and reminders (in progress/completed), using the existing save/reminder APIs; it is not a new local-only task service.
- Use the system accent color, semantic materials, SF Symbols, native type sizes, and platform selection states. Respect current system appearance automatically rather than painting a frozen imitation of one macOS release.
- Adjustable sidebar width, compact/comfortable message density, user-adjustable transcript font size. Avoid sprawling phone-sized spacing on a desktop.
- Narrow windows hide the inspector or open the thread separately. Do not shrink three columns until all become unusable or replace the Mac UI with a bottom tab bar.
- Keep navigation history per window: back/forward should restore conversation, message anchor, and search scope. Saved window/search state is private local metadata; account removal must purge that account’s restoration records.

### 4.2 Windows are first-class

- **New Message** opens a recipient/channel chooser. **New Window** opens another browsing window.
- Any conversation or thread can **Open in New Window**. Option-click or a contextual command can open without replacing the current view.
- Support native window tabbing when enabled, the Window menu, full screen, tiling/Spaces, standard title-bar interactions, and normal Cmd-W/Cmd-Q behavior.
- Closing the final window leaves a normal messaging app running, with a Dock menu to reopen it. Cmd-Q really quits; never silently install a helper to defeat Quit.
- Restore window frames, account/workspace, conversation, thread, and scroll anchor when allowed by system preferences. Never restore a signed-out account's private content.
- A thread window carries enough parent context to make sense alone and has “Show in Channel.”
- One account-level session/sync engine serves all its windows. View subscriptions are reference-counted; no duplicate room traffic, refreshes, or sends per window.

### 4.3 Transcript: text, not a stack of unselectable cards

- Favor a chronological, left-aligned transcript with clear author/time grouping. Chat bubbles can be an appearance option, not the organizing principle.
- Real native selection: words, paragraphs, keyboard extension, cross-message ranges, Select All, Copy, Look Up, Services, accessible links, and an appropriate contextual menu.
- Copy emits plain text and a safe rich-text representation. A separate “Copy Transcript” action can include author names/timestamps. “Copy Message Link” copies the canonical Raven web URL so authorized colleagues can use it without Nevermore: the validated Raven web base plus `/message/<percent-encoded message ID>`. The [permalink contract](RAVEN-RESEARCH.md#4-api-contract-inventory) is an existing web route, not a new server RPC; validate the web base and route on each supported deployment before enabling it.
- Preserve the reader's visible message and pixel offset when prepending history, inserting realtime messages, updating media dimensions, or resizing a window.
- Auto-scroll only when already following the live edge. Otherwise show an unobtrusive new-message affordance. A background notification must not drag the transcript to the bottom.
- Render code with a monospaced font, horizontal scrolling, selectable content, and Copy Code. Long code can collapse without hiding the fact that content exists.
- Render images, files, polls, link previews, and document cards as accessible native content. Never execute embed HTML. Open YouTube/Spotify/etc. in the appropriate browser/app rather than reproducing every web player.
- Distinguish unknown/unsupported content, deleted replies, inaccessible documents, and failed media. Blank space is not a fallback.

**Early go/no-go prototype:** virtualized AppKit rows do not automatically provide selection across text views. Prove cross-row text selection, keyboard selection, VoiceOver, and scroll anchoring before committing the transcript architecture. A beautiful demo that can only select one message is not sufficient.

### 4.4 Composer

Use `NSTextView` and the native text-input system, with a small formatting accessory and Format menu.

- Standard selection/editing, Undo/Redo, findable menu commands, spelling, substitutions, dictation, IME/marked text, dead keys, accents, RTL, and emoji picker.
- Return sends by default; Shift-Return or Option-Return inserts a line break; Cmd-Return always sends. Offer “Return inserts a newline” as a preference. Never send while the input method is committing marked text.
- Native formatting for bold/italic/underline/strike, code, links, lists, and blockquotes. Add the other supported Raven constructs deliberately, not by accepting arbitrary pasted HTML.
- Optional Markdown-style input shortcuts may transform to the native document model, but the wire format remains Raven-compatible HTML. Do not send raw Markdown and hope other clients interpret it.
- `@` user and `#` channel completion are keyboard-accessible popovers with stable identifiers, not plain-text substitutions. Custom emoji retain server identity.
- A visible reply/edit state, with Escape cancelling the operation without destroying unrelated drafts. Up-arrow may edit the last own message only when the composer is empty and no input composition is active.
- Drafts persist per account + conversation/thread, including formatting, reply context, staged attachments, and caret position. Two windows editing the same draft share one draft session or explicitly offer separate drafts; never last-writer-wins silently.
- Paste text normally; Paste and Match Style removes foreign styling. Paste screenshots/files into an attachment staging area. Large/multiline paste should not accidentally send.
- Show attachment progress, cancellation, retry, size/type rejection, and an explicit send state. No disappearance of a file when upload fails.
- Once Send is accepted, the durable send operation is immutable. Correct it after acknowledgement, or cancel only if transmission has not begun. Do not mutate the payload under an existing retry key.

### 4.5 Menus and keyboard behavior

Every important command must exist in the menu bar and participate in normal enabled/disabled validation. A command palette is an optional accelerator, not the only discoverable UI.

| Menu | Representative commands |
| --- | --- |
| Nevermore | About, Settings… (Cmd-,), Services, Hide, Quit |
| File | New Message (Cmd-N), New Window (Cmd-Shift-N), Open Conversation… (Cmd-O), Attach Files…, Save Attachment As…, Close |
| Edit | Undo/Redo, Cut/Copy/Paste, Paste and Match Style, Find (Cmd-F), Find Next (Cmd-G), spelling/substitutions |
| View | Show Sidebar, Show Inspector, transcript size/density, full screen |
| Conversation | Reply, Open Thread, Mark Read/Unread, Mute, pin/save, search this conversation |
| Format | Native text formatting; Add Link (Cmd-K in the composer) |
| Window | Standard windows/tabs/navigation commands |
| Help | Nevermore Help, Keyboard Shortcuts, connection diagnostics |

Use Cmd-Shift-F for search across the current account. `Open Conversation…` is a fast fuzzy chooser. Preserve Ctrl-Cmd-Space for the system emoji picker, ordinary text navigation, and system shortcuts. Do not install a global hotkey by default.

### 4.6 Search

- A native search field and results view, with explicit **conversation / workspace / account** scope. All-account search can fan out later, but must never silently mix identically named sites.
- Immediate cached results while online search runs; label offline/partial results as such. Server search is permission-filtered and can lag indexing.
- Translate supported filters into actual Raven API arguments; do not claim a Slack-style query grammar or unbounded result pagination the server does not supply.
- Cmd-F searches the conversation, Cmd-Shift-F searches the account. Cmd-G/Shift-Cmd-G traverse results without discarding the search.
- Selecting a result loads a server context window around its message. It must not assume the message is already in local history, nor mark the intervening channel history read.
- Native Quick Look and file actions also work from file-search results. Cache removal or permission loss removes related local index entries.

### 4.7 Files and system integration

- `NSOpenPanel`/`NSSavePanel`, Finder drag/drop, pasteboard images, and file promises for dragging downloaded attachments back to Finder.
- Space invokes Quick Look for a selected attachment; images can have a native preview window. PDFs and media use system frameworks where practical.
- Private media needs a controlled authenticated downloader/resource loader. Do not assume an arbitrary `AVPlayer` URL request inherits API authorization headers. Prove Range requests, refresh, seek, and cancellation in the integration spike.
- Downloads are streamed to temporary files, atomically finalized, and exposed only when complete. Honor MIME/type and size limits; quarantine untrusted downloads appropriately. Never execute downloaded content or auto-open executables.
- Reveal in Finder, Open With, Save As, Copy Link, and the system sharing menu where appropriate.
- Sandbox access is user-selected and scoped. Copy staged attachments into app-controlled durable storage before queueing; do not assume Finder URLs remain readable after restart. Use security-scoped bookmarks only where necessary and handle revocation.
- A Mac Share extension can send text/files into a **reviewable draft**, never directly to a guessed account/channel. Use the app's own App Group and bounded authenticated IPC/data handoff, not the official app's group.

### 4.8 Notifications and attention

Use `UNUserNotificationCenter`, with permission requested after the user understands what will notify them.

- Respect Raven channel preferences, explicit availability/quiet hours, macOS notification settings, and Focus. Do not claim to read or control the user's Focus configuration.
- No sound for every background message by default. Offer a conservative mentions/DM policy; separate local Mac preferences from server-shared settings.
- Suppress redundant presentation for a conversation actively being read. Deduplicate by account + message across socket and push deliveries.
- Show account/site when necessary. Offer sender-only or content-hidden notifications; spoilers and sensitive document fields must not leak into previews.
- Notification activation routes to the right account and message. Offer Mark Read/Reply only after the routing, authorization, persistence, and background lifecycle are proven.
- Badge policy is explicit: mentions/DM attention by default, optionally all unreads or none. Do not sum raw message rows when Raven counts a multi-file batch as one send.
- An optional menu-bar item can show status/unreads. It is not a replacement for a normal Dock app, and is off unless wanted.
- “Launch at Login” is opt-in through `SMAppService`. No hidden LaunchAgent or immortal polling helper.

[The delivery tiers and server work are specified below](#8-background-push-and-server-side-cooperation).

### 4.9 Settings, accessibility, and visual character

Use a conventional Mac Settings window: Accounts, General, Appearance, Notifications, Privacy & Storage, and Advanced/Connection. Settings should be searchable or have clear labels; account-specific settings must identify their account.

- Follow light/dark appearance, accent, increased contrast, reduced transparency/motion, keyboard navigation, and user font preferences. Do not encode unread, mention, or availability solely in color.
- VoiceOver can traverse messages as meaningful groups, inspect author/time/content/actions, operate the composer and polls, and navigate threads without a mouse. Avoid announcing every background update while someone is typing.
- Make status descriptions and timestamps localizable; support RTL, long names, emoji graphemes, and differing regional date/number formats from the beginning.
- **App icon decided:** use the project owner's supplied blue-black raven over a glowing blue “R,” preserved as [`assets/AppIcon-original.png`](../assets/AppIcon-original.png). macOS icon sizes and an `.icns` are provided in [`Resources`](../Resources); include `Assets.xcassets` in the future application target and select `AppIcon`. Preserve the supplied composition rather than commissioning a replacement icon. Keep personality elsewhere restrained: no Poe quotations in errors or novelty graphics throughout the workspace.

## 5. Engineering architecture

### 5.1 Shape of the application

```text
AppKit application / windows / menus / native text views
                     ↓ commands        ↑ observable read models
                AccountCoordinator (one per account)
                     ├── RavenAPI / OAuthSession
                     ├── RealtimeConnection + subscription registry
                     ├── SyncEngine + mutation/outbox coordinator
                     └── AccountStore (SQLite + files)

Shared, UI-independent code:
  wire codecs • domain identities • rich-text AST/HTML codec • reducers
```

Use actors for account session, durable storage, and mutation serialization; keep AppKit and presentation state on `@MainActor`. Parse rich text, decode large responses, and perform disk/network work away from the UI thread. Do not pass mutable AppKit text/layout objects across actor boundaries.

A small set of Swift packages/targets is enough:

- **NevermoreApp:** AppKit lifecycle, windows, commands, settings, notifications, previews, share-extension integration.
- **RavenProtocol:** typed RPC/resource clients, wire models, Socket.IO adapter, endpoint/capability descriptions; no AppKit dependency.
- **NevermoreCore:** account/domain models, sync reducers, outbox, drafts, local store, search, rich-text model/codec.
- **TestSupport:** fixtures, fake clock/transport/socket, deterministic fault injection; not shipped.

Keep the share extension separate and small. Do not build a generic cross-platform UI framework or a plugin marketplace before shipping chat.

### 5.2 Technology choices

| Area | Starting choice | Reason / validation needed |
| --- | --- | --- |
| Window/sidebar/toolbars | `NSWindowController`, split view, outline view, toolbar, responder chain | Native behavior and fine control of restoration/focus |
| Transcript | Continuous TextKit-backed native transcript with a bounded working set | Native cross-message selection; validate VoiceOver, prepending anchors, table fallback, and large-history performance |
| Composer | `NSTextView`, TextKit, `UndoManager`, native input handling | Do not trade IME/accessibility for easier custom rendering |
| Rich-text parsing | Small native AST plus a maintained HTML parser, e.g. SwiftSoup | Explicit allowlist/normalization; not arbitrary browser rendering |
| HTTP | Foundation `URLSession`, async/await, typed `Codable` adapters | Cancellation, authentication, streaming; no general networking framework required |
| Realtime | `socket.io-client-swift`, pinned after compatibility tests | Existing Raven iOS precedent; validate Engine.IO/Socket.IO versions and proxy behavior |
| Persistence | GRDB/SQLite, explicit migrations and FTS for cached content | Predictable schema, transactions, bounded queries, offline search |
| Secrets | Security framework / Keychain | Per-account tokens; no secrets in defaults or logs |
| Files/previews | Quick Look, ImageIO, PDFKit, AVKit as needed | Familiar behavior; bounded decode/resource use |
| Updates | Sparkle 2 for direct distribution | Signed update metadata/artifacts; sandbox/signing spike before commitment |
| Testing | Swift Testing/XCTest plus XCUITest | Protocol tests independent of GUI; real Mac interaction tests |

Pin versions, audit transitive dependencies/licenses, validate Swift 6 concurrency compatibility of every pinned dependency, and keep the runtime dependency list short. Reuse maintained protocol/parsing/database libraries rather than inventing them. SwiftData/Core Data are not needed in addition to SQLite. Avoid layers whose only purpose is to rename another layer's methods.

### 5.3 Account and storage model

A **site** has an origin and Frappe namespace. An **account** is a local identity bound to a site, authenticated user, and OAuth registration. A **workspace** belongs to that account's Raven site. Display names and server message IDs are not globally unique keys.

Persist, scoped per account:

- site metadata, discovered versions/capabilities, current user and directory subset;
- workspaces, channels/memberships, threads, server sidebar summaries;
- messages keyed by server ID, with raw wire payload and normalized fields;
- loaded-range coverage/freshness and observed deletion tombstones;
- drafts and attachments in staging;
- immutable queued send operations, attempts/status, and server acknowledgements;
- pending read watermarks and explicit unread-operation generations;
- notification-inbox read state, pins/saves, reminders/schedules as cached projections;
- view restoration state and local search index.

Keep media bounded and evictable, separate from non-evictable unsent drafts/outbox. Suggested initial policy: cache recently opened conversations with a configurable age/size limit; do not download the whole company archive on login. Start with a modest media budget (e.g. 500 MB) and expose usage/clear controls.

**Local privacy boundary:** Keychain protects tokens; a sandbox and user-only file permissions protect local databases/files, and FileVault is the device-at-rest boundary. Do not describe SQLite or downloaded attachments as app-encrypted when they are not. Offer “Don't retain message history” for shared/sensitive Macs while preserving explicitly unsent work. Deployments requiring application-layer encryption need a vetted SQLCipher/attachment-storage design and validation before rollout—not homemade crypto or an unqualified security claim.

Never sync tokens or chat databases through iCloud by default. Spotlight indexing is off by default and out of initial scope. Removing an account clears its credentials, database/index, staged data, media, notifications, and restored views after a clear warning about unsent work. Explain that OS backups and already exported files are outside guaranteed erasure.

### 5.4 Rich-text boundary

Create one tested codec between Raven HTML and a native, versioned rich-text document model. Keep raw HTML alongside it for compatibility/debugging without recording it in logs.

- Support an explicit element/attribute set for Raven's actual message grammar: paragraphs/breaks, inline marks, lists, quotes, code, links, mentions, emoji, spoilers, tables, and safe inline media fallbacks.
- Preserve server identifiers and semantic attributes; never round-trip mentions as display text alone.
- Decode nested JSON string fields independently and tolerate missing/unknown fields, numeric/string booleans, and future message types where observed in fixtures.
- Reject scripts, event handlers, unsafe URL schemes, unbounded data URLs, and unsolicited embedded web frames. Never let a message invoke native commands through a link.
- Fetch site-private images only through the authenticated resource layer; external previews/media never receive account credentials. Provide controls for external media requests to reduce tracking.
- Normalize pasted rich text into supported constructs. Export canonical Raven-compatible HTML; do not use the derived `content` string for rich-body edits.
- Prove table/block-attachment layout early. TextKit 2 is not a blanket compatibility guarantee: `NSTextTable` can trigger TextKit 1 compatibility mode. Choose a tested native rendering path rather than assuming every rich-text construct has the same layout/accessibility behavior.
- If an edit would remove an unhandled construct, stop and offer a safe alternative. The user should not need to discover data loss after sending.

Build a golden corpus from sanitized examples produced by the existing clients. Include multilingual text, mentions, custom emoji, spoiler-only content, links with special characters, nested lists, code, tables, malformed HTML, legacy messages, and structured System events.

## 6. Server integration and compatibility

### 6.1 Onboarding and authentication

1. Enter a site URL. Normalize to an origin; prefer HTTPS. Reject credentials embedded in URLs and ambiguous/non-web schemes. If supplied `/raven/...`, explain which site origin will be used.
2. Fetch public Raven metadata. It can identify a site even if its **mobile** `client_id` is null. Distinguish unreachable, incompatible, redirected, and non-Raven sites.
3. Obtain a dedicated Nevermore OAuth Client ID. Initially this is an administrator setup step, with documented exact redirect URI, roles, and public-client settings for the relevant Frappe version. Enter that public client ID in an Advanced field in Add Site and persist it with the account's OAuth registration before starting authorization. A configuration-file input may supplement this field; managed profiles are not an alpha prerequisite. Do **not** run the mobile client's repair method to configure Nevermore.
4. Start `ASWebAuthenticationSession` with random state and S256 PKCE. Use an owned reverse-DNS callback scheme finalized with the bundle identity; do not register Raven Mobile's callback.
5. The site's existing login/SSO/MFA UI runs in the system browser. Exchange only the resulting code through `URLSession`; store refresh/access tokens in account-specific Keychain items.
6. Fetch authenticated boot/current Raven User, verify identity, and create/open that account's store. If the same site is added with a different user, it gets a separate account/store. Offer a separate-account sign-in flow rather than assuming the browser's existing site session belongs to the intended user; always show the identity actually returned.
7. Refresh through a single-flight account session coordinator, allowing at most one authentication retry on a safe request. A refused refresh requests login; a network failure retains work and credentials rather than logging the user out.
8. On sign-out, unsubscribe push where possible, revoke tokens best-effort, close sockets, and forget credentials locally even if the site is unreachable. Retain or remove unsent work only through an explicit recovery/discard choice, inaccessible to another account.

The existing mobile scope is `all openid`, not a narrow Raven-only scope. Explain the actual server consent; do not pretend Nevermore can enforce scopes the server does not expose. Never ship a client secret or offer password/API-secret storage as the standard login path.

### 6.2 HTTP and deployment handling

- Separate Frappe RPC `message`, resource `data`, OAuth top-level fields, and binary responses in transport code; tolerate omitted payloads for successful void methods.
- Isolate bearer-authenticated HTTP/socket transports per account. Disable shared cookie storage and avoid a shared authenticated-response URL cache; the same URL fetched by two users must never become a cross-account cache hit.
- Encode identifiers safely; use opaque server IDs and server-resolved document links. Message permalinks use the source-verified web route in §4.3 with a deployment-validated web base; do not guess workspace/channel paths or infer a document route from a message route.
- Send bearer credentials only to the bound site origin. Redirects to another origin require explicit handling and never forward authorization automatically. Do not migrate an authenticated account to an unexpected hostname behind the user's back.
- Trust the OS certificate store; support enterprise roots installed by the administrator. No “ignore all certificate errors.” Plain HTTP is a clearly isolated local-development configuration, not a release default.
- URLSession needs no CORS bypass or disabled CSRF setting. Do not copy Raven's development instructions to production onboarding.
- Bound request timeouts and retries, respect rate-limit/backoff hints, cancel stale window loads, and present useful maintenance/auth/permission/offline errors.
- Use site/system timezone metadata to interpret Frappe timestamps. Preserve raw timestamp precision, including microseconds, for paging/read state. Never silently interpret all naive server timestamps in the Mac's timezone.
- No automatic retry of non-idempotent operations just because their HTTP request timed out.

### 6.3 Capability policy

There is no reviewed complete, versioned Raven capability manifest. Start with a small adapter for the **tested stable contract**, explicit feature checks, and a compatibility table maintained alongside tests.

- Unknown optional fields should not break decoding.
- Unavailable optional APIs disable the affected UI with a clear reason; they must not stop basic messaging.
- Unsupported core contracts produce a meaningful incompatibility screen and “Open Raven in Browser.”
- Probe non-mutating endpoints only; never discover a capability by creating a poll, channel, or OAuth Client.
- Treat Raven's `min_app_version` as a mobile-app hint, not a Nevermore version gate.
- Do not claim Raven 2.x/3.1 support until a separate compatibility adapter and test matrix earn it.

The [research inventory](RAVEN-RESEARCH.md#4-api-contract-inventory) names the concrete existing endpoints. A proposed future capability/discovery endpoint belongs in an upstream contribution, not a list of APIs Nevermore assumes already exist.

## 7. Synchronization and reliability

### 7.1 Connection state

Track **network reachability, HTTP authentication/service health, realtime connection, and content freshness separately**. A working website with broken Socket.IO is not “offline,” and a connected socket does not prove the cache is current.

One authenticated Socket.IO connection per live account, using the site's namespace and required Origin/Authorization/site headers. Subscribe to visible conversations plus a bounded warm set; use viewer/typing rooms only for actively viewed channels. Rejoin after reconnect; reference-count interest across windows. Idle or sleeping Macs should not aggressively poll every channel.

Account state is explicit: connecting, live, realtime-degraded, offline/cached, maintenance/read-only, authentication required, or incompatible. Surface it calmly in the sidebar/toolbar, not as an endless spinner or repeated modal alert.

### 7.2 Reconnect algorithm

1. Bump a connection generation; mark affected ranges and account summaries stale. Discard late responses belonging to an obsolete navigation/account generation.
2. Refresh authentication if necessary, reconnect, and restore desired subscriptions. Buffer concurrent message events while canonical fetches run.
3. Re-fetch account channel/workspace membership, unread summaries, notification IDs, and current thread metadata. Remove known-revoked access immediately, including local index/media references.
4. Re-fetch the visible message span using the existing context/newer APIs, including existing rows rather than only requesting newly created messages. Page until the intended range is covered; boundary batches may exceed requested limits.
5. Reconcile inserts/edits/reactions and observed deletions transactionally. Only infer deletion within a **fully covered authoritative range**, not from absence in an arbitrary page. An expired/deleted cursor requires re-anchoring.
6. Apply buffered events against the refreshed projection; preserve tombstones and guard against a stale pre-delete HTTP response resurrecting content. Re-fetch when partial events or event/snapshot ordering leave ambiguity.
7. Resume serialized retryable sends, then eligible read-state updates; refresh affected canonical state after ambiguous results.
8. Repair other cached ranges lazily when revisited. Surface cached/last-checked status offline; do not promise that an unvisited historic range has received every deletion.

There is no complete reviewed server change cursor/deletion log. A fully synchronized permanent archive would need upstream work. Nevermore's v1 promise is **a dependable bounded cache**, not a perfect offline replica of the entire server.

### 7.3 Durable send pipeline

```text
Draft → durable queued operation → uploading → sending → acknowledged
                                  ↘ retryable / needs review / rejected
```

- Commit the immutable operation and any staged attachment references **before** clearing the draft or presenting it as safely queued. If storage fails, keep the editor content and explain the failure.
- Generate a high-entropy UUID once per logical send and persist it. Use the v3 `send_message_with_attachments` endpoint for both text and files, with the same `client_id` on every retry.
- Upload privately first. Persist completed File identifiers/URLs/sizes so a retry can reuse them; a failed send must not repeatedly upload every attachment unnecessarily. Do not assume upload itself has send-level idempotency or resumable-chunk support.
- Show a stable optimistic group keyed by the local operation. Reconcile the returned array of server messages into it without moving the scroll anchor or duplicating the caption/files.
- The HTTP acknowledgement is authoritative for the send. A realtime echo may precede/follow it; deduplicate by message ID and batch/client ID.
- Serialize attempts **per operation**, across windows and relaunch. Raven's current batch lookup is not a concurrent exactly-once guarantee. Validate returned channel/owner/batch identity before accepting an acknowledgement.
- Treat timeouts after transmission as uncertain, not rejected. Retry only the same immutable send/key through the documented dedupe path. Permission/validation errors remain visible and require correction/manual action.
- Old offline sends should pause for review after a defined age (initial proposal: 24 hours). Keep their text/files recoverable; never copy the existing client's silent seven-day deletion policy.
- Permit Cancel before transmission and Discard/Recover Text afterward where appropriate. Do not promise cancellation can unsend a request the server may already have committed.
- Limit concurrent uploads and total staging space, retain retry history without content in logs, and clean orphaned temporary files conservatively. Never delete a server File that may already belong to a sent message without checking.

Other mutations get separate policies. Reaction/pin toggles, workflow actions, poll operations, thread creation, and schedule creation must reconcile after an uncertain result rather than blindly replay. Initial beta can require a connection for these actions while preserving drafts offline.

### 7.4 Unread state

- Fetch messages with `update_last_visit=false`; history fetches must not mark a channel read.
- Report `track_visit` only for the newest actually visible/seen message in an eligible foreground window. Prefetch, search, previews, background windows, and received notifications do not count as reading.
- Persist failed/declined watermarks; a `false` read-only/maintenance response is not success.
- Ordinary watermarks advance monotonically. Explicit Mark Unread starts a new local generation and invalidates stale queued visits that would immediately undo it. Coordinate this with cross-device updates and accept the server's canonical response.
- Keep channel unread, thread unread, and notification-inbox unread IDs separate. Use server canonical counts to heal local estimates and count logical file batches correctly.
- Presence reflects foreground activity and explicit availability, not merely an open socket. Do not report “active” indefinitely while the Mac sleeps.

**Quiet-hours contracts.** Raven User stores availability, custom status, read-receipt preference and `quiet_hours_nudge`; organization working hours come from Raven Settings/boot. There is no per-user server start/end window. Nevermore’s incoming-notification quiet hours are explicitly local and account scoped. Apply the Raven after-hours nudge at send acceptance and persist the resulting `send_silently` choice with the immutable outbox payload; reconnect must not change it.

## 8. Background push and server-side cooperation

### Tier A: no new push infrastructure

While Nevermore is running, realtime events plus ordinary canonical reconciliation drive local notifications. This works without enrolling the user's organization in a Nevermore cloud service. State the limitation plainly: **Quit stops this delivery path, and sleep can suspend it.**

This is the public-beta baseline. Use user-scoped unread events to notice activity outside subscribed warm channels; fetch any required canonical message data through authorized APIs. Do not join every channel merely to make notification bodies available.

### Tier B: real background delivery

Investigate with Raven/Frappe maintainers whether the existing push service can support Nevermore's distinct macOS bundle/topic. If not, design an optional server-side integration that routes authorized events to APNs through an explicitly configured provider/relay.

Required work:

- Nevermore App ID, push entitlement, development/production APNs registration and provider credentials;
- provider-side routing for this app/topic, not the official mobile project's configuration;
- authenticated token registration tied to account/user/device, rotation/unsubscribe, stale-token cleanup, and correct environment;
- minimal payloads with a deliberate privacy policy; do not send access/refresh tokens or unnecessary message/document content through a relay;
- server authorization and notification-preference enforcement, including quiet hours and access revocation;
- deduplication with running-app notifications, delivered-notification cleanup, and correct cold-start routing;
- physical-Mac tests of delivery, activation, denied permission, logout, account removal, and provider outages. APNs delivery is best-effort, not a sync log.

**Decision gate:** before advertising quit-time notifications for 1.0, demonstrate end-to-end delivery using Nevermore's signed production identity on both intended deployment types. Otherwise ship the running-app tier with the limitation clearly documented. Do not add a hidden always-on helper or mandatory centralized relay as a shortcut.

### Small upstream improvements worth proposing

These are **proposals, not existing endpoints**:

1. A capability/version manifest and a supported way to discover/register separately named native clients without overwriting the mobile OAuth client.
2. Better scoped/concurrency-safe send idempotency if multiple independent writers must retry the same operation.
3. Desired-state mutation APIs where current toggles complicate retries.
4. A durable changes/deletions cursor if a complete offline archive becomes a goal.
5. Extensible push registration/provider routing for additional native apps.

Core messaging should not require maintaining a fork of Raven. Keep any optional bridge/provider component narrowly scoped and independently documented.

## 9. Security, privacy, and distribution

### Threat boundaries

Treat message HTML, filenames, document previews, links, server configuration, push payloads, and deep links as untrusted input—even on an organization's own site.

- Site-origin isolation for all tokens/downloads, including redirects and media requests; test lookalike hostnames, ports, URL userinfo, and encoded paths.
- No rendering/execution of remote JavaScript in privileged native UI. Parse server-formatted document fields safely; execute workflow/custom actions on the server only, after clear user confirmation for consequential changes.
- Permission changes close/restrict related windows, cancel queued unauthorized mutations, and remove known-revoked cached content. Be honest that an offline client cannot learn about revocation immediately.
- Custom deep links contain routing identifiers, never credentials. They cannot trigger a send, join an unknown site, read local files, or execute a workflow without user confirmation. Copy/share canonical web message links by default.
- Resource limits for malformed HTML, decompression/image bombs, huge code blocks, attachment staging, preview generation, and search responses.
- Private content excluded from diagnostics by default. Logs contain operation/request identifiers, endpoint category, timing, error class, and connection transitions—not tokens, message bodies, sensitive URLs, or document data.
- Crash reporting is opt-in, with redaction; no analytics/AI telemetry dependency in the app's normal chat path.

### Distribution

Start with a sandboxed, hardened-runtime app signed with Developer ID and notarized, distributed as a straightforward download/DMG. Use only necessary network, user-selected file, notification, and extension entitlements. Test the **packaged signed app**, not just Debug builds.

Use Sparkle's signed updates for direct distribution, with a pinned update-signing policy, separate test/stable feeds, update notes, and reversible database migrations/backup recovery. Protect signing and provider credentials outside the repository. Publish checksums, supported server/OS versions, dependency notices, privacy documentation, and a security-reporting contact.

Evaluate the Mac App Store separately after sandbox, update-channel, encryption/export, and licensing requirements are understood. Nevermore's current Unlicense must not be assumed to relicense Raven's AGPL source or artwork. Implement independently, use the owner-supplied Nevermore app icon, create or obtain permission for additional assets, and review any contemplated upstream code reuse before it enters the repository.

## 10. Delivery plan

### Team and estimate

A sensible team is one experienced Mac/AppKit engineer and one protocol/storage engineer, with part-time design/accessibility/QA help and a Raven/Frappe maintainer available for integration questions. One person can do it, but the text-system and sync work should not both be treated as weekend glue code.

Initial planning allowance: **20–30 engineer-weeks for the core 1.0 scope, plus about 25% contingency**. With two experienced engineers, allow roughly four to six calendar months including integration and beta feedback. The milestone ranges below are **before contingency**: the arithmetic allowance including 25% is **25–37.5 engineer-weeks**, not 20–30. These are unvalidated scope estimates, not commitments; milestone 0 must map every §3 alpha/beta/1.0 commitment to a deliverable and re-estimate the full rich-text corpus work before confirming a schedule. In particular, channel membership actions, early polls/pins/saves, reminders/schedules, and document cards need explicit allocation before their promised tier can ship; milestone 4 cannot be the first delivery of items promised for alpha/beta. New push infrastructure and specialized AI/admin parity are separately estimated.

### Milestones and acceptance gates

| Milestone | Work / deliverable | Acceptance gate |
| --- | --- | --- |
| **0. Prove the dangerous assumptions** · 1–2 engineer-weeks | Run pinned Raven/Frappe fixtures; dedicated OAuth registration; HTTP + Socket.IO + private media spike; transcript-selection/IME prototype; signing/sandbox/update feasibility; first native window mockup | Browser PKCE works without the mobile callback; two-user realtime and private Range downloads work; prototype proves cross-message selection, VoiceOver and stable history prepending; record unresolved provider support |
| **1. A useful native reader** · 3–4 | AppKit shell/menus/sidebar; account storage; workspaces/channels/DMs; safe HTML renderer; history/context/unread display; multiple windows; read-only cache | Read a real organization's channels without a browser; restart into bounded cached content; no incorrect read marks or cross-account data; native selection/window behavior passes review |
| **2. A trustworthy writer** · 4–6 | Native composer/codec; drafts; mentions; private attachment staging; immutable durable send queue; ack/echo reconciliation; edit/delete/reply/basic thread/reaction actions | Web/mobile correctly render Nevermore messages and vice versa; IME/Undo work; lost acknowledgements/restarts do not lose sends or cause sequential duplicates; full-disk failure preserves the draft; two windows editing the same conversation prove the chosen shared-session or explicit separate-draft behavior without silent overwrites |
| **3. Daily-driver public beta** · 4–6 | Multiple simultaneous accounts; reconciliation; explicit read state; search/inbox/Later display; system notifications while running; Quick Look/downloads; presence/mute; native settings | Two accounts/two windows survive offline, sleep/wake, expired token, maintenance and membership changes; privacy commitments in §§5.3 and 9 verified; §11 performance budgets measured; no claim of unsupported quit-time push |
| **4. Finish conversation parity** · 5–8 | Rich-text edge cases/tables/spoilers; polls; reminders/scheduled text; pins/saves/forwarding/read receipts; document cards and supported workflow/actions; share-extension decision | Core parity matrix satisfied against real deployments; unsupported/admin features have explicit browser handoffs; no lossy editing or blind retries of consequential actions |
| **5. Ship a Mac app, not a prototype** · 3–4 | Accessibility/localization pass; resource/power tuning; restore/update/migration tests; production signing/notarization; documentation and recovery UX; external beta | Release checklist below passes on supported OS/hardware/server matrix; signed direct-distribution update tested; privacy/license/security review complete |

**Tier gates:** milestone 2 is the earliest internal alpha, milestone 3 the earliest public beta, and milestone 5 the 1.0 release gate. Each also requires all commitments in its §3 column (including earlier tiers); a milestone title alone does not establish readiness. Rich-text work starts in milestones 0–2 and finishes against the supported corpus in milestone 4; its total effort must be included in the re-estimate.

The two tracks can overlap after milestone 0: native shell/text work and protocol/storage work. Integration contracts and the fixture corpus are shared deliverables, not work postponed until the UI is done.

### First ten implementation tickets

1. Record architectural decisions, supported baseline, bundle identity/callback scheme, and the source-pinned contract manifest.
2. Create two-user Raven fixtures on Frappe 15 and 16, with channels, DMs, threads, mixed rich messages, private files, and permission changes.
3. Demonstrate dedicated-client browser PKCE, refresh/revocation, and account isolation.
4. Demonstrate Swift Socket.IO namespace/auth headers, room rejoin, partial events, and degraded-realtime state.
5. Prototype native transcript selection/accessibility/anchoring with a 10,000-message synthetic conversation.
6. Prototype rich native composition with IME, Undo, mentions, and round-trip HTML fixtures.
7. Define the per-account schema/migrations and transactional draft/outbox acceptance semantics.
8. Ship the first read-only AppKit window with real menus and two independent windows.
9. Add text-only durable send, then simulate server-accepted/lost-ack/relaunch/retry.
10. Add private attachment staging and authenticated preview/download; do not begin provider-specific media embeds or admin UI first.

## 11. Test and release criteria

### Automated coverage

**Protocol/codec:** real response envelopes; nullable/nested-JSON fields; unknown types; HTML import/export; timestamps/timezones/DST; server-version differences; encoded identifiers; dedicated OAuth and callback rejection; error classification.

**Sync/storage:** duplicate/out-of-order/partial socket events; late HTTP responses; edits/deletes during disconnect; deleted paging cursor; batch boundary pages; send-before-echo/echo-before-ack/lost-ack; process death at every outbox transition; migrations, disk-full, unavailable staging files, and account deletion.

**Permissions/privacy:** private/Open/Public/DM/thread access before/after membership changes; two users on one site; two sites with identical server IDs; credentials never sent to another origin; untrusted previews/links/downloads; logout and token revocation; notification content redaction.

**Mac UI:** menus/responder validation; focus/keyboard-only operation; cross-message copy; IME/dead keys/RTL; native Undo; thread windows and restoration; drag/drop/file promises; Quick Look; accessibility tree and VoiceOver interaction; appearance/contrast/motion settings; notification routing.

**Deployment:** latest supported Raven 3.2 stable release and stable-branch snapshot; Frappe 15.111+ and 16; reverse-proxied hosted site and self-hosted site; custom external hostname differing from sitename; custom port, slow link, HTTP working with sockets blocked, read-only/503, sleep/wake, and Keychain temporarily unavailable. Test declared minimum versions as well as current stable patches; one passing branch head does not establish an entire supported range. Expand compatibility only with passing fixtures.

### Provisional performance budgets

Validate on an agreed reference Mac (e.g. Apple silicon with 16 GB RAM), fixed seeded data, and production builds. These are engineering targets to verify, not measured claims:

- Cached launch to interactive window: **under 2 seconds** without waiting for a network request.
- Warm conversation switch: **under 100 ms** for the first cached content.
- Queued-send feedback: **under 100 ms** in ordinary conditions after successful durable storage.
- Smooth 60 Hz scrolling with a long persisted history and mixed media; a 10,000-message channel must not instantiate 10,000 native views.
- Settled one-account memory target **under 200 MB**, with bounded visible/warm windows and no unbounded image/video retention; measure representative multi-account use separately.
- Near-zero settled idle CPU (target **below 0.5%** over a quiet five-minute run), no tight retries, no unnecessary wake-from-sleep work or archive-wide polling.

Track p95 latency, memory growth, energy/network activity, and regressions—not just a fast empty-window demo. Adjust unrealistic budgets openly after the first measurements rather than quietly dropping them.

### 1.0 must pass

- [ ] No WebView chat/composer/navigation, and no mouse-only essential action.
- [ ] Standard Mac menus, text editing/selection, windows, previews, and accessibility genuinely work.
- [ ] Cross-client message corpus round-trips without hidden formatting/mention loss.
- [ ] Drafts/accepted queued sends survive restart; failed persistence never pretends success.
- [ ] Reconnect repairs visible edits/deletes/read state; sleep/wake and auth outages do not duplicate messages or erase work.
- [ ] Accounts, credentials, caches, search results, and notifications remain isolated.
- [ ] Offline/incomplete history and notification-delivery limitations are stated accurately.
- [ ] Unsupported server capabilities have a safe, explicit fallback.
- [ ] Production-signed/notarized package, sandbox, update verification, migration recovery, and distribution documentation are tested.
- [ ] Dependency/license review and privacy/security review are complete.

## 12. Highest risks and remaining decisions

| Risk | Why it matters | Containment |
| --- | --- | --- |
| Native rich-text fidelity and selection | Most likely source of a superficially native but unpleasant app | Milestone-0 prototypes and shared golden corpus; do not defer IME/selection/accessibility |
| Dedicated OAuth onboarding | Existing mobile discovery is not generic client registration | Admin-configured independent client first; upstream discovery enhancement separately |
| Missing replay/deletion contract | A socket reconnect can leave believable but incorrect cached state | Bounded cache, canonical range reconciliation, permission refresh; no “complete offline archive” claim |
| Ambiguous mutations / weak concurrent dedupe | Retries can repeat actions or reverse toggles | Immutable serialized sends; canonical rereads for toggles/actions; propose stronger server contracts |
| Background push ownership | Requires credentials, provider routing, maintenance and privacy decisions | Explicit running-app tier; validate provider route before promising more |
| API drift across deployments | Method names/types are not a complete stability guarantee | Pinned baseline, capability adapters, integration suite, documented support matrix |
| Scope expands into “all of Frappe” | Delays a great messaging client indefinitely | Browser handoffs for administration and unsupported document actions |
| Local content on shared Macs | A cache improves usability but retains sensitive material | Clear retention controls, explicit at-rest boundary, no Spotlight/iCloud by default |

Implementation defaults are recorded in the [implementation decisions](implementation/DECISIONS.md); owner configuration and acceptance evidence remain required for deployment. Track answers, responsible people, due gates, and the disposition of the review PRs in the [single decision register](NEVERMORE-OPEN-QUESTIONS.md). Resolve test-access, OAuth-registration, and signing-identity prerequisites **before their milestone-0 experiments**; confirm the remaining owner decisions before milestone 1:

1. Is macOS 15 the right floor, and is Intel a shipping requirement? Recommended default: yes to both initially.
2. Which real Raven sites/versions and authentication providers must the first release support? Obtain a test site/account; source review alone cannot settle deployment behavior.
3. Is administrator-created OAuth registration acceptable for the first beta? Recommended: yes, rather than impersonating the official mobile client.
4. Who owns signing, the final bundle/callback identity, update hosting, and any optional push-provider service?
5. Are quit-time notifications, application-layer cache encryption, or specific ERP workflows contractual 1.0 requirements? If so, schedule their proof before broad feature work.

Build a small, native, excellent reading-and-writing application on Raven's existing server. Prove authentication, text fidelity, selection, and reconnect behavior first. Add breadth only when those foundations already feel unmistakably like a Mac.
