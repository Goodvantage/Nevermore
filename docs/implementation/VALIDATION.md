# Validation record · 8 November 2026

This is a working early implementation, **not completion of the full 1.0 plan**. Local checks do not waive the milestone-0 authenticated integration gates or the later product/quality gates.

## Environment

- Apple M4 Max, arm64, macOS 27.0.1; Xcode 27.2, Swift 6.4.2.
- Deployment target: macOS 15. Both architectures compile with explicit macOS 15 triples, so compiler availability checks match the app's declared minimum. The minimum OS and Intel hardware were not available for execution tests.
- Release executable and bundled Sparkle framework contain **x86_64 and arm64** (`lipo -archs`); both executable slices declare minimum macOS 15.0 (`vtool -show-build`).
- Packaged sandboxed/hardened app signed with the installed **Apple Development** identity. `codesign --verify --deep --strict` passes. This is development signing, not Developer ID notarization.
- The owner supplied a test site and created a dedicated public OAuth client. On 8 November, browser sign-in/consent, PKCE token exchange, authenticated boot/current-user/channel loading, the live Socket.IO connection, and Keychain-backed recovery after Quit/relaunch succeeded on Raven 3.1.0 / Frappe 16.53.0. The sitename differs from the external hostname. The mobile OAuth registration was not reused, and no client secret was required or stored in the repository/CI.
- No production update feed/key, Developer ID identity or notary profile was supplied.

**Identity context:** the first successful real-account flow used the legacy `app.nevermore.mac` identity. Main's concurrent family-standardization change (`51cda6d`) then renamed the bundle, callback and Keychain service to `ch.lkmc.Nevermore`. The owner registered both redirect URIs in one space-separated line. The new-identity universal Release build passes all 146 native checks and now also passes fresh browser sign-in/consent, authenticated channel loading, a Live connection and Keychain-backed recovery after normal Quit/relaunch. Both initial and restarted windows showed nine conversation rows and Live without an error status; restart did not require browser sign-in. No automatic migration of the existing sandbox/Keychain data is claimed. The tested legacy build is preserved as `build/Nevermore-legacy-registration-development.zip`.

## Automated results

`swift test --triple "$(uname -m)-apple-macosx15.0"`: **184 tests, 0 failures**:

- 40 protocol/auth/transport/model tests: origin/redirect isolation, PKCE callbacks, JSON envelopes, OAuth forms, single-flight refresh, Keychain separation, refresh-vs-logout races, redacted errors, filenames/private multipart uploads, bounded responses, DM display identity, search normalization unknown/missing preference fields, and canonical channel/thread archive checks.
- 22 storage tests: migrations/reopen, exclusive locks, durable drafts/immutable operations, transactional acceptance/acknowledgement, interruption recovery, history/search/staging/read watermarks, revocation/account isolation and bounded collection snapshots.
- 14 notification-policy tests: site-timezone boundaries, overnight/midnight/week boundaries, both DST transitions, malformed/disabled/equal windows, Codable and incoming-notification suppression.
- 82 further core regressions (including 21 offline rich-text corpus fixtures, code extraction/spoiler guards and byte-bounded transcript windows): authoritative history ranges, rich-text safety and list/code structures, mention queries/Unicode identity matching, navigation/restoration, collection paging/generations/scoped caches, shared-draft races, staged-file safety, and durable/legacy-compatible silent-send policy.
- 26 macOS-completion regressions: 20 scoped-search filter/cache/Codable and result-boundary cases, four channel-management permission/archive/revocation policies, and two canonical-unread/badge-policy checks.

`UNIVERSAL=1 CONFIGURATION=release ./scripts/build-app.sh`: universal Release bundle builds and verifies its signature. Packaging plist/entitlement checks, shell syntax, Python contract-probe syntax and `git diff --check` pass.

`build/Nevermore-development.zip` contains the signed `ch.lkmc.Nevermore` Release app. The archive was extracted to a private temporary directory, its extracted signature verified strictly, and the executable matched against the tested bundle. Its SHA-256 is recorded in `build/Nevermore-development.zip.sha256`.

The signed universal Release app's `--demo --self-check` passed **146 native checks, 0 failures**: twice consecutively under the legacy identity, then once under `ch.lkmc.Nevermore`. Coverage includes continuous cross-message selection; native editing/menus/shared sessions; marked-text and modified Return behavior; mention identity and Undo; lists, code, quotes and semantic entities; unsupported-format protection; chooser and scheduled editing; thread inspectors/restoration/parent revocation; local preferences; collection filtering, paging controls, keyboard commands and account guards; and private account-view clearing.

The continuation also verifies exact code copying and real horizontal scrolling, wrapping and stale-reader invalidation; spoiler masking and metadata-free plain/RTF copying; native selection copying without presentation commands; bounded file-promise snapshots, duplicates, timeouts, path swaps, symlinks, cancellation and late cleanup; durable account-bound imports and visible provider errors; shared draft/import/acceptance barriers, revision ordering, failed-save recovery, closed-window sends, and save-before-Quit/refusal on unsaved failures. Geometry checks cover transcript/composer resizing, sidebar collapse/restoration, thread replies and the scheduled editor.

Each self-check run uses a disposable local demo database. Synthetic typing yields to Cocoa's automatic undo-event checkpoints before proceeding; the runner never manually closes the undo manager's automatic groups. The synthetic large-history input inserts 10,000 messages; the cache retains its configured 1,000 per-channel rows and the transcript displays at most 500, with a 4 MiB input budget. The final Release new-window render measured about **145 ms in one sample**. This is not a warm-switch/p95 benchmark or proof of the plan's memory, energy, launch and scrolling budgets.

Desktop inspection confirmed labeled transcript/composer controls that fit their visible panes, an enabled Sidebar command, Settings text-size/spacing controls, and a scrollable account-preference window with disabled server controls in demo mode. A normal demo launch followed by the application's Quit command exited successfully through its termination delegate. This is not a comprehensive VoiceOver or accessibility certification. Test apps were quit and desktop ownership released.

## Native attachment continuation

Full attachments now stream to private account-scoped temporary files with a 64 MiB per-file bound and a 512 MiB active-file reservation budget. Completed files carry quarantine without credential-bearing URL paths. Preview and drag retain their backing artifact; account removal/history clearing purges private download folders. Active formats remain Save As only. Sharing and Open With use a user-saved copy rather than an expiring preview file.

The current unit suite passes 202 tests (36 XCTest, 55 protocol, 111 core). The signed Release attachment fixture passed 174 native checks before the native-shell merge, including real Quick Look opening/teardown, off-main callback rejection, post-close file promises, quarantine, collision refusal and decoded HTTP compression. The updated branch includes the native-shell continuation and builds both architectures. CI now runs the credential-free native attachment fixture; external Save As requires the optional shared-desktop driver and is reported separately.

The actual sandbox Save As regression failed after the user action accepted the real panel: copying a sibling staging file was denied, because the save grant covered only the chosen target. Export staging now uses Foundation's item replacement directory on the target volume before atomic publication. The three file-preservation/quarantine/no-overwrite tests pass after this correction. The signed universal Release fixture then passed all 186 native checks, including actual Save As outside the sandbox, quarantine preservation and cancellation of a pending save sheet on window closure. The optional driver reports automation failures immediately and verifies the exported body outside the app. No live private-media, real Mail/Finder receiver or minimum-OS accessibility acceptance is claimed.

## Remaining implementation/product work

The [feature inventory](FEATURES.md) describes implemented entry points and their limits. Full 1.0 fidelity still needs the real web/mobile golden corpus, table/custom-style editing decisions, complete permission-transition behavior across deployed versions, localization and the plan's full accessibility/performance/interaction matrix. Tables, complex block combinations and unknown/custom styling remain read only with browser editing available; no lossy edit is presented as supported.

Share extension delivery remains conditional on its lifecycle/security gate. Specialized AI/admin controls, native calls, Spotlight/App Intents remain deferred. Archive/mute controls are source-verified, with live permission-transition validation still required. Custom message actions needing dynamic server forms use browser handoff. APNs provider routing is not configured and quit-time push is not advertised.

## External/manual release gates — not performed

- The broader browser OAuth/SSO/MFA and deployment matrix on Frappe 15.111+ and 16. One Raven 3.1/Frappe 16 deployment now passes basic sign-in/read/connection/restart checks; this does not establish full compatibility with the pinned 3.2 research baseline or verify every authentication provider.
- Two-user/two-site permissions, private media/Range requests, socket proxies, lost acknowledgements and web/mobile interoperability.
- Real offline/sleep/wake, token expiry, maintenance, full-disk/process-death and minimum-OS/Intel execution matrix.
- Comprehensive VoiceOver/IME/RTL/dictation, real Finder/Mail/Safari promise providers, contextual commands and system restoration review.
- Production Developer ID/notarization, a hosted signed-update round trip, final bundle/domain ownership and monitored security contact.
- Real beta feedback and the remaining 1.0 release checklist.

Use `scripts/check-live-contracts.py` as a read-only starter probe, followed by the plan's mutation/reconnect/permission matrix. Production packaging is scripted in `scripts/package-release.sh`; it requires owner-provided credentials/configuration. No release checkbox was marked passing merely because local source or demo code exists.


## Fixture and toolchain limits

The rich-text corpus is [documented separately](RICH-TEXT-CORPUS.md). It uses provenance-labeled offline fixtures and pinned primary-source behavior, not a real cross-client rendering certification. Provider tests use scripted sources through the same receive/snapshot engine; actual Finder/Mail/Safari drag behavior and transient provider-side disk usage still require manual validation.

The Xcode linker can emit a third-party `SocketIO.o` ambiguous-address warning; builds exit successfully. An earlier SDK/Intel deprecation warning exposed host-default compilation for macOS 27.2 despite the linker's 15.0 minimum. Packaging now builds explicit per-architecture macOS 15 triples and merges the slices; CI and developer test instructions use the explicit target too. The final build has no host-target deprecation warning. Actual Intel/minimum-OS execution and deployed Socket.IO interoperability remain release gates.

## Browser callback follow-up · 8 November 2026

The first real consent callback exposed a Swift actor-isolation trap: AuthenticationServices called a closure inferred to be main-actor isolated from SafariLaunchAgent's XPC queue. `BrowserAuthenticationCallback` now supplies an explicitly Sendable, nonisolated entry point and hands results to the main actor. Closing/replacing a login cancels its attempt, and stale completions are ignored. The fixed app completed the real consent callback and restored the account's live connection after a normal Quit/relaunch.

All 155 automated tests still pass. Three new success/cancellation/empty-result regressions pass from a background executor, both in a headless runner and in the native checks. CI now runs the same callback regressions without a browser, credentials or GUI. A live namespace connection is not proof of room-event delivery, lost-ack recovery, message/media interoperability or the remaining two-user/permission matrix.

Repeated Release checks also exposed two completion-test failures: manually closing Cocoa's automatic undo groups corrupted subsequent synthetic input, and AppKit could request a stale suggestion row after the popup's candidates were cleared. The runner now waits for a real undo-event boundary; the popup reloads on dismissal and rejects out-of-range row requests. A direct delayed-row regression is included in the final 146 native checks. No speculative window-focus workaround was retained. The final Release app also restored the real account, loaded the conversation list and returned to Live after a normal relaunch; no additional browser sign-in was required.

The identity-change validation initially returned `Mismatching redirect URI`: the setup instructions had incorrectly placed the two allowed callbacks on separate lines. Frappe 16.53.0 splits that field on literal spaces, with no newline normalization. After the owner saved both URIs on one line separated by a single space, the unchanged app completed fresh consent and restart recovery under `ch.lkmc.Nevermore`. The setup documentation now records the required delimiter. The test apps were quit normally and desktop ownership released.

## macOS completion continuation · 8 November 2026

The owner confirmed macOS-only scope. Source-verified channel archive/mute/membership controls, scoped/filterable/saved searches, collection result navigation, and configurable Dock attention policy are implemented. The universal Release continuation passes **164 native checks, 0 failures**, including attached choice-sheet selection/cancellation/parent closure, account-isolated saved-query storage/removal, stale collection rows, archived-send protection, responder-chain search dispatch and filter-pane geometry. The earlier 146-check runs and live account results above remain historical evidence; no new live channel mutation or notification-delivery matrix is claimed for this continuation.

The first new native run exposed a lifetime error in the temporary parent-window fixture: closing an unmanaged `NSWindow` released it before the fixture's final inspection. The fixture now retains ownership through the close check (`isReleasedWhenClosed = false`), and the Release suite passes. Test processes exited and the shared desktop was released. The larger code-completion and release gates remain open.


## Review corrections · macOS continuation

Independent source review found two important defects before merge. First, Raven/Frappe merges its permission `parent_channel_id` filter over the client filter, broadening workspace searches. The regression failed against the original implementation. Workspace search now intersects an independent `channel_id` filter, reapplies it at the collection boundary, and explicitly covers workspace channels; use account search for thread replies.

Second, Raven's send API does not enforce channel archive state. The outbox now pauses known archived channels and thread parents before any upload/attempt, reads canonical channel/thread ancestry before transmitting, and retains affected sends for explicit review. Both native queued-send regressions failed before the fix, then passed in the final 164-check universal Release run. Three protocol regressions cover archived ancestry, malformed flags and cycles. Client checks cannot make an external archive concurrent with the final POST atomic; that requires a server precondition.

The automated full-PR review was inspected alongside the independent review. Its empty quick-search finding was fixed; filtered searches can still intentionally run with no text. Search controllers release their owner reference on close, fixture validation has a cancellation watchdog, and fallback notifications use `message_id` rather than mention-document names. Other alleged major defects do not apply: `JSONValue` subscripting returns `.null` for missing keys, `.nested` already decodes JSON-array strings (covered by saved-search tests), and `AccountSession`/`AppDelegate` are `@MainActor`. Existing menu validation, canonical unread `name` keys, explicit mute intent and Open-channel workspace-derived membership were checked against full source. Animation/layout/storage-diagnostic suggestions remain minor follow-up work; no speculative permission or substring-matching rewrite was applied.


## Native shell continuation

The signed universal Release build passes **174 native checks, 0 failures**. Ten new checks cover application-targeted New Message, Dock commands, the conversation chooser, stopped-account window creation, spelling/substitution menus, scrollable Settings, login-state preservation, optional menu bar lifecycle, aggregate-only diagnostics and native keyboard help. The stopped-account regression failed before the fix: New Window reused the stopped session in the focused window. New Window and New Message now choose an active account context.

Login startup uses `SMAppService.mainApp` only after an explicit checkbox action. Opening Settings did not change registration. Actual login registration/unregistration and the System Settings approval path were not exercised; no login item was installed by these checks. Requires-approval status remains visible and can be cancelled by clearing the checkbox. The optional menu bar item was added and removed under the desktop lease, and the prior preference was restored. All test windows exited and the desktop was released. Unit coverage remains 184 passing tests; no protocol or storage behavior changed in this slice.


## Native poll continuation

The macOS poll composer now supports named or anonymous polls, single or multiple choices, a source-verified finite choice limit, and an optional deadline in the site timezone. The native poll window presents counts and authorized voter names, preserves anonymous privacy, selects stable option child IDs, and offers explicit vote, retract, owner-confirmed close, and refresh actions. Mutations run once, require canonical conversation write preflight, and remain disabled until a canonical poll refresh after either success or uncertainty. Account switches, revocation and window closure clear private content. Archived conversations retain read access while writes are disabled.

The unit suite passes 205 tests: 36 XCTest, 49 protocol and 120 core tests. New coverage includes malformed/hostile poll payloads, canonical documents without a channel field, anonymous identity stripping, option/selection validation, choice-limit contracts and site-timezone/deadline encoding. The initial signed universal Release app passed 188 native checks, including 14 poll selection, layout, privacy and editor-lifecycle checks. Two additional regressions then failed: the archived-conversation menu blocked poll reading, and owner cleanup left an in-flight creation sheet visible. The menu now allows poll reading and the owner cancels its creation task on account/window cleanup. Both regressions then passed in the final signed universal Release run: 190 native checks, 0 failures. The poll RPC contract was checked against the pinned Raven source; no live poll creation, voting or close operation is claimed. Universal build and current-commit CI/review results are recorded with the PR.


## Combined attachment/poll validation and review

After merging attachment support, the combined suite passes 223 unit tests: 36 XCTest, 64 protocol and 123 core tests. The signed universal Release app passes 206 native checks with `scripts/check-native-attachments.py --polls --save-panel`; CI runs the 204-check variant that explicitly skips the external save dialog. The real loopback poll fixture uses an isolated, credential-free account session that never enters the account list or starts realtime. It verifies suspended controls, exactly one vote POST from repeated clicks, canonical acknowledgement and automatic recovery after a failed read. The recovery check failed before clearing cancelled task handles, then passed after the fix.

The completed GLM review identified that recovery defect. Cleanup now releases the cancelled read/mutation task handles, and native sheet checks wait for dismissal before advancing. Poll preflight also remaps outbox-specific error copy. The claimed missing success guard does not apply: the operation completion already checks cancellation, generation and window closure before any UI update, with no intervening suspension. Failed canonical reads deliberately clear private poll content until a successful refresh revalidates access. Opaque IDs are preserved rather than normalized, and malformed identity references fail closed. Popup selection already defaults to a valid item and invalid finite limits are rejected. The proposed optional-array fallback would weaken the privacy fixture by allowing an absent window to pass. Remaining documentation/assertion refinements are minor. A focused independent review of the final corrective diff found no confirmed important issues.

Both architectures compile and the bundle signature verifies. The local Xcode 27 run reports a weak-sentinel mutability warning in an attachment test and an x86_64 linker warning concerning anonymous atoms in vendored SocketIO; neither fails the build. Physical Intel/minimum-OS interaction and the broader manual release matrix remain separate gates.

## Account cleanup follow-up

Account removal now attempts private-download purge, credential deletion, notification removal and account-directory removal independently, collecting actionable failures. It retains the account registry and stopped session unless credential deletion and both file cleanups succeed; missing directories count as successful cleanup. A failed registry write restores the in-memory registry too. This keeps the account UUID available for retry rather than stranding private files after a permission failure. All affected conversation windows switch to one remaining active session, or clear their account when none is active. Clearing received history notifies the UI immediately after clearing stored and in-memory history, before attempting private-download purge. Cancelling an attachment download restores the conversation status immediately.

Per-download cleanup now removes only its own private child directory. It leaves the shared account directory for explicit purge, because another download can be between ensuring that parent and creating its child. Two deterministic regressions reproduced the missing-parent failure before the fix, once on last-owner release and once after a rejected download. Both pass after the fix. A selected set of 14 protocol/export tests passes with network access denied, using an ephemeral protocol-only package and the checkout's cached SocketIO/Starscream dependencies. The normal package test setup could not finish offline because GRDB's SQLite submodule was not cached. No full application build, native UI checks, real credential operations or live account cleanup were performed for this follow-up.

The AppKit account/history paths do not have a headless unit-test target. Their remaining fault-injection checks must use a disposable synthetic account, temporary store/download roots, and recorded replacements for Keychain, revocation and notification operations; never a production account:

- Inject a private-download purge failure during confirmed removal while credential deletion succeeds. Verify that credential deletion, both notification cleanup calls and account-directory cleanup still run; registry removal must not run, and both the account record and stopped session must remain. Repeat with account-directory removal failing instead, then with both purge and credential deletion failing. Each failure must be reported with permission/relaunch/retry guidance. Repair permissions and relaunch the synthetic fixture: its original account UUID must still be available for a successful retry. Missing private/account directories must count as success, allowing registry removal once credential deletion succeeds.
- With every private cleanup succeeding, inject registry-persistence failure. Verify that the in-memory account record is restored, the session stays stopped and retained, and registry failure/retry guidance is shown. Repeat with two windows on the removed account, another active account, and a previously stopped account. Both affected windows must switch to the active account, never the stopped account. Without another active account they must clear their account; an unrelated window must keep its own session. No window may switch back to the retained stopped session while asynchronous cleanup completes.
- Clear synthetic received history while injecting a subsequent private-download purge failure. Observe `.sessionChanged` after the store and memory clear, verify that transcript data is cleared, and verify that the purge failure remains visible. Inject a store-clear failure separately and verify that it is not reported as successful history clearing.
- Suspend a fixture attachment download, call `clearPreview()`, then release its stale completion. Verify immediate task cancellation/status restoration and that the old attempt cannot open an attachment window or replace the current status.

These AppKit fault-injection checks are documented procedures, not executed acceptance results.

The full application package subsequently passed 225 unit tests (36 XCTest,
66 protocol and 123 core), including both directory-lifetime regressions. A
filename regression also reproduced a 211-byte result after adding a hidden-file
prefix; sanitation now reserves that prefix inside the 200-byte bound and stops
in one pass. No real account or credentials were removed during these checks.

The fixture interruption regression failed with an orphaned fake application,
then passed after child termination moved into the runner's unconditional cleanup.
CI now runs that credential-free subprocess test. Native save/poll cancellation
checks require an actual pending sheet before asserting dismissal. The macOS 15
CI failure waiting for an automatic undo group is tracked with PR18: the fixture
posts a real app event to advance Cocoa's checkpoint rather than manually closing
its automatic group. Minimum-OS CI verification of that correction is pending.

Completed post-merge reviews of PR16/17 were inspected. The cleanup, sibling-folder
race, pending-sheet and interrupted-process findings above apply. Other alleged
major issues do not: the downloader creates 0700/0600 private storage internally,
its URLSession delegate refuses cross-origin redirects before forwarding a
request, and filenames lose path components before publication. Actual URLSession
fixtures already cover decoded compression and named gzip responses. Poll reading
in archived conversations is deliberate; canonical preflight still blocks writes.
A closed or invalidated attachment view does not update private UI after export;
user-selected saved files remain independent of preview lifetime.

## Native rich-text continuation

Native reading now lays out bounded rectangular tables with TextKit table blocks,
including validated row/column spans. Unsupported geometry retains its complete
text fallback and original source. Tables remain protected from native editing.
Plain copying supplies tab-separated cells; RTF retains native table structure.
Hidden table-cell spoilers remain masked in both formats.

The composer supports inline spoiler authoring with Undo and atomic mention/emoji
selections. A review regression reproduced that semantic spoilers reopened as
read only. The parser now accepts supported inline identities inside spoilers;
nested spoilers, block-level wrappers and unsupported semantics stay read only.
Serialize/reload/edit/removal checks verify unchanged identities and masking.
Formatting also retains the selection after replacing attributed text, allowing
successive formatting commands to apply to the same passage.

Custom emoji use a cancellable native catalog with paged name/keyword search,
validated same-origin image paths and stable server IDs. Composition preserves
Raven's custom-emoji HTML; reactions support Unicode graphemes and custom IDs.
Reaction toggles run once, with explicit uncertainty and refresh guidance. Image
shortcodes remain the safe readable fallback; catalog browsing does not fetch
remote image pixels.

The initial signed Release fixture passed 222 native checks, including actual
sandbox Save As, table geometry/RTF, semantic spoiler reload and the emoji picker.
Subsequent focused regressions reproduced paragraph loss when inserting a long
emoji into a short list/quote, unsafe insertion into code, and coalescing adjacent
identical emoji after an edit. Insertion now inherits the current paragraph,
code contexts refuse the action, and private semantic instance IDs keep adjacent
entities separate without changing their server identities or wire HTML.
Final universal, unit and CI evidence is recorded with the continuation PR.
The headless `--check-rich-text` command runs native text checks without opening
windows; it does not substitute for the remaining desktop/accessibility matrix.

## Inbox batch actions

Inbox alone permits multiple selection. Mark Selected Read, available as a
button and menu command, sends at most 100 selected notification rows in one
source-verified request using deduplicated message IDs. Single-result Open and
Actions are disabled for multiple selection. The operation captures its account
and IDs before suspension, refuses duplicate clicks, never automatically replays
an uncertain mutation, and refreshes the canonical unread-message ID set.
Failures keep an explicit warning. Closing or switching the account prevents
late responses from changing private rows or attention state.

The first combined signed universal fixture passed 237 native checks, including
11 new isolated inbox checks for limits, identity, immutable selection, duplicate
clicks, canonical reconciliation, close/switch races and uncertain/failed reads.
A menu-validation regression was then added. Final exact-head CI and native
checks are recorded with the PR. No live inbox mutation is claimed.

## macOS quality continuation

Links search uses the pinned link index with account/conversation, author,
saved and mention filters and explicit offset paging. Workspace links are
rejected rather than broadened. Distinct links keep distinct rows and open their
source message. Review regressions reproduced literal-text corruption and
spoiler URL/title disclosure; plain previews now preserve literals and suppress
unclassified metadata when canonical content carries the spoiler marker.

The transcript retains native continuous selection and adds a Messages
accessibility rotor, guarded selected-message actions, and keyboard message
navigation. Generic actionable announcements are foreground/IME gated,
deduplicated and cleared on account/window changes. Neither mechanism speaks
hidden spoiler bodies, link destinations or private error payloads. The action
callback uses an explicitly Sendable entry point before checking its executor.
Actual VoiceOver interaction remains a manual acceptance gate.

Connection/outbox labels and selected errors use typed keys in a bundled Core
localization resource. English is the declared UI language; German resources are
partial lookup/format coverage, with explicit English fallback. Timestamps now
parse source-contract precision without DateFormatter truncation and refresh
regional display after locale/device-timezone changes. Three parser regressions
failed before the fix. Naive server timestamps cannot disambiguate repeated DST
hours; unknown/nonexistent values retain a bounded raw fallback.

The integrated package passes 247 unit tests (36 XCTest, 64 protocol, 147 core)
before the rich-text and cleanup continuations are merged. The performance
driver's fake-child tests pass, including timeout/owned-PID cleanup and preservation
of unrelated directories. Its cleanup uses a driver-selected UUID and a non-GUI
app command inside the app's own temporary directory; reported paths never cause
host filesystem deletion. The isolated demo skips Keychain/download purge and
window/toolbar preference autosaving. Actual native checks, reference measurements,
exact-head CI and final combined counts are recorded with the continuation PR.

## macOS quality integration, 2026-11-08

The combined rich-text, inbox, cleanup, links, accessibility, localization and
measurement changes pass 272 local unit tests (36 XCTest, 76 protocol and 160
core), plus five Python driver/cleanup regressions. The previous signed
universal integration passed 264 native checks, including the actual sandboxed
Save As dialog. The cache and cleanup integration also passed all 264 native checks,
including sandboxed Save As. Local hardware is an M4 Max with 36 GiB memory, running
macOS 27.0.1 and Xcode 27.2; compilation targets macOS 15 for both architectures.
These local results do not substitute for physical Intel or minimum-OS use.

The first five-minute Release fixture is archived in
[performance/2026-11-08-baseline.json](performance/2026-11-08-baseline.json).
It measured a 160.09 ms cached-switch p95, above the plan's 100 ms target;
settled physical footprint was 47.84 MB and idle CPU was 0.0066% of one core.
The follow-up cache retains account-local parsed value documents only, with
entry, UTF-8 payload and node limits, exact source/identity matching, negative
parse caching and invalidation on edits, deletion, revocation, stop and history
clear. Presentation objects and action routes are rebuilt per render. New
measurements must establish its effect; the baseline is not a passing result.

The completed PR19 review's unsupported-menu-action finding does not apply.
AppKit resolves nil-target menu actions to responders implementing the selector
before asking their validator. CollectionWindow does not implement the cited
conversation actions; its fallback also validates supported Find Next/Previous,
which an unconditional false would disable. Keeping single-row inbox marking
open is intentional so canonical read status and uncertain-outcome guidance
remain visible. No code change was made for those suggestions.

macOS 15 CI caught a locale-data punctuation assumption in the German staging
budget test. The test now verifies the complete numeric value and format
substitution without pinning one OS version's grouping separator; production
formatting continues to follow the requested locale.

The first cache follow-up is retained in
[performance/2026-11-08-cache-first-pass.json](performance/2026-11-08-cache-first-pass.json).
It passed cached relaunch (416.54 ms p95), footprint (48.51 MB) and five-minute
idle CPU (0.0056% of one core), but switch p95 remained 134.59 ms and synthetic
performClick-to-feedback p95 was 109.60 ms. These failed budgets are retained.
A temporary render-phase probe attributed roughly 73 ms to attributed rows and
32 ms to layout in warm 500-message renders. Reading was computing editor-only
paragraph round trips, signatures and original-document payloads before stripping
them. Skipping only those discarded calculations preserves the editor path and
all public reading/copy attributes. A fresh zero-idle Release smoke run measured
88.96 ms switch p95 and passed the headless native rich-text checks. Independent
static review found no important issues. The final combined five-minute result
will separately record button-action feedback and complete synthetic click time.

## Final reading and attachment continuation

File-search rows now expose keyboard-accessible Quick Look and Save As. Each
operation resolves the canonical message and channel ancestry before downloading;
stale index URLs are not trusted. Selection, paging, account/window changes,
deletion and revocation cancel or invalidate the operation and its owned preview.
Archived threads remain readable only after their parent permission reads pass.

The transcript now shows a known-watermark unread divider and an accessible
Jump to Latest command. Equal-timestamp arrival identities are byte-exact and
bounded; unknown or evicted older-page provenance never invents an unread count.
The account-wide visit/provenance cache retains at most 16 channels, 128 KiB of
payload and 2,048 identities, validates visit timestamps, and prunes detached or
inaccessible contexts. Its six core regressions include 1,000 distinct channels,
independent byte/identity eviction and parent revocation.

Focused native regressions reproduced three failures before the corrective
change: a truncated projection claiming the canonical live edge, a deleted
requested anchor losing its context neighbor, and a deleted older-page cursor
jumping to the latest page. The cursor tests remove the backing-store row as well
as marking it deleted. Unresolved, initially uncached context intent remains
intact. Known-deleted cursors now rebase around surviving viewport neighbors;
only a projection containing the actual authorized tail can become following.
The original visible-neighbor deletion regression and reading-format parity
check also pass in the earlier native/headless runs. The combined GREEN run now passes all 295 native checks, including the
actual sandboxed Save As dialog.

The action timing probe is retained in
[performance/2026-11-08-action-probe.json](performance/2026-11-08-action-probe.json).
It measured switch p95 of 100.52 ms and action-to-observation p95 of 107.64 ms;
pre-action delay was only 0.054 ms. This disproved the initial pre-action delay
assumption. The final harness retains five complete synthetic performClick
samples and separately dispatches five native button actions through the same
production Send selector, requiring ten unique loopback POSTs with no retries.
The five native action samples measure delivery through durable persistence and
observable cleared/enabled composer plus native display; they exclude physical
input delivery. A zero-idle smoke measured 89.96 ms switch p95 and 17.57 ms native
action feedback p95. Synthetic click p95 remained 179.47 ms and is not discarded.
No zero-idle run establishes the five-minute CPU or energy gate.

A second native batch reproduced five additional read-state failures before
fixing them: cache-retained history evicting a resolved cursor, requested and
older-page contexts offering a read-receipt candidate, late visits writing after
account stop, and malformed/response-sized timestamps entering receipt state.
The positive live-visible candidate check passed. Missing cursors now project
around a surviving viewport while retaining unresolved navigation intent.
History/context navigation supplies no receipt candidate, while visible
thumbnails still load. Receipt entry rejects stopped sessions and validates the
bounded server timestamp before memory or database writes. Receipt fixtures use
stopped or already-invalidated transports, so these regressions perform no HTTP.
The final focused reading review completed four rounds; the last found no
confirmed important defects. Independent reviews also cover canonical attachment
access, cache bounds, reading/copy parity and benchmark timing boundaries.

The frozen macOS implementation passes 293 unit tests (36 XCTest, 77 protocol
and 180 core), all five Python driver/cleanup tests and 295 native checks with
zero failures. Both universal slices build and strict deep signature verification
passes. All eight specifically reproduced reading/receipt failures now pass.
Browser callback isolation and packaging-input checks also pass. These results
use development signing and do not establish production distribution readiness.

## Frozen Release measurements

The clean implementation commit `d5b114287da435dcf2d3d5a88f997f841c1b12c6`
passed all 295 native checks before this exact signed universal bundle was
measured. The complete sanitized report is
[performance/2026-11-08-final.json](performance/2026-11-08-final.json).

| Measurement | Observed | Provisional target |
| --- | --- | --- |
| Persisted cached launch, spawn-to-interactive p95 (5 probes) | 345.65 ms | <2,000 ms |
| Warm cached switch p95 (20 switches, 500/200 visible rows) | 82.09 ms | <100 ms |
| Native Send-action delivery-to-feedback p95 (5 sends) | 3.34 ms | <100 ms |
| Settled one-account physical footprint | 48.15 MB | <200 MB |
| Idle CPU over 300.48 seconds, percent of one core | 0.0040% | <0.5% |

All five measured targets pass on this shared M4 Max / 36 GiB / macOS 27.0.1
sample. The database starts with 10,200 mixed synthetic messages; retention keeps
1,000 in the large channel and the transcript displays 500, without downloaded
media. The ten synthetic POSTs are confined to the owned loopback fixture.
Native action samples follow five synthetic clicks, so they measure a warm
fixture, not first-send or physical input delivery. Complete performClick p95
remains 112.96 ms and is retained separately. The child exited and UUID-owned
fixture cleanup succeeded. No real Raven account or message was used.

These observations do not establish 60 Hz presented frame cadence, energy/network
activity, representative live media, multi-account growth, physical Intel or the
agreed reference-hardware/server matrix. Those gates remain open. Production
signing/notarization and a complete signed-update round trip also remain open;
this machine has an Apple Development identity and no Developer ID Application
identity. The development ZIP is verified after extraction against every regular
file and symlink of the tested bundle, with strict deep signature verification.

## Swift 6.1 Release compatibility follow-up

The final macOS 15 CI revision passed its Debug build, 293 unit tests and both
Python suites, then exposed a Release-only Swift 6.1 isolation diagnostic in
PerformanceButtonActionSelfChecks. Its nested local functions treated mutable
clock/probe captures as task-isolated before use by MainActor closures. The
fixture now explicitly owns both references on MainActor and uses ordinary
scopes with defer rather than relying on newer local-function inference. All
four calibration assertions remain intact. The rebuilt universal app again
passes 293 local unit tests and all 295 native checks, including sandbox Save As.
Minimum-toolchain Release and native CI are rerun for this correction.

Only that self-check fixture changed after the frozen performance measurement;
production rendering, send, transport and measurement paths are identical. The
raw timing report remains tied to clean commit d5b1142 and its measured binary
SHA-256. Its exact development archive is retained separately as
build/Nevermore-development-measured-d5b1142.zip; the current development package
includes the fixture compatibility correction. No timing result is relabeled as
a measurement of a different binary.

## Packaged resource lookup across Swift toolchains

The corrected Swift 6.1 Release build passed, then its sandboxed native run
exposed a generated Bundle.module lookup that tried the app root and the external
build tree. The standard packaged bundle was present in Contents/Resources; the
older generated accessor did not look there, and sandboxing blocked the fallback.
A temporary app-root symlink experiment was rejected by strict signing as
unsealed root contents and was discarded without changing the app layout.

Core localization now caches a packaged-resource-first resolver under
Bundle.main.resourceURL and evaluates the generated SwiftPM fallback lazily only
when the packaged candidate is absent. Unit tests prove candidate preference
without fallback evaluation and missing/nil candidate fallback. The read-only
resolved bundle URL is exposed for the native package-integrity check. Locale
and English fallback behavior remain covered by the existing tests.

The rebuilt universal development app passes all 295 unit tests (36 XCTest,
77 protocol and 182 Core). An archive was extracted to a fresh temporary location
outside the checkout; its signed sandboxed app passed all 296 native checks,
including actual Save As and the physical packaged-resource location assertion.
Both slices compile and strict deep signature verification passes. The app keeps
the standard signed layout; no resource aliases or signing exceptions were added.
A fresh measurement and minimum-toolchain packaged CI run follow this fix.

## Resource-corrected frozen measurements, 2026-11-09 UTC

Clean commit `6bcea010a63fb02b9c9d019456d10737ebb860c1` was measured again after
the resource resolver change. The complete sanitized report is
[performance/2026-11-09-packaged-final.json](performance/2026-11-09-packaged-final.json).
The measured executable matches the signed, extracted app that passed 296 native
checks. All 295 unit tests and the unchanged five Python checks pass locally.

| Measurement | Observed | Provisional target |
| --- | --- | --- |
| Cached launch, spawn-to-interactive p95 | 295.68 ms | <2,000 ms |
| Warm cached switch p95 | 77.57 ms | <100 ms |
| Native Send-action feedback p95 | 3.28 ms | <100 ms |
| Settled physical footprint | 47.22 MB | <200 MB |
| CPU over 300.69 idle seconds, percent of one core | 0.0069% | <0.5% |

All five measured targets pass on the same shared M4 Max / 36 GiB fixture.
Complete synthetic click p95 is separately retained at 116.05 ms. Ten unique
loopback POSTs were acknowledged; no real site was contacted. The child exited
and UUID-owned fixture cleanup succeeded. Frame cadence, energy, real media,
multi-account, supported hardware/server and production distribution gates remain
open as described above.

The new bounded LongCat and free Command Code resource-review attempts both
timed out without output and are not approvals. No further helper-integration
retries were made. The three-file resolver/test change was independently reviewed
locally against the generated accessor and signing constraints; direct unit and
relocated signed-package evidence is recorded above. Latest minimum-toolchain
packaged CI is required before merge. The completed PR18/20 automated findings
were triaged in their PR descriptions: no important issue applies; optional
coverage, cell reuse and fixture diagnostic refinements are deferred.

## Transcript viewport follow-up, 2026-11-10

Resizing a window lost the reader's place. AppKit holds the top of a scrolled
text view: a shorter pane hid the newest messages behind the composer, and a
new width kept the first visible line rather than the last.
`TranscriptViewportKeeper` now keeps the line at the bottom of the readable
band in the conversation transcript and the thread inspector.

A standalone AppKit probe on macOS 27 established the order the keeper
depends on. In one resize step AppKit resizes the text view, rewraps it and
scrolls its first visible line back into place, and only then posts the clip
view's frame change, so a placement made on that notification is not undone.
During a live resize the text view puts that scroll off until the drag ends.
A change of content insets posts nothing. One width step costs 20 to 30 ms
for 400 messages (71,000 characters) when reading at the bottom, where AppKit
already lays out the whole document. Reading near the top now costs the same
instead of 2 to 6 ms.

Run against the unmodified sources, 20 of the first 26 focused native checks
failed: a shorter, narrower or wider window, the sidebar, a growing composer,
a message taller than the window and the thread inspector all moved the
bottom line, and a scroll between picking a conversation (or Jump to Latest)
and its first render detached the new conversation from its newest message
and offered a read-receipt candidate from the previous one. They pass after
the change. The check for the end of a live resize fails with the text
view's hook disabled and passes with it. Three later checks (resizing back
after a live resize, and two with a legacy scroller) were added after the
fix and were never observed failing.

Review found one more gap of the same kind. A scroll that reached the top
between picking a conversation and its first render asked for the new
conversation's earlier messages, counted from the first message of the
previous one, and turned following off. Its check failed before Load Earlier
was made to wait for the render and passes after. A render that fails with a
store error after Jump to Latest now lets the rows still in the pane be
observed again. No check can make the store fail, so that path was read, not
run. After a failed render of a newly picked conversation the pane still
shows the previous one, as before this change, and stays ignored.

The automated review noted that the wrap width was compared with the
half-point tolerance meant for heights and insets. A width change of any size
can rewrap, and an animated pane can end within half a point of the last
width placed for. A unit test for a quarter-point change failed before the
comparison became exact.

CI on the macOS 26 runner twice failed the check that a shrinking composer
returns the transcript to its place, while every other viewport check passed.
Its diagnostic showed the transcript holding its line and the composer still
at its five-line height: emptied by the check, the composer measured the
height of the text it had held, which does not happen on macOS 27. The check
now shrinks to one line and passes on the runner. Whether a composer emptied
by typing or sending stays tall on macOS 26 was not examined.

In a visible window of the Debug demo build, window resizes through
accessibility, a mouse drag of the window corner out and back, and a drag of
the sidebar divider all left the bottom line of a scrolled-up transcript
above the composer, and returned to the starting position at the starting
size. The first drag trial exposed the end-of-live-resize scroll, which the
hidden-window checks could not see. Screenshots were inspected and not
retained.

Full screen was tried with a temporary probe in the native check, which
showed the fixture window and toggled full screen twice on a 1920 by 1080
display. An earlier reading position kept its bottom line on entering and
returned to its starting offset on leaving, and a followed transcript stayed
on its newest message both ways. The probe was not kept: it needs a visible
window and a free display.

Not verified in a visible window: window tabs and the thread inspector's
divider; they change the same clip view frame as a resize.

## Transcript placement follow-up, 2026-11-10

Three more places where the pane did not show what the window had decided to
show, found while auditing scroll positions for the viewport change above.

Sending while a page of history or the context of an opened message was in
view set the "following" state but kept the view, so the pane scrolled to the
end of the older messages and the next scroll check turned following off
again. A send now leaves that view the way Jump to Latest does.

A message opened from search, the inbox or Go ▸ Back kept the scroll offset
the pane had until the server answered, and only then moved to the message.
The first render that has the message now places it, in the conversation on
screen as well as in another one: in view, or for a restored location at its
remembered offset.

The server's answer, and the offset Go ▸ Back restores after it, also
scrolled back to the opened message after a send or Jump to Latest had left
it. Both now do so only while the message is still the one requested.

Run against the previous behaviour, eight of eleven focused native checks
failed: a send from a page of history and from a message's context, a late
answer to an opened message and a restored location after a send, a scroll
between an accepted send and its render, and before the server answers a
cached message in another conversation, one in the conversation on screen
and a restored location's offset. All eleven pass after the change. The
other three guard existing behaviour and never failed: the fixture opens on
its newest message, and an opened message and a restored location end in
place once the server answered. A demo session does not send, so the send
checks start at the point where the window learns that its send was
accepted. The single call that leads there from the send was read, not run.

Not verified: a real send against a live server, and any of this in a
visible window.

## Composer preview transport, 2026-11-10

The original preview fetcher checked DNS answers and then let URLSession
resolve the name again. TLS hostname validation is not an address pin.
Production preview requests now use macOS's system libcurl, with the checked
addresses supplied as its DNS entry and checked again before socket creation.
The original URL remains the TLS and HTTP authority. Proxies and connection
reuse are disabled; redirects return to the loader for a fresh policy check.

Two native-transport tests supply public answers for `localhost` and observe
the IPv4 and IPv6 endpoints libcurl actually asks to connect to. Their socket
observer refuses the connection before socket creation, so these tests need
no network or local server. Both fail when the DNS pin is removed and pass
with it restored. Additional tests exercise header/body caps, early head
termination, rejected content types, redirects, interrupted images, interim
responses and trailers. The existing URLProtocol fixtures remain internal
and cannot select the production transport. The focused preview suites pass
66 tests. Clang's static analyzer reports no findings for the C bridge.

A temporary live probe, not retained in the test suite, fetched Apple,
Wikipedia and GitHub titles through the production transport, plus Apple's
and GitHub's preview images. Self-signed and wrong-host certificates from
badssl.com produced no preview. No test disables certificate validation.
A live hostile DNS server was not used; socket selection was tested directly
instead. CI remains credential-free and does not contact these sites.

A later review found that Task.detached still put synchronous curl and DNS
work on Swift's cooperative executor. Both now use a utility dispatch queue.
A focused check observes the current Swift task inside the blocking operation:
it fails with Task.detached and passes on the dispatch worker, without sleeps,
network access or deliberately starving the executor.

## Composer completion and shared reactions, 2026-11-11

The cross-window reaction race in #40 is reproduced with the loopback
fixture: one window's older response arrives after another window's accepted
toggle and fresh response. The check fails with a window-local acceptance
counter and passes with session-owned coverage. It checks the shared messages
and both rendered transcripts, without replaying either toggle POST.

Live preview inspection found a short-title layout defect: descriptions were
squeezed into the title's intrinsic width. Two new checks fail before the
layout fix and pass afterward, with and without a picture, including a hidden
then shown description. Existing long-title and minimum-window checks pass.

Returning from an edit could leave an out-of-bounds selection in an already
correct shared draft, which restoreDraft does not need to rewrite. Two checks
fail before storage swaps restore a valid, collapsed caret and plain typing
attributes for an empty draft. A separate real-key-event guard covers the
send's temporary editing lock and return to the shared draft.

Live server readback also exposed formatting inherited after Undo/Redo.
Five new checks fail before checkpoints restore typing attributes alongside
the caret: bold, italic, code, strike-through and spoilers. All five pass
afterward, with subsequent text serialized outside the converted span.

Local validation passes 217 XCTest tests plus 78 protocol and 212 core Swift
Testing tests. The signed packaged app passes 818 native checks, including
polls, reactions, avatars and a real sandboxed Save As with byte verification.
Normal signed-app launches against the existing live test account exercise
Markdown formatting, native Undo/Redo actions, typed links, Apple/GitHub
metadata and pictures through the production transport, preference gates,
draft recovery across Quit/relaunch, and sending/editing in a private
self-DM. No messages to other people or production channels are used. See the
completion PR for the final head, CI/review and live acceptance evidence.

## Goodvantage migration integration · 11 November 2026

The owner approved the full Goodvantage migration, including the
`ch.goodvantage.Nevermore` bundle, callback and Keychain namespace, Forgejo
CI, and the existing release pipeline. No account/container migration is
claimed. Preserve the old build and its data before adding accounts again;
the dedicated OAuth registration must allow `ch.goodvantage.Nevermore://oauth`.
The earlier live sign-in evidence above concerns the earlier identities,
not this new namespace.

The integration retains current main's account-setup link, Settings reloads,
composer/undo fixes, build-bundle cleanup, and native reaction/avatar fixture
coverage. Local verification on the integrated tree passed:

- 250 XCTest cases and 293 Swift Testing tests, with the Keychain tests
  enabled on this Mac; the standalone browser-callback isolation check.
- All 25 Python fixture/release tests on Python 3.13 and 3.15, plus the three
  performance-driver ownership tests. The semver fixture first failed on
  Python 3.13: its dynamically loaded publisher module was not registered
  for dataclass annotation resolution. Registering it before execution fixes
  that failure without changing the vendored publisher.
- A universal Release app with arm64 and x86_64 slices, signed with Apple
  Development, with deep/strict signature and plist/entitlement validation.
- All 827 native demo self-checks and the credential-free native attachment,
  poll, reaction and avatar fixtures. External Save As was skipped because
  `--save-panel` was not requested in this run.
- Shell syntax checks. GitHub actionlint passed structural checks with the
  three Forgejo runner labels configured and exceptions only for Forgejo's
  supported, fully qualified HTTPS action references. This is not Forgejo
  execution validation.

The configured Git access to
`https://forge.goodvantage.cloud/Goodvantage/Nevermore.git` returns
`Repository not found`, including a read with configured credentials. Forgejo
CI and its runner/secret configuration have therefore not been verified.
No release tag, real notarization, production publication, or live OAuth
sign-in/restart recovery under the Goodvantage identity was attempted.
Local results do not waive these deployment gates or count as passing
Forgejo CI.

### Forgejo follow-up before the first beta

Repository access was restored. Native Mac CI run 15 (API run 4544) passed
on `6d7239a`, including the browser callback check, Swift tests, 39 script
tests, three performance-driver tests, release build, and the complete
native fixture with `Native self-check: PASS (0 failures)`. Five Keychain
cases explicitly skip in the system LaunchDaemon; they passed in the local
suite above. External Save As still needs the separate desktop check.

The sandboxed app cannot initialize directly in the system bootstrap. The
fixture now uses an owned Aqua agent in the runner user's GUI domain,
without changing UID or passing CI credentials. A Background agent started
the app but did not satisfy keyboard-focus checks. The successful run used
an unlocked `forgejoci` desktop; merely having a GUI domain was insufficient.
Real SIGTERM verification left neither the owned app nor its agent running.

Two full migration review rounds were inspected. Important defects were
not confirmed; false positives and deferred minor findings are recorded in
Forge PR #1, merged as `04ae83c`. The website icon change passed its own CI
and independent review in Apps-Site PR #11, including 233 nginx/catalog
end-to-end checks. Its main deployment passed, and the public PNG's SHA-256
matches the native app asset.

All six required release secret names are configured. Their contents,
Developer ID signing, notarization, app publication, and live sign-in under
the new namespace still require verification. No release tag has been
pushed at this checkpoint.
