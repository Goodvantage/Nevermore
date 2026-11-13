# Module boundaries

Nevermore uses Swift 6 and targets macOS 26 (Tahoe). `Package.resolved` pins every dependency revision.

## RavenProtocol

`Account`, `RavenChannel`, `RavenMessage` and `JSONValue` preserve account identity, opaque server identifiers, timestamps and unknown wire fields. `SiteOrigin` isolates scheme/host/effective port and rejects credential-bearing URLs. `PKCETransaction` generates state/verifier/challenge and validates exact callbacks, including duplicate-parameter rejection.

`RavenClient` is an account actor with isolated cookie-free/cache-free HTTP, typed envelope boundaries, Keychain refresh persistence and single-flight refresh. RPC reads use GET; mutations use POST; resource updates use PUT and DELETE. Uploads preserve original filenames, sanitize multipart headers and use private File uploads. Binary downloads and RPC bodies have explicit size limits. Refresh completion cannot restore credentials after invalidation/logout. `RavenRealtime` runs on the main actor, owns one account socket and rejoins its desired rooms after reconnect. A connected socket does not prove room delivery: activation and focused windows request a coalesced HTTP catch-up, and disconnected accounts with open conversations retry every 15 seconds even in the background. Realtime diagnostics record connection and subscription counts without channel IDs or message content.

## NevermoreCore

`AccountStore` is an actor backed by GRDB migrations and an exclusive account-directory lock. Atomic `acceptDraft(channelID:expected:)` converts only the expected shared draft into an immutable `SendOperation`; failures preserve the draft. Acknowledgement and cache insertion commit together. Generation-aware visit snapshots distinguish a stale completion from a later identical timestamp. Staging copies regular file contents privately, checks byte budgets inside a serialized transaction and reclaims terminal-send files only when no live draft/outbox reference remains.

`RichTextCodec` parses an allowlisted Raven HTML grammar into a bounded `RichDocument`/`RichNode` tree. It preserves semantic identifiers, masks spoilers in plain previews and rejects executable URLs/embeds. Unknown semantics, custom styles, tables and complex unsupported block combinations remain readable but read only. Nested ordered/unordered lists and multiline code are editable through versioned paragraph metadata that retains structure, item identity, numbering, language and generated-marker provenance. `rawHTML` is preserved locally; it is never executed. `MessageReconciliation` authorizes deletion inference only within a fully covered ordered snapshot span.

## NevermoreApp

AppKit presentation remains on the main actor. `AccountSession` shares HTTP/socket/store state, native draft text storage and Undo managers across its windows. It serializes send acceptance, invalidates obsolete snapshots and holds read marks after Mark Unread. Reauthentication retains the account UUID, database, drafts and queued sends.

`ConversationWindow` owns per-window navigation and a continuous native NSTextView transcript with a 500-message working set. `NativeRichText` maps safe document semantics to attributed text without using an HTML importer or loading remote resources. Formatting-only changes are detected; semantic entities are coalesced across font runs so an edited custom emoji does not duplicate. Unhandled edit constructs require browser handoff.


`CollectionSource` carries reviewed paging strategy and query arguments; its cache key includes both. `CollectionPager` rejects stale generations and advances offsets by received wire rows, independently of deduplication/access filtering. Cached projections are evictable (64 snapshots, 2 MiB per snapshot, 16 MiB total), separate from durable drafts/outbox.

`MentionCompletion` uses native UTF-16 ranges and stable person/channel IDs. The AppKit popover preserves composer focus; composition/selection/code spans do not trigger completion, and modified Return retains the configured send/newline behavior. `ConversationChooser` resolves cached identities before any DM creation. `ThreadInspector` shares the account session with a separately released room subscription; narrow windows open a thread window instead.

`NavigationHistory` captures account-local conversation anchors, pixel offsets and search text. Versioned saved windows include account/window identity, workspace, frame and optional inspector root. Restoration requires a still-configured account and canonical server authorization; removal purges that account's restoration records.

`RavenUserPreferences` preserves raw fields and limits mutations to reviewed, present fields. Availability and after-hours choices with unknown values remain read only. `QuietHours` gates local incoming notifications by site wall-clock time, including DST/overnight windows. `OutgoingPolicy` separately applies Raven's organization working hours/nudge to send acceptance. Its silent-send decision is frozen into the durable operation; retries do not recalculate it. Legacy operations without that flag decode as normal sends. Foreground interaction heartbeats are bounded to one per minute; sleep/quit never globally deactivate the user across devices.


`MessageWindow` bounds the native reading projection by both rows (500) and input HTML bytes (4 MiB), retaining a requested/visible opaque anchor. A single oversized message retains its safe parser fallback. This does not evict durable drafts/outbox.

`NativeRichText.readingString` strips all editor-only attributes after masking spoilers. Native clipboard/RTF output therefore carries displayed formatting without the original hidden HTML/semantic payload. `CodeBlocks` excludes spoiler subtrees and binds references to content/position. `CodePresentation` adds local, in-memory command links and explicit long-code collapse. `CodeReaderWindow` uses a horizontally scrollable native text view, optional wrapping, exact Copy Code, and account/message/parent-channel invalidation. Code references are not encoded into saved window routes.

`PromisedFileReceiver` captures receivers during the paste/drop event and uses one private destination for the whole drag, as required by AppKit. Its coordinated reader takes a descriptor-based snapshot before returning: every path component is opened without following symlinks, only a private regular file is accepted, byte growth/change is checked, and accepted snapshots have independent private paths. Duplicate callbacks are counted once per source/path; same-name files from separate receivers get independent snapshots. Cancellation, timeout, late callbacks and process-owned cleanup are bounded. Provider activity itself cannot be force-cancelled; transient provider writes are not a hard disk quota.

Incoming copies and promise receipts are bound to their originating window/session/navigation generation and staged into the account store before any draft references them. Pending imports block Send in every window sharing the draft; local send acceptance briefly pauses editing across those windows. Draft-save revisions reject superseded tasks, and recoverable in-memory snapshots preserve failed saves across navigation. Quit waits for local persistence/acceptance, not network delivery, and refuses to discard failed or unencodable drafts. Graceful termination cleans active receive/preview windows; startup removes only marked receive directories whose owning process has exited.
