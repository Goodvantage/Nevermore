# Attachments from native search results

File and image rows from the verified `sqlite_search` collection expose Quick
Look and Save Attachment buttons and context-menu actions. With the results
table focused, Space previews and Command-Shift-S saves; Return continues to
open the source message. Actions stay disabled for missing/invalid identities,
non-file rows, revoked projections and unavailable account/window state.

Search metadata locates a message, not a trusted download URL. Each user action
reads the canonical Raven Message through the current account's client, checks
its message/channel/type identity, then reuses the shared channel-context traversal through `channelReadContext` to read
canonical channel and thread-ancestor resources with server permission checks.
Archive status does not block reading. Only then does it resolve the canonical
`file` URL against the same account origin. Index `internal_link` values are never downloaded directly.
The existing bounded authenticated download creates a private quarantined
`DownloadedAttachment`; the existing AttachmentWindow owns Quick Look, explicit
Save As, export quarantine, private-file lifetime and cancellation of save sheets.
There is no separate export or unbounded in-memory download path.

The collection captures its source key, pager generation and selected identity.
It checks these and account/window/revocation/deletion state before and after
suspension, retaining canonical parent IDs for subsequent revocation checks. Selection/filter/page refresh, collection or parent closure, account
switch and permission changes invalidate pending work and close attachment
windows. No failed request is automatically replayed by the collection.

Pure tests cover index identity normalization, canonical identity/type mismatch,
and cross-origin/user-info/root-path rejection. Hidden native checks cover the
controls/keyboard routes and cancellation of suspended reads on selection,
revocation and close. Those checks inject only a demo canonical-read transport
and do not download, show sheets or use a live account. Existing attachment
checks cover quarantined export and Quick Look ownership. Live private-media
permissions and real Save As interaction remain release acceptance work.
