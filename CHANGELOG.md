# Changelog

## Unreleased

- Play GIFs in conversations. Uploaded GIFs and GIFs sent from Raven's
  GIF picker (hosted by KLIPY, GIPHY or Tenor) animate while they are in
  view and stay still under Reduce Motion. Settings ▸ GIFs turns loading
  GIFs in messages off; other remote images are never loaded.
- Send GIFs from KLIPY or GIPHY with Conversation ▸ Send GIF… (⌃⌘G) or
  the GIF button beside the composer. Search needs your own key from the
  service, kept in the Keychain. A GIF goes out as its own message, in the
  form Raven's web client shows, and carries a reply you were writing.

## 0.1.0-beta.3

- Add a compact message-formatting toolbar, including highlighting, inline
  code, code blocks, lists, quotes, rules and links.
- Add native table insertion and a rich cell editor with row/column controls.
  Preserve Raven's spans, column sizing and cell alignment. Merged cells support
  text edits; structural changes require an unmerged table.
- Switch between Visual and Markdown in the conversation composer without
  opening another editor. Drag the top edge to resize it, or double-click the
  grip to restore automatic sizing. Literal Markdown and unfinished drafts are
  saved locally; Raven-only formatting is preserved as HTML where needed.
- Give people without a profile photo a distinctive raven portrait in direct
  messages and the transcript. Front and profile views, varied silhouettes,
  plumage colors, crests, beaks and bold markings come from a stable hash of
  their Raven username. Portraits are generated entirely on your Mac;
  uploaded photos still take precedence.
- Distinguish channels from people with rounded-square tiles: a prominent
  `#` for ordinary channels and a lock for private channels, with colors
  seeded by the channel name and workspace. Keep thread and archive icons,
  and identify private channels in accessibility
  labels and tooltips.
- Check apps.goodvantage.cloud for new Nevermore versions after launch and
  daily, using beta or stable according to the running version. Offer a
  dismissible sidebar/menu notice and a one-time system notification.
  Manual checks and an automatic-check preference are in General settings.
  Downloads open in your browser; installation remains manual. Checks send
  no Raven credentials or account data.
- Start the conversation sidebar at 300 points wide. Apply the default after
  AppKit's first layout so it takes effect; you can still drag the divider
  to adjust it.

## 0.1.0-beta.2

- Show profile photos beside direct messages in the sidebar, including your
  own conversation. Keep presence indicators and a symbol when no photo is
  available. Photos use the existing account-scoped cache and update as they load.
- Keep unread ravens on their sidebar rows until the conversation is read,
  then give them one departure. Remove the unread-divider hop and the extra
  all-read farewell; the footer continues to show your connection status.
- Remember your conversation window's position and size across restarts,
  including the demo and launches without conversation restoration.
- Drop files across the chat window to attach them to the current draft,
  not just inside the message editor.
- Start the message editor at three lines tall, while retaining automatic
  growth for longer drafts and compact attachment, emoji, and send controls.

## 0.1.0-beta.1

- Settings ▸ General: the menu bar item shows a raven by default and
  offers a choice of icons (Raven, Raven Head, Feather, Bird, Speech
  Bubbles). The send key is a popup that names both choices, "Return
  sends, Shift-Return inserts a new line" and "Command-Return sends,
  Return inserts a new line", instead of a checkbox. The stored
  preference is unchanged.

- Themes: Settings ▸ Appearance and View ▸ Theme offer sixteen looks,
  from Classic (the native look, unchanged) to Memphis, Halloween, Neon
  Fun, Bubblegum, Nevermore, Synthwave, Vaporwave, Under the Sea, Meadow,
  Cosmic Sprinkles, Aurora, Lemonade, Peppermint, Midnight Cocoa and
  Phosphor. Themes color names, links and accents, tint the sidebar and
  composer glass, pick fonts, draw a wallpaper and play a short
  celebration when chosen. Every palette passes a contrast audit; the
  wallpaper and celebrations step aside for Increase Contrast and Reduce
  Motion.

- Repository guidance in `AGENTS.md` and `CICD.md`, with SHA-pinned CI
  and GLM PR review.

- `scripts/build.sh`: lkm-build entry point for local builds —
  `--install` replaces `/Applications/Nevermore.app`, `--zip`/`--dmg`
  package it. `build-app.sh` now defaults to Release and accepts
  `--debug`/`--release` (the `CONFIGURATION` env override still works).

- `build-app.sh` signs with one Apple Development certificate when the
  keychain holds several. It passed the bare name to codesign, which
  refused it as ambiguous and stopped `scripts/build.sh --install`
  before installing.

- Reacting to a message is one click: the hover bar's React button and
  Message → React… open a small row of eight emoji, led by your
  most-used reactions from Raven. The full picker moves behind its
  More Emoji… button. Your existing reactions are marked and a click
  removes them. Hover-bar buttons now show the arrow cursor and a hover
  highlight instead of the text I-beam, and stay put while the pointer
  moves onto them.

- The repository moved to the Goodvantage forge
  (forge.goodvantage.cloud). CI and the GLM review run on Forgejo
  Actions from `.forgejo/workflows/`: the macOS checks on the forge's
  Mac mini, never for fork pull requests. Dependabot is gone.

- Bundle and service identity moved to the Goodvantage namespace
  (`ch.goodvantage.Nevermore`). The OAuth redirect is now
  `ch.goodvantage.Nevermore://oauth`: register it on each Frappe site
  before signing in. Accounts, drafts and tokens stored under
  `ch.lkmc.Nevermore` are not migrated; add the accounts again.

- Releases: `scripts/release.sh X.Y.Z --push` tags a version, and the
  forge's release workflow tests it, signs it with the Goodvantage
  Developer ID, notarizes and staples the app and the DMG
  (`Nevermore-X.Y.Z-macos-universal.dmg`), attaches it to the forge
  release and publishes it on apps.goodvantage.cloud. A prerelease goes
  to the site's beta channel. The About panel shows the bundle's version
  instead of a fixed 0.1.0.

Earlier history lives in the commit log and docs/implementation/.
