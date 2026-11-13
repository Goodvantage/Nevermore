# Composer formatting

## Raven's contract

Checked against Raven `develop` `9b01029a92f790e999aab8973e428601261615d1`
and `main` `1771d07e04337d083973f518a938b1c60afa25c6`. Their editor configuration
is identical. This is public-source research, not live-server verification.

- The [editor configuration](https://github.com/frappe/raven/blob/9b01029a92f790e999aab8973e428601261615d1/apps/web/src/components/features/editor/useRavenEditor.ts)
  enables bold, italic, underline, strike, inline/fenced code, lists, quotes,
  horizontal rules, links, highlights, tables, mentions, emoji and spoilers.
- Headings, task lists, details, general text-alignment controls and inline image
  authoring are not enabled. Files belong to the attachment workflow.
- Raven stores HTML. Markdown-style typing shortcuts are an editor affordance,
  not a different message wire format.
- Raven Message's `text` is a Long Text field without an `ignore_xss_filter`
  exemption. Frappe's document-save sanitization applies even though Raven's
  message controller does not itself sanitize the field. Framework behavior was
  checked at Frappe version-16 `3d1284c5fdb52207a516a49bbf2fd186cb43b3ab`.
- Raven's dependency declaration includes Tiptap TableKit `^3.26.1`. Inspection of
  that version's [table serializer](https://unpkg.com/@tiptap/extension-table@3.26.1/src/table/table.ts),
  [column serializer](https://unpkg.com/@tiptap/extension-table@3.26.1/src/table/utilities/createColGroup.ts)
  and [cell alignment](https://unpkg.com/@tiptap/extension-table@3.26.1/src/utilities/parseAlign.ts)
  establishes `colgroup`/`col`, pixel `width`/`min-width`, cell `colwidth`, and cell
  `text-align: left|center|right`. Table-cell alignment is separate from the
  disabled general text-alignment extension.

No Raven/AGPL implementation was copied. Contract fixtures and implementation
are original. This does not establish compatibility with every deployed Raven
or Frappe version; live web/mobile interoperability remains unverified.

## Native editing

The compact toolbar uses the existing `ComposerView`, draft storage and shared
undo manager. It exposes formatting without changing send keys, attachment
routing, mention completion or conversation persistence. Highlight, inline-code
toggling, explicit code-block/rule authoring and table commands supplement the
existing formatting actions. Code-block conversion accepts ordinary paragraphs;
existing code-language metadata, entities, links, spoilers and other block
structures are left unchanged rather than flattened. Code text keeps its literal
whitespace.

Tables render through AppKit's native text tables. They are atomic inside the
flowing composer: deleting a whole table is allowed, but typing or formatting
part of its rendered representation is rejected. An internal fingerprint also
rejects partial copies and unmediated changes at serialization time.

The table button opens a native cell editor. It edits rich cell contents and
adds/removes rows and columns. The operation commits once or cancels without
changing the draft. Spans, header/body groups, semantic identities, column sizing
and cell alignment survive cell edits. Column changes update the corresponding
column metadata and total width. Cell undo resets when you change the selected
cell or table size; the sheet explains this, and Cancel still discards the whole
transaction. Native tables fit their pane rather than forcing an upstream pixel
width onto a narrow conversation window.

Limits are 50 rows and 20 columns. Merged cells support content editing; geometry
operations on merged tables are explicitly refused. Nested, malformed and larger
tables stay read only. CSS is not generally enabled: only bounded pixel sizing on
tables/columns and left/center/right cell alignment are accepted. Unsupported CSS
continues to make editing read only.

## Visual and Markdown modes

The conversation composer has **Visual** and **Markdown** modes in its toolbar.
Both occupy the same inline editor area. Drag its upper edge to resize it;
double-click the grip to restore automatic sizing. Manual height stays with the
window and is bounded by the conversation's available height.

The toolbar uses borderless formatting icons, an overflow menu, and an explicit
mode control. The text spans the composer width above a separate attachment,
emoji, and send row. Native theme colors apply in both appearances.

Visual uses the native rich-text adapter; Markdown hosts
`swift-markdown-engine` 0.14.0 in `NSHostingView`. Literal-source mode avoids
wiki-link transformations, syntax hiding, and smart input. The image service
performs no loading. No browser or remote editing service is involved.

Source clipboard commands use literal text, not the library's rich HTML/RTF copy
or whitespace-normalizing smart paste. Source drops accept text only. This keeps
code whitespace intact and avoids invoking an HTML image importer during Copy.
Other fields retain Cocoa's normal clipboard routing and validation. Copying
source includes its visible HTML islands and spoiler bodies. Inline source
formatting refuses cross-line selections instead of accidentally styling or
protecting only their first paragraph; use Visual mode for larger selections.
Multiline inline code uses newline entities to retain blank lines within its mark.

The Foundation-only `RavenMarkdown` bridge uses `swift-markdown` 0.7.3 and its
resolved `swift-cmark` parser, not a home-grown Markdown parser. Ordinary
CommonMark/GFM constructs become Raven HTML. Headings, task lists, ordinary
inline images and unsupported HTML fail conversion explicitly. GFM table
alignment becomes Raven cell metadata. Raven-only constructs, and cases where
ordinary Markdown would lose information, remain HTML islands. Export candidates
are re-imported and compared before use. Repeated switching preserves text,
spans, semantic identities and supported metadata.

Inline mode changes are undoable and use the conversation draft's undo history.
The local draft stores literal source, mode, and selection alongside its HTML.
Incomplete source is saved and shared between conversation windows even when
conversion fails. Send and Schedule validate the active source, never a cached
HTML body. Conversion failures leave the source visible with an inline error.
Older drafts without editor state open in Visual mode. Message wire payloads
remain Raven HTML.

Scheduled-message editing retains its separate transaction: **Use Text** commits
and **Cancel** leaves the original unchanged. Its isolated mode conversion still
resets local undo, as its UI explains. Table editors also remain transactional.
Account changes and window closure dismiss owned editor surfaces. Draft
comparisons use immutable copies because `NSTextView.attributedString()` exposes
mutable backing storage.

The core editor product is linked, not its optional code-highlighting or LaTeX
products. Licenses and the Swift Markdown notice ship in `Resources/Licenses`.
The app's identity, signing, deployment target, sandbox and distribution setup
are unchanged. No release or installation is part of this change.

## Verification

Core tests cover CommonMark/GFM output, source fixed points, escaped punctuation
and whitespace, nested marks, links, mentions, emoji, spoilers, byte/depth bounds,
unsafe input, table geometry, failed-mutation atomicity, spans, row groups,
column metadata and alignment.

Packaged native self-checks exercise toolbar formatting and undo, empty-composer
code/list authoring, partial-table protection, table insertion and undo, rich
cell editing, row changes, cancellation, stale commits, the real TextKit 2 source
surface, Visual/Markdown switching, invalid-source retention and private-editor
cleanup. These are disposable native fixtures, not live account tests.
