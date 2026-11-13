# Accessible status announcements

The status policy accepts two typed attention states and an opaque context token. Its only spoken messages are fixed generic instructions for account attention and lost conversation access. Error payloads, message bodies, people, site names and conversation titles are never announcement inputs.

Only the current account's foreground key conversation window can post an announcement. A sheet or active marked-text composition suppresses it. Suppressed transitions are observed and discarded, so returning to the window or finishing composition does not replay them. Repeated unchanged attention is silent; recovery or an account/conversation context change permits a new transition. State is bounded to one token and two status values, with no delayed queue.

`Session.fail` supplies typed account attention rather than parsing localized status text. Successful refresh clears it. Conversation access checks include revoked thread ancestors and deleted thread roots. Switching accounts, stopping a session and closing a window clear announcement metadata and fixture callbacks. User errors shown by `NSAlert` do not call the announcement adapter. Generic account attention has medium priority; loss of conversation access has high priority. Posting runs synchronously on the main actor.

Six policy unit tests pass using a temporary dependency-free package that compiles the real policy and test files in Swift 6 mode with the explicit macOS 15 triple and network access denied. The AppKit adapter type-checks against the current SDK with a minimal session stub; changed AppKit files pass syntax parsing. This does not establish a full application build or native execution result.

`StatusAnnouncementSelfChecks.run(owner:)` adds nine native checks with a demo-only captured-post callback for routing, fixed-copy privacy, deduplication, two-window focus, IME suppression, account switching, stopped contexts and closure. It does not load accounts or use network/credentials. The stopped-context check exercises the stop notification's routing state without destructively stopping the shared demo session. These checks are not yet wired into `SelfCheck.swift` and were not run in this slice. Demo self-check windows without a captured post remain silent; production accounts cannot install the callback.

## Manual VoiceOver gate

Native captured-post checks do not prove actual VoiceOver behavior. Before acceptance, run the signed app with VoiceOver on macOS 15 and a current macOS version:

- Trigger a synthetic connection failure with a private-looking error payload in the focused account window. Hear only generic account-attention instructions once. Verify the medium priority does not interrupt unrelated speech unnecessarily.
- Revoke access to a focused conversation and to a thread's parent. Hear generic access-loss instructions once, without a title, person, site or message body. Verify the higher priority remains usable.
- Repeat failures while the app is inactive, another account/window is key, a sheet is open, and marked text is composing in the composer or another text field. Hear no announcement and no deferred replay after returning or committing text.
- Receive background messages, presence updates and shared-draft changes. Hear no status announcement. Show a user-initiated error alert and verify that the alert is not followed by duplicate generic speech.
- Switch accounts/conversations, close the window, and stop the session while an old operation completes. Verify that no stale context speaks, and that a later fresh failure in the current context can announce.

Actual VoiceOver speech, localized announcement copy and the minimum-OS interaction matrix remain manual validation gates.
