# Nevermore analysis and backlog

A backlog of verified findings and ready-to-build ideas for Nevermore,
written for the next person or model who picks up work. Each entry says
where the problem lives, what to change, and how to know it worked.

- **Original audit baseline:** `main` at 5ada162 (v0.1.0-beta.5), reviewed 17 and 18
  November 2026 by two independent reviews whose results are merged here.
- **Code review:** a full read of the session, realtime, render,
  notification, sidebar and composer paths; the demo run in Classic and
  Vaporwave, narrow and wide, with screenshots of Home, Search, the hover
  bar and Settings; an AppKit probe app for the toolbar scroll edge; and 31
  helper reviews (13 code slices, each on two models, plus lenses for Raven
  parity, Mac-native expectations, visual system, delight and performance).
  Helper claims were checked against the code before they were kept. Its
  entries carry the tags below.
- **Signed Release walkthrough:** the signed Mac client exercised with
  disposable local accounts and loopback Raven responses, with performance
  measurements and window captures (§13). Its entries carry an `NM-` ID,
  which its pull requests cite, and say what was observed and what is still
  to establish.
- **Follow-up baseline:** `63194f6`, extended by a second follow-up pass
  (2026-11-18) whose PRs #98-#109 are in the table below and whose new
  findings are folded into the sections with a `2026-11-18` note.
  All eight PRs are merged into main.
  The follow-ups examined recipient
  search, Home metadata, File inspector layout and recovery, date pickers,
  AppKit rendering, Code Reader validation, and Search state. A later
  swift audit re-read the update monitor, protocol errors, sidebar layout,
  composer accessibility and theme delight (§1, swift audit table).
  Verification used synthetic directories, AppKit probes, and loopback
  fixtures. The release measurements in §13 describe the original audit.
  The added native regressions and cache lookup probe are recorded in
  §13.6.
- **Opus review (63194f6, evening of 18 November):** a debug demo run
  in Classic and Vaporwave at 1080 × 760 with window captures, a read of
  the render path, menus, message menu, notification delivery and
  collection keys, Raven's `chat_stream.py`, `raven_channel.py` and
  `raven_message.py` (develop) for field availability, a standalone
  AppKit probe for the scroll-path cost, and helper reviews of the
  session (LongCat 2.5) and render, composer and core slices (GLM-5.3).
  Its fourteen PRs are in §1; its new findings are tagged in place.
- **Epic-chicken review (`63194f6`, evening of 18 November):** a native
  client read of the session, store, render, composer and core paths. Its
  four PRs are in §1. Two independently implement findings already
  assigned to #84 and #92; the differences are recorded there. New
  evidence covers the decoded-caption display invariant, the table header
  insertion contract, acyclic ancestry walks, the collection filter escape
  paths, the projection purge scope, the thumbnail cache and Home
  freshness.
- **Third-pass review (`18e8722`, 19 November 2026):** five small fixes,
  PRs #110-#112 and #114-#115, all merged into main. They cover the
  parsed-document cache, presence recovery, mention ranking, the poll
  deadline and the search loading state. A seventh, the collection-filter
  Escape, duplicated #82/#84 and was closed. New findings are folded into
  the sections below.
- **Epic-chicken second pass (`627a0fb`, 20 November 2026):** a fresh read
  of the Home feed, notification delivery, collections, the store, the
  protocol transport and the search helpers, plus a re-check of entries the
  earlier passes would otherwise have re-derived. Its three PRs (#116-#118)
  are in §1; new findings carry a `2026-11-20` note in §2 and §3, and the
  entries checked and found not to be defects are in §12.
- **Epic-chicken follow-up (`d86965c`, 23 November 2026):** reviewed the
  composer, transcript rendering, conversation picker, preferences and
  outbox against the current backlog. Two changes have separate PRs in §1.
  Remaining tasks are folded into the relevant sections below.
- **Nevermore sweep (`d86965c`, 23 November 2026, epic-chicken worktree):**
  a fresh read of the session, store, transport, render, composer, Home,
  Search, sidebar and update paths, with the backlog checked rather than
  re-derived. Six small fixes have PRs in §1; the pass also confirmed which
  findings were still live and recorded its checks in §13.10.
- **Epic-chicken audit pass (`d86965c`, 23 November 2026):** a fresh read
  of the session, outbox, transport, store, transcript render, sidebar and
  Home/Search paths, plus three bounded LongCat 2.5 audits of
  `Session`/`RavenRealtime`/`RavenClient`, the transcript shell, and
  `Store`/Search/Home. PRs #145, #146 and #153 carry the implementations;
  new findings carry a `2026-11-23` note in §2, §3 and §4.
- **Independent pass (`e9a2041`, 23 November 2026):** a separate private
  worktree read the session, transport, store, transcript, composer, Home
  and Search paths, with seven bounded LongCat 2.5 audits (three completed
  and were folded in after the cited code was checked). Five small fixes
  are PRs #175, #176, #177, #180 and #181; new findings carry a
  `2026-11-23 independent` note.
- **Epic-chicken task pass (`db515b7`, 23 November 2026):** a fresh read
  of notification routing, session lifecycle, the thread inspector,
  transcript hover and the animated-image cache. Four small fixes are PRs
  #170, #178, #184 and #186; new findings carry a `2026-11-23 epic-chicken`
  note.
- **Tags:** `[V]` verified in code, on screen or by a test. `[H]` found by a
  helper review, cited code supports it, not traced end to end. `[P]`
  plausible, needs a closer look before building.
- **Done items are removed.** Work from the two reviews is indexed by pull
  request in §1 so nobody builds it twice.
- **Where to start:** §2. The walkthrough review suggested the two-account
  reconnect fixture (NM-Q1, §3.8), the mixed-media scroll measurement
  (NM-P1, §4.7) and composer contrast on light glass (NM-26, §5.8).

## Contents

1. Pull requests from the reviews
2. Priorities
3. Bugs and coverage gaps
4. Performance and stutter
5. Visual and layout
6. UX and convenience
7. Missing features and Raven workflows
8. Aesthetics plan
9. Delight and experiments
10. Code health
11. Questions for the owner
12. Checked and rejected
13. Validation record
14. Working notes for whoever picks this up
15. Deep-model pass of 2026-11-23 (consolidated findings)

---

## 1. Pull requests from the reviews

**Follow-up audits on `63194f6`.** The table records implementations for verified findings. Use the linked PRs for current CI and branch status.

| Finding | Implementation and verification |
| --- | --- |
| An exact person could disappear behind 100 matching channels | [#70](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/70) ranks the full directory before limiting the result. A fixture with 101 matching channels moved the exact person from absent to first. In an optimized seven-run probe with 3,000 people and 3,000 channels, median matching time fell from 35.2 to 14.2 ms on the review Mac. These timings exclude AppKit. |
| Invalid reply counts or file sizes could interrupt Home rendering | [#71](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/71) omits invalid metadata while retaining each row. Boundary coverage includes a valid zero, an absent field and a maximum-size integer string. |
| A scheduled message could slip by one slot | [#76](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/76) derives the create and reschedule payloads from the displayed minute. The native picker retained 37 hidden seconds on baseline. The fixed calculation covers midnight, a non-hour site offset, and the spring clock change. |
| A failed File download stayed stuck on the same attachment | [#78](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/78) adds Try Again, same-file retry and explicit Save As retry. An offscreen AppKit probe checked the failure action, and the loopback fixture exercises each entry point. An independent implementation in [#72](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/72) (`audit/0zimz457-file`) verifies duplicate activation shares the successful retry in the same panel. Its native CI passed. Forgejo could not publish an inline suggestion, so a separate GLM review checked the same head and found no actionable issues. |
| The Code Reader could close on an older row still in memory | [#73](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/73) (`audit/0zimz457-reader`) uses one channel-scoped cached lookup. Native checks cover the 1,000-row boundary and actual eviction. The store test covers channel isolation and deletion. One GLM round confirmed the existing history-retention guard and disk-read coverage. |
| Search showed empty results early and shared failure state across tabs | [#74](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/74) (`audit/0zimz457-search`) scopes progress and errors to each tab. The loopback fixture holds Search with no local matches and fails Files independently of Messages. One GLM round checked task cancellation and fixture bounds. |
| Unread and linked-document text stayed small at large reading sizes | [#75](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/75) (`audit/0zimz457-type`) scales both runs. The native transcript checks 11, 13, and 24 pt, the unread divider's copy attribute, and a document type without an identifier. The first GLM round improved coverage and partial-link copy. The second raised minor test and organization suggestions. |
| Mention candidates were rebuilt on every keystroke and caret move | [#98](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/98) gates pool construction on `MentionCompletion.query` and caches the pool behind new `AccountSession` version counters (`directoryVersion`, `channelsVersion`, `generation`, revoked-channel count). A self-check counts pool builds while typing. Branch `feat/mention-pool-gating`. Merged into main after a CI fix (self-check cache reset). |
| "Mark All Notifications Read" looked enabled in conversation windows but did nothing | [#99](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/99) adds a session-wide `AppDelegate.markAllNotificationsRead`, retargets the Message menu item to it, and validates both read items in every window kind (`CollectionWindow.markSelectedRead` stays Inbox-only). Branch `fix/mark-all-read-from-any-window`. Merged into main. |
| The composer link-preview card could neither be opened nor dismissed | [#102](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/102) makes the card open its URL (scheme-checked, VoiceOver custom action) and adds a dismiss button tracked per target URL in `ComposerLinkPreview.dismissedTarget`. Branch `feat/link-preview-open-dismiss`. Merged into main. |
| Code-block line counts were off by one on a trailing newline | [#104](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/104) ignores a single trailing newline in `RichCodeBlock.lineCount`; `CodeBlocksTests` updated (4 to 3) plus a new regression case. Branch `fix/code-block-line-count`. Merged into main. |
| The open-conversation chooser listed the account user as a person, leading to a self-DM attempt | [#105](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/105) excludes `session.account.user` from person candidates when no filter is set; asserted in `NativeShellSelfChecks`. Branch `fix/chooser-excludes-self`. Merged into main. |
| Closing a window with several collection windows could orphan some | [#107](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/107) iterates `Array(collectionWindows)` in both close paths, because `CollectionWindow.windowWillClose` removes itself from the owner's array mid-iteration. Branch `fix/collection-windows-iteration`. Merged into main. |
| A refreshed or re-ingested link preview kept its stale LRU position and could be evicted first | [#108](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/108) moves the key to the end of `insertionOrder` on every `store`. Branch `fix/sent-link-previews-lru-refresh`. Merged into main. |
| "Schedule Message" accepted a marker-only draft | [#109](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/109) validates the built draft with `ConversationWindow.hasText`, like `send`, instead of only checking `activeComposer.string.isEmpty`. Branch `fix/schedule-requires-text`. Merged into main. |

The table preserves the original review rounds and validation results at the time of the audits. All 28 changes are in main by `63194f6`. The subsequent File inspector work is also on that revision. Use the remaining findings below when choosing work. Historical branch states in the table describe the original audit date.

**Swift audit follow-up on `63194f6`.** A second pass over the same
revision, concentrating on the update monitor, protocol errors, sidebar
layout, composer accessibility and theme delight. Its PRs are open; the
entries they implement stay in the sections below until they merge.

| Finding | Implementation and verification |
| --- | --- |
| A manual update check could be swallowed by a cancelled request after stop/start | [#87](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/87) drops the cancelled request in `stop()`, lets only the current request tear down the checking state, and clears `isChecking`/`manuallyRequested`. A `UpdateMonitorTests` case holds the first request, stops and starts, and asserts a second fetch; it fails on the base. |
| `.resourceLimit` always said 64 MB per attachment | [#91](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/91) carries the enforced budget, formats it with `ByteCountFormatStyle`, adds one `maximumAttachmentBytes` constant, and pins the channel-ancestry depth guard to `invalidResponse`. |
| `ChannelPolicy.isArchived` failed open on cyclic ancestry | [#92](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/92) fails closed on a cyclic or over-deep walk and documents that an unknown parent stays sendable because the server is authoritative. |
| The hidden muted bell reserved title width | [#94](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/94) collapses the bell with a zero-width constraint, pins the visible bell at `.defaultHigh`, and self-checks both states. |
| The attachment chip hid its Remove control from VoiceOver | [#101](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/101) leaves the chip out of the accessibility tree; a Home self-check asserts the Remove button keeps its label. |
| Rapid theme switching stacked celebration overlays | [#103](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/103) removes an in-flight overlay before adding the next; a theme self-check asserts one overlay. |

**Epic-chicken review on `63194f6`.** Four small fixes, each with regression coverage and native or unit checks. Two overlap concurrent work: [#82](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/82) and #84 both clear a collection filter on Escape, and [#80](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/80) and #92 both make cyclic ancestry fail closed. #80 walks acyclic chains to their end instead of treating depth past eight as corruption, which is the difference to reconcile if both land.

| Finding | Implementation and verification |
| --- | --- |
| A file caption repeated an encoded file name | [#77](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/77) decodes the caption only for the echo comparison; display stays exactly as the index wrote it. `SearchResultsTests` covers the encoded echo, an empty highlight set after dedupe, a malformed `%` caption and highlight remapping past an escape. Three GLM rounds; the last two found nothing actionable. |
| Inserting above a table header duplicated it | [#79](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/79) emits body cells for any inserted row, so multi-row headers and header-only tables are not extended either. Tests pin the top-inserted row's `<thead>` placement (a documented tradeoff), exact removal, and insertion below the header. Five GLM rounds; the recurring placement finding was declined with evidence: native header styling reads the cell tag, the codec round-trips an all-`td` row inside `<thead>`, and the table sheet only inserts below the selection. |
| Cyclic ancestry failed open for archives | [#80](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/80) fails closed on cycles and walks acyclic chains to their end; an ancestor missing from both maps ends the walk as open, leaving the verdict to the server. Tests cover a self-parent, a two-node cycle, a 20-link chain, a far archived or revoked ancestor, and an O(1) channel lookup. Five GLM rounds; the depth-bound major was resolved by removing the arbitrary cutoff, and the last round found nothing actionable. |
| Escape in a collection filter closed the window | [#82](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/82) clears a populated filter first, from the field delegate and from results focus, and closes only when the control and its live field editor are empty. Six native assertions cover both paths and the editor-only case; the full `--demo --self-check` passes 1,328 checks with zero failures. Six GLM rounds; the stale-buffer finding was fixed, and the later repeated suggestions (install a real field editor, add a redundant marked-text guard, rename `onClose`) were declined with reasons recorded on the PR. |

**Third-pass review on `18e8722`.** Five small fixes, each with a build and
a native or unit check; all five are merged. The collection-filter Escape
was also implemented here and closed as a duplicate of #82/#84.

| Finding | Implementation and verification |
| --- | --- |
| A deleted row dropped every parsed document | [#110](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/110) removes the per-lookup whole-cache clear; the deletion and revocation sets already invalidate when they change. Build and demo self-check pass. No parse-count seam exists for a regression test. |
| A presence refusal latched for the session | [#111](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/111) clears the flag on reconnect and retries a refusal once after five minutes, re-arming on failure. Demo self-check passes. |
| Mention ranking folded titles twice per comparison | [#112](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/112) precomputes the folded title and rank, and clears the Release build's only warning. `MentionCompletionTests` covers the rank tiers and an ID tiebreak. |
| The poll deadline picker could walk into the past | [#114](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/114) sets and refreshes `minDate`; the poll self-check drives the real toggle action and asserts the floor advanced. |
| An empty search cache said "No messages match" while the server searched | [#115](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/115) publishes cached hits only when a tab has them, keeps the tab loading otherwise, and documents `fromCache` as result-set-wide. Demo self-check passes. |

**Epic-chicken second pass on `627a0fb`.** Three small fixes, each with a
build and a unit or protocol check; all three are merged. The Home change
went through four GLM rounds (a cancelled task slot, a newer task's slot,
failed-refresh freshness and a failure backoff were each addressed) and the
URLSession change through three.

| Finding | Implementation and verification |
| --- | --- |
| A cancelled Home refresh looked fresh for 120 s | [#116](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/116) stamps `loadedAt` when a refresh finishes, guards the task slot with a refresh generation, keeps a total failure stale so the next display retries, and adds a 15 s backoff for that case. `swift test`; a dedicated regression test is impractical because the cancellation window is not deterministic. |
| `RavenClient` leaked one `URLSession` per re-login and account removal | [#117](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/117) derives session ownership, invalidates an owned session in `invalidate`, `revoke` and `deinit`, and leaves an injected session alone. `SessionInvalidationTests` observes the real teardown through the session delegate for all four paths. |
| Equal thread timestamps ordered nondeterministically | [#118](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/118) breaks ties by ascending thread id, reads the sort keys once per row, and documents the textual comparison. `threadsIdsBreakEqualTimestampsByName` fails on the base and covers a duplicate id, an empty name and an out-of-scope parent. |

**Epic-chicken follow-up on `d86965c`.** Implementation PRs are left open
for integration. The backlog links each implementation and its verification.

| Finding | Implementation and verification | Review |
| --- | --- | --- |
| Rendering one conversation decoded pending sends from other channels | [#123](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/123) filters in SQLite and preserves Swift channel equality, pending-state exclusion and order. The store regression failed before the fix and passed after it, along with the full local Swift suite. A synthetic 1,000-operation SQLite workload returned 10 matching payloads for one of 100 channels. The query still scans metadata. Frame timing remains open. | Two GLM rounds. Verified collation registration and column/payload consistency. |
| A chooser query with zero matches showed a blank list and an active default action | [#124](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/124) shows scoped empty feedback and enables the default action when a result is selected. Nine native assertions cover empty query results, Return and recovery across the three picker modes. | Two GLM rounds. Prefix-specific empty wording remains in §6.5. |

**Nevermore sweep on `d86965c`.** Six small fixes, each with a targeted
check. The pull requests were open at the time of writing; the verification
record is §13.10.

| Finding | Implementation and verification |
| --- | --- |
| A failed emoji page erased pages already loaded | [#134](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/134) keeps rows and the failed offset so Load More retries that page; a demo fixture and a native self-check drive a 50-row first page whose second page fails. |
| Staging errors named the global budget | [#125](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/125) reports the room that applied, refuses empty stages once the allowance is spent, and pins exact-fit and partial-room boundaries. |
| Roster and chooser filters ran during marked input-method text | [#139](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/139) adds the `hasMarkedText()` guard to both fields and checks the notification sender. |
| A send that never left could not be cancelled | [#143](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/143) derives Cancel Send from `InkRules.canTakeBack` so the outbox and transcript agree; a state-matrix unit test covers attempted and unattempted sends. |
| The search thread cache never evicted | [#144](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/144) caps the cache at 24 entries and drops the stalest by fetch time. |
| The update panel kept Download after dismissal | [#147](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/147) derives Download and Dismiss from one `visibleOffer` predicate. |

A seventh branch (a silent no-op for a missing host-slot count) was closed as
a duplicate of #126, which is already on main.

**Epic-chicken audit pass on `d86965c`.** The PRs are open for integration;
the entries they implement stay in the sections below, marked with their
number, until they merge.

| Finding | Implementation and verification | Review |
| --- | --- | --- |
| A re-render restored the caret by raw character offset, so prepending history could move the Message menu to another message | [#145](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/145) captures the caret's message and offset within it before the ranges are rebuilt, restores strictly inside that message's new range, maps an end-of-text caret to the last message, and collapses to the nearest surviving message when the caret's message is gone. A new placement self-check fails on the base revision and passes after the change; `swift test` and the full demo self-check pass. | Three GLM rounds. Round 3 was minor-only; the end-of-text caret and collapse target were fixed. A non-empty selection still restores by raw offset (recorded below); the confirming round and native checks are queued. |
| Home's Mark All Read counted conversations it could not acknowledge | [#146](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/146) adds `HomeUnreadDigest.actionable`, counts only entries with a readable newest-message timestamp and reports the remainder, with an informational sheet when none can be acknowledged. `HomeDigestTests` covers the no-details, details-without-timestamp and cached-fallback cases; `swift test` passes. | Two GLM rounds, minor only. The empty-actionable copy and the latest-without-timestamp test were fixed; a confirming round and native checks are queued. |
| A Files or Links search kind survived a switch to the local Conversations and People tabs | [#153](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/153) applies `criteria.on(next)` for every tab, so the local tabs search the Messages kind and a saved search stores the right kind. A new search self-check fails on the base revision and passes after the change. | Three GLM rounds. Round 3 was minor-only: the filter-semantics test gap is recorded below; native checks are queued. |

**Concurrent follow-up on `d86965c`, merged as `db515b7`.** Two entries
from the 2026-11-20 list are done; the code is in `main`.

| Finding | Implementation |
| --- | --- |
| `releaseHostSlot` contradicted its own comment (N6) | #126 returns silently when the host count is missing instead of calling `assertionFailure`. |
| `Store.stage` named the global budget (N9) | The same merge throws the applied `limit` at both the size guard and the copy guard. |

**Independent pass on `e9a2041`.** Five small fixes, each with a check
observed failing on the base revision before it passed. The PRs are open for
integration; the entries they implement stay in §3 and §4 until they merge.

| Finding | Implementation and verification | Review |
| --- | --- | --- |
| A transient OAuth `server_error` rejected a queued message | [#175](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/175) classifies the token endpoint's server fault as retryable, like `temporarily_unavailable`. `MutationOutcomeTests` gained transient and client-fault cases; the transient case failed on the base. Protocol suite 91/91. | Open |
| A local search snippet dropped a match past the 400th word | [#176](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/176) normalizes whitespace but searches the whole indexed body, then windows around the first match. `localSnippetFindsAMatchPastTheWordWindow` failed on the base; 40 search tests pass. | Open |
| A withdrawn channel's queued read receipt was retried on every flush | [#177](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/177) deletes withdrawn channels' `visits` with their history. `testWithdrawnChannelsDropTheirQueuedReadReceipts` failed on the base; `NevermoreCoreTests` 406/406. | Open |
| Home kept the previous account's content on an account switch | [#180](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/180) schedules a Home rebuild and starts the new account's feed in `use(_:)`. A new `HomeSelfChecks` case failed on the base and the Home module then passed with zero failures. | Open |
| Re-caching an unchanged page re-parsed and re-indexed every row | [#181](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/181) compares the stored payload in the upsert, skips the FTS rewrite for unchanged rows, skips the trim when nothing changed, and encodes stored JSON with sorted keys so equal content has equal bytes. A new store case pins the FTS rowids across a repeated cache; `NevermoreCoreTests` 406/406. | Open |

**Epic-chicken task pass on `db515b7`.** Four fixes, each with a native
check or a documented fixture procedure. The PRs are open for integration;
the entries they implement stay in the sections below until they merge.

| Finding | Implementation and verification | Review |
| --- | --- | --- |
| A notification click at cold launch is dropped before channels load | [#170](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/170) retains the route while the account or channel is still loading, replays it from the session-change observer, expires it after 60 seconds, honors revocation and stopped sessions, and activates only once a live session is found. Collection self-checks cover retention, replay, a revoked channel and teardown; the first run exposed an observer token that was not retained, now fixed. | Open |
| The thread inspector's root goes stale, its failures hide behind a cached render, and it cannot page back | [#178](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/178) rebuilds the header during render, latches refresh errors behind Retry, and adds Load Earlier with a window that grows by one server page per page-back. A rename assertion and `testMessagesBeforeBoundaryReadsTheOlderPage` cover it; the full native suite passes. | Open |
| Hover and caret lookup scan every message range per pointer move | [#184](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/184) binary-searches layout order for both, shares one band scan between thumbnails and the read receipt, and remembers the newest receipt per channel. Layout self-checks probe the first and bottom visible rows, assert range order, and fail against the linear base. | Open |
| One failed visit aborts the flush and marks the account failed; `realtimeLive` survives a disconnect | [#186](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/186) gives each `track_visit` its own catch and leaves the snapshot pending, and clears `realtimeLive` in `reauthenticate` and `stop`. Build and the native suite pass; the loopback fixture is the remaining procedure. | Open |

**Opus review follow-up on `63194f6`.** One branch per finding, each with
new native or unit checks; for #90, #93 and #106 the new check was seen
failing before the fix. The PRs are open for the owner; the entries they implement stay in the
sections below, marked "Implemented in #N", until they merge. Review
rounds and declined suggestions are in the PR threads and the notes after
the original table.

| Finding | Implementation and verification | Review state |
| --- | --- | --- |
| Save for Later could only add; the transcript never showed saved or pinned state; the menu said "Pin / Unpin" | [#81](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/81) reads `_liked_by` (every `get_messages` row) and `pinned_messages_string` (every channel), draws bookmark and pin marks after the header time, and makes the items "Save for Later" / "Remove from Saved" and "Pin Message" / "Unpin Message" (`save_message` with `add: false` removes). `MessageMarkSelfChecks`, `MessageMarksTests`. | 1 GLM round, minor only; CI green |
| No way to copy a whole message; Open Code Reader validation parsed HTML with SwiftSoup on every menu validation | [#83](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/83) adds Message ▸ Copy Message Text and context "Copy Text" (plain text, spoilers masked, shared with Copy Transcript) and validates the Code Reader item through the cached `messageDocument(for:)`. Check against #73, which also touches Code Reader lookups. | 1 round, minor only; CI green |
| Escape in a collection's filter closed the window | [#84](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/84) clears the filter first and keeps the selected record; Escape on an empty field closes. A parallel commit on another branch ("Clear a collection filter on the first Escape") does the same; merge only one. | 1 round; a "major" refuted (PR comment); CI green |
| Annotation lines ignored the reading font and size; "Code · 1 lines" | [#85](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/85) adds `TranscriptStyle.secondaryFont` (system, max(11, size − 2)) for the linked-document line, the fallback note, the Reactions line and the unread and day dividers, and says "1 line". Overlaps #75 on the linked-document and unread lines; merge one and rebase the other. | 1 round, minor only; CI green |
| "11 more than the week before" after an empty week; "You Talk with Most"; "1 queued sends" | [#86](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/86): "None the week before", "People You Talk With Most" (PRIVACY.md too), "N unsent messages" with a singular. | 2 rounds, minor only |
| Notifications always said "New activity in Raven" | [#88](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/88) adds Settings ▸ Notifications ▸ Show: nothing about the message (default, unchanged), sender and conversation, or the message with spoilers masked (240-character excerpt). A conversation not yet in the list stays generic. `NotificationPreviewTests`, PRIVACY.md. | 2 rounds; the re-raised "major" refuted with Raven source (PR comment) |
| Right-clicking Home, a sidebar heading or empty sidebar space showed an empty menu | [#89](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/89): Home offers Customize Home…; headings and blank space offer New Message…, New Channel… and Show Archived Conversations. | 1 round, minor only |
| `www.example.com` did not auto-link | [#90](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/90) links "www." hosts with at least three labels and a letters-only top-level label, opening `https://`; lookalikes stay text; a "www." address carrying a redirect target links too. | 2 rounds, minor only |
| A conversation whose access returned never rejoined its realtime room; a malformed presence reply cleared every presence dot | [#93](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/93) calls `updateRooms()` from `revokedChannels.didSet` and keeps the last presence set unless the reply is an array of strings. The restore check failed before the fix. | 1 round; a "major" refuted (PR comment) |
| Long scrolls lose track of the day (delight) | [#95](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/95) floats the topmost message's day under the toolbar while the reader scrolls, in the day divider's style, fading 1.2 s after scrolling stops; it gives way to a divider at the top and to the earlier-messages spinner. | 1 round; "major" about `NSApp.currentEvent` declined, see notes |
| No Previous Unread Conversation | [#96](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/96) adds Go ▸ Previous Unread Conversation (⇧⌥⌘↑), wrapping like Next Unread. First checks for the adjacent-conversation commands. | 1 round, minor only |
| Each scroll event measured every message twice (3.9 ms p50 for 500 messages on an M4 Max) | [#97](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/97) binary-searches `messageRanges` for the band (0.11 ms p50, same messages in all 50 probe bands). `markSeen` per event remains (§4.2). | 2 rounds; a "major" refuted (PR comment) |
| A conversation with an unsent draft looked like any other in the sidebar | [#100](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/100) shows a pencil in the muted-bell slot (", draft" for VoiceOver), not for the conversation on screen; the session keeps the set from the store and from saves. | 2 rounds; a "major" refuted, two minor fixes applied |
| Escape during IME composition cancelled the reply instead of the conversion | [#106](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/106) lets Escape reach the input method while text is marked, as Return already did. The check failed before the fix. | 1 round; a "major" refuted (PR comment) |

Verification for all fourteen: `swift test` and the full `--demo
--self-check` on each branch (1,321 to 1,334 checks) with only the
focus-dependent flakes listed in §14 failing, rerun where a new name
appeared. CI results are on each PR.

<details>
<summary>Original 28 implementation PRs and review rounds</summary>

| PR | Finding | Branch | What it does | State (2026-11-18) |
| --- | --- | --- | --- | --- |
| [#37](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/37) | Related navigation | `fix/reuse-conversation-windows` | Notification clicks and Inbox, Threads and Saved opens reuse a window that shows the conversation, else a free window of the account; a new window only when none is free. Option-click in collections still opens a new one. | 2 rounds; round 2 re-raised a refuted claim (PR comment); steady; CI green |
| [#38](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/38) | NM-10 | `fix/keep-unread-on-failed-refresh` | A failed unread-count or notification-ID read keeps the last known values instead of clearing every badge, raven and the Dock dot. | 1 round, minor only; steady; CI green |
| [#39](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/39) | NM-08, partial | `perf/presence-without-rerender` | Presence pings post `sessionPresenceChanged` and refresh only sidebar rows and Home, instead of re-rendering every transcript. | 2 rounds; the last claim refuted (PR comment); steady; CI green |
| [#40](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/40) | Related navigation | `feat/clickable-reply-quotes` | Clicking a reply quote goes to the answered message (in place or loaded with context); unloaded quotes name their author from `replied_message_details`; VoiceOver action "Show Answered Message". | 1 round, minor only; steady; CI green |
| [#41](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/41) | NM-04 | `review/badge-contrast` | Make themed Home unread counts legible: the Favorites badge picks a black or white number for its actual fill. | Walkthrough review; CI green |
| [#42](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/42) | NM-H1 | `review/home-state` | Keep Later accurate when a local read fails: each local source on Home carries a loading, success or failure state. | Walkthrough review; CI green |
| [#43](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/43) | NM-05 | `review/home-order` | Make Home module order editable without dragging: Move Up/Down buttons and Option-Up/Down in Customize Home. | Walkthrough review; CI green |
| [#44](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/44) | Related input | `fix/chip-press-defers-render` | Reaction-chip presses run under `LiveResizeTextView.trackPress`, so renders wait for the press like link presses do. | 1 round, minor only; steady; CI green |
| [#45](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/45) | NM-H2 | `review/home-drafts` | Open the intended draft from Later: choose which draft to resume from Home. | Walkthrough review; CI green |
| [#46](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/46) | NM-S2 | `review/compact-preview` | Preview surrounding messages in a compact Search pane. | Walkthrough review; CI green |
| [#47](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/47) | Related composer | `fix/readable-markdown-source` | Switching to Markdown no longer escapes every punctuation mark; a readable candidate is verified by round trip, with the old full escaping as fallback. | 2 rounds, minor only; steady. CI red only from the Services-menu clash that #63 fixes (PR comment); rerun once #63 is in |
| [#48](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/48) | Related navigation | `fix/sidebar-keyboard-opens` | Arrow keys in the sidebar open the conversation the selection rests on after 250 ms; Return opens the highlighted one at once. A sidebar reload during the pause keeps the arrowed selection, which is compared by conversation, not row index; opening a conversation, Home or search another way during the pause cancels the pending open. | 3 rounds; round 2's blocker refuted (PR comment) and its minor race fixed; round 3 minor only; steady; CI green |
| [#49](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/49) | NM-S1 | `review/search-local` | Show eligible cached matches before the thread list arrives. | Walkthrough review; CI green |
| [#50](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/50) | NM-12 | `review/members-roster` | Replace the Members alert (200 names at most) with a searchable native roster that can start a direct message. | Walkthrough review; CI green |
| [#51](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/51) | NM-03 | `review/visit-retry` | Keep read receipts retryable after a failed local write. | Walkthrough review; CI green |
| [#52](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/52) | NM-11 | `review/schedule-feedback` | Distinguish "scheduled" from "draft cleanup failed". | Walkthrough review; CI green |
| [#53](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/53) | NM-19 | `review/complete-reminder` | Complete a fired reminder in Later. | Walkthrough review; CI green |
| [#54](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/54) | NM-01 | `review/gif-recovery` | Stop replaying a GIF when the original send outcome is unknown: an uncertain GIF send waits in Needs Review. | Walkthrough review; CI green |
| [#55](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/55) | Related composer | `fix/markdown-mentions` | Mention completion works in Markdown mode (code spans and fences still suppress it); the popover's list no longer steals the editor's focus. | 1 round, minor only, one claim refuted (PR comment); steady; CI green |
| [#56](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/56) | Related notifications | `fix/notification-grouping` | Notifications stack per conversation (`threadIdentifier`); a failed delivery no longer consumes its dedupe entry; dedupe keeps the newest 1,000 instead of resetting. | 1 round; a major claim refuted (PR comment), minor otherwise; steady; CI green |
| [#57](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/57) | NM-13 | `review/channel-details` | Make channel identity and description visible: a Channel Details sheet in Conversation Info. | Walkthrough review; CI green |
| [#58](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/58) | NM-23 | `review/thread-resize` | Keep an open thread recoverable when the window gets narrow. | Walkthrough review; CI green |
| [#59](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/59) | Related transcript | `feat/edited-mark` | Edited messages show a small "(edited)" after their text, as Raven's web client does. | 1 round; a blocker refuted (PR comment), one minor deferred; steady; CI green |
| [#60](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/60) | NM-02 | `review/history-epoch` | Invalidate overlapping loads on conversation access denial. | Walkthrough review; CI green |
| [#61](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/61) | NM-20 | `review/inbox-read-all` | Mark the entire notification inbox read in one action (`mark_all_notifications_read`). | Walkthrough review; CI green |
| [#62](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/62) | NM-25 | `review/onboarding-labels` | Keep sign-in labels visible and explain the site-specific preset. | Walkthrough review; CI green |
| [#63](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/63) | Related native checks | `fix/menu-check-skips-services` | The native self-check's menu-shortcut uniqueness check skips the Services submenu, whose system items (Make New Sticky Note, Open man Page in Terminal) collided with app shortcuts on the CI Mac and failed unrelated PRs. A second fixture shows a real clash between app menus is still caught. | 2 rounds, minor only; steady; CI green |
| [#64](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/64) | NM-07 | `review/search-filters` | Keep every Search filter reachable in a narrow pane. | Walkthrough review; CI green |

</details>

The combined integration is recorded in main at `04f31ec`. The [original integration notes](https://forge.goodvantage.cloud/Goodvantage/Nevermore/src/commit/63194f6d3472a44f22c81e66ea89add2b3a43b11/ANALYSIS.md) preserve the pairwise conflict inventory, fixture requirements and pre-integration checks.

**Remaining scheduling check.** Confirm whether read-only accounts can still open the date picker. The create action guards the POST after date selection. Exercise both menu validation and direct invocation.

Review notes deferred from the code review's PRs (minor, worth a
follow-up), by PR:

- #37: Option-click detection in `CollectionWindow.open()` reads
  `NSApp.currentEvent`, so direct calls from checks depend on whatever
  event is current; pass the modifier flags in instead (CollectionWindow.swift
  around :309). The Open button's accessibility label still says "Open
  selected result" although its default now reveals in place; make it
  "Show selected result" (CollectionWindow.swift:58).
- #38: the kept values have no staleness bound. See NM-10 (§3.6).
- #40: when `replied_message_details` lacks a name, the quote falls back to
  the raw owner ID; resolve it through the users list first
  (ConversationWindow.swift around :1058). Quote hit-testing is only
  self-checked on a single-line quote; add a wrapped multi-line case.
  Clicking a reply quote while editing a message moves focus out of the
  editor when the answered message is loaded, and does nothing when it is
  not (ConversationWindow.swift around :1240). Pick one behavior; at least
  say why nothing happened. `[H]`
- #44: `TranscriptViewportKeeper.trackPress` has no depth count, so a
  nested press would clear `textUnderPress` and fire `pressDidEnd` for the
  outer one (TranscriptViewportKeeper.swift around :189); count nesting
  if a nested press becomes possible. `PressProbe` was widened from
  `private` so `DelightSelfChecks` can share it. `[H]`
- #47: `RavenMarkdown`'s `startsEntity` treats `&#;` and `&#xZZ;` as entity
  references and escapes them. Harmless (round trips hold); tighten to `&#`
  plus a digit or `&#x` plus a hex digit if exact source matters.
- #47: paragraph text that starts with four spaces or a tab would parse
  back as indented code, so the readable form fails its round trip; full
  escaping does not touch whitespace either, so the export falls back to
  the HTML island form (as it did before #47). In readable mode, escape the
  first leading space as `&#32;` or the tab as `&#9;`. First check that
  `RavenMarkdown.document(from:)` keeps leading spaces in paragraph text at
  all; test `"    see this"` and `"\tsee this"`. `[H]`
- #55: the self-check that mentions stay off inside a code span can pass
  because the query was dismissed, not because of the code span
  (SelfCheck.swift around :183); use a fresh, never-dismissed query.
  `MentionPopover` picks Markdown detection by `textView.isRichText`
  (MentionPopover.swift:38); pass the composer's mode instead, so syntax
  highlighting in the source view cannot switch it. `[H]`
- #56: `RecentIdentifiers` evicts oldest-first and a repeated insert does not
  refresh an entry; say so in its doc comment before it gains another caller.
- #59: when "(edited)" takes its own line after block content, its run has
  no paragraph style, so that line uses AppKit's default spacing
  (TranscriptStyle.swift around :122); give it the body paragraph style in
  the `afterLineBreak` case. `[H]`
- #81: the transcript reads pins from `session.channels` with the
  window's channel as fallback, while `isPinned(_:)` returns nil when the
  channel is not listed; one shared lookup would keep mark and menu title
  in step. Marks build a handler-drawn symbol image per message per render;
  cache by symbol and size if marks become common. Confirm the `_liked_by`
  wire shape (JSON array, string-encoded or native) on Frappe 15 and 16.
- #83: `copyFullTranscript` still spells out the revocation check that
  `channelIsRevoked(_:)` now covers (ConversationWindow.swift around :1843).
- #84: filtering as you type drops the table selection (`applySearch`
  reloads); only the Escape path restores it. Factor one
  capture-and-restore helper if typing should keep it.
- #95: the pill's center is set on scroll only, so a resize while it shows
  leaves it off-center for up to 1.2 s; a stale `.scrollWheel` in
  `NSApp.currentEvent` can show it briefly after a placement the app made.
  An explicit momentum flag from scroll-wheel phases would remove the
  `currentEvent` read.
- #96: the no-selection path of Previous Unread Conversation (selects the
  last unread) has no check.
- #100: `AccountSession.holdsContent` calls `ConversationWindow.hasText`;
  move that helper into NevermoreCore with the draft model.
- #63: the menu-shortcut uniqueness check scans one submenu level. No
  static shortcut sits deeper today (Edit > Find > Saved Searches is filled
  lazily by its delegate), but a future one would go unchecked. A recursive
  walk that records full item paths ("Edit > Find > Saved Searches > …")
  and still skips the Services subtree would cover it; give the clash
  fixture a nested duplicate.

**Epic-chicken pass on `d86965c` (23 November 2026).** One branch per
finding, each with a PR against main; verification ran locally (`swift test`
plus `--demo --self-check` where noted) and in CI. All twelve merged into
main by `acfe5bb` (the "open" markers below were written before the merges);
the matching entries in the sections below can now be dropped. #127 (staging
budget) and #130 (host-slot no-op) were closed as duplicates of #125 and
#126, which landed on main.

| Finding | Implementation and verification | Review |
| --- | --- | --- |
| `clearHistory()` deleted projections although its contract keeps them (§3.2) | [#131](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/131) drops the `DELETE FROM projections`; `StoreTests` asserts messages are gone and the projection survives. Caller audit: the only callers are retention-off sync and the user-facing clear; account removal deletes the whole account directory. Full suite green. | 1 GLM round; the Major (caller audit) was answered with the audit on the PR. Merged as `7bb2427`. |
| Selection marks and segmented controls ignored the theme accent (§5.2) | [#141](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/141) uses `themeAccent`/`selectedSegmentBezelColor` for the gallery ring and badge, quick-reaction fill, GIF selection border (re-resolved on redraw via a `wantsUpdateLayer` cell view), Visual/Markdown segments, search tabs, and the update notice. | 2 GLM rounds; round 2's Major (`updateLayer` dead without `wantsUpdateLayer`) fixed. |
| A failed emoji-picker page erased the pages already loaded | [#142](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/142) keeps `items` and the failed `nextOffset` on a page failure (reset failures already re-zero the offset); a demo fixture (`demo-page-failure`) and `EmojiSelfChecks` case drive it; local self-check passes. #134 covers the same fix concurrently. | 2 GLM rounds; the round-1 Major (stale offset) was refuted with the reset path that sets `nextOffset = 0` before fetching; round 2 found nothing actionable. |
| Presence parsing treated empty strings as skippable | [#149](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/149) skips only `.null` entries (cache-key expiry race); an empty user ID is malformed and rejects the reply, so an empty set never silently clears every presence dot. `PresenceReadTests` updated. | 2 GLM rounds; round 1's Major (empty string must be malformed) fixed; round 2 caught an accidentally committed `tmp.md`, removed. |
| `deliverNotification` could swallow an incoming message (§3.5 N4) | [#155](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/155) reads a named-constant page (`notificationPageLimit = 5`) and picks via `NotificationPolicy.nextNotification(in:user:seen:notified:)`, which filters delivered and already-seen (`lastSeen`) rows before choosing the newest foreign one; `newestForeign` is order-agnostic (max by `creation`). Unit tests cover masking, nil watermark, ordering. | 2 GLM rounds; both Majors (heuristic ceiling, phantom re-notify) addressed — named constant plus the `lastSeen` bound and filter-before-pick. |
| Line-capped labels clipped mid-glyph | [#156](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/156) sets `lineBreakMode`/`truncatesLastVisibleLine` on the roster, emoji picker, file inspector and thread-inspector labels; the filename truncates middle so the extension stays visible; truncated labels got tooltips with the full text. | 1 GLM round; Minors (middle truncation, tooltips) applied. |
| Retryable outbox rows and hard errors shared one color | [#157](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/157) moves collection status and search footer errors to `themeAlert`, but keeps retryable outbox rows `systemOrange` so will-retry stays distinct from failed. | 1 GLM round; the Major (collapsing warning onto the alert token) fixed by reverting that one line. |
| Thread replies never raised notifications | [#158](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/158) gates a thread on its parent conversation via a pure, tested `ChannelPolicy.shouldNotify(channelID:channels:revoked:threadParents:)` — revocation on the whole ancestry, gate ID walked to the top-most ancestor with a cycle guard. `ChannelPolicyTests` cover revoked/archived/muted/allow_notifications, unknown IDs, threads, nested threads, cycles. | 2 GLM rounds; the Critical (self-revocation) and Major (one-level gate) folded into the extracted helper with table-driven tests. |
| Collection bottom bar overflowed at minimum width | [#160](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/160) hides the two inbox-only buttons below 720 pt in `updateBarVisibility()` (called from `updateChrome()` and `windowDidResize`, writes guarded against redundant `isHidden`); both actions stay in the Message menu. | 2 GLM rounds; Minors (redundant writes, initial state, menu fallback) addressed; the outside-diff Major was answered — both items exist in MainMenu. |
| Thread root re-parsed on every `updateContext()` | [#161](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/161) reads through `session.messageDocument(for:)`, which parses synchronously on a miss and re-parses when the html bytes change. | 1 GLM round; the Major (cache miss degrades) was refuted — `MessageDocumentResult` has no pending state, a miss parses on the spot. |
| One undecodable saved search discarded all of them | [#165](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/165) decodes entry by entry via `JSONSerialization` and skips undecodable entries; an over-limit stored list (written by a newer version) truncates to its first 30 instead of reading as empty. `SearchSelfChecks` seeds the broken entry alone first (non-vacuous) plus an over-limit case; local self-check passes. | 1 GLM round; both Minors applied. |
| Schedule accepted a message while an edit was open | [#166](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/166) adds `editing == nil` to the schedule validator and guard. | 1 GLM round; nothing actionable. |

---

**Deep-model pass (`epic-chicken-mine` worktree, 2026-11-23).** A fresh read
of the whole app plus five bounded LongCat 2.5 audits (transcript/window,
composer, core/protocol, Home/Search/collections, shell/theme/onboarding).
Findings are consolidated in §15; the implementations are these PRs, each on
its own branch off the then-current main, labelled `zai-model:deep`:

| Finding | PR and status |
| --- | --- |
| Missing host-slot count was not a silent no-op | [#126](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/126) merged |
| Conversation chooser's Cancel had no Escape key equivalent | [#128](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/128) merged |
| An 11th conversation in one burst was never queued (count cap) | [#129](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/129) merged |
| Saved Searches had no target in a non-conversation window | [#135](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/135) merged |
| A forced Home refresh could pass an in-flight one | [#136](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/136) merged |
| Notification picked the newest row even when it was the reader's own | [#132](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/132) closed as duplicate of #155, which landed the same fix on main via `NotificationPolicy.nextNotification` |
| `sendGIF` could post the same GIF twice | [#133](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/133) merged — `acceptingChannels` guard now held through delivery |
| Visual composer accepted an unbounded text paste | [#137](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/137) merged — `paste` refuses text above `RichTextCodec.maximumBytes` |
| Menu-driven caret format left the toolbar stale | [#138](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/138) merged — refresh only when `sendAction` was handled |
| Write in Markdown was not a checked toggle | [#140](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/140) merged |
| Home Mark All Read skipped conversations with no reported latest | [#148](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/148) merged — falls back to the newest cached message and reports acted/skipped/unreadable truthfully |
| Empty poll retraction reported success | [#151](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/151) merged — `PollError.noVote` |
| Attachment window showed saved-file actions before saving | [#152](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/152) merged |
| Buffered responses enforced the byte cap before status classification | [#159](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/159) merged — `readBounded` classifies first; oversized 401 refreshes, oversized 403 maps to its status; 6 boundary tests |
| Re-login invalidated the live client before the Keychain save | [#163](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/163) merged — save first |
| "Mark All Notifications Read" could act on an arbitrary account | [#164](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/164) merged — disabled when ambiguous |
| Clear Received History left decoded GIFs and link previews in memory | [#167](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/167) merged |
| Code-reader context menu re-parsed HTML instead of the cache | [#168](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/168) merged |
| "Reply in Thread" inside a thread created a nested thread; actions offered on System events | [#169](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/169) merged — menu, hover bar, validation and AX all gated |
| Home rows built a DateFormatter per row and dropped the year past a week | [#171](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/171) merged — cached per template/time zone/calendar; `d MMM y` |
| People card showed the empty note on a failed load | [#172](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/172) merged |
| Cancelled search attachment read kept a stale status | [#173](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/173) merged |
| Search preview cache cleared entirely at 51 entries | [#174](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/174) merged — real LRU |
| Ordered lists kept stale numbers after leavingBlock / whole-line delete | [#179](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/179) merged — renumber beside the caret |
| Theme taglines still in the Settings gallery tooltip/AX help | [#182](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/182) merged — owner rule restored |
| Member roster refolded every entry per keystroke | [#183](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/183) merged — `MemberRoster.SearchIndex`, equivalence test |
| One undecodable payload aborted store recovery / the v3 migration | [#185](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/185) merged — rows skipped and os.log-logged, tests corrupt a row via GRDB |
| Composer placeholder was not exposed to VoiceOver | [#188](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/188) merged — placeholder surfaced as accessibility value/help |
| `--demo` never activated the app | [#189](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/189) merged — demo branch activates like the shared path |
| Keyboard Shortcuts window was hand-written and drifted from the menus | [#190](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/190) merged — generated from `NSApp.mainMenu`, HIG modifier order, correct function-key glyphs |
| Reply/edit could clobber each other; deleting the edited message orphaned the edit | [#187](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/187) merged — reply/edit/delete all gated on `editing == nil`; draft no longer persisted mid-edit |
| "writeHistory wedge" / "refreshAfterInflight shadowing" | [#162](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/162), [#154](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/154) closed as false positives — see §12 |


## 2. Priorities

The ten items with the best value for the effort, in order.

1. **Stop full re-renders on every session change** (§4.1, NM-08, fixes 2
   and 3).
   Measure the resulting layout and frame-delivery cost before attributing stutter.
2. **Recover from a failed transcript load** (§3.1), then
   **open conversations at the first unread message** (§6.1).
3. **Toolbar title drawn over transcript text** (§5.1).
4. **Notification previews and actions** (§7.1).
5. **Failed sends retry only while Nevermore is frontmost** (§3.4).
6. **Typing indicators** (NM-15, §7.4), with the typing raven (§9.1, idea
   1).
7. **Add message destinations to Open Conversation** (§7.3).
8. **Visual sweep 1** (§8): radius ladder, themed sidebar selection, theme-aware
   chips and day pill.
9. **Mark All Read command and Inbox read state** (§6.5, §3.5); the
   Inbox-wide action is in #61 and works from any window since #99.
10. **Render-path costs that scale with scrolling** (§4.2).

**From the 2026-11-20 pass** (see the tags in §3):

- **Notification delivery can lose a message** (§3.5, N4 and N5): a newer
  message from the reader swallows the notification (N4, implemented in
  #155), and an 11th conversation in one burst is never queued (N5, open).
  Higher user impact than most
  of the items above because the reader never learns a message arrived.
- **Home's Mark All Read skips a conversation without a latest message**
  (§3.5, N8) while still counting it in the confirmation.

**From the 2026-11-23 pass** (see the tags in §3):

- **Serialize `refresh()`** (§3.5, 2026-11-23). Two overlapping refreshes
  can publish a stale channel list and resurrect a newly revoked channel.
  This is the strongest remaining correctness lead in the session.
- **Confirm room joins** (§3.5, 2026-11-23). A silently rejected
  `doc_subscribe` is remembered as joined and never retried, so an open
  conversation can miss live messages until the socket reconnects.
- **Give the large directory and history RPCs their own budget**
  (§4.5, 2026-11-23). `get_list` is read with `try?` under the 8 MB default,
  so a large site silently loses names, DM titles and avatars.
- **Do not let a failed Home module clear the last good value**
  (§3.5, 2026-11-23): a failed `get_unread_threads` empties every thread
  badge, and a forced refresh during an in-flight one is dropped.
- **Copy staged files outside the store transaction** (§4.5, 2026-11-23);
  the existing note already says the copy blocks the queue, and the fsync
  makes the stall longer.

---

## 3. Bugs and coverage gaps

### 3.1 Make failed transcript loads recover in the same pane `[V]`

A cached read failure after switching conversations keeps previous rows visible under a new title and leaves viewport tracking suspended. Start with a deterministic read-failure fixture. Preserve same-channel text on a background refresh failure, clear foreign rows on failed navigation, release the updating state, and offer a contextual Retry against the current navigation generation. Test access removal and attachment presses explicitly because `TranscriptView.clearText()` retains pressed link storage until mouse-up. [Render path](Sources/NevermoreApp/ConversationWindow.swift#L1032) · [Press retention](Sources/NevermoreApp/TranscriptViewportKeeper.swift#L185)

### 3.2 `clearHistory()` deletes projections although its contract keeps them `[V]`

Done in #131 (merged as `7bb2427`): the code was wrong, the doc comment was
the contract. The `DELETE FROM projections` is dropped; `StoreTests` seeds a
projection, clears, and asserts messages are gone while the projection
survives. Caller audit recorded on the PR: the only callers are
retention-off sync and the user-facing "Clear Received History"; account
removal deletes the whole account data directory, so no erase path relied
on this method clearing projections. See §1 for the full entry.

### 3.3 Bodies are cut at 4,096 characters without a mark `[V]`
- **Where:** plain-text fallback and system events use
  `String(prefix(4096))` (ConversationWindow.swift:1020, :1045). Copy
  Transcript uses the full text, so display and copy disagree.
- **Fix:** render the full text, or truncate with "…" and a "Show Full
  Message" reading control.
- **Check:** a layout self-check with a 5,000-character plain message.

### 3.4 Failed sends retry only while Nevermore is frontmost `[V]`
- **Where:** the reconciliation worker flushes the outbox only
  `if NSApp.isActive` (Session.swift:440, added in #14 without a recorded
  reason). Sends in `.retryable` are retried only there.
- **What happens:** a message can sit queued for hours while the app is in
  the background, although refresh succeeds and the socket is live.
- **Fix:** flush after every successful reconciliation; if the gate exists to
  avoid retry storms, gate on connectivity or back off per operation
  instead. Ask the owner first
  (§11).

### 3.5 Smaller bugs
Each is small and local. `[V]` unless tagged. An entry marked
"implemented in #N" has an open PR in §1; remove it when that PR merges.

**Session and lifecycle**
- Re-login keeps the old `displayName`, `siteName` and `timezone`
  (`reauthenticate` updates only the client ID and tokens) and never
  rebuilds the timestamp formatter; a renamed site keeps sending the old
  `X-Frappe-Site-Name` (App.swift:225-230, Session.swift:286-290). `[H]`
- `reauthenticate` drops the socket but leaves `realtimeLive` true, so the
  status shows live and polling waits up to a minute (Session.swift:286-294).
  `[H]` Implemented in #186, which also clears it in `stop()`.
- `presenceUnavailable` is set for good by one 403/404 and cleared only by
  re-login (Session.swift:281); clear it on reconnect like `avatarFailures`.
  Implemented in #111: a reconnect clears it and a refusal retries once
  after five minutes. `[H]`
- A partly failed account removal leaves a stopped session; signing in again
  says "Account removal is still in progress", which never resolves until
  relaunch (App.swift:226-228, 335-349). `[H]`
- One failing `track_visit` aborts the remaining visits and marks the
  account failed; per-operation send failures also raise account attention
  (Session.swift:696-714). Only session-level errors should call `fail()`.
  The store half, dropping a withdrawn channel's queued receipt, is #177;
  the Session half is implemented in #186. `[H]`
- `markUnread` polls `flushing` every 25 ms without a bound
  (Session.swift:735); behind a large upload it hangs with no feedback.
  `[H]`
- `sendGIF` lacks `send`'s re-entrancy guard; a double confirmation posts the
  GIF twice (Session.swift:538-546). #54 (NM-01) reworks uncertain GIF
  retries; build on it. `[H]`
- `ensureRealtime()` reads the Keychain synchronously on the main actor on
  every reconcile pass and socket error (Session.swift:388). `[H]`
- `messageDocument(for:)` clears the whole document cache whenever asked for
  a deleted message, which a lingering deleted row does on every render
  (Session.swift:215-221); the sets' `didSet` already invalidates.
  Implemented in #110. The recording-time whole-cache clear remains; see
  the scoped-eviction note in §4.3. `[H]`
- A cancelled caller drops freshly granted OAuth tokens
  (RavenClient.swift:349-356); the socket keeps a dead bearer token across
  reconnects (RavenRealtime.swift:44-50). `[P]`
- `RavenClient` never invalidates its ephemeral `URLSession` (created at
  RavenClient.swift:32, used at :259, :266), unlike `GIFSearch` (:318) and
  `ReleaseCheck` (:85) — one leaked session per re-login or account removal.
  Invalidate in `deinit` and in `invalidate()`/`revoke()`, guarding the
  shared-session test path with an ownership flag. (2026-11-18 pass) `[V]`
- Sign-in rejects loopback HTTP and subpath installs: `Onboarding.swift:88,126`
  use `SiteOrigin.normalize` with `allowLocalHTTP: false` although the error
  text promises local development and the perf harness accepts loopback.
  (2026-11-18 pass) `[V]`
- One revoked channel purges thumbnails and decoded GIFs for ALL channels:
  `Session.swift:437,595` run `thumbnails.removeAll()` and
  `forgetAnimatedImages()` on any revocation, causing a re-download storm for
  unrelated conversations. Scope eviction to the withdrawn channels' message
  IDs. (2026-11-18 pass) `[V]`
- A notification click at cold launch can be dropped before channels load:
  `App.swift:381-392` resolves the response while `Session.start` populates
  channels after async store reads. Retain and replay the response once
  channels are ready; also call `NSApp.activate` like the update path.
  (2026-11-18 pass) `[H]` Implemented in #170.
- `forgetAnimatedImages()`/`stop()` leave `animatedRequests` and
  `thumbnailRequests` populated, blocking retries for up to the 300 s timeout
  (Session.swift:136,143,998,1121). Clear them. (2026-11-18 pass) `[H]`
- Adding an account silently reuses the last window (`App.swift:245`
  `windows.last?.use(session)`). (2026-11-18 pass) `[P]`
- Implemented in #93: a refresh that restored access to an open
  conversation never re-sent its `doc_subscribe` room, so it stayed silent
  while the status said Live; a non-array presence reply cleared every
  presence dot (Session.swift:412, :430).
- Signing in to an additional account calls `windows.last?.use(session)`
  (App.swift:245): the most recently created window switches accounts and
  loses its history, not the one in front. Use the frontmost conversation
  window or open a new one; owner call (§11). `[H]`
- `notificationChannels` stops accepting channels at 10 per reconciliation
  pass (Session.swift:497); an eleventh conversation with a message in the
  same burst is never notified. Carry the overflow into the next pass.
  `[H]`
- `deliverNotification` reads only the newest row (`limit: 1`,
  Session.swift:1145) and skips when it is the reader's own, so a reply
  sent from the phone in between swallows the incoming notification. Read
  a few rows and take the newest one not by the reader. `[H]`
- `flush()` maps `unauthorized` to the terminal `.rejected` state
  (Session.swift:825); a send in flight while the reader signs in again
  needs a manual retry. Treat it as retryable during reauthentication.
  `[H]`

**Demo and app shell**
- Demo: Mark as Unread and Receive a Reaction on a pending send put the demo
  into a lasting error state (Session.swift:730-739, DemoWire.swift:365).
  `[H]`
- A demo seeding failure leaves the app running with no window
  (App.swift:450). `[H]`
- `DemoWire` holds its session `unowned` while delayed tasks outlive it
  (DemoWire.swift:37). `[P]`
- Help ▸ Raven Documentation opens the GitHub repository root
  (App.swift:373). `[H]`
- `showError` puts the whole text in the alert title when there is no early
  sentence break (App.swift:280-287). `[H]`
- Account removal says "N queued sends" for rejected and needs-review
  rows, and "1 queued sends" (App.swift:290-292). `[H]` Implemented in
  #86 as "N unsent messages" with a singular.
- The first background update offer triggers the notification permission
  prompt out of context (AppUpdateController.swift:105-118). `[H]`
- The update panel is sized once; a longer status line clips its controls
  (AppUpdateController.swift:86-94). `[H]` Implemented in #87:
  `UpdateMonitor.check` no longer joins a cancelled request after
  stop/start (UpdateMonitor.swift:65-83).
- The menu bar item's "Check for Updates…" title never becomes "Update
  Available…" (NativeShell.swift:48, 58). `[H]`
- Turning on notifications swallows a denied permission: the checkbox stays
  on and nothing arrives (Onboarding.swift:424-426). Show the state and a
  button to open System Settings.
- Cancelling browser sign-in shows the raw framework error
  (Onboarding.swift:140); starting a second sign-in silently ends the first
  (App.swift:272). `[H]`

**Transcript and composer**
- VoiceOver message actions use the text caret, not the rotor position, so
  Reply can act on another message (TranscriptAccessibility.swift:127). `[P]`
- Next/Previous Message clears `isFollowing` without refreshing the Jump to
  Latest button (TranscriptAccessibility.swift:185). `[H]`
- File drops are refused without feedback while editing a message; the paste
  path explains why (ConversationNativeWindow.swift:40-44). `[H]`
- Typing while the transcript has focus moves the composer caret to the end
  on every keystroke (ConversationShell.swift:449-452). `[H]`
- Markdown-mode list and quote commands put one marker before a multi-line
  selection (MarkdownSourceFormatting.swift:36). `[H]`
- Edit ▸ Undo does not reach Markdown-mode snapshots; only ⌘Z does
  (InlineComposer.swift:97). `[P]`
- Escape in a table cell discards the whole table edit
  (TableEditorSheet.swift:74); the table sheet is not resizable. `[H]`
- Paste and Match Style skips link detection (ComposerClipboard.swift:48);
  Insert Link does not prefill an existing link's URL. `[H]`
- Implemented in #90: `www.example.com` did not auto-link in the composer,
  only `http(s)://` (LinkDetection.swift:104-113).
- One send landing removes Undo Send for every other pending send
  (`removeAllActions(withTarget: self)`, InkController.swift:303, 505). `[H]`
- In Markdown mode the ink animation and take-back read the hidden visual
  composer, which still holds the pre-switch draft (InkController.swift:168).
  `[H]`
- A rejected reaction toggle leaves the chip's emoji veiled
  (Stickers.swift:603, 487-490); custom-emoji chips cannot be toggled by
  clicking (Stickers.swift:588). `[H]`
- `PressTracking.next()` dequeues and drops every key except Escape during a
  sticker drag (Stickers.swift:902). `[H]`
- A failed "Load More" in the emoji picker erases the loaded list
  (EmojiPickerSheet.swift:132). `[H]` Implemented in #142 (merged; #134
  covered the same fix concurrently): a page failure keeps the loaded rows
  and the failed offset so Load More retries that page, with a demo fixture
  and self-check.
- Implemented in #79: `insertRow(at: 0)` on a table with a header added a
  second header row (EditableRichTable.swift:57-70). Any inserted row now
  uses body cells. The top-inserted row still lands inside `<thead>`; that
  placement is pinned and documented.
- Implemented in #106: Escape during IME composition went to the
  composer's `onEscape` (cancelling a reply or edit) instead of the input
  method (ConversationWindow.swift:196).
- Implemented in #85: the "Linked document" line had no `.font`, so it drew
  in Helvetica 12; the fallback note and the unread divider were fixed at
  11 pt; code headers said "1 lines" (CodePresentation.swift:55, :106).
  #75 covers the linked-document and unread lines too.
- Implemented in #83: Open Code Reader's menu validation parsed the
  selected message with SwiftSoup on every validation, including each ⌘R
  key-equivalent lookup (ConversationWindow.swift:2142).
- A re-render restores the transcript selection by raw offset
  (ConversationWindow.swift:1235-1238), while scrolling is re-anchored by
  message ID. After Load Earlier prepends messages, or a message above is
  deleted, the caret lands in another message and the Message menu acts on
  it. Remember the selected message's ID and offset within it and restore
  into its new range, or clear it when the message is gone. Check: select a
  message, prepend 20 older ones, `selectedMessage` keeps its ID.
  The caret case is fixed in #145; a non-empty selection still restores by
  raw offset, so extending the same anchoring to a range is the remaining
  work.
- The thread inspector cannot page back: it renders cached replies and
  `start()` loads the newest page only (ThreadInspector.swift:83, :95).
  Reuse the main pane's load-earlier pattern. Implemented in #178 with an
  explicit Load Earlier control.
- The thread inspector's root header (author and text) is built once in
  `loadView()` (ThreadInspector.swift:47-49) and stays stale after an edit
  to the root or a rename; rebuild it in `render()`.
  Implemented in #178.
- Take-back loses Markdown mode: `SendOperation` does not keep the
  accepted draft's `editorState`, so `takeBack` restores HTML and caret
  only (Store.swift:432) and `inlineComposer.load(nil)` switches to Visual.
  Persist the editor state on acceptance. Distinct from the InkController
  entry above. `[H]`
- In Markdown mode the mention popover is not refreshed on caret moves
  (only the visual composer's `textViewDidChangeSelection` calls
  `updateCompletions()`), so after moving away from "@al" Return is
  swallowed by a stale popover (MentionPopover.swift:62). `[H]`
- An Escape-dismissed mention list reopens on the next letter, because
  `dismissed` stores the whole query (MentionPopover.swift:63). Comparing by
  trigger position would keep it closed until the trigger is retyped;
  product call. `[H]`
- Markdown table export on `main` escapes a cell's `|` twice (inline
  escaping, then `&#124;`; RavenMarkdown.swift:166). #47's readable
  candidate does not backslash-escape `|` and every export is verified by
  round trip. Verify the current output with a literal cell pipe before changing it. `[H]`
- Formatting, link and mention commands corrupt a draft inside a code block:
  inside `pre` the encoder emits markup that `RichTextCodec` then reads as
  read-only, making the draft unsendable until undone
  (ComposerFormatting.swift:133-154,34-42; ComposerExtraFormatting.swift:5-33,118-146;
  ComposerLinks.swift:248-255; ConversationWindow.swift:1542-1549;
  ConversationActions.swift:336-347). Add one shared code-context guard.
  (2026-11-18 pass) `[V]`
- The visual composer accepts arbitrarily large pastes
  (ConversationWindow.swift:207-214) with no check against
  `RichTextCodec.maximumBytes`, unlike the Markdown paste paths.
  (2026-11-18 pass) `[V]`
- "Schedule Message" accepts a marker-only draft: `ConversationActions.swift:115-116`
  uses `string.isEmpty` where `send` uses `hasText` (:1670).
  (2026-11-18 pass) `[V]`
- Caret moves in Markdown mode never refresh mention suggestions:
  `textViewDidChangeSelection` (ConversationWindow.swift:1529-1531) only
  handles the visual composer. (2026-11-18 pass) `[V]`
- Format-menu caret-only formatting leaves the toolbar stale:
  `ComposerCommandRouting.swift:12-16` never calls `updateSelection`.
  (2026-11-18 pass) `[V]`
- Insert Link in Markdown mode inserts a placeholder URL
  (ConversationActions.swift:320-321, MarkdownSourceFormatting.swift:40).
  (2026-11-18 pass) `[V]`
- Escape during IME marked text cancels reply/edit, and trait commands can
  replace marked text (ConversationWindow.swift:192-205,
  ComposerFormatting.swift:133-154,34-42 lack `hasMarkedText()` guards).
  (2026-11-18 pass) `[H]`
- U+2029 splits paragraphs for NSString but not for the composer's structure
  rules (ComposerStructure.swift:96-100 vs MarkdownShortcut.swift:47-53).
  (2026-11-18 pass) `[V]`
- "Load Earlier" from the bottom can drop the last 100 rows and move the
  reader up (ConversationWindow.swift:1719,1048-1049,1108,1257).
  (2026-11-18 pass) `[H]`
- An evicted `historyUpperID` cursor falls back to the newest page
  (ConversationWindow.swift:1048,1097-1108). (2026-11-18 pass) `[P]`
- Custom emoji in message bodies render as `:name:` text instead of images:
  the renderer skips `data-type="customEmoji"` nodes
  (RichTextAdapter.swift:364-365). Extend `InlineImagePresentation.embed` to
  custom-emoji img nodes with the existing bounded path — parity with Raven
  web. (2026-11-18 pass) `[V]`

**Sidebar, windows and collections**
- "Add Members…" throws "Too many choices" above 500 users and has no search
  (ChannelManagement.swift:62-65); Forward silently stops at 500
  conversations (ConversationActions.swift:8). The searchable roster sheet
  in #50 (NM-12) is a model for the picker. `[H]`
- Implemented in #89: right-clicking a sidebar header, empty sidebar space
  or the Home row showed an empty menu (ConversationShell.swift:888-891).
- Implemented in #94: the hidden muted bell kept its width, truncating
  unmuted titles early (ConversationShell.swift:114-128).
- Implemented in #101: the attachment chip was one accessibility element, so
  VoiceOver could not reach Remove (ConversationShell.swift:329-331). `[H]`
- The File panel and the attachment window observe `.sessionChanged` with
  `object: nil`, so activity in any account closes a file panel that
  belongs to another account (FileInspector.swift:135,
  AttachmentWindow.swift:71). Scope the observer to the panel's own
  session. `[V]`
- The lit raven (mention waiting) is missing from the row's VoiceOver label
  (ConversationShell.swift:200-206). `[H]`
- Implemented in #84, and independently in #82: Escape in a collection's
  filter field closed the window instead of clearing the filter
  (CollectionWindow.swift:123-125). #82 also clears an active field editor
  and covers results focus.
- "Delete Reminder" deletes without confirmation while "Cancel Scheduled
  Message" confirms (CollectionWindow.swift:317-326). `[H]` The Opus review
  found it is chosen in a sheet and confirmed with Continue, so it already
  takes two steps; a further alert adds friction. Leave it unless readers
  report accidents.
- Two promised-file failures without URLs collapse into one callback and the
  receive waits for its timeout (PromisedFileReceiver.swift:243). `[H]`
- `PromisedFileReceiver.Collector.record` can trap when the byte sum reaches
  `Int.max` (PromisedFileReceiver.swift:243); clamp the sum. (2026-11-18 pass) `[H]`
- "Who Has Read This?" lists every reader without a cap
  (ConversationActions.swift:22-28). `[H]`
- The collection toolbar's Refresh item is re-parented into the
  customization palette (CollectionWindow.swift:187-196); fix like the search
  item's `flag ? search : NSSearchField()`. (2026-11-18 pass) `[H]`
- The attachment actions window shows a disabled Reveal/Open-With row before
  anything is saved (AttachmentWindow.swift:60-66 vs FileInspector.swift:108,210-212);
  hide it until `savedURL` is set. (2026-11-18 pass) `[V]`
- `ChannelDetails.rows` checks `deletedIDs` as the revoked set
  (ChannelDetails.swift:20-21). (2026-11-18 pass) `[H]`
- Retracting an already-gone vote reports "completed"
  (PollWindow.swift:595-603,526). (2026-11-18 pass) `[V]`
- #78 added Try Again to a failed File download; re-clicking the same
  attachment in the File panel still never retries
  (ConversationWindow.swift:2056-2062, FileInspector.swift:181-188,207-214) —
  restart the download when the inspector is in the failure state.
  (2026-11-18 pass) `[V]`
- A Quick Look window can outlive the deletion of its message:
  `ConversationWindow.swift:2026-2036` omits `messageID` from
  `attachmentActivity`. (2026-11-18 pass) `[H]`
- `AttachmentWindow.saveCopy`'s pre-guard defeats the documented save-panel
  fallback (AttachmentWindow.swift:129 vs AttachmentExport.swift:13-17).
  (2026-11-18 pass) `[H]`

**Home and Search**
- A failed Search tab currently requires Return to retry. Add a visible Retry
  action to the failed tab's empty state and footer, preserving criteria and
  selection. Verify that switching tabs does not retry silently, and that
  retrying a failed tab keeps the other tab's results visible.
- Implemented in #77: file results showed the name twice when it had
  percent escapes (SearchResults.swift:272). Local snippets still stop at
  400 words (SearchResults.swift:181). `[H]` The whole indexed body is
  searched in #176.
- Home's Mark All Read skips conversations whose latest message is unknown
  (HomeView.swift:683); the Later card can show stale drafts after
  `.draftChanged` (HomeView.swift:102). `[H]` The confirmation now counts
  only the actionable entries and reports the remainder in #146; the
  cached-latest fallback already existed. The Later staleness remains.
- Implemented in #86: Home's people module was titled "You Talk with Most"
  (HomeDigest.swift:14); Your Week said "11 more than the week before"
  after an empty week (HomeView.swift:479).
- The Search footer labels a good tab "matches saved on this Mac" when another
  tab's request failed (SearchFeed.swift:301-302, SearchView.swift:738-741,771);
  track per-tab provenance. (2026-11-18 pass) `[V]`
- The Saved Searches menu reads only the key window (SearchNavigation.swift:183-184)
  and shows "No Saved Searches" over collection windows; fall back to the
  active conversation window. (2026-11-18 pass) `[V]`
- Refresh Home silently no-ops while a refresh is in flight
  (HomeFeed.swift:69-71); chain after the in-flight task or disable the item.
  (2026-11-18 pass) `[V]`

**Core and protocol**
- Implemented in #91: `.resourceLimit` always said "64 MB per attachment",
  also for 8 MB RPC bodies, 32 MB images and 4 MB avatars
  (Errors.swift:101-102). `[H]`
- Implemented in #92, and independently in #80:
  `ChannelPolicy.isArchived` failed open on cyclic ancestry while
  `isRevoked` failed closed (ChannelPolicy.swift:11-23). `[H]` #80 walks
  acyclic chains to their end instead of treating depth past eight as
  corruption.
- Store permission hardening uses `try?` (Store.swift:159, 181) while staging
  uses `try`; the staging-budget error names the global budget, not the
  limit that applied (Store.swift:640-650). `[H]`
- `removeRevokedChannels` and `withdrawHistory` clear every cached projection,
  not just the revoked channels', so one private revocation drops the
  Saved/Threads/Files snapshots account-wide (`Store.swift`). Scope the
  delete to the withdrawn keys or document the conservative purge. `[V]`
- `ChannelPolicy.isRevoked` resolves parents only through `threadParents`,
  while `isArchived` also follows `RavenChannel.raw["parent_channel_id"]`;
  a revoked ancestor reachable only through the raw edge is missed. Unify
  one ancestry walk, decide whether corrupt ancestry needs its own message
  instead of "archived" in `requireWritableConversation`, and confirm the
  pinned server controller's walk matches the now uncapped client walk. Also
  confirm no deployment writes a self-referential `parent_channel_id` as a
  no-parent sentinel: a cycle now blocks both archive and revocation checks.
  `[H]`

**Themes**
- The theme editor's list rows overflow its fixed 640 pt pane
  (ThemeEditor.swift:50); the ornament Position popup does nothing for
  scanlines and aurora (ThemeEditor.swift:480); an encode failure wipes
  all saved customizations (ThemeManager.swift:260). `[H]` Implemented in
  #103: rapid theme switching stacked celebration overlays
  (ThemeCelebration.swift:24-37).
- The theme editor snapshots whole preset lists on first edit
  (ThemeEditor.swift:84-94), breaking "left-alone fields follow preset
  updates" (ThemeCustomization.swift:3-5). (2026-11-18 pass) `[H]`

**2026-11-20 pass.** Read in the current code; each entry says what to
change and how to know it worked.

- **`deliverNotification` swallows an incoming message** `[V]` (N4).
  `Session.deliverNotification` reads `limit: 1` and gives up unless the
  newest row is from someone else. A message the reader sent from the
  phone after the incoming one makes the newest row the reader's own, and
  the notification is dropped forever. Read a small page and take the
  newest row not authored by the reader, then apply the existing batch
  dedupe. A stub `get_messages` whose newest row is the reader and whose
  second-newest is a teammate must still deliver one notification.
  Implemented in #155 (merged): reads a named 5-row page and picks via
  `NotificationPolicy.nextNotification(in:user:seen:notified:)`, which
  filters delivered and already-seen rows before choosing the newest
  foreign one.
- **`notificationChannels` drops the 11th conversation in a burst** `[V]`
  (N5). `AccountSession.event` only inserts when `notificationChannels.count
  < 10`; the set drains once per reconciliation pass and events debounce by
  350 ms, so an 11th conversation in the same burst is never queued and the
  server will not re-emit. Carry the overflow into the next pass, or drop
  the cap and let the drain bound the work.
- **Home's Mark All Read skips a conversation without a latest message**
  `[V]` (N8). `HomeView.markAllRead` does `guard let timestamp =
  entry.latest?.timestamp else { continue }`, so a conversation counted in
  the confirmation is not marked and the reader gets no feedback. Fall back
  to the newest cached message and report any difference between the
  confirmed and acted-on counts. Addressed in #146: the cached-latest
  fallback was already passed into the digest, and the sheet now counts
  `digest.actionable` and states how many have no readable newest message.
- **A failed Home refresh overwrites the last good module data** `[V]`.
  `HomeFeed.refresh` assigns `snapshot.reminders = results.0` even when
  `results.0` is `.failed`, so one failed refresh replaces the previous
  loaded list with an error. Consider keeping the last loaded value and
  showing a per-module failure beside it, as the File panel does for
  offline collections (#71's pattern).
- **`OutboxWindow` Return can trigger Retry and the table action** `[P]`.
  `retryButton.keyEquivalent = "\r"` while the table is first responder;
  confirm a selected row does not activate both.
- **Thread fetch failures can disappear under a cache render** `[V]`.
  The initial fetch and the cache render write the same status label.
  Give them separate state and a Retry action, following the File
  inspector's pattern. In the loopback fixture, fail a thread's first
  page with cached replies present, post an unrelated session change and
  retry successfully. Also test an empty cache and withdrawal of parent
  membership during the retry. [ThreadInspector.swift](Sources/NevermoreApp/ThreadInspector.swift#L69)
- **Account Preferences can overwrite edits typed during Save** `[V]`.
  The response and the recovery readback both repopulate editable server
  fields. Hold a Raven User mutation in the fixture, try to edit while it
  waits, and check success, failure and close/reopen during cancellation.
  Disable the submitted fields until reconciliation or preserve post-Save
  edits independently. The local quiet-hours save finishes before the
  request starts. Check keyboard focus and whether a further local change
  remains visible as unsaved. [AccountPreferencesController.swift](Sources/NevermoreApp/AccountPreferencesController.swift#L311)

**2026-11-23 pass.** Read in the current code; each entry says what to
change and how to know it worked.

- **`markUnread` has no demo path** `[V]`. `Session.markUnread` always calls
  `client.rpc("raven.api.raven_channel_member.mark_channel_as_unread")` and
  then `refresh()`. In `--demo` (origin `https://demo.invalid`) that is a
  real network attempt that fails with a transport error and an alert,
  breaking the demo's local-only contract. Add a demo branch that updates
  `intentionallyUnread`, `lastSeen`, the transcript visit and the store,
  then returns.
- **Overlapping `refresh()` calls can resurrect a revoked channel** `[H]`.
  Refresh A reads a channel list containing C, refresh B reads a later list
  without C and adds it to `revokedChannels`, then A subtracts its own list
  and restores C. Chain refreshes through one writer, as `writeHistory`
  does, or publish only from the newest generation. A `readRPC` fixture can
  hold the first response and assert the final `channels` and
  `revokedChannels` after a second refresh.
- **A rejected room join is remembered as joined** `[H]`.
  `RavenRealtime.setChannels` updates `joined` when `doc_subscribe` is
  emitted, with no acknowledgement. A silently rejected join leaves `added`
  empty, so the open conversation is never re-subscribed until the socket
  reconnects, even though `reconciliationTick` treats a silent live socket
  as possible. Confirm with a Socket.IO ack, or re-emit the desired set on
  the reconciliation tick.
- **The 8 MB default RPC budget silently truncates large directory reads**
  `[H]`. `Session.refresh` reads `raven.api.raven_users.get_list` with
  `try?`; a larger reply throws and the directory stays empty, so DM titles
  fall back to raw user IDs and avatars never load, with no visible failure.
  Give `rpc` a per-call budget for the large directory and history reads and
  surface the failure rather than swallowing it.
- **`HomeFeed.refreshAfterInflight` returns the wrong task** `[V]`. It
  returns the task captured before `refresh(force:)`, so a caller with no
  in-flight refresh gets nil and reads Home before the new feed lands; with
  one in flight it returns the old task rather than the replacement. Return
  `self.task` after starting the refresh.
- **A failed `get_unread_threads` clears every thread unread badge** `[V]`.
  `snapshot.unreadThreads` is rebuilt from `results.3.value ?? []`, so a
  failed module leaves an empty dictionary and Home shows no thread counts
  until the next success. Assign only on `.loaded`, as the other modules do.
- **`loadCachedLatest` never retries a conversation it found empty** `[V]`.
  `latestKeys` is updated for every stale id even when no cached message was
  found, so opening the conversation later does not fill in the preview.
  Record the key only for ids present in `found`.
- **A forced Home refresh is dropped while one is in flight** `[V]`. The
  `task == nil` guard in `refresh` returns without recording the request, so
  a mutation during a refresh can leave Home showing pre-mutation state for
  up to the freshness window. Record a pending forced refresh and consume it
  when the in-flight task finishes.
- **A Files or Links search kind survives a switch to Conversations or
  People** `[V]`. `tabChanged` only applied `criteria.on(next)` for the
  server-backed tabs, so the leftover kind leaked into the Filters menu and
  a saved search. Fixed in #153 by applying the mapping for every tab.
- **Local search tabs keep filters, and the new check does not pin it**
  `[H]`. `SearchCriteria.on(_:)` normalizes only the kind for Conversations
  and People; author, date and attribute filters survive. That keeps a
  filtered Messages search intact across a local-tab detour, but the Filters
  menu and a saved search on a local tab still show them, and the self-check's
  `!hasFilters` assertion is vacuous because no filter is set. Decide the
  intended semantics, correct the "clean slate" comment, and apply a real
  filter in the check so the assertion can fail.

**2026-11-23 independent pass.** Each entry says where the issue lives and
how to check the fix; entries with a PR name it.

- **A withdrawn channel's queued read receipt is retried forever** `[V]`
  (store half in #177). `removeRevokedChannels` and `withdrawHistory` delete
  the channel's history but not its `visits` row, so every flush sends a
  `track_visit` the server refuses. The visit loop shares the flush's outer
  `do/catch`, so that refusal also skips receipts queued after it and calls
  `fail` for a per-conversation problem. Session half: give each visit its
  own `do/catch`; drop a receipt on a permanent refusal and keep a transient
  one for the next flush.
- **HTTP 409 is described as "the site is busy right now"** `[V]`.
  `RavenError`'s description groups 409 with 429 (`Errors.swift`), although
  409 is a conflict, not throttling, and `isPermanent` already treats it as
  retryable. Give 409 its own "refresh and try again" wording and assert
  both descriptions in `AuthTests`.
- **Search result rows never pick up a photo or presence** `[V]`. The
  `.sessionAvatarsChanged` observer runs the `.sessionChanged` body, whose
  `feed.restrict()` gate returns false for an avatar arrival, so cells keep
  the generated raven until the query reruns; `.sessionPresenceChanged` is
  not observed at all (`SearchView.swift`, observer list). Reload on both
  when visible and keep `restrict()` only for access changes. Check: post
  the notification and assert a row's image changes without a new query.
- **`SearchView.reset` keeps the previous account's `selectionKey`** `[H]`.
  A same-key row in the new account is treated as unchanged, skipping the
  attachment and preview reset. Clear it in `reset` and test the switch.
- **`SearchFeed.restrict()` leaves the footer counters stale** `[H]`. Only
  the three `.loaded` arrays are filtered; `serverHits`, `cacheOnly` and
  `indexErrors` survive a revocation, so the footer can claim the best 100
  matches for a smaller set. Recompute them with the filtered results and
  check the footer after a revocation.
- **Staging files orphaned by a crash are never reclaimed** `[V]`.
  `stage(file:)` creates the file before inserting its `staging` row, so a
  process death between the two leaves a file that `pruneStaging` never sees
  and the budget never counts. At store open, delete files under `staging/`
  whose path is absent from the table (match `path`; the file's own UUID
  name is not the row id). Check: write an orphan, reopen, assert it is gone
  and the budget is free.
- **Home keeps the previous account's content after an account switch**
  `[V]` (implemented in #180). Home's observers filter on the current
  session and `use(_:)` posted nothing, so the pane showed the old account's
  reminders and drafts until the next reconciliation.
- **A token-endpoint `server_error` rejects a queued message** `[V]`
  (implemented in #175). RFC 6749 defines it as a transient authorization
  server condition; the outbox treated it as permanent and parked the send
  as rejected.

**2026-11-23 epic-chicken pass.** New findings from the 23 November sweep
on `d86965c` (see §1 for its PRs); entries marked implemented have an open PR.

- **`reauthenticate` leaves `realtimeLive` true** `[V]`. `Session.swift`
  drops the socket with `realtime?.disconnect()`, which removes all
  handlers so no "disconnect" event fires and `realtimeLive` stays true;
  the status line shows Live with no socket and the 60 s live-refresh gate
  is skipped. Set `realtimeLive = false` when dropping the socket.
  Implemented in #186, which also clears it in `stop()`.
- **`stop()`/`forgetAnimatedImages()` leave request sets populated** `[H]`.
  `animatedRequests` and `thumbnailRequests` are not cleared
  (Session.swift), so a stopped session still blocks retries for up to the
  300 s timeout. Clear both sets in both paths.
- **Loading older history can evict the live edge from memory** `[P]`.
  `memoryMessages[channelID] = olderThan == nil ? suffix(1500) :
  prefix(1500)` keeps the *oldest* 1,500 rows when paging deeper than
  1,500 messages, so the newest rows vanish from the cache and the rendered
  transcript until the next socket load. One eviction rule instead: keep
  the reader's span plus the newest page. Check: seed 1,600 rows, load
  older, assert the newest id is still cached.
- **A sustained realtime burst can starve notification delivery** `[H]`.
  The reconciliation worker drains `notificationChannels` only after the
  `while reconcileRequested` loop exits, but every socket event re-arms the
  loop; combined with the N5 cap, later conversations are dropped
  permanently. Drain pending notifications before re-looping, or deliver
  from a separate task with a deadline.
- **Pending read watermarks answered `false` are replayed forever** `[P]`.
  The pinned `track_visit` documents `False` as "queue and replay after
  maintenance"; the client re-POSTs each row on every foreground pass with
  no backoff while `readOnly`. Keep the row but rate-limit replay.
- **A cancelled caller drops a freshly granted OAuth token** `[P]`
  (RavenClient.swift). After the single-flight grant answers,
  `!Task.isCancelled` discards the fresh token without persisting; if the
  server rotated the refresh token, the next call fails `invalid_grant` and
  the reader is signed out. Persist before the cancellation check.
- **File panel / attachment window observe `.sessionChanged` with
  `object: nil`** `[V]` (low). FileInspector.swift:141,
  AttachmentWindow.swift:71. The handler only closes when the panel's own
  `active()` is false, so another account's activity is a no-op; scoping
  the observer would need the session plumbed into both inits.
- **Thread replies never raised notifications** `[V]` — implemented in
  #158 (merged): threads are synthesized locally and never listed in
  `channels`, so the gate now resolves the parent via the tested
  `ChannelPolicy.shouldNotify` (whole-ancestry revocation, top-most
  ancestor row).
- **Saved Searches menu reads only the key window** `[V]` — implemented in
  #135 (merged, `vibe/saved-search-menu`): over a collection window the
  menu shows "No Saved Searches" although the account has some
  (SearchNavigation.swift:183-184). Fall back to
  `AppDelegate.activeConversationWindow`'s session.
- **Roster search filters run during IME marked text** `[V]` — open (another
  agent's `fix/roster-ime-guard` covers it): MemberRosterWindow.swift:174-177
  lacks the `hasMarkedText()` guard the newer pickers have.
- **Retracting an already-gone vote reports "completed"** `[V]` — open
  (another agent's `vibe/poll-retract-no-vote` covers it):
  PollWindow.swift:601-603 returns silently, then `performMutation` says
  "Retracting vote completed." Throw a dedicated error instead.
- **`deliverNotification` bypasses the read seam** `[H]`
  (2026-11-23 epic-chicken task pass). `Session.deliverNotification` calls
  `client.rpc` directly instead of `read(_:)`, so a `readRPC` fixture cannot
  drive the notification path. Route it through `read` before adding the
  N4 fixture.
- **`message_deleted` durability is fire-and-forget** `[V]`
  (2026-11-23 epic-chicken task pass). `Session.event` spawns
  `Task { try? await store.deleteMessages(ids:) }` without awaiting it;
  quitting in that window loses the durable deletion and the next launch
  shows the row until a refresh reconciles it. Record the deletion before
  spawning the task, or await it during the stop drain.

### 3.6 NM-10 · Verify badge freshness through a partial outage and membership change

On the reviewed baseline an unread-count failure replaced a populated snapshot with a null value. Losing both attention sources could also remove the attention dot. The implementation on `main` retains earlier counts. Exercise the combination of an offline attention source and changed membership before deciding whether the remaining gap needs UI.

Hold both attention reads offline while refreshing the permitted channels. Inspect Home, the Dock, and both windows before and after a genuine empty response. Add a freshness indicator only if a reader could still mistake stale counts for an up-to-date empty inbox.

The review of #38 raised the same gap from the code side: the kept values have no staleness bound (Session.swift around :368). If a freshness indicator is needed, mark the badges as possibly stale after repeated failures.

### 3.7 NM-21 · Refresh the span the reader is looking at after reconnect

Reconciliation reloads the latest page of every open conversation. A window parked on older history may therefore miss an edit or deletion in its visible span during the disconnect. The pinned newer-history endpoint can include the cursor row and can run without updating last visit. [Current reconciliation](Sources/NevermoreApp/Session.swift#L420-L452) · [Pinned stream contract](docs/RAVEN-RESEARCH.md#4-api-contract-inventory)

**Acceptance.** On reconnect, separately request the authorized historical spans currently displayed, with bounded coalescing per account/channel. Confirm anchor and coverage before reconciling deletions. Inject an edit and a deletion outside the latest page, including a deleted cursor and a complete boundary batch. Preserve view position and do not send a visit. Compare behavior with a second window already at the live edge.

The cache-invalidation change is on main. Run the older-span fixture against it. Overlapping history responses and deleted cursors need reliable authority and coverage boundaries.

### 3.8 NM-Q1 · Exercise two-account reconnect and revocation in the same open window session

`AccountSession.reconciliationTick` covers silent connections and explicit disconnects. Unit fixtures and the feature inventory do not establish behavior across a real proxy after wake. Use two synthetic accounts with the same channel IDs. Open a private thread, drop one connection, revoke access on that account, and wake and reconnect. Verify inaccessible rows disappear from search, previews and restored windows, retained drafts stay recoverable, queued messages require review, and the other account keeps its state. Record deployed Raven/Frappe versions, expected transition, and observed result before changing policy.

### 3.9 NM-A1 · Verify spoiler drawing under the current SDK

The current macOS 26-targeted Release build on Swift 6.4.2 warns that the nonisolated `drawGlyphs(forGlyphRange:at:)` reads the main-actor-isolated `veiled` array. Determine which AppKit layout paths execute that override when drawing, printing and copying. Exercise a masked spoiler during background layout and reveal/hide changes. Keep the mask correct and selectable text behavior intact. Choose the state-ownership change after establishing the execution contract; suppressing the warning would leave that question open.

---

## 4. Performance and stutter

### 4.1 NM-08 · Every `sessionChanged` rebuilds every open transcript `[V]`
- **Where:** the window's `sessionChanged` observer calls `refreshSidebar()`,
  `updateContext()`, `updateCompletions()` and `render()`
  (ConversationWindow.swift:645). `render()` reads up to 5,000 rows and
  decodes them, re-reads all outbox operations, rebuilds the attributed
  string for up to 500 messages, replaces the storage, calls `ensureLayout`
  on the whole container (:895-1127) and rebuilds the accessibility rotor.
  A cached switch measured 37 ms p50 / 77 ms p95 in the 9 November signed
  Release run, and 60 ms p50 / 106 ms p95 on 17 November (95 and 92 ms p95
  in two shorter runs) against a 100 ms target (§13.1). Parsed documents
  are cached, but the history fetch and layout remain.
- **What posts it:** each realtime event posts once (Session.swift:414),
  then `requestReconciliation()` runs `refresh()` (boot, all channels,
  unread counts, notification IDs and, each minute, active users: four or
  five RPCs) and `load()` per open conversation (100 messages plus a
  5,000-row store read for the deletion diff), each ending in `notify()`
  (:379, :483). One incoming message means about three full renders per
  window, three sidebar reloads and a Home rebuild. Also avatars, link
  previews, deletions, thumbnail arrivals and timestamp-environment changes
  (locale, time zone, a new day). The reconciliation worker coalesces RPCs,
  and events still notify the UI one by one. Presence-only notifications
  already skip transcript rendering. Measure what remains with a third conversation's messages, read receipts
  and reactions.
- **Fixes, safest first:**
  1. `refresh()` and `load()` notify only when something changed: compare
     channels, unread, attention IDs and state; compare fetched rows,
     previews and visit with what is held.
  2. A render fingerprint: skip `render()` when message IDs and `modified`,
     operations, read position, metrics, expanded code and media presence
     are unchanged. Keep a "force" path for theme and metrics changes.
  3. Apply `message_created` and `message_edited` payloads directly: current
     Raven publishes the full message in `message_details`
     (raven_message.py:960-1005 at e2ae015), which its web client uses. Keep
     reconciliation as a slower check. Validate on the Raven 3.1 test site
     first.
  4. Append new tail messages to the storage instead of rebuilding it.
- **Check:** count `render()` calls per incoming message in a self-check
  with the demo wire (target: one); time `render()` with signposts.
- **Acceptance (walkthrough review):** count database reads, render
  publications and hitches with two open windows and traffic in a third
  conversation. If unrelated work dominates, target invalidations by
  conversation and presentation input. Preserve immediate access removal
  and required changes to selection, drafts, send feedback and read state.
  Replay the same workload and compare work, frame delivery, focus and
  viewport stability. This is also a source lead for the burst probes in
  NM-P1 (§4.7).
- **Links:** [Session dispatch](Sources/NevermoreApp/Session.swift#L395-L444) · [Window observer](Sources/NevermoreApp/ConversationWindow.swift#L645-L648) · [Render path](Sources/NevermoreApp/ConversationWindow.swift#L895-L1127)

### 4.2 Work that scales with scrolling and pointer movement `[H]`
- `seenVisible()` runs on every clip-bounds change, computes `rect(for:)` for
  every message and spawns a `markSeen` task each time
  (ConversationWindow.swift:1139-1157). Measured `[V]`: with 500 two-line
  messages the two scans (thumbnails, read receipt) cost 3.9 ms p50 and
  4.4 ms p95 per scroll event on an M4 Max, half a 120 Hz frame. The
  binary search is implemented in #97 (0.11 ms p50). Addressed in #184:
  one band scan feeds both consumers and `markSeen` runs only when the
  bottom visible message changes.
- Hover lookup scans every message range per mouse move
  (ConversationShell.swift:966-1008). Use `characterIndexForInsertion(at:)`
  once, then a binary search. Addressed in #184 with a direct binary search
  over layout order, also used by the caret highlight.
- `visibleAnchor` computes `rect(for:)` for every loaded message on every
  non-following render to find one anchor. Binary-search `messageRanges`
  against the old bounds, as `messageEntries(intersecting:)` does, and
  binary-search the nearest survivor for the no-intersection fallback.
  (2026-11-23 pass) `[H]`
- Raven gaze re-evaluates every visible sidebar row per mouse-moved
  (Unkindness.swift:111,156,332-343); throttle or coalesce. (2026-11-18 pass) `[H]`
- The sidebar's unread count is a linear scan per row, done twice
  (ConversationShell.swift:886,901-904); build a dictionary once per refresh.
  (2026-11-18 pass) `[V]`
- The GIF overlay re-places every view per scroll frame and forces full
  layout when layout is incomplete (AnimatedImages.swift:207-258); its cache
  `touch` is O(n) per lookup (:73). The viewport keeper queries layout per
  frame (TranscriptViewportKeeper.swift:78-86).

### 4.3 Other render-path costs `[H]`
- The first render parses up to 500 messages with SwiftSoup on the main
  actor (`messageDocument`, Session.swift:215). Prewarm the cache off the
  main actor after `cachedMessages`.
- `TranscriptAccessibility.refresh()` plain-texts every message on every
  render even with VoiceOver off (TranscriptAccessibility.swift:37-74).
  Build entries on first rotor or action access.
- The thread inspector and outbox window each redo their work on every
  `sessionChanged` (ThreadInspector.swift:62-96, OutboxWindow.swift:49-51,
  141-156). Evaluate whether they can observe conversation or outbox
  changes specifically. Keep immediate access and deletion handling.
- Any observed deletion or revocation still clears the whole document
  cache (Session.swift:68, 474); `MessageDocumentCache` evicts with an
  O(n) scan. #110 removed the per-lookup clear (§3.6), but the
  recording-time clear remains: scope eviction to the withdrawn message
  and channel IDs so one deletion does not re-parse every conversation.
- Drying a sent message draws two full-body bitmaps on the main thread
  (InkController.swift:569-571).
- Theme art rebuilds motif paths, including path booleans, for every drawn
  instance (ThemeArt.swift:55); the theme poster re-scatters the wallpaper
  per tile (ThemePoster.swift:140); theme colors allocate a new dynamic
  `NSColor` per access and `senderName` looks up its font per header
  (ThemeManager.swift:41, 100).

- `JSONValue.nested` re-decodes the JSON string on every access
  (`Models.swift`), and the transcript asks for `message_reactions` once per
  message per render, plus per sticker hit-test. Cache the parsed value per
  message, or precompute it beside the parsed document.
  (2026-11-23 independent pass) `[V]`
- `copyFullTranscript` and the context menu's code-reader item parse HTML
  directly instead of using the session's parsed-document cache that the
  render just filled (`ConversationWindow.swift` `plainBody(of:)`;
  `ConversationShell.swift` `codeMenuItems`). Copying a 500-message
  transcript therefore runs hundreds of SwiftSoup parses synchronously on
  the main thread. Use `session.messageDocument(for:)` and move any miss off
  the main actor. (2026-11-23 independent pass) `[V]`
- The day pill runs two `enumerateAttribute` passes per scroll frame
  (FloatingDayPill.swift:106,114). Cache the pill's paragraph range.
  (2026-11-23 epic-chicken pass) `[H]`
- Link-preview and image arrivals re-render every open window
  (SentLinkPreviews.swift:69). Scope the invalidation to windows showing
  the affected conversation. (2026-11-23 epic-chicken pass) `[H]`
- `TranscriptReadPosition` parses `creation` for up to 5,000 cached rows per
  render (TranscriptReadPosition.swift:46,70; `ServerTimestampParser.date`
  does two Calendar conversions each). Memoize `(id, creation) -> Date` per
  session. (2026-11-23 epic-chicken pass) `[H]`
- Unsent outbox rows render in anchor/history windows: pending sends are
  appended to every rendered slice, including an anchor window opened from
  search, so a queued send appears after rows far older than the newest
  cached one (ConversationWindow.swift:1208). Append only when the
  projection reaches the canonical tail. (2026-11-23 epic-chicken pass)
  `[H]`

#### Measure independent costs in a busy transcript `[P]`

Use this workload to attribute NM-08 and NM-P1. Seed grouped quotes,
spoilers, files, inline GIFs and an outbox with pending sends to unrelated
channels. Reply quotes perform a linear search through visible rows for
each reply. Compare a per-render ID index that preserves first-match
precedence, spoiler masking and pending-send treatment. Use [#123](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/123)
as the channel-scoped SQL variant. Exercise idle scroll, unrelated
realtime updates and continuous resize at the same initial window size
and position. Count text storage replacements, glyph layouts, animated
image callbacks and decoded payloads separately from missed compositor
frames. [Render inputs and reply lookup](Sources/NevermoreApp/ConversationWindow.swift#L1107) ·
[Performance harness](docs/implementation/PERFORMANCE-HARNESS.md)

### 4.4 Composer `[H]`
- Every keystroke encodes the whole draft to HTML and writes it to SQLite
  (ConversationWindow.swift:1244, Store.swift:255). Debounce the save
  (about 300 ms, flushed on send, switch and close).
- Markdown mode parses the source twice per keystroke and snapshots the whole
  draft into the undo stack per keystroke (ConversationShell.swift:753,
  InlineComposer.swift:189). Coalesce snapshots by typing pause.
- ~~Mention candidates rebuilt on every text and selection change~~ — fixed
  by #98: the pool is built only when `MentionCompletion.query` finds a
  trigger at the caret and cached behind session version counters. The
  remaining sort re-folds titles inside comparisons
  (MentionCompletion.swift:51-57). Implemented in #112: the folded title
  and rank are precomputed per candidate.
- Auto-link correction enumerates the whole draft per keystroke
  (ComposerLinks.swift:136).
- Markdown mode measures the whole source per keystroke:
  `ConversationShell.swift:750-759` runs `boundingRect` over up to ~1 MB per
  key. Debounce or measure a bounded range. (2026-11-18 pass) `[H]`

- The window that typed reloads its own draft after every keystroke: the
  `.draftChanged` observer calls `restoreDraft()` for every window showing
  the conversation, including the writer, which reads the draft back from
  SQLite and re-serializes the live composer to compare HTML
  (`ConversationWindow.swift`). Carry the saved HTML in the notification and
  skip the reload when `displayedHTML` already matches. (2026-11-23
  independent pass) `[V]`

### 4.5 Network and store `[H]`
- `load()` upserts all 100 fetched rows (FTS delete and insert, a SwiftSoup
  parse each) even when one is new (Session.swift:478).
- `cacheMessages` parses HTML for FTS inside the write transaction
  (Store.swift:527-532, 782-802); `stage(file:)` copies up to 64 MB inside a
  write (Store.swift:635-657); `trimMessages` sorts the whole table and
  sweeps every channel after every write (Store.swift:806-831). All of them
  block every other store access, draft saves included. `stage` also
  fsyncs inside the write, so a large staging copy stalls history loads,
  search and read receipts; copy to a temporary location and rename inside a
  short write after re-checking the budget. (2026-11-23 pass)
- The 8 MB default `perform` budget applies to every RPC, including the large
  directory, channel and history reads. `get_list` is read with `try?`, so a
  larger site silently keeps an empty directory. Give those calls their own
  budget and surface the failure. (2026-11-23 pass) `[H]`
- A `Raven User` doctype event clears names, directory, preferences and every
  profile photo, so all photos download again (Session.swift:401).
- `HomeFeed.refresh()` makes six reads including a 5,000-row "sent" list
  and publishes none until all finish (NM-P2, §4.9); search fans out to six requests per query and its preview decodes up to
  1,500 messages per selected hit (SearchView.swift:777); cached hits parse
  HTML on the main actor (SearchFeed.swift:317-330).
- The collection filter parses every record's HTML on each keystroke
  (CollectionWindow.swift:148, 190-204).
- Responses are read one byte per `AsyncBytes` step (RavenClient.swift:209-216,
  304-311; GIFSearch.swift:344-347). Measured: 8 MB took 85-93 ms that way
  against 3 ms with `data(from:)`, on the client actor. Worth a chunked read
  only for large downloads.
- `upload` reads the whole file and then copies it into the multipart body,
  about 2x peak memory (RavenClient.swift:113-124); use `httpBodyStream` or a
  chunked append. (2026-11-18 pass) `[V]`
- `SearchCriteria.matches` rebuilds date patterns and rescans channels per
  cached message (SearchCriteria.swift:204-206,233-237); prepare once per
  `cachedHits`. (2026-11-18 pass) `[V]`
- Search reload repeats O(channels+users) work per publication
  (SearchView.swift:675-690,1041,1072,1194-1197; SearchSideColumn.swift:67-68);
  memoize per reload. (2026-11-18 pass) `[V]`

- `messages_fts.id` is declared `notIndexed()`, but every upsert, deletion,
  trim and withdrawal deletes FTS rows by `id` (`Store.swift`). Each such
  delete scans the whole index, so caching a page on a 20,000-row index
  performs millions of row visits on the serial store queue. Use an
  external-content FTS table keyed by `messages.rowid` (GRDB can synchronize
  it) or an `id -> rowid` side table, and delete by rowid. (2026-11-23
  independent pass) `[V]`
- Re-caching an unchanged page re-indexes every row: JSON encode, FTS delete
  and insert, a SwiftSoup parse for the index body, then two global sorts in
  `trimMessages`. Make the upsert conditional (`ON CONFLICT ... DO UPDATE ...
  WHERE raw IS NOT excluded.raw`), rebuild the FTS row only for changed
  messages, and skip `trimMessages` when nothing changed. Implemented in #181, which
  compares the stored payload in the upsert, encodes stored JSON with sorted
  keys, and pins unchanged FTS rowids across a repeated cache.
  (2026-11-23 independent pass) `[V]`
- Home and Search file rows ask `NSWorkspace` for a file icon per row and
  per reload (`HomeView.swift`), while `TranscriptStyle.fileIcon(for:)`
  already caches the same lookup for the transcript. Route `HomeFileIcon`
  through it. (2026-11-23 independent pass) `[V]`

### 4.6 Launch and memory `[H]`
- Account stores are opened and migrated on the main actor before the first
  window (App.swift:123-128); restoring up to 12 windows builds each
  synchronously.
- With "retain history" off, `memoryMessages` keeps up to 1,500 messages for
  every channel ever opened (Session.swift:384 prunes only when it is on).
- Per-channel shared text storages and undo managers are never evicted;
  `deletedIDs` and failure maps grow without bound.
- The decoded-GIF budget is 160 MB; the media metadata beside it has no
  bound (NM-09, §4.8).
- `AnimatedImageCache` clears ALL source sizes when it hits 4,096 keys
  (AnimatedImages.swift:57-61), so in-view GIFs can change aspect ratio; evict
  per key. (2026-11-18 pass) `[P]`
- Decoded thumbnails are a 20-entry FIFO shared by every channel
  (`Session.swift`), so scrolling an image-heavy conversation evicts rows
  still on screen and re-downloads them on the way back. Use a bounded LRU
  keyed by recent use; measure the memory cost before raising the bound.

### 4.7 NM-P1 · Measure frame delivery during a mixed-media conversation

The Release harness times 20 synchronous layout/display scroll steps over a 500-message visible window. Its corpus intentionally excludes downloaded media. `AnimatedImages` overlays decoded frames for visible GIFs while the transcript also responds to view size and message changes. This is a plausible contention point. A CPU duration alone cannot establish that a frame missed presentation. Use the measured workloads in the validation record. Obtain an attributed Animation Hitches trace on reference hardware with matching text-only and animated-media transcripts. Scroll, resize a split view, type through a burst of incoming messages, then idle with the window occluded. Record rendered interval distribution, hitch durations, CPU and footprint, alongside Reduce Motion results. Optimize only an attributed hot path and replay the identical workload.

### 4.8 NM-09 · Bound media metadata as well as decoded frames

GIF fetches are viewport-gated and decoded pixels have per-image and cache limits. The session separately records URLs and failed fetches. Inline rendering registers encountered sources, with no per-channel or time bound in the URL registry. The standard Release corpus excludes downloaded media. The three-GIF fixture in the validation record is a starting point for a long-running measurement. [Registry and failures](Sources/NevermoreApp/Session.swift#L824-L878) · [Decoded cache](Sources/NevermoreApp/AnimatedImages.swift#L38-L82) · [Decoder budgets](Sources/NevermoreCore/AnimatedImage.swift#L54-L142)

**Acceptance.** Measure URL, failure, decoded-frame and size-record counts through sustained visits to different media-heavy channels. Tie unbounded metadata to warm windows or expiry if observed. Preserve stable aspect ratio, repeated GIF playback, suppression of recent failures and invalidation after revocation. Compare estimated decoded bytes with actual row stride and end-to-end footprint before changing limits.

### 4.9 NM-P2 · Let fast Home modules appear independently

`HomeFeed.refresh` starts reminders, saved messages, followed threads, unread threads, files and sending statistics concurrently, then awaits a tuple before publishing any of them. Even an immediate response waits for the slowest one, including a list of up to 5,000 sent rows. It also stamps `loadedAt` before its task starts, so a cancelled refresh leaves the feed looking fresh for the 120 s window and suppresses retry; stamp on completion or clear on cancel. Prototype per-module publication in the loopback fixture with the statistics response held and a successful reminder available. Require the reminder to be actionable before releasing statistics. Count Home rebuilds and check that focus and scroll position survive incremental updates before choosing publication granularity.

### 4.10 Measure File inspector latency during selection

Time the synchronous ImageIO metadata read, workspace file-icon lookup and inline Quick Look setup in `FileInspector.show` separately. Use a signed Release app and repeat the same keyboard sequence over a JPEG, multi-page TIFF, PDF and unsupported document. Capture selection-to-next-key latency as well as preview-ready time. If a stage blocks input, move only that work and check that rapid selection, dismissal and revocation discard its result and release the prior file. [File inspector](Sources/NevermoreApp/FileInspector.swift)

---

## 5. Visual and layout

### 5.1 The toolbar title is drawn over transcript text `[V]`
- **What:** the transcript scrolls under the toolbar (by design:
  DECISIONS "The composer floats as Liquid Glass over the transcript, which
  scrolls beneath the toolbar"), but Tahoe's scroll-edge blur is missing, so
  "engineering / Acme" sits on top of legible message text in every theme.
- **Known:** a standalone AppKit probe (split view, manual `contentInsets`,
  overlays, hidden scroll views, `titlebarSeparatorStyle = .none`) always
  got the system `NSScrollPocket` blur. Something specific to Nevermore's
  pane suppresses it.
- **Next steps:** dump the transcript scroll view's subviews in the running
  app and look for `NSScrollPocket`; if absent, bisect (theme backdrop,
  overlays, `drawsBackground`, the custom text view, the split item's
  `allowsFullHeightLayout`). If AppKit cannot be convinced, add a soft
  gradient scrim under the toolbar tinted with the pane background.
- **Check:** screenshots at the top of a scrolled conversation in Classic
  and a dark theme. Needs the desktop (a GUI session), not just self-checks.

### 5.2 Theme accent ignored by system-styled controls `[V]`
- Under Vaporwave the sidebar selection is a system-blue pill and the
  Visual/Markdown control is system blue while the theme accent is pink.
  The sidebar uses `.sourceList` selection (ConversationShell.swift:458);
  Search already draws a themed `SearchRowView` (SearchView.swift:1044).
- **Fix:** a themed sidebar row view for non-Classic themes, and
  `selectedSegmentBezelColor` and `contentTintColor` from the theme.
- Partially implemented in #141 (merged): the Visual/Markdown segments
  (composer bar and editor sheet), search tabs, theme-gallery ring/badge,
  quick-reaction fill, GIF selection border and update notice now follow
  `themeAccent`. Still open: the themed sidebar row view.

### 5.3 No design scale `[H]`
About 15 spacing values, 8 corner radii (1.5 to 18), 13 font sizes
including 9.5, 11.5 and 12.5, and 10 row heights. The composer's three rows
use three inset sets (9/14/1/12, 9/14/1/10, 10/12/2/12). Search hit cells
use 7/12 and group headings 10/12, with a "Show N more" indent of 54 that
aligns with nothing. See §8 for the plan.

### 5.4 Surfaces that ignore the theme `[H]`
Thread inspector (system font, `labelColor`); code blocks (rectangular
`quaternaryLabelColor` background, worst under Phosphor and Neon Fun); the
day-divider pill (`textBackgroundColor` on dark wallpapers); resting
reaction chips (`tertiarySystemFill`); sent link preview titles
(`linkColor`); the search error (`systemRed`); the "customized" badge on dark
theme posters (ThemeSettingsView.swift:223). The visual sweeps in §8 cover all
of these except the badge. The search error and the collection status now
use `themeAlert` (implemented in #157, merged); label truncation ellipsizes
instead of clipping mid-glyph (implemented in #156, merged).

### 5.5 Smaller visual issues `[V]`
- The empty composer is three lines tall and always shows the formatting bar
  and Visual/Markdown control: about 150 pt of chrome per window. Show the
  bar on focus or when the draft has text, or let the user hide it.
- The hover action bar overlaps the day-divider line above a message, and
  there is no hovered-row background (the caret row is highlighted; hover is
  not).
- Home and line-length issues moved to NM-16 (§5.7) and NM-V1 (§5.6).
- Settings ▸ General: the interface-sound volume slider is not indented
  under its checkbox.
- Sender name and body are both 14 pt at the default size; hierarchy rests
  on weight alone.
- Search rows have fixed heights (62/66 pt) that can clip a two-line
  snippet (SearchView.swift:657-665). `[P]`
- The theme editor's ornament opacity slider has no value readout
  (ThemeEditor.swift:488). `[H]`
- The composer toolbar's inline-code button lacks the gray chip background the
  renderer draws, and leaves an orphan background after toggle or Clear
  Formatting (ComposerExtraFormatting.swift:35-48, ComposerFormatting.swift:14-32
  vs RichTextAdapter.swift:192). (2026-11-18 pass) `[V]`
- Home's Customize popover reserves 26 pt per row but draws 24 pt
  (HomeView.swift:1318,1341). (2026-11-18 pass) `[V]`
- Home's Files empty state stacks two notes (HomeView.swift:549,559).
  (2026-11-18 pass) `[V]`
- Short conversations hang from the top: three messages leave about 300 pt
  of empty pane above the composer. Messages, Slack and Raven's web client
  put a short transcript against the composer, where the eye is. Pad the
  top by `max(0, visibleHeight - usedHeight)`; this needs
  `textContainerOrigin` instead of `textContainerInset.height` in every
  geometry helper (`rect(for:)`, hover, ink, stickers, GIF overlay,
  viewport keeper, accessibility frames), so do it as its own change with
  screenshot checks.
- Vaporwave's motif shapes and horizon line sit directly under message text
  and avatars; the horizon reads like a divider between two messages.
  Lower ornament opacity inside the reading column, or fade the backdrop
  under the text column as the composer glass does.
- Code block commands are underlined system-blue links ("Open Reader  Copy
  Code") under a one-line run. Draw the header as a caption row in
  secondary text with `doc.on.doc` and
  `arrow.up.left.and.arrow.down.right` buttons; belongs with §8's code
  cards.
- Search's filter row clips "Mentions Me" under the sort popup at the
  default 1080 pt width (NM-07 handled the narrow pane). Let the row
  scroll or move the sort popup to the group header line.
- Search result times end about 50 pt left of the "N results" count above
  them.
- The title bar does not mark a private channel ("design / Acme"); the
  sidebar uses a lock tile. Show the same symbol in the title or subtitle.

- Search file rows install two required sizes for one icon: `HomeFileIcon`
  activates 28 x 28 and the hit cell activates 16 x 16 on the same anchors,
  so Auto Layout breaks one and logs a conflict per row. Give the icon a
  size parameter and pass 16 from Search. (2026-11-23 independent pass) `[V]`

From the 2026-11-23 epic-chicken pass:
- **Theme editor Wallpaper tab clips the ornament row** `[V]`:
  ThemeEditor.swift:50,511,603-604 — the row's intrinsic width is ~761 pt
  in a 640 pt pane with no horizontal scroller, so at six color wells the
  Remove control is unreachable. Wrap the wells or enable
  `hasHorizontalScroller`.
- **Collection window bottom bar overflows at minimum width** —
  implemented in #160 (merged): the two inbox-only actions hide below 720 pt
  and both stay available from the Message menu.
- **Onboarding and Account Preferences ignore the theme** `[P]`: system
  colors/fonts only, no raven mark on the first-run window
  (Onboarding.swift:44-104, AccountPreferencesController.swift:117,135-138).
- **Attachment window is fixed 540x260** `[P]`: add `.resizable` or size to
  content (AttachmentWindow.swift:47).
- **Empty states are bare** `[V]`: collections show "No Items"/"No
  Matches" (CollectionWindow.swift:367); reuse the SearchView empty-state
  component (icon, title, detail, action).

### 5.6 NM-V1 · Check transcript line length without sacrificing code or tables

The conversation can span a large monitor, while Home already limits the width of its content. Compare prose reading at default and wide widths in Classic and a textured theme. Prototype a readable line measure for prose with attachments, code blocks, tables and the composer still able to use the available width. Compare wrapped line lengths, horizontal eye travel, and scroll-anchor stability during live resize. Keep the current behavior unless readers prefer the result across both dense chat and long-form messages.

The code review measured lines running to about 1,000 pt in wide windows.

### 5.7 NM-16 · Refine the first glance at Home

Keep the configurable modules, and test a compact header and common alignment for titles, counts and secondary actions. Favor unread and pending work first in the default arrangement. At the one-column breakpoint, prefer one readable row per item over compressed card interiors. [Home layout](Sources/NevermoreApp/HomeView.swift) · [Design decisions](docs/design/home/HOME-SCREEN.md)

**Acceptance.** Compare Classic and Nevermore at 650, 1080 and 1400 pt. Ask the reviewer to find next unread, a draft and a recent file with mouse and keyboard. Inspect focus rings, long labels, readability with Increase Contrast, and scroll position during resize. Use a static header that keeps selection stable when counts change.

**Known details.** Home's subtitle "Nevermore Demo · demo.inva…" truncates at 900 pt. Home's Unread row shows "# design" beside a lock tile for a private channel. A fresh account's Home shows four empty modules, each with a paragraph of instructions; collapse them into one getting-started card. #41 (NM-04) fixes the unread badge contrast and #43 (NM-05) adds keyboard reordering.

### 5.8 NM-26 · Check composer controls against the actual glass surface

A light Meadow capture made the placeholder and several small composer tools faint against pale green glass. System placeholder and secondary icon colors are chosen independently of the theme's tinted material. Status text and disabled tool states need a separate visual comparison. [Placeholder drawing](Sources/NevermoreApp/ConversationWindow.swift#L35-L43) · [Formatting button tint](Sources/NevermoreApp/ComposerFormattingBar.swift#L75-L89)

**Acceptance.** Measure active and inactive windows and enabled controls at light and dark theme extremes, with and without Increase Contrast. Use a legible foreground or a quieter material for the affected active roles, preserve distinct disabled styling and stable layout, and keep the empty editor and attachment action identifiable without hover. A toolbar stroke or short label is preferable to adding another animated cue during typing.

The aesthetics plan's contrast audit (§8, sweep 2) covers the same pairs on every surface.

### 5.9 Fit the File inspector into a short conversation window

A standalone AppKit probe used the production inspector layout with a long filename and a 280 × 375 pt host. AppKit expanded the content to 460 pt while loading and 493 pt after displaying a passive placeholder with details. The real split view, saved-file actions and toolbar have different constraints. Reproduce at the conversation window's 420 pt minimum height with loading, failure and saved-file states. Tab to every action in Classic light and dark, including Full Keyboard Access and Increase Contrast. Include long sender and conversation names. Check VoiceOver reading order and independent preview scrolling and zoom. If the split view clips or resizes unexpectedly, allow the details/actions to scroll while keeping the file identity and close control in view. Preserve the user's divider width and the currently covered thread. [Inspector layout](Sources/NevermoreApp/FileInspector.swift) · [Window sizing](Sources/NevermoreApp/ConversationWindow.swift)
- The attachment actions window is fixed at 260 pt and can clip its bottom
  row (AttachmentWindow.swift:50,63-64). (2026-11-18 pass) `[P]`

---

## 6. UX and convenience

### 6.1 Open conversations at the first unread message `[V]`
- **Where:** `select()` sets `isFollowing = anchor == nil`
  (ConversationWindow.swift:804), so the first render scrolls to the newest
  message and `seenVisible()` marks the bottom read. A long backlog's
  divider is far above or outside the 500-message window.
- **Fix:** when the read position has a first unread message above the
  viewport, open with the divider near the top instead of following; the
  Jump to Latest control and read-receipt band already handle the rest.
  When more than 500 are unread, anchor the load at the first unread
  message: `get_messages` already takes `anchor_to_unread` and returns the
  window around the first unread in one request (RAVEN-RESEARCH §4), so
  the search anchor path is not needed.
- **Check:** self-checks for a conversation with 30 and with 800 unread
  messages; the viewport keeper and the checks that assume following on open
  need review.

### 6.2 Window subtitle carries little information `[V]`
Channels show their workspace; DMs show nothing. Show the channel
description or member count, and for DMs presence, custom status and the
person's local time. #57 (NM-13) shows name, workspace, visibility and
description in a Channel Details sheet; the subtitle can reuse those
fields.

### 6.3 Routine failures are app-modal alerts `[H]`
`showError` runs `NSAlert.runModal()` for send, download, reaction, poll,
search and collection failures. DECISIONS keeps them app-modal "because they
often arrive after their window closed or changed account". Proposal in §11.

### 6.4 Accessibility gaps `[H]`
- Reaction chips cannot be toggled from the keyboard or VoiceOver; add
  "Toggle Reaction…" and "Remove My Reaction" actions per message.
- New messages arriving while scrolled away are not announced; post a
  throttled announcement.
- Jump to Latest is not in the key-view loop (ConversationShell.swift:433);
  read NM-06 (§6.6) before changing the loop.
- Inline GIFs have no accessibility description (AnimatedImages.swift:321).
- Account Preferences and SheetPrompt accessory controls have no
  accessibility labels (AccountPreferencesController.swift:52-62,
  SheetPrompts.swift:47-76).
- The theme editor's low-contrast warning is not announced
  (ThemeEditor.swift:127).
- A saved search cannot be removed via VoiceOver (SearchSideColumn.swift:83-88);
  add an AX custom action. (2026-11-18 pass) `[H]`
- The theme gallery is one AX element, hiding the cards
  (ThemeSettingsView.swift:45-46). (2026-11-18 pass) `[P]`
- The File panel's filename is no longer selectable or copyable
  (FileInspector.swift:92-94,161). (2026-11-18 pass) `[H]`
- The Messages rotor falls back to "Attachment" for messages whose HTML is
  empty, so every file announces the same words. Build the rotor body from
  the displayed file name, image text or `content`.
  (2026-11-23 pass) `[H]`

- The member roster's count replaces the field's accessibility label, so
  VoiceOver says "Member count" without the number
  (`MemberRosterWindow.swift`). Let the count text be the label, or set the
  accessibility value. (2026-11-23 independent pass) `[H]`
- Reduce Transparency is honored nowhere (zero hits for
  `accessibilityDisplayShouldReduceTransparency`), and Jump to Latest sits
  outside the key-view loop (ConversationShell.swift:472-476).
  (2026-11-23 epic-chicken pass) `[H]`

### 6.5 Convenience `[H]`
- No Mark All Read command, only Home's button: add Message ▸ Mark All Read
  (⇧⌘A). The Inbox-wide Mark All Notifications Read
  (`mark_all_notifications_read`) is in #61 (NM-20) and its menu item now
  works from any window (#99). Inbox rows should still show read state.
- Favorites have no shortcuts; ⌘1-⌘6 belong to collections, so use ⌥⌘1-9
  or migrate deliberately.
- Mute, favorite and archive have no Undo.
- The hover bar disappears on any scroll even when the pointer stays on the
  message.
- The composer's text size does not follow the reading size (⌘+/⌘−).
- Compact mode shows no time for continuation rows, even on hover or with
  the caret on the row: `ConversationWindow.swift:1229` adds the gutter-time
  attribute only for group starts and `TranscriptMetrics.gutter` is 0 in
  compact mode (TranscriptStyle.swift:57,358). Give compact mode a small
  gutter (about 30 pt) and add the attribute for continued rows. `[V]`
- Saved searches can only be removed, not renamed (SearchSideColumn.swift:85).
- The emoji picker shows `:name:` rows without the emoji although each entry
  carries an image (EmojiPickerSheet.swift:157-162;
  `RavenCustomEmoji.imagePath` is never loaded). Add a per-row `NSImageView`
  fed from a small capped in-sheet cache, downloading through
  `session.client.download` with the origin-resolved URL and a 256 KB cap. `[V]`
- Poll options toggle only on the small control, not the text
  (PollWindow.swift:368-381); the poll deadline picker allows past times —
  `PollEditorSheet.swift:41` never sets `minDate`, so the stepper can walk
  into the past and `PollDraft` later rejects with `deadlineNotFuture`. Set
  `minDate = Date()` and re-clamp in `accept()`. Implemented in #114: the
  minimum is set at creation and refreshed on the timed toggle, and
  `accept()` still rejects a deadline that has passed. `[V]`
- **Use the typed prefix in the Open Conversation empty message** `[V]`.
  In [#124](https://forge.goodvantage.cloud/Goodvantage/Nevermore/pulls/124)
  the generic chooser already filters `@` to people and `#` to channels,
  and its empty message names both. Use the parsed prefix for the
  generic picker. Check both prefixes, a bare query and the two
  Search pickers. [ConversationChooser.swift](Sources/NevermoreApp/ConversationChooser.swift#L53)
- **Expose the selected outbox error in the window** `[P]`. The table
  only exposes operation errors as pointer tooltips. Give the selected
  row a selectable explanation below the table with its state and any
  delivery uncertainty. Verify paused, retryable and ambiguous cases
  with VoiceOver and Full Keyboard Access. Check the existing Return
  routing issue (§3.5) before adding another keyboard action.
  [OutboxWindow.swift](Sources/NevermoreApp/OutboxWindow.swift#L188)
- Outbox "Cancel Send" discards the text instead of taking it back into the
  composer (OutboxWindow.swift:279-292); the app already has take-back.
- GIF settings cannot test a pasted key (GIFSettings.swift:83).
- Closing Account Preferences discards unsaved server edits without asking
  (AccountPreferencesController.swift:107).
- "Write in Markdown" is a silent no-op in Markdown mode and there is no way
  back via the menu (ExpandedComposer.swift:5, MainMenu.swift:239).
  (2026-11-18 pass) `[V]`
- The conversation chooser's Cancel has no Escape key equivalent despite the
  on-screen hint (ConversationChooser.swift:36,39). (2026-11-18 pass) `[V]`
- Home's Later never surfaces scheduled messages (HomeFeed.swift:28-47,
  HomeView.swift:370). (2026-11-18 pass) `[P]`
- Implemented in #83: no Copy Text in the message menu; copying a whole
  message needed a drag selection.
- Implemented in #100: no draft marker in the sidebar.
- Implemented in #96: Go had Next Unread Conversation (⇧⌥⌘↓) but no
  Previous Unread.
- Implemented in #81: Save for Later could only add, and nothing showed
  that a message was saved or pinned.

- **Edit an existing date in context.** Change Time and Edit Reminder currently open at one hour from now. Read the row's `scheduled_time` or `remind_at` in the site timezone and prefill a future edit from it. Keep snooze as a distinct operation. Decide how to show an elapsed time and a repeated DST hour. Verify Cancel, an absent timestamp and differing device/site timezones. [Collection actions](Sources/NevermoreApp/CollectionWindow.swift) · [Date sheet](Sources/NevermoreApp/SheetPrompts.swift)

- **Jump to First Unread** in the transcript (Option-Command-U) complements
  Jump to Latest and opening at the first unread (§6.1): scroll the divider
  into the top of the reading band and stop following, without changing the
  selection. Disable the item when nothing is unread. Check a divider above
  and below the loaded window. (2026-11-23 independent pass)
- **Sort the sidebar by recent activity** (opt-in) instead of by name, using
  `last_message_timestamp` with a name tiebreak, within each workspace and
  for Direct Messages. Keep name order the default until the owner prefers
  otherwise. Put the pure ordering in Core and test equal and missing
  timestamps. (2026-11-23 independent pass)
- **Mark a workspace section read** from its header's context menu: confirm
  the unread count, then queue one read receipt per conversation in that
  section. Leave muted and archived rows alone.
  (2026-11-23 independent pass)

### 6.6 NM-06 · Test pane focus restoration before changing the Tab loop

The fixed conversation key loop looked as though it would skip Home controls. With ordinary Tab navigation, the observed route was sidebar and toolbar search. With Full Keyboard Access on, Tab reached a scroll area, Mark All Read, and both unread rows. The stronger claim that Home is inaccessible by Tab did not reproduce. Search already has explicit Down-to-results and Up-to-field actions. [Window key loop](Sources/NevermoreApp/ConversationShell.swift#L429-L439) · [Search focus actions](Sources/NevermoreApp/SearchNavigation.swift#L41-L94) · [Home controls](Sources/NevermoreApp/HomeView.swift#L861-L884)

**Acceptance.** Capture forward and backward focus across Home, Search, transcript, composer and thread inspector, including Back/Forward and popover dismissal. Compare ordinary keyboard navigation with Full Keyboard Access. Change the routing only where focus becomes stranded, hidden, or fails to restore. Preserve Search arrows and editor keyboard behavior.

#### Give keyboard users a clear way into and out of the File panel `[P]`

The conversation sets an explicit key-view loop from transcript to composer and has a dedicated collapsed-thread affordance. File panel Show Message calls `scrollTo` and selects text without explicitly moving first responder. Test Tab/Shift-Tab and VoiceOver when the File panel is visible, covering a thread, or hidden by a resize. Route focus only on explicit actions and restore it to the invoking attachment or nearest surviving message on close. Preserve focus while the file follows the caret and when a download finishes. [Existing key-view routing](Sources/NevermoreApp/ConversationWindow.swift#L1385) · [File panel actions](Sources/NevermoreApp/FileInspector.swift#L266)

---

## 7. Missing features and Raven workflows

### 7.1 Notifications `[V]`
Notifications already group by conversation. Remaining work:
- **Preview setting:** implemented in #88. Today the body is always "New
  activity in Raven" (Session.swift:989-993). Offer Generic / Sender and conversation / Message
  text, with spoilers masked through `RichTextCodec.plainText`. The plan
  already calls for sender-only and content-hidden modes (NEVERMORE-PLAN
  §4.8).
- **Actions:** no notification category is registered today. Add one with
  Reply (`UNTextInputNotificationAction`) and Mark Read. The
  plan gates these on proven routing, persistence and lifecycle; the reply
  must go through the durable outbox (`acceptDraft`), not a direct RPC.
- **Sound:** optional, for DMs and mentions; the app asks for `.sound`
  permission already.
- Show a denied permission in Settings (§3.5).
- Settings ▸ Notifications is one checkbox (one popup with #88). It has
  room for sound and quiet hours, which live per account in Account
  Preferences today.

### 7.2 Raven parity, ranked `[H]`
Checked against Raven at e2ae015.
1. **Typing indicators:** NM-15 (§7.4).
2. **Presence beyond DM rows:** member lists, message headers, profiles,
   Search's People rows (they do not refresh on presence today).
3. **User profiles:** view on avatar click; edit your own name, photo and
   status.
4. **Channel settings:** rename, description, type, delete (`Raven Channel`
   updates, gated by `ChannelPolicy`).
5. **Workspaces:** browse, join, leave (`raven.api.workspaces.*`).
6. **Channel browser** with join.
7. **Custom emoji** upload and delete.
8. **AI threads and bots** in Threads and New Message (administration stays
   in the browser).
9. **Per-channel notification level** (`toggle_push_notification_for_channel`,
   `allow_notifications`).
10. **Attachment contact sheet.** Prototype arrow navigation across one Raven batch in the File inspector. Display a static “3 of 8” position at 280 pt and use the message caption as its accessible name. Confirm batch order and access before loading a sibling. Keep one preview active and support zoom for images. Check mixed file types, deleted siblings, Escape and Reduce Motion. Compare the compact rail with simply opening the next attachment in the transcript.

Also: open Raven message links in the app (NM-14, §7.5); attach a Frappe
document; copy a file's download link where permissions allow, and batch file export (NM-22, §7.6); who reacted; reminder presets;
per-channel Links and Threads views; composer banners (mention not in
channel, quiet hours); on-leave badges; meeting links.

From the 2026-11-23 epic-chicken pass `[P]`:
- **Channel Files paging ignores the server cursor.**
  `ConversationActions.swift:280` hardcodes `limit: 100` and never sends
  `cursor_creation`/`cursor_id`; files past the first 100 are unreachable.
- **Per-channel mark-all-read RPC unused.** `raven_channel.
  mark_all_messages_as_read` exists on the pinned server; Home marks
  conversations one by one via `track_visit`.
- **Privacy: received-message `og:image` previews fetch third-party hosts
  even when link previews are disabled.** ConversationWindow.swift:1275-1277
  requests previews regardless of `ComposerPreferences.showsLinkPreviews`,
  which only gates the composer card. Honor the preference for
  received-message images too, or document the scope.

**Verify the offline attachment workflow** `[P]`. Stage a file and caption
in a cache-backed, previously writable conversation, then restart with
the attachment still in the draft. Accept the send while loopback uploads
are held unavailable. Check that the user can tell the queued row from a
completed upload, and that authorization still applies when the session
reconnects. Include an expired grant, an archived conversation and a
second account. Change the button or status copy if the fixture exposes
a discovery problem. Scheduled sends use a separate text-only contract.
[Composer send](Sources/NevermoreApp/ConversationWindow.swift#L1772) ·
[Raven constraints](docs/RAVEN-RESEARCH.md#9-other-constraints-that-affect-the-design)

### 7.3 Mac-native expectations, ranked `[H]`
Actionable notifications (§7.1); add message destinations to the existing
Open Conversation sheet and test integrating it with Home's “Go To” field.
The File inspector already shares saved copies and copies message links.
A native Share action for message text remains open. Other candidates include App
Intents (open conversation, send message, set status); URL-scheme deep links
(`ch.goodvantage.Nevermore://channel/…`, separate from the OAuth callback);
drag a message out as text and link; Handoff; Reduce Transparency (opaque
composer and panels); system text-size scaling; more VoiceOver rotors (links,
attachments); Quick Look in Home's Recent Files and Conversation ▸ Files;
Open Recent; a compact sidebar; sidebar type-ahead; syntax highlighting and
Save As in the code reader (CodeReaderWindow.swift:20-33); progress for
uploads and large downloads. Spotlight stays out of scope per the plan
unless the owner revisits it.

### 7.4 NM-15 · Prototype optional receive-only typing indicators

The pinned Raven realtime implementation emits a channel-specific list of typers. Nevermore consumes presence and message invalidations, but does not subscribe to it. Deployment support differs across the Frappe versions in the project's contract notes. [Native realtime client](Sources/RavenProtocol/RavenRealtime.swift) · [Pinned typing event](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/realtime/handlers.js#L35-L58) · [Compatibility notes](docs/RAVEN-RESEARCH.md#6-realtime-is-socketio-not-raw-websocket)

**Acceptance.** Prototype an opt-in fixed-size label in the active authorized room. Expire names and clear on switch, revocation, and disconnect. Verify two users, a non-member, missing events, multiple windows, and disposable Frappe 15 and 16 sites. Keep the label static, with no focus or scroll changes. Design outbound typing separately as an opt-in privacy decision.

**From the code review.** Raven at e2ae015 takes `raven_channel_typing` and `raven_channel_typing_stopped` emits and answers `raven_channel_get_typers` to the asking user only (realtime/handlers.js). `RavenRealtime` documents the inbound `raven_channel_typers` name (Endpoints.swift:105-112) but has no emit API. Frappe 15 does not load app handlers; degrade silently. Two traps, both read in the code `[V]`:

- Raven sends `raven_channel_typers` to the `open_doc:Raven Channel/<id>` room, and Nevermore joins rooms only with `doc_subscribe` (RavenRealtime.swift:139-157). The prototype must also join the open-doc room for the conversation on screen (check which Frappe realtime event joins it; likely `doc_open`) or ask with `raven_channel_get_typers`.
- `AccountSession.event` sends every event it does not recognize to `notify()` and `requestReconciliation()` (Session.swift:396-415). Handle typers before that fall-through, or each burst of typing costs a reconciliation and a render in every window (§4.1).

### 7.5 NM-14 · Open a pasted Raven message link in Nevermore

Copy Message Link emits a web route. Search already opens a context anchor inside the app. Add an explicit Go command for pasting a link received elsewhere. Match the exact configured site origin, resolve through an authorized read, and reuse the anchor route. [Pinned permalink contract](docs/RAVEN-RESEARCH.md#later-read-receipts-and-message-permalinks-review-follow-up) · [Native search navigation](Sources/NevermoreApp/SearchNavigation.swift)

**Acceptance.** Cover a channel and thread target, two accounts on the same site, deleted and inaccessible rows, and a mismatched scheme, host or port. Ask which account when ambiguous. Preview without marking intervening messages read. Retain browser handoff for unknown web base paths.

First verify the accepted link forms produced by each supported deployment, including sites mounted below a nondefault web path. The ambiguous two-account case needs an explicit account choice.

### 7.6 NM-22 · Save the files in one message batch together

The native Save As path is per message. The pinned Raven batch endpoint accepts a JSON-encoded list of message IDs in a GET and returns a ZIP. It checks message access and skips rows without an attached file, which supports batches with captions. [Native file actions](Sources/NevermoreApp/ConversationWindow.swift#L1692-L1719) · [Pinned binary endpoint](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/raven/api/raven_message.py#L1054-L1109)

**Acceptance.** Use canonical batch lookup and reuse bounded, authenticated download and atomic quarantined export. Test captions, duplicate filenames, a removed file or revoked message, missing endpoint, malformed/oversized body, canceled save panel, and a batch inside a thread. Describe missing archive members accurately. Keep single-file Save As available.

First exercise the pinned ZIP endpoint on a mixed accessible/unavailable file batch. Establish how the app can detect missing entries when the server silently skips rows. The UI must be able to tell the reader which files actually reached disk.

---

## 8. Aesthetics plan

From the visual-system review, adjusted to what the screenshots show. Each
step needs a screenshot check and may move self-check geometry.

### 8.1 Treat the transcript as the dominant surface `[P]`

Build on the recorded contrast findings in NM-26. Capture matched screenshots at 650, 900 and 1,400 pt. Include dense conversation, File panel, Search and Home in Classic and one high-chroma theme. Start with title readability at the scroll edge, focused and inactive sidebar selection, and composer contrast over a bright image. Use consistent insets and type roles across those screens. Let the transcript retain the strongest contrast, keep contextual panels quieter, and reserve accent for selection, unread state and primary actions. Use Reduce Transparency and Increase Contrast in the acceptance matrix. Compare pixel crops only after the window has settled, since the existing walkthrough recorded capture timing variance.

### 8.2 Visual sweeps

**Sweep 1, small and local**
- One radius ladder: 16 for panels, 12 for inner tiles, the hover bar and
  link cards, 8 for rows, the chip container and attachment chips.
- Sender name `max(13, size − 1)` semibold; body stays at the reading size.
- Compare the unread divider's current 4/6 pt padding with the date
  divider's 12/8 pt regular spacing. Check both at large reading sizes.
- Sidebar section headers match card headings (11 pt bold caps, kerning
  0.6).
- Home row hover alpha from 0.07 to 0.09, with a press state.
- Reaction chips: themed resting fill, monospaced counts.
- Day pill: theme-aware fill.
- Integral font sizes only (11.5 → 12 or 11, 9.5 → 10, 12.5 → 12).
- The composer's rows share one inset set (8/12).
- The search error uses `themeAlert`.
- Themed sidebar selection and segmented control (§5.2).

**Sweep 2, a token file**
- Spacing 4/8/12/16/24/32, the radius ladder and type sizes in one place,
  then migrate the transcript, composer, sidebar, Home and Search.
- Search rows on the scale, with hover and focused and unfocused selection.
- Code blocks as rounded, theme-colored cards.
- Give the thread inspector the parent transcript's reading scale and
  color roles. Prototype a compact root card with one jump action and use
  quiet separators between replies. Compare matched captures in Classic
  and a light glass theme, with large type, Increase Contrast and a short
  pane. Include a root with a long unbroken token and check that Close
  and Open in Window remain reachable. Keep inline reply and attachment
  actions independent. [ThreadInspector.swift](Sources/NevermoreApp/ThreadInspector.swift#L41)
- One empty-state component.
- Focus rings everywhere.
- Extend the contrast audit to text over tinted glass, the accent over
  wallpaper (ThemeRules.swift:58), and raise panel tint from 0.22 to about
  0.3 (NM-26, §5.8, has the composer measurements; #41 fixes the Home
  badge pair).

**Sweep 3**
- Attachment lines as cards: icon tile, name, size.
- Sent link previews matching the composer's card.
- An avatar size scale: 20/28/32/44/52.
- Replace the 7 pt blank-line separators with paragraph spacing.

---

## 9. Delight and experiments

### 9.1 Delight

Built on what exists: the unkindness of ravens, Wet Ink, stickers, raven
portraits and synthesized sounds. All motion respects Reduce Motion; anything
that could distract is off by default. No per-theme taglines anywhere in the
UI (owner's rule).

1. **Typing ravens:** a small raven hops along the composer edge while
   someone types (needs NM-15, §7.4).
2. **The Familiar:** a raven on the Add Account window turns its head toward
   the field being edited.
3. **Startle the Roost:** clicking Home's resting ravens when all is read
   sends them up for one beat, with a cooldown.
4. **The Raven's Eye:** a small raven-eye mark in the avatar column of
   messages that mention you, matching the sidebar's lit eye.
5. **Quoth the Raven:** triple-click the connection dot for one original
   raven line ("The ink is still wet.") for four seconds.
6. **Their Morning:** a schedule preset that sends at 9:00 in the
   recipient's time zone, and their local time in DM subtitles (§6.2).
7. **Summon the Raven:** a menu bar action that flies the newest mention in
   and opens it.
8. **Message notes:** private, local notes on any message, separate from
   server Saved.
9. **While You Were Away:** a dismissible card on opening a busy
   conversation ("43 new since Tuesday, 3 mention you, 2 threads").
10. **The Raven Gazette:** Threads as a front page, each thread a story with
    its root as the headline.
11. **Reaction roost:** clicking a chip's count shows who reacted.
12. **Raven phrases:** saved snippets inserted with a `;` shortcut.
13. **Print the Raven:** a typeset PDF of a thread with a masthead.
14. **On This Day:** an opt-in Home module with a message from a year ago.
15. **Roost mode:** a Nevermore quiet mode that holds notifications and
    shows a sleeping raven in the menu bar until a set time. Pairs with
    Hold Outgoing Messages (NM-18, §9.2).
16. **Who is around:** an opt-in Home module of colleagues active now, with
    their local times.

17. **Attachment export cue.** When a save completes, show the resulting file name and reveal action without shifting preview geometry or replacing command focus. Prototype a short highlight on the saved-file row that becomes an immediate static state with Reduce Motion. Announce completion once through the existing status-announcement policy. Give cancellation, failure and retry their own static states. Verify success with a long name, cancellation, overwrites, background window and duplicate saves. [File save state](Sources/NevermoreApp/FileInspector.swift#L225) · [Announcement policy](Sources/NevermoreCore/StatusAnnouncementPolicy.swift)

18. **Floating day pill:** implemented in #95.
19. **Seen-by perch:** in a DM, the other person's tiny raven portrait
    perches at the end of the last message they have read and hops down as
    they read more (readers per message are already fetched for "Who Has
    Read This?"). Opt-in, DMs only.
20. **Quill caret:** in the Nevermore and Wet Ink-styled themes, draw the
    composer's insertion point as a thin nib with a 150 ms ink tail when
    typing fast (`drawInsertionPoint(in:color:turnedOn:)`). Plain caret
    under Reduce Motion.
21. **Dock raven eye:** a custom Dock tile whose raven opens one lit eye
    while a mention waits, instead of only the badge dot.
22. **Nevermore countdown:** a scheduled message shows a tiny hourglass in
    the transcript where it will appear, with "in 2 h" on hover.
23. **Inkwell meter:** a faint fill in the send button that rises with draft
    length and turns amber past Raven's message-length limit, so the limit
    is known before the server rejects the send.

### 9.2 Experiments for frequent readers

#### NM-F1 · Pin one recurring search to Home

Saved searches already live in Find and the wide search side column. A reader who repeatedly checks mentions in one workspace could open those exact filters directly from Home. Try one opt-in action on an existing saved search and reuse its per-account ID. Compare time and actions to reach that search from Home with the existing Find menu. Pursue if it saves a meaningful step for frequent users. Acceptance includes rename, removal, a revoked channel, account switching, and no background requests or read receipts just from displaying the shortcut.

#### NM-17 · Add a one-step return after Jump to Latest

When people jump from old history to the latest message, save a single-use return point scoped to that window and conversation. A static “Back to where you were” action can extend the app's paper-and-ink character by making a common action reversible. [Jump to latest](Sources/NevermoreApp/UnreadAffordance.swift#L27-L49) · [Viewport restoration](Sources/NevermoreApp/TranscriptViewportKeeper.swift)

**Acceptance.** Save the old message ID and viewport offset only on explicit Jump to Latest. Restore after new arrivals with a nearest-survivor fallback after deletion. Clear on conversation or account change. Keep focus and selection until the user chooses the action. Provide the same static control in Reduce Motion.

Compare the automatic jump-back with the manual bookmark below. Both can use the same window-local message anchor.

**NM-D1 · Manual reading bookmark.** When comparing two messages far apart in one conversation, the reader can save a message to Raven or navigate back through intervening locations. Prototype “Hold My Place” in the message menu. A small stationary feather marks one message in this window and a keyboard command jumps back to it. Use the existing authorized message-anchor navigation. Store only the account, channel and message identifiers in window memory, clear it on access loss or closure, and announce the action in VoiceOver. Compare the number of actions needed to read a linked thread and return to a particular sentence against Back and Saved Messages. Keep it only if it improves that task without competing with the unread divider.

If the window-local bookmark proves useful, test whether people need to
resume from it after closing and reopening the app. Store one local message
identifier per conversation and clear it on revocation or account removal.
Test edited, deleted and evicted anchors before choosing a persistent
representation.

Related: §11, question 4, on where the unread boundary goes after Jump to Latest.

#### Navigate cached dates `[P]`

Prototype a Go menu sheet that lists days the current authorized conversation has loaded, with each day's first message and an indication when history coverage is partial. Reuse the transcript's site-time-zone date grouping and anchor placement. Selecting a day leaves a Back entry. The prototype should work from the keyboard and never imply an arbitrary uncached date can be fetched without a verified server contract. Test midnight and DST, gaps, threads, access changes and a second window parked on a different date. [Transcript day grouping](Sources/NevermoreCore/TranscriptLayout.swift) · [History navigation](Sources/NevermoreApp/ConversationWindow.swift#L982)

#### Copy a shareable message citation `[P]`

Offer Copy Message Citation next to Copy Message Link. Make the clipboard item usable in a bug report or email with sender, site-local timestamp, conversation, a short spoiler-masked quotation and the existing Raven permalink. Use current authorization and canonical message identity at invocation. Keep copying local and explicit. Test edited and deleted messages, multiline formatting and code, private channels, and rich and plain clipboard clients. Compare against the existing Copy Transcript and the proposed typeset thread export in §9.1. [Message actions](Sources/NevermoreApp/ConversationActions.swift) · [Transcript clipboard](Sources/NevermoreApp/TranscriptAccessibility.swift)

#### NM-18 · Let the user hold outgoing messages during travel or a meeting

The existing Wet Ink send and demo wire already distinguish queued local content from server delivery. A menu command could pause outbox POSTs until resumed and label that hold in the existing status surface. Call the feature Hold Outgoing Messages. [Outbox flush](Sources/NevermoreApp/Session.swift#L637-L716) · [Demo wire hold](Sources/NevermoreApp/DemoWire.swift) · [Wet Ink design](docs/design/WET-INK.md)

**Acceptance.** Keep the hold account-scoped and durable across quit, with a clear exception for a POST already underway. Define what Retry and Take Back do during a hold, and resume in queue order after an intentional action. Keep reading and drafting active, with no focus change or motion on incoming events. Test across two windows and verify normal retries after resume.

Today the outbox flushes only while Nevermore is frontmost (§3.4); settle that question first, since a hold changes the same flush.

### 9.3 Product ideas beyond the current plan

- **Quick switcher (⌘T):** one palette for conversations, messages and
  people. Reuse `SearchCriteria` parsing and the conversation anchor route;
  keep it keyboard-first and free of background requests or read receipts.
- **Forward a message:** choose a destination and send the original text
  with attribution through the durable outbox, like any other send.
- **Drag a message onto a sidebar row** to forward it or quote it there,
  reusing the existing drag/outgoing payload types.
- **Per-channel notification level in the UI:** surface mute and
  `allow_notifications` from Channel Details instead of leaving them as raw
  channel fields.
- **Quiet send mark:** a message accepted with Send Silently leaves a still,
  low-contrast ink mark instead of the Wet Ink drop, matching the existing
  pending-send status line. No new motion.
- **A raven that explains itself:** the sidebar row's tooltip gains the
  unread and mention state whose bird the perch already shows, so hovering a
  bird says "3 unread, mentions you" without adding chrome to the row.
- **Recent search terms as static buttons** in Search's empty state; no
  query is sent until one is chosen.

---

## 10. Code health

- `ConversationWindow.swift` (about 1,765 lines, 135 KB) and
  `ConversationShell.swift` hold rendering, navigation, actions and layout in
  one controller, with many single-line multi-statement bodies. Extract the
  render pipeline into a `TranscriptRenderer` that takes a snapshot and
  returns an attributed string plus ranges. That also makes render skipping
  (§4.1) and incremental append testable.
- `AccountSession` cannot be unit-tested: `RavenClient`'s stub-transport
  initializer is internal to RavenProtocol. A `package`-level initializer
  would let self-checks drive `refresh()`, `load()`, `event()` and
  `deliverNotification` against a `URLProtocol` stub. Several fixes in §1
  and §3 could not get automated tests for this reason.
- `AccountStore` has no fault injection, so store-failure paths (§3.1) are
  untested.
- Terminal outbox rows are kept forever and decoded in full by
  `pruneStaging` and `deliveredMessageIDs`; `pruneStaging` re-decodes every
  operation and draft payload after each acknowledged send
  (Store.swift:505-508 from `acknowledge` :499), so the cost grows with the
  lifetime send count. Prune incrementally on terminal state. (2026-11-18 pass)
- The German strings file covers only part of its declared scope
  (Resources/de.lproj/Localizable.strings). `[H]`
- The staging-byte budget is dead API with no UI (Store.swift:70-71).
  (2026-11-18 pass) `[H]`
- Several sheets call `endSheet` unconditionally (ChoiceSheet.swift:287,
  MemberRosterWindow.swift:212, ConversationChooser.swift:83,
  ChannelDetailsSheet.swift:124); guard `attachedSheet === panel`.
  (2026-11-18 pass) `[P]`
- Sparkle is linked, embedded, codesigned and shipped but never imported
  (Package.swift:14, build-app.sh:64-70, Info.plist SU* keys; no
  `import Sparkle` anywhere): about 2.9 MB of dead framework. Owner decision:
  remove it or wire it. (2026-11-18 pass) `[V]`
- `ComposerLinkPreview.update` ignores its `draft` parameter
  (ComposerLinkPreview.swift:33) — dead API. (2026-11-18 pass) `[V]`
- "Open With" computes the app list synchronously on the main thread after
  every Save As (AttachmentExport.swift:24-30); compute off-main or cache, and
  populate it regardless of preview kind so "Open Saved File With…" is not
  disabled for unsupported types (AttachmentWindow.swift:138-140,
  FileInspector.swift:213,233-235). (2026-11-18 pass) `[H]`
- Test runs leave empty preference files behind. `UpdateTestPreferences`
  (UpdateMonitorTests.swift:138-143) opens a `UserDefaults` suite named
  `NevermoreUpdates-<UUID>` per test, and the native self-check's
  `UpdateSelfChecks` (UpdateSelfChecks.swift:6-8) one named
  `NevermoreUpdateSelfCheck-<UUID>` per run. Both only call
  `removePersistentDomain`, which empties the domain but leaves its plist.
  On the review Mac, 1,096 files had built up in `~/Library/Preferences`
  (from `swift test`, since 12 November) and 328 in the app container's
  `Data/Library/Preferences` (from self-checks). Give `UpdateMonitor` a
  small key-value protocol with an in-memory test double, or use one fixed
  suite per test that is cleared before and after use; then remove the
  existing files with `rm ~/Library/Preferences/NevermoreUpdates-*.plist`
  and the same for `NevermoreUpdateSelfCheck-*.plist` in
  `~/Library/Containers/ch.goodvantage.Nevermore/Data/Library/Preferences`.
  `[V]`
- Extend preference isolation to native layout fixtures. The transcript
  test temporarily writes `fontSize` to the standard defaults and restores
  it at scope exit. A per-run override for renderer preferences would also
  cover process interruption. Verify the 11, 13, and 24 pt cases and compare
  defaults before and after interruption.
- Release tooling: `package-release.sh` accepts only a certificate name for
  `SIGN_IDENTITY`, though `resolve-sign-identity.sh` exists for ambiguous
  names; the CI SDK check fails cryptically on a non-numeric version
  (ci.yml:71). `[H]`
- `Endpoints.swift`'s "RPCs the app layer calls today" inventory omits nine
  used methods (document_link.get_preview_data,
  notifications.get_unread_notification_message_ids,
  raven_channel_member.add/remove, raven_message.forward_message/
  get_message_readers, search.search_links,
  threads.get_other_threads/get_unread_threads). Add them, or generate the
  list in CI and diff it against `"raven.api.…"` literals in Sources.
  (2026-11-23 epic-chicken pass) `[P]`
- `removeRevokedChannels`/`withdrawHistory` purge all projections, not just
  the revoked channels' (Store.swift). Pairs naturally with the merged #131
  contract. (2026-11-23 epic-chicken pass) `[V]`
- Store permission hardening still uses `try?` where staging uses `try`
  (Store.swift:159,181). (2026-11-23 epic-chicken pass) `[H]`

---

## 11. Questions for the owner

1. **Background send retries (§3.4):** was `if NSApp.isActive` in #14
   deliberate? If not, retry in the background with per-operation backoff.
2. **`clearHistory()` (§3.2):** should projections survive, as the comment
   says?
3. **Errors (§6.3):** keep app-modal alerts as DECISIONS says, or route
   failures whose window is still current to the window's status row or a
   sheet?
4. **Unread boundary on Jump to Latest:** `TranscriptReadPosition.caughtUp()`
   sets the boundary to the frontier, which is nil when nothing has been
   observed yet; `resolvedVisit` stays true, so the divider will not return
   for that position. Keeping
   the old boundary instead would show later-loaded rows as unread although
   the reader jumped to the latest. Which is intended? If the old boundary
   should stay, the change is `if let frontier { boundary = frontier }`
   (TranscriptReadPosition.swift:118-121) with a unit test in
   `TranscriptReadPositionTests` for Jump to Latest before any row arrives.
   NM-17 (§9.2) would add a return point to the same action.
5. **Notification previews (§7.1):** which preview levels to offer, and the
   default. #88 offers three and keeps the generic body as the default.
6. **Favorites shortcuts (§6.5):** ⌥⌘1-9, or move collections off ⌘1-⌘6?
7. **Spotlight:** still out of scope?
8. **Adding an account (§3.5):** signing in to another account switches the
   most recently created window. Should it switch the frontmost window, or
   open a new one?
9. **Draft pencil and muted bell (#100):** one slot after the title shows
   the pencil when a muted conversation has a draft (VoiceOver says both).
   Keep that, or show both marks?

---

## 12. Checked and rejected

So these are not raised again.

- "Search shows 'No messages match' while the server search is still
  running": an earlier pass could not reproduce it, but `showCached` has
  published `.loaded([])` for an empty cache since #49, so the empty state
  could show "No messages match" while the server search was in flight.
  #115 keeps the tab loading until the server answers and documents
  `fromCache` as result-set-wide.
- "Attachment names show percent escapes": `URL.lastPathComponent` decodes
  them, and `URL(string:)` accepts spaces on macOS 14 and later (tested).
- "UpdateNoticeView leaks its observer": it uses the selector-based
  `addObserver`, which is removed automatically.
- "Older drafts fail to decode": `Draft.attachments` and `caret` exist since
  the first commit (142d120).
- "Saved searches without `savedOnly`/`mentionsMe` are dropped": both keys
  exist since the first Codable version (e5e4207).
- "Per-byte response reading is a major cost": about 10 ms per MB on the
  client actor (§4.5).
- "A malformed presence payload marks the user inactive": `JSONValue.bool`
  is non-optional and false for a missing key, unchanged behavior; Raven
  always sends `active`.
- "Taglines in the Theme menu": the owner wants no theme taglines in the UI.
- "Make errors window-modal": conflicts with DECISIONS; asked in §11 instead.
- "`reveal()` routes around the revoked-channel guard" (review of #37):
  `open(session:channel:anchor:)` never checked revocation; the guard is in
  `CollectionWindow.open()` before either path runs, and notification
  responses only resolve channels in `session.channels`.
- "The presence self-check asserts before the main-queue refresh runs"
  (review of #39): posting on the main thread to a `queue: .main` observer
  runs the block before `post` returns, and the row's accessibility label is
  set statically in `configure`, so the passing check proves the refresh ran.
- "`.bool` won't fire for a number-encoded `is_edited`" (review of #59):
  `JSONValue.bool` (RavenProtocol/Models.swift:29) is true for a non-zero
  number and for `"1"`/`"true"`; SwiftyJSON is not used.
- "`notifiedIDs` mutations race across suspension points" (review of #56):
  `notifiedIDs` and `deliverNotification` belong to the `@MainActor`
  `AccountSession`, not to `TimestampEnvironmentObservation`, so they resume
  on the main actor.
- "Mention HTML inserted into Markdown source is not escaped" (review of
  #55): it is built by `RichTextCodec.html`, which escapes every text node
  and attribute value through `RichTextCodec.escape`.
- "The sidebar's delayed open can open a different conversation after rows
  move" (review of #48): a reload re-selected the conversation already
  shown, so a matching index landed on it and the open did nothing. The real
  defect was that the reload dropped the arrowed selection; #48 fixes that.
- "The Services skip fails if `NSApp.servicesMenu` is another instance"
  (review of #63): MainMenu.swift:50-53 registers the same `NSMenu` it
  attaches.
- "NSTableView sends its row action for keyboard selection changes, so each
  arrow press opens a conversation at once" (review of #48): it sends the
  action for clicks only. The self-check feeds a real key event through
  `NSTableView.keyDown` and asserts the shown conversation is unchanged
  right after the press; it passes locally and in CI.
- "Home is inaccessible by Tab" (walkthrough review): did not reproduce.
  With ordinary Tab the route was sidebar and toolbar search; with Full
  Keyboard Access, Tab reached Home's controls (NM-06, §6.6).
- "A line starting with `--` need not be escaped" (review of #47): a line
  of `--` under paragraph text is a setext heading underline, so the escape
  is needed there; `--x` gets a redundant but harmless backslash.
- "`memoryMessages` should keep `suffix(1500)` instead of `prefix(1500)` on
  older loads" (2026-11-18 helper review): the older window is deliberately
  kept because rendering slices around `historyUpperID`, and the dropped live
  tail is reloaded by the next reconciliation. Not a defect.
- "`Dictionary(uniqueKeysWithValues:)` at Session.swift:583 can trap on
  duplicate message IDs" (2026-11-18 helper review): `memoryMessages` is
  unique by construction and rows merge via subscript, not the trap. Not
  exploitable.
- "Deletion reconciliation drops a row tied on the page's oldest
  timestamp" (helper review, Reconciliation.swift:16): Raven's
  `get_messages` orders by `creation desc, name desc` (chat_stream.py), the
  same `(creation, id)` tuple `observedDeletions` uses, so every cached row
  at or above the page's lowest tuple is in the page unless deleted. Holds
  while Raven names compare the same in MariaDB and Swift (lowercase
  hashes).
- "Collection selection restore by `name` picks the wrong row" (review of
  #84): every collection lists one doctype, whose `name` is its primary key.
- "The notification raw-content fallback leaks spoilers" (review of #88):
  the fallback runs only for empty `text`; for Image, File and Poll rows
  `content` is Raven's derived teaser (file name, poll question).
- "`updateRooms()` is skipped when access returns" (review of #93): the
  observer's guard is `!added.isEmpty || !removed.isEmpty`.
- "Escape with marked text may never reach `super`" (review of #106):
  `ComposerView.keyDown` falls through to `super.keyDown`, and nothing in
  the view overrides `cancelOperation` or `doCommand`.
- "The sidebar's Show Archived Conversations title is static" (review of
  #89): validation checkmarks it, as in the View menu.
- "A top-inserted table row must move into `<tbody>`" (review of #79):
  native header styling reads the cell tag (`NativeTables.swift`,
  `RichTextAdapter.swift`), the codec round-trips an all-`td` row inside
  `<thead>`, a leading `<tbody>` is non-conforming HTML the server parser
  may normalize, and `TableEditorSheet.addRow()` inserts below the
  selection, so `index == 0` is API-only. The placement is pinned by a test.
- "`RavenChannel.id` reads `raw["id"]`" (review of #80): it reads
  `raw["name"]` (`Sources/RavenProtocol/Models.swift:65`), so the
  deep-chain fixture that sets `name` is the correct one.
- "Ancestry deeper than eight is corruption" (review of #80): the visited
  set terminates every walk; only a cycle fails closed. Deep acyclic chains
  are walked to their end, and a missing ancestor ends the walk as open.
- "Clearing a collection filter fires `applySearch` three times" (review
  of #82): `CollectionWindow` implements no `controlTextDidChange:` or
  `controlTextDidEndEditing:` handler and the field uses target/action, so
  programmatic clearing runs it once.
- "The File panel and the attachment window close on another account's
  activity" (2026-11-20 pass): both observe `.sessionChanged` with
  `object: nil`, but the observer guards on `active()`, and
  `attachmentActivity` compares `self.isCurrent(session)`. Another
  account's change cannot make it false, so the panel stays open.
- "`SearchThreads.ids` needs a channel tiebreak" (review of #118): the
  thread id is the document primary key, so the same id cannot name two
  different parents; the id tiebreak is the whole ordering guarantee.

The grouped-reply timestamp audit was stale on `d86965c`. The renderer
records `bodyStart` before appending the quote, so it equals the row start
for a continued message. A native assertion at the first character of the
grouped quote passed without changing production code.

From the 2026-11-23 epic-chicken pass:
- "`ChannelDetails.rows` passes `deleted` as a revoked set": pinned intent,
  not a bug. `ChannelDetailsTests.revokedOrDeletedChannelsExposeNoStaleFields`
  asserts a channel ID in `deleted` yields no rows, and the second
  `isRevoked` call covers the real revoked set, so the two calls are a
  union. No change.
- "`RavenClient` leaks an ephemeral `URLSession`": already fixed —
  `deinit`/`invalidate()`/`revoke()` now tear it down (#117).
- "Menu bar 'Check for Updates…' never becomes 'Update Available…'": already
  handled via `refreshUpdateMenuTitles()` (AppUpdateController.swift:163-167).
- "'Schedule Message' accepts a marker-only draft": already guarded via
  `hasText` (#109).

---

- "One failed `writeHistory` permanently wedges later history writes" and
  "`refreshAfterInflight` returns the shadowed old task": both were false
  positives found on review of PRs #162 and #154 (closed). `Task.result`
  returns a `Result` and never throws, and `if let task` shadows only inside
  the if body, so `return task` already re-read the property.

## 13. Validation record

The walkthrough review's record. The code review's method is in the
introduction; its checks are listed with each entry and in §1.

**Build and host.** Clean detached checkout of commit `5ada162f2b1c`, Apple Development-signed Release 0.1.0 beta 5, macOS 26 deployment target. Ran on arm64 Mac16,9 with 36 GiB and macOS 27.0.1 build 26A434, using Swift 6.4.2. The executable SHA-256 is `ca1f2c1bb48275aed13e32f24a78cfd1edb493e7d54118603c71711b6b68136a`. Build/signature and plist checks passed. The Release compiler reproduced the actor-isolation warning in NM-A1.

**Automated baseline.** `swift test --disable-keychain --triple arm64-apple-macosx26.0` passed 279 XCTest and 425 Swift Testing cases. The three performance-driver unit tests, 32 packaged rich-text checks, and 10 packaged sound checks passed. The isolated sound/settings fixture passed 15 checks.

The baseline signed app passed its demo native self-check. No real Raven user account was connected. Browser SSO, speech quality throughout the app and idle behavior against a live server remain unverified. The repository documents a preset OAuth client ID but supplies no authoritative mapping to a site origin. PR #62 preserves manual IDs and describes the preset as site-specific. Origin-based automatic clearing would require that mapping.

### 13.1 Release measurements

`python3 scripts/check-performance.py --idle-seconds 300` completed, including fixture cleanup. The large channel retained 1,000 of 10,000 messages and displayed 500. The account fixture and the ten loopback send acknowledgements used synthetic data. Native code blocks, tables, formatting, emoji shortcodes and multilingual messages were included. Downloaded media, multiple live accounts, and reference macOS 26 hardware remain unmeasured.

| Metric | Result | Project target |
| --- | ---: | --- |
| Cached launch, p50 / p95, 5 launches | 554.14 / 627.60 ms | <2,000 ms, pass |
| Cached conversation switch, p50 / p95, 20 samples | 60.46 / 105.88 ms | <100 ms, **miss** |
| Queued-send action feedback, p50 / p95, 5 samples | 20.74 / 35.65 ms | <100 ms, pass |
| Durable enqueue transaction, p50 / p95, 20 samples | 0.64 / 1.25 ms | Diagnostic |
| Scroll layout/display step, p50 / p95, 20 samples | 0.108 / 0.205 ms | CPU-side diagnostic |
| Physical footprint, start / end of idle | 86.85 / 79.86 MB | <200 MB settled, pass |
| Resident bytes, start / end of idle | 152.32 / 61.80 MB | Diagnostic |
| Idle CPU, 302.57 seconds | 0.0169% of one core | <0.5%, pass |

After the driver reached its idle sample, the manual demo and Instruments trials ran separately on the same Mac. These results characterize one app process on a shared desktop. The [9 November signed Release run](docs/implementation/performance/2026-11-09-packaged-final.json) on the same Mac model recorded 296 ms p95 launch, 77.57 ms p95 switch, 3.28 ms p95 send feedback, 47.22 MB settled footprint and 0.0069% idle CPU. The two runs use different revisions and desktop conditions. Treat the current switch miss as a lead for a repeatable comparison, with NM-08 as one candidate. An isolated headless Release seed completed in 3,886 ms. Seed time is outside cached launch.

A second Release run with a five-second idle interval measured **94.82 ms p95** cached switch, **508.71 ms p95** cached launch, **18.84 ms p95** queued-send action feedback, and **85.53 MB** settled footprint. Both runs completed all ten loopback sends. The switch p95 straddles the 100 ms target, so more repeated, controlled samples would be needed to attribute a regression.

A third five-second run on the same machine measured 463.87 ms p95 cached launch, 91.51 ms p95 cached switch, 17.65 ms p95 send feedback and 85.28 MB footprint.

With both thread-list responses held for two seconds, the Release search fixture on main first displayed its cached hit just after two seconds. PR #49 displayed it in 24, 65 and 23 ms across three runs. The final signed fixture also checked selection, duplicate suppression and access filtering. These observations describe time to the local result.

PR #60 also measured the cost of finding affected thread IDs after a membership change. An optimized Swift run with 100 withdrawn rooms and 2,000 known threads found the same 1,100 IDs in four comparisons. The per-room traversal took 52.77 to 54.48 ms. The combined traversal took 0.50 to 0.53 ms. This measures the ancestry calculation and excludes database and network work.

### 13.2 Window capture timing

The signed Release app displayed the 500-message large transcript at 1,080 × 760 pt on the M4 Max. A window-scoped ScreenCaptureKit stream requested 60 Hz, excluded the cursor, recorded the display timestamp of each complete changed frame, and retained no images. Each four-second trial sent 240 pixel-scroll events to that window, reversing once per second. The two trials recorded 136 and 130 intervals. The median intervals were 17.52 and 17.55 ms, the 95th percentiles 99.01 and 99.85 ms, and the maxima 100.16 and 100.57 ms. Both had 34 intervals above 25 ms. ScreenCaptureKit can coalesce identical frames. These are observed changes in captured window content, and do not identify which intervals were caused by the renderer, by input at a scroll boundary, or by capture scheduling. Compare against a simple continuously moving control and record visible offset before using these results to attribute stutter. These two attempts covered formatted text and tables.

Three additional four-second captures used the same Release sources, hardware and 500-message fixture, with a temporary driver for repeatable input. The app confirmed three visible six-frame GIFs, 30 typed characters interleaved with ten incoming messages, and live resize between 1,080 and 1,260 pt. The densely scripted resize reached its first quarter before the time budget expired. Only the target window was captured. The p50 / p95 / maximum intervals between changed frames were 17.42 / 49.34 / 84.04 ms for GIFs (191 intervals), 17.35 / 81.12 / 119.77 ms for typing with incoming traffic (167), and 17.31 / 28.48 / 124.79 ms for resize (205). The GIFs intentionally advance every 80 ms and the typing and arrival inputs are intermittent. These runs establish workload-specific baselines. A separate 10 Hz resize script completed its whole sweep and emitted the completion marker. Its 47 captured changes had a 17.70 ms median, 448.77 ms p95 and 898.58 ms maximum. The different input cadence and low count make these numbers unsuitable for comparison with the dense resize trial. A repeated comparison with matched input and an attributed renderer trace is needed before assigning delays to AppKit layout or image decoding.

### 13.3 Interactive walkthrough

- **Onboarding.** The isolated no-account launch showed Add Raven Account with the site field selected. Accessibility exposed both field labels. Visually, prefilled values hide the placeholders, so the app began with two unlabeled fields and an always-prefilled OAuth client ID. PR #62 adds visible field labels and identifies the ID as site-specific. Test a valid unfamiliar origin, a configured origin, and an invalid origin, keeping the lookup link scoped to the entered site. Browser authentication was outside this synthetic pass. The callback-isolation executable passed all three checks.
- **Home and Search.** Home's unread and Later actions were visible at 1,080 pt. Full Keyboard Access reached the unread actions. A keyboard search for `release` returned three grouped results with visible term highlighting. At 658 × 480 pt, grouping and results held, but many filter chips were clipped and the query moved into toolbar overflow. See NM-06 and NM-07.
- **Conversation, composer and thread.** Verified scrolling to earlier engineering messages, grouped authors, code and quoted replies, and a visible Jump to Latest. The synthetic draft `audit draft` survived a trip to Home and back. Exercised Make Text Bigger from the View menu. Opened a seeded thread and confirmed that resizing through 950 pt discards the inspector. See NM-23.
- **Settings and appearance.** Opened General Settings and inspected the native control groups. Compared dark Classic and Nevermore with light Meadow. Nevermore's ornamentation gives the transcript a distinct identity. Meadow's pale glass makes ancillary composer glyphs and placeholder copy harder to distinguish in the observed frame. The visual follow-up is to audit actual composed foreground/background pairs and use a clearer toolbar/placeholder role wherever they fail the app's text or component targets. With Increase Contrast on, the transcript wallpaper disappeared and the toolbar and date rules became clearer. Selected Meadow while Reduce Motion was confirmed on and captured its settled appearance. A complete animation-timing comparison remains open.
- **Assistive technology.** Ran a brief Home VoiceOver traversal with the OS setting confirmed on, and inspected the AX navigation targets. Spoken phrasing, rotor coverage, and a full reading order matrix remain open. Restored VoiceOver, Increase Contrast, Reduce Motion, and Full Keyboard Access to their initial off states.
- **Frame delivery.** Ran two bounded Animation Hitches captures during direct scroll and 1,080 → 840 → 1,080 pt resizing. The application visibly scrolled and the resize operation succeeded. Both recordings reached their time limits, then failed to finalize. Instruments left two large temporary trace files despite the limits. The trace writers exited and both files were removed. These traces did not yield compositor hitch counts. The separate ScreenCaptureKit estimates above report changes visible in the captured window. Use a tool that demonstrably stops its trace writer and bounds file growth before repeating this experiment.

### 13.4 NM-24 · Attachment press checks passed on the exclusive desktop

On 18 November 2026, both attachment-link press checks and the attachment-name click passed in two exclusive-desktop runs of the Apple Development-signed arm64 Release bundle at `5fa6bbbe8c5c7aec7b1e3adc70104beae8dc6fcc`. The host ran macOS 27.0.1 and the app targeted macOS 26. Both runs used synthetic loopback data and the normal bundle identity.

- `python3 scripts/check-native-attachments.py --user-session --polls --reactions --avatars` exited successfully with 1,154 passing lines.
- `python3 scripts/check-native-attachments.py --save-panel --polls --reactions --avatars` exited successfully with 1,156 passing lines. Save As exported the expected bytes and quarantine metadata outside the sandbox. Closing the attachment window canceled the second save sheet.

This closes the baseline reproduction task. The earlier shared-desktop runs did not record the individual probe values, so their precise failure remains unknown. If it recurs, record `tracked`, `rendered`, both edit counts and the retained-link lifetime. PR #44 covers reaction-chip presses separately.

### 13.5 File inspector follow-up verification

A signed Debug build of the File retry change passed all eight new loopback assertions on the shared development Mac, including the count of HTTP requests for each action. The full local run recorded six failures in draft-link previews, Edit-menu Undo and theme persistence. An unchanged Debug baseline showed three composer shortcut failures and reached its time limit after an unexpected demo-mode alert was dismissed. Another Nevermore process was present during that comparison. These runs do not establish the cause of the broader failures.

The packaged Release build reproduced all 12 File-panel failures reported by native CI on the first PR revision. After the retry fix at `51681d5`, the same checks passed locally. The full Release fixture recorded 1,380 passes and zero failures, including an access-revocation check and exact request counts for all three retry actions. The external Save As sheet was skipped in that run. The earlier release timings remain the performance baseline.

### 13.6 Code Reader, Search, typography, and File retry verification

The macOS 26-targeted Swift suite passed with the four patches applied
together. Eleven Python tests for the native fixture driver and packaging
lint also passed. Each primary AppKit regression failed on the baseline
product code and passed after the change. The expanded reading-size
checks passed in the subsequent Release run. The fixtures used synthetic
loopback responses.

A local Debug store probe seeded 1,000 messages in one conversation with
roughly 360 bytes of body text each. Across 20 repetitions after a warmup,
the median for loading the page and finding the target was 27.6 ms.
The exact lookup took 1.04 ms median and returned the same payload each
time. This measures the store path on the test Mac. Frame delivery remains
covered by the measurement proposal in §4.7.

Two local combined runs overlapped another Nevermore process. The Debug
run reported the new regression checks as passing and exposed failures
around transcript presses and Quick Look focus. The later Release run
passed the expanded typography and attachment retry checks, then reached
its 240-second deadline. Verify broad native behavior in the independent
CI runs. For a focused press investigation, reproduce as the sole
Nevermore instance and log the probe values below.

### 13.7 Epic-chicken verification

`swift test --disable-keychain --triple arm64-apple-macosx26.0` passed on
the final head of each PR: 383 tests in 31 suites for #77, 382 for #79, and
381 each for #80 and #82. A Debug build of #82 ran the full
`--demo --self-check`: 1,328 checks passed with zero failures, including six
new collection-Escape assertions, and the suite was rerun after the final
field-editor change with the same result. Each new unit expectation was
observed failing against the unfixed source before it passed. No live Raven
connection, Instruments trace, signed Release run or GUI screenshot came
from this worktree; CI carries those checks.

### 13.8 Epic-chicken second-pass verification

`swift test --disable-keychain --triple arm64-apple-macosx26.0` passed on
the final head of each PR: 383 XCTest in 31 suites plus 80 Swift Testing in
6 suites on `627a0fb`, 84 Swift Testing after #117, and 384 XCTest after
#118. The new expectations were observed failing against the unfixed source
before they passed (the thread tiebreak test and the session-invalidation
suite). All three PRs carry green Native Mac checks and a completed GLM
review on the merged head. No live Raven connection, Instruments trace,
signed Release run or GUI screenshot came from this worktree.

### 13.9 Epic-chicken follow-up verification

Built the macOS 26-targeted debug app with Xcode 27.2. The unpackaged
native suite ran the grouped-reply probe and the nine new chooser
assertions. Its packaged-resource check requires an app bundle, and
focus-dependent press and formatting checks varied across bare runs.
The review used local fixtures. The interactive screen and frame timing
still need a dedicated pass.

### 13.10 Nevermore sweep verification

Baseline `swift test --triple "$(uname -m)-apple-macosx26.0"` passed 406
tests in 34 suites on `d86965c`. A debug `--demo --self-check` run recorded
1,448 PASS and two failures, both the focus-dependent flakes documented in
§14 while another Nevermore instance drove the desktop; no failure was
attributed to the product. Targeted suites passed for each change:
`StoreTests` (25 tests) and `InkPlanTests` (8), and the emoji module passed
its own assertions, including the new paged-failure case that fails without
the fix. No live Raven connection, Instruments trace or GUI screenshot came
from this worktree; Native Mac checks run in CI.

### 13.11 Epic-chicken audit-pass verification

`swift test --triple "$(uname -m)-apple-macosx26.0"` passed 407 tests in 34
suites on the audit-pass branches. Each new AppKit expectation was observed
failing against the unfixed source before it passed: the placement check on
the base revision, the search check with `tabChanged` unchanged, and the
`HomeDigestTests` actionable set before the digest change. A Debug
`build-app.sh` build ran the full `--demo --self-check`; a first run showed
six focus-dependent failures while other agents drove the shared desktop,
and a clean rerun passed with zero failures. No live Raven connection,
signed Release run or GUI screenshot came from this pass; CI carries those.
The bounded LongCat audits of the session, store/Home and transcript shell
independently re-derived the selection-restore defect that #145 fixes, and
added the `visibleAnchor` scan, the rotor fallback and the HomeFeed entries
recorded above.

### 13.12 Independent pass verification

Baseline `swift test --disable-keychain --triple "$(uname -m)-apple-macosx26.0"`
passed 406 tests in 34 suites on `e9a2041`. Each new expectation was observed
failing on the unfixed source before it passed: the transient OAuth code, the
long-message snippet, the withdrawn receipt, Home's content after an account
switch, and the repeated page cache's FTS rowids. The Home case ran in a Debug
`build-app.sh` bundle through a temporary `--home-only` early exit that was
removed before committing, and the Home module then passed with zero failures.
The other four ran their targeted suites plus the full package suite (287
XCTest, 89 protocol and 406 core tests, all passing). Four of seven bounded
LongCat 2.5 audits produced no output within their limit; the three that
completed were checked against the cited code before any entry was kept. No
live Raven connection, signed Release run, Instruments trace or screenshot
came from this worktree; CI carries the native checks.

### 13.13 Epic-chicken task-pass verification

`swift build --target NevermoreApp` passed on each branch, and
`swift test --triple "$(uname -m)-apple-macosx26.0"` passed 406 tests in
34 suites on `fix/thread-inspector-refresh`, including the new
`testMessagesBeforeBoundaryReadsTheOlderPage`. Unpackaged Debug
`--demo --self-check` runs recorded 1,441 to 1,442 passes: #184 and #178
each failed only the expected packaged-resource check, and #170 added the
two documented shared-desktop press flakes in an earlier run. The first
#170 run exposed an observer token that was not retained and a demo
early-return that skipped registration; both were fixed before the
passing rerun. #186 adds no self-check because its mutation path needs a
loopback server; the change is build-verified and CI carries the suite.
No live Raven connection,
signed Release run, Instruments trace or GUI screenshot came from this
worktree. All four branches went through at least two GLM rounds; the
confirmed findings (observer retention, cancellation, paging boundary,
receipt band and dedupe, visit error visibility) were fixed, and the rest
were declined with code evidence in the PR threads.

---

## 14. Working notes for whoever picks this up

- **Concurrent worktrees:** this task ran several agents against the same
  repository at once, and one worktree was shared by more than one agent.
  Check `git worktree list` and `git branch -vv` before committing, and
  prefer a separate worktree (`git worktree add --detach <path> origin/main`)
  over checking out a branch another agent may be using. A copied `.build`
  cache needs its `workspace-state.json` paths rewritten.

- **Opus review verification (63194f6):** each branch ran `swift test` and
  the full `--demo --self-check`. More focus flakes seen while other agents
  drove the desktop: "an open row stays on its message across pointer
  moves and re-renders", "More Emoji… closes the row and opens the full
  picker", "Command-Return keeps its send meaning while suggestions are
  open" and "Shift-Return inserts a line break while suggestions are
  open". Each passed on a rerun.
- **Iterate on one self-check module:** a local, uncommitted
  `if CommandLine.arguments.contains("--<name>-only")` branch in
  `SelfCheck.swift`, placed after the demo window loads, runs one module
  in seconds instead of the whole suite in about fifteen minutes on a busy
  Mac. Remove it before committing.
- **Snapshot a hidden check window:** `bitmapImageRepForCachingDisplay` and
  `cacheDisplay(in:to:)` on the window's content view give a PNG without
  the desktop. The app is sandboxed, so write it under
  `FileManager.default.temporaryDirectory` (the container's `tmp`) and
  copy it out. The toolbar glass is not in the capture.

- **Swift audit verification (63194f6):** `swift test` passed (279 XCTest,
  381 Swift Testing); the Release `build-app.sh` passed with no new warnings;
  `--demo --self-check` ran 1,318 checks with only the three documented
  focus flakes. The follow-up PRs add unit tests for the update monitor,
  resource limit and channel policy, and native self-checks for the muted
  bell, attachment chip and celebration overlay.
- **Build and test:** `swift test --triple "$(uname -m)-apple-macosx26.0"`;
  `scripts/build-app.sh --debug` then
  `build/Nevermore.app/Contents/MacOS/Nevermore --demo --self-check` (hidden
  windows, exit 1 on any FAIL, about five minutes). Use `build-app.sh`, not
  `build.sh`, which opens Finder.
- **New worktree:** clone a sibling's build cache with
  `cp -c -R ../<sibling>/.build/. .build/` and fix the path in
  `.build/workspace-state.json`; a cold build clones GRDB's SQLite.
- **Self-check flakes when another app has focus:** "clipboard commands
  outside source mode…", "Edit menu enables Undo for source changes", the two
  transcript press checks, and the emoji picker sheet checks fail on
  unmodified `main` while another process drives the desktop. "X is stored
  as the chosen theme" fails when another process changes the theme
  defaults. Compare against a `main` run before blaming a change. On CI,
  "menu key equivalents are unique" failed because of system Services
  items until #63.
- **The Services menu is AppKit's:** items added to `NSApp.servicesMenu`
  lose their key equivalents, so tests about it need a fixture menu.
- **Press checks:** a press sent from inside an async self-check runs inside
  a main-queue job, so no main-actor work can run during it; deliver presses
  from the run loop (`RunLoop.main.perform`), as `holdPress` does. Presses
  into a window that cannot become key only focus it; call the view's
  `mouseDown` directly when the check is about the view's own tracking.
- **Popovers and focus:** an `NSPopover` whose content can become first
  responder hands the parent window's first responder to that content when
  it is ordered in (`_setUpFirstResponder`). Lists driven by an editor's keys
  should refuse first responder.
- **Reviews:** add the `zai-model:deep` label (forge label id 18) when
  opening a PR; the forge GLM reviewer edits one comment in place, with a
  `lastReviewedSha` marker.
- **Merging from the shell:** `POST /api/v1/repos/Goodvantage/Nevermore/
  pulls/<n>/merge` with `{"Do":"merge"}` and the token from
  `git credential fill` merges a mergeable PR (an empty 200 response is
  success). The combined commit status endpoint is
  `/commits/<sha>/status`; the GLM check being green only means the run
  finished, so read the PR comments for the actionable count.
- **Merge checks without a worktree:** `git merge-tree --write-tree
  --name-only origin/<a> origin/<b>` exits non-zero and names the files
  when two PR heads conflict (§1).
- **Tracing:** the walkthrough's Instruments Animation Hitches captures ran
  to their time limit, failed to finalize and left large temporary trace
  files (§13.3). Bound every tracer, and use a tool whose writer
  demonstrably stops before repeating that experiment.
- **Performance driver:** `python3 scripts/check-performance.py
  --idle-seconds 300` produces the §13.1 table; the second and third runs
  there used a five-second idle.

---

## 15. Deep-model pass of 2026-11-23 (consolidated findings)

Source: `tmp.md` from the `epic-chicken-mine` worktree, merged here. The pass
combined one full self-review with five bounded LongCat 2.5 audits (A:
transcript/window, B: composer, C: core/protocol, D: Home/Search/collections/
panels, E: shell/theme/onboarding). Tags: `[V]` verified in code, `[H]` high
confidence, `[P]` plausible. Items implemented by this pass carry their PR in
§1 and are marked DONE; the §1 table is authoritative for each PR's merge
status (final: all 29 implemented PRs merged; #132 closed as a duplicate of
#155; #154 and #162 closed as false positives, §12). Two helper findings
turned out to be false positives (§12). Everything else is open backlog.

### 15.1 Transcript and window (audit A)

- "Reply in Thread" offered inside a thread creates a nested thread
  server-side — DONE, #169 (menu, hover bar, menu validation and VoiceOver
  actions all gated; `openThread` in a thread replies in place).
- Message actions were offered on System events — DONE, #169 (System rows get
  only copy commands, matching Raven web).
- Hover bar is not repositioned when a render reflows text without scrolling —
  it can point at one message while its buttons act on another
  (ConversationWindow.swift:1330,:1351, ConversationShell.swift:1092-1149). [H]
- Thread inspector has no reply composer (Raven web's ThreadDrawer has one)
  (ThreadInspector.swift:41-62). [V]
- Anchored open never resumes auto-follow at the live edge; `requestedAnchor`
  is cleared only by followLatest/loadEarlier/deletion
  (ConversationWindow.swift:1407, UnreadAffordance.swift:10). [P]
- Thread inspector restores its selection by raw character offset
  (ThreadInspector.swift:113). [V]
- Context menu's "Open Code Reader…" re-parsed the message HTML — DONE, #168
  (uses `session.messageDocument(for:)`).
- Reply chosen while editing another message is silently dropped by the edit
  save, then reappears as a banner (ConversationWindow.swift:1912). [V]

### 15.2 Composer (audit B)

- Ordered-list renumber after leavingBlock / whole-line delete — DONE, #179.
- `sendGIF` could post the same GIF twice — DONE, #133 (`acceptingGIFs` keyed
  by channel + body, held through delivery and released in `release()`).
- Menu-driven caret format left the toolbar stale — DONE, #138 (refresh only
  when `sendAction` was handled).
- Formatting commands act only on the first of multiple selections
  (ConversationWindow.swift:142 etc.). [V]
- `MarkdownSourceFormatting` does not escape the selection. [H]
- Clear Formatting leaves inline-code background; list/quote commands only
  add, never unwrap; dead in Markdown mode (ComposerFormatting.swift:22,:67). [V]
- `pasteLinkingAddresses` multi-selection span bug (ComposerLinks.swift:261). [H]
- Formatting buttons lack VoiceOver on/off state
  (ComposerFormattingBar.swift:87) [H]; composer placeholder not AX-exposed
  (ConversationWindow.swift:40) — DONE, #188.
- `insertText` stale replacementRange after `prepareForTypedText`;
  undo checkpoint on rejected edit (ComposerTyping.swift:280). [P]
- Table cell editor has no mentions; inserted table rows/cols drop alignment
  (EditableRichTable.swift:70,:95); table at draft end not clickable to edit
  (ComposerTables.swift:34). [P]/[H]

### 15.3 Core and protocol (audit C)

- Buffered responses enforced the byte cap before status classification —
  DONE, #159 (`readBounded`; oversized 401 now refreshes, oversized 403 maps
  to its real status, padded error bodies still classify `exc_type`).
- v2 FTS migration never backfills `messages_fts` (Store.swift:241) — latent. [V]
- Download lease (512 MiB) covers streamed saves, not inline images/GIFs/
  avatars (DownloadedAttachment.swift:91). [V]
- `LinkPreviewLoader.imageData` lacks in-flight coalescing (:201). [V]
- Global 8 MiB RPC cap. [P]
- `MessageDocumentCache` parses before the cacheability check (:61) — parse
  is needed for rendering, so only the cost walk could move; low value. [V/P]
- `ReleaseCheck` drops manifest sha256/size from `ReleaseOffer` (dead API). [V]
- Store recovery / v3 migration aborting on one bad payload — DONE, #185.
- Real-time Task ordering, `SiteOrigin.normalize` loopback/port edges, PKCE
  constant-time compare, JSONValue payload bound, close GRDB queue in deinit. [P]

### 15.4 Home, search, collections, panels (audit D)

- `refreshAfterInflight` "shadowing" — FALSE POSITIVE, see §12.
- `CollectionWindow.restrictRevoked` does not drop `deletedIDs` rows. [V]
- PollWindow transient refresh failure erases the poll. [H] (product call)
- Empty poll retraction reported success — DONE, #151 (`PollError.noVote`).
- Home Mark All Read skipped conversations with no reported latest — DONE,
  #148 (falls back to the newest cached message; acted/skipped/unreadable
  reported truthfully).
- Attachment window showed saved-file actions before saving — DONE, #152.
- Home People card on `.failed` — DONE, #172.
- `SearchSideColumn.cancel` status clear — DONE, #173.
- Scheduled "Edit Text…" is a no-op for attachment-only messages. [H]
- SearchSideColumn silent when the parent thread is deleted. [V]
- CodeReaderWindow closes on any validate error. [H]
- MemberRoster per-keystroke refold — DONE, #183 (`SearchIndex`).
- Search preview cache — DONE, #174 (LRU).
- Home row date formatter per row + missing year — DONE, #171.

### 15.5 Shell, theme, onboarding (audit E)

- "writeHistory wedge" — FALSE POSITIVE, see §12.
- Re-login invalidating before the Keychain save — DONE, #163.
- Wrong-account "Mark All Notifications Read" — DONE, #164.
- clearHistory leaving decoded GIFs/link previews — DONE, #167.
- Window restoration saves only conversation windows, not collection
  windows (Inbox/Threads/…) (App.swift:169). [V]
- `lastConversation` is memory-only; Dock reopen after quit lands on Home
  (App.swift:91). [V]
- Account removal purges window restoration before knowing removal succeeded
  (App.swift:334). [V]
- Theme taglines in the gallery tooltip/AX help — DONE, #182.
- Theme ornaments redraw on every live-resize frame
  (ThemeBackdropView.swift:126). [H]
- Keyboard Shortcuts window is hand-written and already drifts (missing ⌃⌘G)
  (NativeShell.swift:106) — DONE, #190: generated from `NSApp.mainMenu`, HIG
  modifier order (⌃⌥⇧⌘), correct function-key glyphs, F1–F35 labels.
- `--demo` never activates the app (App.swift:123) — DONE, #189.
- Theme-editor drags re-apply chrome to every window per step
  (ThemeIntegration.swift:19). [H]

### 15.6 Own-pass findings beyond the audits (from tmp.md §2)

- `deliverNotification` bypassed the `read` seam — DONE, #132 (now reads via
  `read`, page widened to 50).
- `message_deleted` durability is fire-and-forget (Session.event spawns an
  unawaited delete task). [P]
- `Session.stop()` leaves `realtimeLive` true and does not clear
  draft-related caches (`draftChannelIDs`, `composerModes`, `sharedTextStorage`,
  `draftUndoManagers`, `draftRevisions`, `pendingVisitWrites`,
  `approvedOldSends`, `mentionedChannels`). [P]
- `App.add` switches `windows.last`, not the frontmost window (App.swift:248)
  — related owner question in §11 item 8. [V]

### 15.7 Novel ideas from this pass (additions to §9)

- Restoration feather: fly one feather from the sidebar onto a restored
  conversation row (reuse `UnkindnessController.fly`); static under Reduce
  Motion.
- Day-ink divider: deterministic subtle ink tint derived from the calendar
  date for the day divider / floating day pill.
- Account-switch flight: the old account's perched raven flies off and the new
  account's arrives when a window switches accounts.
- Ink-bleed theme cards: one-shot ink-bleed edge on gallery cards when first
  shown/hovered.
- Feather drag cursor while carrying a sticker/emoji.
- Ink anchor for Jump to Latest: a feather in the gutter at the parked
  position plus one-shot "Back to where you were" (extends NM-17, §9.2).
- Inspector reply perch: a narrow glass-quill composer sliding up from the
  thread inspector footer with the root message as reply context.
- System events as quiet centered ink rules with a quill mark and no actions.
- Day-pill shadow + feather left at the divider when crossing into a new day.
- Hover-bar ink blot: a press leaves a brief wet-ink blot that dries into the
  button highlight, tying into the Wet Ink send animation.

### 15.8 Verification notes for this pass

- Every PR branch was built and the full suite run locally
  (`swift build` / `swift test --triple "$(uname -m)-apple-macosx26.0"`,
  406 tests / 34 suites on the base, plus new tests where the target is
  package-testable: RavenClient boundary tests, SerializedWriteChain tests,
  SearchIndex equivalence, Store recovery/migration corruption tests).
- GLM review findings were addressed per PR (page widened to 50 with a
  boundary self-check, guard held through delivery, named error-body cap plus
  lenient error decode, truthful mark-read summary, cache-key calendar
  identifier, hoisted renumber anchors, sendAction-gated toolbar refresh).
- Two helper findings were closed as false positives after review (§12).
