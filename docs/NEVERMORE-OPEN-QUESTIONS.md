# Nevermore decisions and open questions

**Status:** reviewed 7 November 2026; external commitments remain unconfirmed.

This is the single decision register for the [plan](NEVERMORE-PLAN.md). It consolidates review PRs #1–#7. Resolve each item before its affected gate, record the answer and responsible person, then fold it into the plan. Unanswered questions do not approve defaults or establish staffing, access, funding, or measured feasibility. Keep credentials outside this document.

**Implementation update, 7 November 2026:** the owner authorized implementation and supplied a test-site URL, then deferred dedicated OAuth registration and live sign-in. Local development uses the defaults recorded in [implementation decisions](implementation/DECISIONS.md); [validation](implementation/VALIDATION.md) distinguishes passing local checks from the outstanding deployment and release gates. This does not establish external staffing, production credentials, operational ownership, or beta/1.0 acceptance.

**Validation update, 8 November 2026:** the owner created and authorized the test site's public OAuth client. Browser sign-in/consent, PKCE exchange, basic authenticated reads, a live connection and Keychain-backed restart recovery now pass on that Raven 3.1/Frappe 16 deployment. Other deployments, authentication providers, two-user permissions, message/media tests and production ownership remain open; no beta/1.0 gate is waived.

## External decisions and commitments

### 1. Test deployments, administrator access, and integration support

Which real Raven sites, installed Raven/Frappe revisions, and login providers must the first release support? Who supplies authorized test accounts and administrator coordination? Is Raven/Frappe maintainer time actually available, and who is the contact?

**Current proposal:** source-pinned fixtures plus real intended deployments; record the installed commit as well as the advertised version. Maintainer availability is an assumption, not a secured commitment. If unavailable, use reproducible local fixtures and upstream issue reports, record blocked contracts, and revise scope/schedule without assuming an upstream response deadline.

**Due:** before the affected milestone-0 integration experiments; confirm the support matrix before milestone 1. **Answer / responsible person:** pending.

### 2. Dedicated OAuth registration

Is administrator-created Nevermore OAuth registration acceptable for the first beta? Who creates it on each test site and confirms the exact redirect URI and public-client settings?

**Accepted on the supplied test deployment:** independent administrator registration, without reusing or repairing the official mobile registration. The app's Client ID input is resolved in plan §6.1; registration acceptability and site access for other deployments still require an owner answer.

**Due:** before milestone-0 browser-PKCE tests. **Answer / responsible person:** the owner created and authorized a dedicated public client on the supplied test deployment on 8 November 2026, then registered both the legacy and current callbacks when the app identity changed. Registration and administrator support for additional deployments remain pending.

### 3. Signing identity and distribution

Who owns the signing identity, final bundle identifier/callback scheme, update-signing keys, and update hosting? What is the fallback if the signed sandbox/Sparkle spike fails?

**Current proposal:** retain the plan's sandboxed direct-distribution baseline. A manually installed, signed/notarized download with update checks is a fallback to evaluate, not an approved replacement for Sparkle. If selected, revise §§5.2, 9–11 and test that distribution path; do not silently remove the sandbox or claim the existing update gate passed.

**Due:** identity/access before the relevant milestone-0 experiment; update-path decision at milestone-0 exit. **Answer / responsible person:** pending.

### 4. Supported Macs and contractual 1.0 requirements

Is macOS 15 the minimum, and is Intel a shipping requirement? Are quit-time notifications, application-layer cache encryption, or specific ERP workflows mandatory for 1.0? If workflows are mandatory, which actions and deployments must pass?

**Current proposal:** macOS 15 and both architectures while dependencies support them; running-app notifications are the beta baseline. Background push and app-layer encryption require separate validated designs; unsupported administration/actions use browser handoffs.

**Due:** before milestone 1; any contractual requirement changing a milestone-0 proof must be identified before that proof. **Answer / responsible person:** pending.

### 5. Recurring operations and service retirement

Who operates and funds signing/notarization, release/update hosting, key rotation, and the security contact after launch? If optional push is pursued, who owns provider credentials, relay operations, and privacy obligations? What will users be told, and what update/recovery path remains, if a service stops?

**Current proposal:** separate core release operations from optional push operations. No mandatory Nevermore relay, budget, or person is assumed.

**Due:** operating plan before public beta; approved ownership/budget and retirement policy before 1.0. Optional push needs its own commitments before development/advertising. **Answer / responsible person:** pending.

### 6. Upstream liaison and license-boundary review

Who evaluates, files, and follows up the optional §8 upstream proposals? Who reviews any contemplated upstream code/artwork reuse before it enters this independently implemented client?

**Current proposal:** core messaging must work without a Raven fork or assumed acceptance of new endpoints. Assign a liaison when pursuing a proposal; obtain an appropriate license review before reuse. Upstream contribution work is not itself the same as copying upstream code into Nevermore.

**Due:** before relying on an upstream change, starting optional provider work, or importing upstream material. **Answer / responsible person:** pending.

### 7. Compatibility and corpus maintenance

Who maintains the source-pinned contract manifest, deployment compatibility table, and sanitized golden rich-text corpus? Who supplies sanitized fixtures and reviews changes when a Raven/Frappe version or message construct changes?

**Current proposal:** maintain these artifacts alongside protocol/codec tests, add a deployment or construct only with passing fixtures and permission/privacy checks, and review the matrix for each release and supported upstream upgrade. This proposes a process; it does not assign a person or confirm their capacity.

**Due:** establish artifact responsibility in milestone 0, before milestone 1 relies on it; review at each release. **Answer / responsible person:** pending.

## Implementation and estimation work

### 8. Scope allocation, release tiers, and a credible estimate

Plan §10 now identifies milestone 2 as the earliest internal alpha, 3 as the earliest public beta, and 5 as 1.0; the §3 scope matrix also gates each tier. This resolves the missing labels, but does not fix missing work allocation or validate the estimate.

At milestone-0 exit, map every scope row to implementation and acceptance work. In particular, allocate channel browse/join/create/leave, alpha pins/saves and safe poll/document display, beta poll voting, reminder/schedule reads, document cards, and the promised composer constructs to their actual tiers. Count rich-text work across milestones 0–4, including corpus parity, selection, accessibility, and safe editing; do not estimate only late edge cases. Re-estimate or explicitly revise tier commitments before confirming the schedule. Adding detail to a milestone is not evidence that its current allowance is sufficient.

**Known arithmetic:** the milestone ranges sum to 20–30 engineer-weeks **before** the additional 25% contingency, hence 25–37.5 including it. This calculation does not validate scope or the four-to-six-month calendar allowance.

**Due:** milestone-0 exit, with re-estimation after prototypes; no public beta until all beta commitments pass or the scope is explicitly revised. **Estimate / responsible person:** pending.

### 9. Two-window drafts and typing indicators

**Drafts:** retain §4.4's supported alternatives: one shared draft session or explicitly separate drafts. Select and document the interaction during the native prototype; milestone 2 must demonstrate concurrent-window edits without silent last-writer-wins loss, including persistence/restart behavior. The existing safety requirement does not need an owner answer before it can be tested.

**Typing:** §7.1's room policy is not a release-scope commitment. Decide explicitly during milestone 0 whether to add optional display/send indicators to beta or defer them. If included, add a scope row and milestone work, test Frappe 15 and 16 separately, and degrade gracefully when handlers are absent. Never let typing block basic messaging.

**Implementation choice:** drafts now share account-scoped native text storage, revision-ordered persistence, import/acceptance barriers and recovery state across windows. Local native checks cover that behavior; restart, full-disk and real multi-account acceptance remain subject to the validation matrix. Typing scope remains unconfirmed.

**Due:** behavior/scope choice at milestone-0 exit; draft acceptance at milestone 2. **Remaining decisions, acceptance / responsible person:** pending.

## Questions resolved by text or pinned source

- **Read receipts:** the initial research inventory was incomplete. `raven.api.raven_message.get_message_readers(message_id)` exists in the inspected develop and stable-branch snapshots. It derives reader IDs from channel watermarks, with privacy exclusions; it supplies no exact read times. Keep the feature subject to deployment contract tests, not an assumption that `get_channel_members` exposes receipt data. See the [research follow-up](RAVEN-RESEARCH.md#later-read-receipts-and-message-permalinks-review-follow-up).
- **Canonical links:** the existing client builds `<origin>/<web base>/message/<encoded message ID>` and the web app resolves context. Plan §§4.3/6.2 now name this validated route separately from server-resolved document links. Validate custom bases, authorization, deleted targets, and thread links on supported deployments; no invented message-link RPC is needed.
- **Later:** the pinned web view groups saved messages and in-progress/completed reminders, backed by the existing save/reminder APIs. Plan §4.1 now defines it; it is neither an unidentified API nor a new Nevermore service.
- **OAuth Client ID entry:** plan §6.1 now requires an Advanced Add Site field before authorization, following the research's existing recommendation. Managed configuration profiles remain optional future work.
- **Contingency:** additive, as the original “plus” stated; §10 now spells out the arithmetic. Estimate sufficiency remains item 8.
- **“Privacy budgets”:** milestone 3 now verifies the existing privacy commitments in §§5.3/9 and measures the §11 performance budgets. No undefined numerical privacy budget is assumed.

These resolutions are source/text checks, not completed live-server experiments or permission to claim untested compatibility.

## PR dispositions

| PR | Decision | Reason and retained contribution |
| --- | --- | --- |
| [#1](https://github.com/L-K-M/Nevermore/pull/1) | Consolidate into #2; close without merging | Retain test-access/support question in item 1. Clarify contingency directly. The absent-receipt implication is disproved by the dedicated endpoint. |
| [#2](https://github.com/L-K-M/Nevermore/pull/2) | Amend and squash-merge | Best base: distinguishes proposed defaults from external commitments and identifies milestone-0 prerequisites. Expand this single register and link it from the plan. |
| [#3](https://github.com/L-K-M/Nevermore/pull/3) | Consolidate into #2; close without merging | Retain recurring operations, upstream liaison, reuse review, and rich-text estimating in items 5, 6, and 8; do not invent owners/budgets. |
| [#4](https://github.com/L-K-M/Nevermore/pull/4) | Consolidate into #2; close without merging | Fix privacy-gate wording; retain two-window validation in item 9. Resolve receipt/link questions from source rather than defer supported features. |
| [#5](https://github.com/L-K-M/Nevermore/pull/5) | Consolidate into #2; close without merging | Add Client ID input and tier labels; retain update fallback, typing scope, and access prerequisites in items 1, 3, and 9. Managed profiles are not made a new prerequisite. |
| [#6](https://github.com/L-K-M/Nevermore/pull/6) | Consolidate into #2; close without merging | Retain the substantive tier/milestone mismatch and maintenance ownership in items 7–8. Later is already mapped in the research and now defined accurately in the plan. |
| [#7](https://github.com/L-K-M/Nevermore/pull/7) | Consolidate into #2; close without merging | Preserve its combined access, operations, liaison, estimate, and draft concerns in items 1, 5, 6, 8, and 9; resolve the repeated permalink question from source. |

One squash commit keeps a coherent documentation change and a single maintained register. Review-local labels such as “PR-003” in the original submissions were not links to actual GitHub PRs and are not retained as dependencies.
