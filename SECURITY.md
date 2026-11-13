# Security and release policy

Nevermore is an early implementation. Production support is conditional on the compatibility and release tests in `docs/NEVERMORE-PLAN.md` and `docs/implementation/VALIDATION.md`.

Treat site responses, rich HTML, media, filenames, workflow descriptions and URLs as untrusted. Native rendering does not execute message scripts. Authentication uses a dedicated public OAuth client, PKCE and exact callback validation. Tokens do not enter defaults, message databases, source control or logs. There is no certificate-validation bypass.

Report vulnerabilities privately to the repository owner through a private security advisory if the repository supports it. A monitored release security contact must be established before public distribution; no email address is invented here. Include a minimal synthetic reproduction, affected revisions and security impact. Do not post private message data, credentials or a complete chat database.

Release gates include real Frappe/Raven permission tests, signed sandbox testing, authenticated redirect/media tests, dependency review, Developer ID/notarization and a verified signed-update round trip. Do not advertise background push, complete offline synchronization, application-layer cache encryption or tested hardware/server coverage without the corresponding evidence.
