# Demo performance harness

Build Release, then run the owned-child driver from the checkout being measured:

```sh
CONFIGURATION=release scripts/build-app.sh
python3 scripts/check-performance.py --idle-seconds 5 --output /tmp/nevermore-performance-smoke.json
python3 scripts/check-performance.py --idle-seconds 300 --output /tmp/nevermore-performance-five-minutes.json
```

The default binary is `build/Nevermore.app/Contents/MacOS/Nevermore`. The driver
uses `Popen` directly, owns that exact child PID and terminates only its child on
failure, cancellation or timeout. It performs no GUI automation. Coordinate the
desktop lease for launch; it can be released during the announced idle interval.
Default timeout is idle duration plus 180 seconds. Idle duration is bounded to
0–600 seconds, with 10 or 20 switch/enqueue samples and 20 scroll steps.

The explicit `--demo --performance-check` path precedes normal account, updater,
notification and file-receive startup. It creates a random disposable store and
account, skips Keychain reads and real-server connections, and disables native
window/toolbar preference autosaving. It never reads the account registry or
normal demo store and does not change login or application preferences. Existing
appearance/font preferences can affect layout; choose a stable reference setup.
Fresh runs remove their database on completion/error. Persisted probes preserve
the database for subsequent launches until driver cleanup. The driver selects a UUID
nonce and passes it to the child. After terminating its own child, it invokes
the same binary with `--demo --performance-cleanup UUID` and a bounded deadline.
That command resolves only the known prefix plus UUID under its own Foundation
temporary directory and exits before creating NSApplication or loading accounts.
The driver never deletes or otherwise acts on child-reported paths. Cleanup
failure is reported explicitly with the nonce and a nonzero exit status.

The corpus seeds 10,000 mixed messages in one channel and 200 in another. The
large channel must retain 1,000 cached and display 500 messages. Mixed means
native code, tables, marks, multilingual text, masked spoilers and emoji
shortcodes, without downloaded image/video payloads. Cached switch timings await
actual conversation load/render tasks and synchronous native layout/display.
Durable enqueue timings surround the real `acceptDraft` database transaction,
after saving each draft; they exclude draft save and UI feedback. A separate
production UI feedback measurement sends only to the owned loopback fixture.

JSON includes nearest-rank p50/p95 and raw samples, configuration/compiled
architecture, hardware/OS/host architecture, source-checkout commit/dirty state,
and binary SHA-256. The commit identifies the checkout, not independently proven
binary provenance: build immediately before measuring and retain corresponding
source/artifacts. Debug binaries are rejected by the driver. Persisted cached
launches are measured from Swift main and separately from driver spawn. Seed
process/database time is reported separately and excluded from launch samples.

RSS and physical footprint use `TASK_VM_INFO`; unavailable fields remain null.
CPU uses the process user+system `getrusage` delta divided by actual elapsed idle
time, as percent of one CPU core. The 0.5% target is evaluated only for requested
idle intervals of at least 300 seconds. Memory/switch targets apply only to the
measured demo sample. Targets say pass/fail/unmeasured. Measurement success and
a passing driver exit code do not imply that every budget target passed.

Scroll steps measure synchronous layout/display execution, not presented frame
cadence or 60 Hz scrolling. Real media, multi-account memory growth,
energy/network activity and real-server behavior remain unmeasured. Validate on an agreed reference Mac and supported OS matrix.

No-GUI checks:

```sh
swift test --triple "$(uname -m)-apple-macosx26.0" --filter PerformanceMetricsTests
python3 scripts/test-performance-driver.py
```

Python tests use disposable fake children to verify result capture, timeout,
owned-PID termination and fixture cleanup; they never launch AppKit.


## Persisted launch and production send feedback

The driver first runs `--demo --performance-seed UUID` without creating
NSApplication. This creates the fixed persisted corpus in the UUID-owned
fixture. Seeding time is reported separately. Five subsequent Release children
use `--performance-cached-launch` to reopen that database, display cached content
and exit while preserving the fixture. The driver records five actual
spawn-to-first-interactive samples and their nearest-rank p95, plus the app's
since-main samples. Probe shutdown and seed work are outside those samples.
These are seeded one-account cached launches, without real account discovery,
Keychain, notification registration or real-server startup. They are not proof
of every production launch configuration.

For the full run, the driver owns an ephemeral-port HTTP server bound only to
127.0.0.1. Its bounded fixture accepts only canonical reads for one synthetic
channel, ten unique send POSTs, and that channel's visit acknowledgements. It
rejects credentials, unexpected routes, replayed client IDs and oversized bodies.
The app's explicit `.loopbackFixture` session constructor validates the loopback
origin, port and synthetic identity before store/download/Keychain IO, creates
its own client with nil tokens, and leaves normal authentication unchanged.

Five performClick samples followed by five native target/action dispatches on
the production Send button invoke the normal
ConversationWindow.send → AccountSession.send → durable acceptDraft flow. Each
sample ends only when the composer is cleared, editable, not busy, Send enabled,
and native layout/display has run. A benchmark-only forwarding target records
monotonic action-delivery time immediately before forwarding the original
selector/target/sender exactly once through NSApp.sendAction. A defer restores
the original target and selector, including failure paths. Pending draft saves are included when they
extend beyond the click. The harness separately waits up to five seconds for
canonical acknowledgement before the next click. It never retries an uncertain
send. The 100 ms queued-send target uses `queued_send_UI_feedback`: the second
five samples dispatch NSApp.sendAction to the button's installed forwarding
target and measure from original action delivery to observable feedback. This
excludes performClick itself, which can block or animate after delivering the
callback. `queued_send_perform_click_total` retains the first five click totals;
`queued_send_perform_click_action_observation` retains their action-to-observation
series, including any post-dispatch blocking. `synthetic_button_pre_action`
reports only their measured before-callback gap; it makes no assertion about
where synthetic animation happens. No fixed delay is guessed or subtracted. This measures observable local queued-send
feedback, not physical input/event delivery, server latency, or live-account
interoperability. The feedback window
and session/client are closed and removed before the one-account idle sample.

Driver tests use fake children and the owned loopback server to verify all five
probe records and ten distinct synthetic POSTs, while retaining external-path
sentinel and timeout/PID cleanup regressions. Swift tests cover seed/probe nonce
arguments and accepted/rejected loopback origins. Real AppKit measurements remain
an operator-run step; deterministic tests alone do not supply timing results.

Hidden native button-action calibration models a 100 ms pre-callback delay with
an injected clock, verifying it remains in the click total and outside the
25 ms action-to-feedback interval. It also verifies original sender/selector
forwarding exactly once and restoration on success/failure. Pure timing tests
reject reversed or nonfinite boundaries. Driver tests retain the four distinct
reported series and still require ten unique loopback POSTs (five per dispatch mode).
