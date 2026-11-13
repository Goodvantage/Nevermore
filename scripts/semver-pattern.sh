# Sourced, not run: sets SEMVER_PATTERN, the release version grammar shared
# by scripts/release.sh, scripts/package-release.sh and
# .forgejo/workflows/release.yml.
#
# Semantic Versioning 2.0.0 as apps.goodvantage.cloud's publisher accepts it
# (SEMVER_RE in scripts/publish_app_release.py), without "+build" metadata,
# which neither a tag nor a bundle version needs. Numbers have no leading
# zeros and prerelease identifiers are not empty: 0.2.0, 1.0.0-beta.1 and
# 1.0.0-rc-2 match; 01.2.3, 1.0.0-01 and 1.0.0-beta..1 do not. A version the
# publisher would refuse must fail here, before a build is signed and the
# forge release is made. scripts/tests/test_semver_pattern.py keeps the two
# grammars in step.
#
# A POSIX extended regular expression for bash's [[ =~ ]].
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$'
