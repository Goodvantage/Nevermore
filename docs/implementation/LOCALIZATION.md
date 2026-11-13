# Status localization boundary

`NevermoreCore.StatusLocalization` owns stable, typed presentation keys in its
SwiftPM resource bundle. The package's default localization is English. German
resources cover representative connection/outbox states and selected errors;
missing German entries fall back to English. This is infrastructure and a
limited translation sample, not a claim that the application is fully German.
The app continues to declare English support.

Explicit `Locale` arguments support deterministic lookup/format tests without
changing process language or UserDefaults. Format strings retain values as
arguments rather than constructing English sentences as lookup keys. Persisted
`SendState` raw values and Raven protocol fields are unchanged. Previously
stored error descriptions remain their original text; they are not translation
keys and are not retroactively translated.

The dependency direction remains App → Core → RavenProtocol. Protocol errors
retain their redacted English `LocalizedError` fallback for protocol-only
consumers. Core maps typed `RavenError` cases to resource-backed presentation
copy at the app boundary: the central error alert, connection failures and
outbox error capture use that mapping. Core store/rich-text errors use the
resource helper directly. Other UI copy remains outside this slice.

`scripts/build-app.sh` already copies every produced SwiftPM `.bundle` into
`Contents/Resources`, which includes the Core localization bundle. Unit tests
verify bundled languages, all English keys, explicit German selection, English
fallback and numeric/string format arguments. Signed-app resource lookup and
a complete language/VoiceOver matrix remain release acceptance work.

Timestamps use cached Foundation short date/time display styles and refresh after
locale or device-timezone changes. A bounded Gregorian/site-timezone parser accepts
absent or 1...6 fractional digits without changing wire values. Naive timestamps
cannot disambiguate repeated DST hours; nonexistent or malformed wall times retain
a bounded raw fallback. Six parser/regional-display regressions cover these cases.
