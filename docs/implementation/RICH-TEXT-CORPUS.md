# Rich-text corpus · 7 November 2026

Offline, provenance-labeled fixtures for `RichTextCodec` in `Tests/NevermoreCoreTests/RichTextCorpusTests.swift`. The suite exercises parse, HTML export, plain text and safe URLs. Separate native self-checks cover the AppKit adapter, including unsupported edits, spoiler masking and clipboard metadata removal.

## Provenance

| Label | Source | Used for |
| --- | --- | --- |
| `[server]` | Pinned Raven `develop` `9b01029a92f790e999aab8973e428601261615d1`, `message_model.py` and `raven_message.py`; see [source research](../RAVEN-RESEARCH.md) | user mentions `span[data-type="userMention"][data-id]` (extract_mentions), custom emoji `img[data-type="customEmoji"]` with `alt=":name:"` and emoji-only-messages-are-non-empty (`raven_message.py`), spoilers masked by **attribute presence** `find_all(attrs={"data-spoiler": True})`, link extraction from `a[href]` |
| `[editor]` | `docs/RAVEN-RESEARCH.md` §2/§5, citing `useRavenEditor.ts` at the same commit | editor feature set: bold/italic/underline/strike, inline + fenced code, lists, blockquotes, links, highlights, tables, mentions, custom emoji, spoilers; headings/task lists/details **not** enabled |
| `[out]` | `Sources/NevermoreCore/MentionCompletion.swift` + the parser allowlist | Nevermore's own outgoing `span[data-type="userMention"\|"channelMention"][data-id][data-label]` markup |

**Not performed:** no running Raven/Frappe server, no web/mobile client execution. Every fixture is synthetic and offline, modeled on the contracts above. Nothing here is cross-client verified; the real web/mobile golden corpus remains a release gate (see `VALIDATION.md`).

## Corpus inventory (`RichTextCorpusTests.swift`, all tests prefixed `richTextCorpus`)

| Corpus id | Construct | Provenance | Key assertions |
| --- | --- | --- | --- |
| `mention-user` | user mention span | `[server]` + `[out]` | `data-type`/`data-id`/`data-label` and text preserved; model fixed point; plainText `Hi @Alex!` |
| `mention-channel` | channel mention span | `[out]` (cached server files do not cover channel mentions) | identity preserved; plainText `see #general` |
| `emoji-inline`, `emoji-only-message` | custom emoji `img` (relative `/files` and https src) | `[server]` | all five identity attrs preserved; plainText `:name:`; emoji-only message plain text non-empty |
| `spoiler-inline` | `data-spoiler="true"` span | `[server]` | plainText masks (`[Spoiler]`), reveal works, wire html keeps mark **and** body |
| `spoiler-complex` | nested spoilers / block wrappers / direct spoiler on `img` | parser policy | read-only warning, still masked in plainText |
| `spoiler-semantic-reload` | inline spoiler around mention/custom emoji | native authoring and codec | serialize/reload/edit/removal preserves one identity and masks previews |
| `spoiler-empty-attribute` | `data-spoiler=""` and bare `data-spoiler` | `[server]` presence semantics | masked, mark kept, fixed point — **exposed F1, now guarded (see F1)** |
| `edge-attribute-guards` | multi-token code class, invalid `ol start`, stray list text, class outside `pre>code` | codec policy | value kept or read-only warning, never silently normalized |
| `link-safe` | https+query, relative `/files`, mailto | `[server]`/`[editor]` | href/title preserved; fixed point |
| `link-unsafe` | `javascript:` (mixed case), `data:`, `//host`, userinfo, backslash, leading space, tab | codec contract | href dropped, warning, link text kept, no `href`/`onclick` in output |
| `url-matrix` | `safeURL` direct | codec contract | 6 allowed / 14 rejected spellings |
| `lists-nested-ordered` | nested `ul`/`ol` with `start` | `[editor]` | structure, `start="3"`/`start="4"`, order, fixed point |
| `code-language-whitespace` | `pre>code class="language-*"` with indent, blank lines, `< & "`, trailing newline; bare `pre` | `[editor]` | byte-exact code text in model and plainText; re-escaped on encode; class kept |
| `quote` | blockquote+p+strong+a, list-in-quote, nested quote | `[editor]` | editable cases round-trip; nested quote read-only, text kept, rawHTML retained |
| `table` | thead/tbody, `colspan`/`rowspan` | `[editor]` | bounded complete tables editable through the table transaction; spans kept; plainText tab/newline cells; fixed point |
| `unsupported-tags` | `h1`, `details`, `style=`, unknown `data-type` | `[editor]` | read-only, warning, visible text kept, rawHTML retained, unknown tag never emitted |
| `malicious` | script/style/iframe/object/embed/form/input/button/svg/math, `onclick`/`onerror`, `javascript:` link | codec dropped/allowlist | neutralized, idempotent re-sanitize, benign text kept |
| `image-sources` | `data:` emoji src, `mailto:` img src, https img with `onerror` | codec img rules | unsafe src dropped, emoji identity kept, fallback warning for non-emoji |
| `forged-document` | hand-built `RichDocument` | encoder contract | no event handlers/schemes/extra attrs emitted; invalid `start` dropped; spoiler still masked |
| `boundaries` | 1 MiB, depth 64, 20 000 nodes | codec limits | at-limit parses; over-limit throws `tooLarge`/`tooDeep` |
| `composite` | all of the above in one message | mix | identities in encoded html, text preserved, spoiler masked, fixed point |

Verification method (not whole-output snapshots): for editable cases, `parse(html(parse(x))).nodes == parse(x).nodes` (model fixed point) plus targeted attribute/text assertions; `rawHTML == input` for the read-only fallback; `plainText` for text preservation and spoiler privacy; `html()` output scanned for forbidden constructs.

The [composer-formatting extension](COMPOSER-FORMATTING.md) adds source conversion,
cell/geometry edits and fixtures for Raven's `colgroup`, pixel sizing and cell
alignment. Nested, malformed and oversized tables remain read only. Table text
is atomic in the flowing composer, so a partial native edit cannot silently
flatten its cells.

## Findings

### F1 — spoiler privacy regression, fixed

- **Symptom (first filtered run: `richTextCorpusSpoilerWithEmptyOrBareAttributeIsStillMasked` failed with 6 issues):** `<span data-spoiler="">secret</span>` or a bare `<span data-spoiler>` lost the spoiler — `plainText` returned the secret in clear, `html()` emitted `<span>secret</span>` with no mark, `canEdit` stayed `true`, and the mark was gone after `parse(html(parse(x)))`, i.e. an edit round-trip silently un-spoilered the message.
- **Cause:** `RichTextCodec.parse` dropped empty-valued attributes (`if !value.isEmpty { attrs[key] = … }`), while `plainText` and the adapter key off the parsed value being non-nil.
- **Contract divergence:** the pinned server masks by attribute **presence** — `message_model.py:143` `find_all(attrs={"data-spoiler": True})` — and Nevermore's own search index does the same (`Store.swift` `select("[data-spoiler]")`). `plainText` feeds channel/DM previews (`CollectionWindow.swift`), so it leaked content the server considers masked.
- **Fix:** the parser records `data-spoiler` by presence (`key == "data-spoiler" && element.hasAttr(key)`). Empty/bare spoilers are masked, re-encoded as `data-spoiler=""`, and survive the round trip. The native adapter also removes hidden spoiler subtrees before rendering or exporting reading text.

### F2–F6 — silent-normalization regressions, fixed

- **F2 — code language class.** Previously `class` was kept only as a single `language-[letter/number/-/_]` token, so `language-swift hljs` / `language-c++` were dropped silently with `canEdit == true` (while Unicode names passed — inconsistent). Now (`RichText.swift:94-101`) a single valid `language-*` token (chars `-_+#.`) plus optional `hljs` is preserved verbatim; anything else warns `Custom class formatting is read only.` and is read-only. `class` on inline code (outside `pre>code`) is also read-only now.
- **F3 — `ol start`.** Invalid/out-of-range `start` (`"-2"`, `"abc"`, `"100000"`) was dropped silently with `canEdit == true`; now warns `Unsupported list numbering is read only.` (`RichText.swift:90-92`).
- **F4 — stray text in lists.** `<ul>hello<li>a</li></ul>` passed the element-children-only check with `canEdit == true`; non-whitespace text children now warn `Complex list markup is read only.` (`RichText.swift:70`), while formatting whitespace stays editable.
- **F5 — unsafe image `src`.** A custom emoji with `data:` src used to lose `src` silently with `canEdit == true`; now warns `An unsafe image source was omitted; editing is read only.` (`RichText.swift:84`) and is read-only. `srcset`, `target`/`rel` remain dropped by the allowlist (safe; links/images still work).
- **F6 — encoder tag checks.** `html()` used to emit `class` on any tag and `colspan`/`rowspan` outside `td`/`th` for forged in-memory documents; now `class` is code-only and spans are `td`/`th`-only with a `1...100` range check (`RichText.swift:121-122`).

### F7 — remaining cosmetic divergence (no action proposed)

`plainText` concatenates inline runs without separators (`<strong>b</strong><em>i</em>` → `bi`), while the server preview uses `get_text(" ", strip=True)`. Cosmetic only: code/pre whitespace, entities, Unicode and emoji `:name:` are preserved exactly. Also noted: SwiftSoup keeps the newline right after `<pre>` where browsers drop one — Nevermore preserves it, which is the fidelity-safe direction.

## Check results

`swift test --filter richTextCorpus`: **21 tests pass**, including the reproduced spoiler failure and F2–F6 guards. These tests also pass in the complete 155-test run. See [validation](VALIDATION.md) for native checks and the outstanding live interoperability gates.
