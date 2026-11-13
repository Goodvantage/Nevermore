# Native links search

The pinned Raven `raven/api/search.py` `search_links` contract (lines 567–755)
returns one row per distinct message/link projection, including links without
preview documents. Native search sends `search_text`, scalar `channel_id`,
`owner`, `saved` and `mentions_me`; pagination uses `start_after` and `limit=50`.
The returned `id` is the source message ID, not a link ID. Collection keys pair
that ID with the raw URL so multiple links in one message survive paging and
local filtering. Open navigates to the source message and never opens the URL.
Preview images are not downloaded; returned title, URL and message content are
inert text, with HTML content passing through the spoiler-masking rich codec.

Account and exact conversation scopes are supported. Workspace scope is
rejected with instructions to choose one of those scopes; this endpoint has no
workspace/channel-array parameter. Saved searches retain their existing Codable
shape with an additional `links` kind. Other search kinds still use the verified
`sqlite_search` contract and its existing 100-result limit.

An older site missing `search_links` shows an explicit failure and offers message
search as the alternative. It does not silently broaden scope or substitute an
incomplete cached-message scan for a complete link index. Collection refresh may
show a previously cached first page, explicitly labeled incomplete. Offset
pagination is the server contract, not a snapshot guarantee: concurrent writes
can shift rows between pages; refresh starts again. Link previews may also lag
fetching, so an absent title falls back to the URL. Live permission transitions
and deployed-version interoperability remain release acceptance work.

Review regressions reproduced corruption of literal `<T>`/entity text and disclosure
of spoiler-contained link metadata. The endpoint's `content` is already derived
plain text; labels preserve it literally. Raven extracts links before replacing
spoilers with `▒▒▒▒▒▒`, so any projection carrying that marker suppresses separate
URL/title fields. Without original HTML the client cannot classify which link was
hidden. This conservatively hides metadata for visible links in mixed messages too;
Open still navigates to the source message. The dedicated regressions pass after
these corrections; no live-link interoperability is claimed.
