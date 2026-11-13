#!/usr/bin/env python3
"""Own one explicit demo child and record bounded Release performance samples.

Does not drive the desktop or inspect live accounts. Hold the desktop lease for
launch, then release while the child reports its idle interval. Budget failures
are data in the report, not a claim that the measurement command itself failed.
"""
import argparse
import hashlib
import http.server
import math
import json
import os
from pathlib import Path
import platform
import selectors
import subprocess
import sys
import time
import threading
import urllib.parse
import uuid


def bounded_integer(low, high):
    def parse(value):
        result = int(value)
        if not low <= result <= high:
            raise argparse.ArgumentTypeError(f"must be {low}...{high}")
        return result
    return parse


def command(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=10).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def metadata(binary):
    repository = str(Path(__file__).resolve().parents[1])
    return {
        "hardware_model": command("sysctl", "-n", "hw.model"),
        "cpu": command("sysctl", "-n", "machdep.cpu.brand_string"),
        "memory_bytes": command("sysctl", "-n", "hw.memsize"),
        "os": platform.platform(), "macos": platform.mac_ver()[0],
        "architecture": platform.machine(), "binary": str(binary.resolve()),
        "commit": command("git", "-C", repository, "rev-parse", "HEAD"),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "binary_source_match": "not independently verified; build from the recorded checkout before measuring",
        "working_tree_dirty": bool(command("git", "-C", repository, "status", "--porcelain")),
        "command_started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def cleanup_fixture(binary, nonce):
    """Ask the same executable to resolve our UUID in its own container."""
    cleanup = None
    try:
        cleanup = subprocess.Popen([str(binary.resolve()), "--demo", "--performance-cleanup", nonce], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return None if cleanup.wait(timeout=10) == 0 else "app cleanup command failed"
    except (OSError, subprocess.SubprocessError) as error:
        return f"app cleanup command failed: {error}"
    finally:
        if cleanup is not None and cleanup.poll() is None:
            cleanup.kill()
            cleanup.wait(timeout=5)


class LoopbackFixture:
    """Only synthetic, bounded channel reads and ten unique send POSTs."""
    channel = "performance-feedback"
    user = "performance-fixture@example.invalid"

    def __init__(self):
        self.requests = 0
        self.sends = {}
        self.failures = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def answer(self, code, value):
                body = json.dumps(value).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def handle_request(self):
                owner.requests += 1
                if owner.requests > 100 or self.headers.get("Authorization") or self.headers.get("Cookie"):
                    owner.failures.append("request limit or unexpected credentials")
                    return self.answer(403, {})
                parsed = urllib.parse.urlsplit(self.path)
                path = urllib.parse.unquote(parsed.path)
                if self.command == "GET":
                    args = urllib.parse.parse_qs(parsed.query)
                    if path == "/api/resource/Raven Channel/" + owner.channel and not args:
                        return self.answer(200, {"data": {"name": owner.channel, "channel_name": "Performance feedback", "is_archived": 0, "is_thread": 0}})
                    if path == "/api/method/raven.api.chat_stream.get_messages" and args.get("channel_id") == [owner.channel]:
                        return self.answer(200, {"message": {"messages": list(owner.sends.values())}})
                if self.command == "POST":
                    try:
                        size = int(self.headers.get("Content-Length", "0"))
                        if not 0 < size <= 16384: raise ValueError()
                        args = json.loads(self.rfile.read(size))
                        if not isinstance(args, dict) or args.get("channel_id") != owner.channel: raise ValueError()
                        if path == "/api/method/raven.api.raven_channel_member.track_visit":
                            if not isinstance(args.get("last_visit"), str) or len(args["last_visit"]) > 64: raise ValueError()
                            return self.answer(200, {"message": True})
                        if path == "/api/method/raven.api.raven_message.send_message_with_attachments":
                            identity = args.get("client_id")
                            if str(uuid.UUID(identity)).upper() != identity.upper() or identity in owner.sends or len(owner.sends) >= 10: raise ValueError()
                            content = args.get("content")
                            if not isinstance(content, str) or len(content) > 1024 or "Feedback fixture " not in content or args.get("files") != []: raise ValueError()
                            row = {"name": "feedback-" + identity, "channel_id": owner.channel, "owner": owner.user, "message_batch_id": identity, "text": content, "creation": "2026-11-08 15:00:%02d.000000" % len(owner.sends), "message_type": "Text"}
                            owner.sends[identity] = row
                            return self.answer(200, {"message": [row]})
                    except (ValueError, TypeError, KeyError, AttributeError, json.JSONDecodeError):
                        owner.failures.append("invalid or replayed synthetic mutation")
                        return self.answer(400, {})
                owner.failures.append("unexpected synthetic endpoint")
                self.answer(404, {})
            do_GET = handle_request
            do_POST = handle_request

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.origin = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.1), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


def summarize(samples):
    ordered = sorted(samples)
    if not ordered or not all(math.isfinite(x) and x >= 0 for x in ordered):
        raise ValueError("invalid timing samples")
    return {"count": len(ordered), "unit": "milliseconds", "samples": samples,
            "p50": ordered[math.ceil(len(ordered) * 0.5) - 1],
            "p95": ordered[math.ceil(len(ordered) * 0.95) - 1]}


def run_owned(invocation, deadline):
    """Own, drain and reap exactly this child, including cancellation paths."""
    child = None
    selector = selectors.DefaultSelector()
    began = time.monotonic()
    events = []
    first_ms = None
    try:
        child = subprocess.Popen(invocation, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        selector.register(child.stdout, selectors.EVENT_READ)
        pending = b""
        total = 0
        while selector.get_map():
            if time.monotonic() > deadline: raise TimeoutError("performance child exceeded its deadline")
            for key, _ in selector.select(timeout=0.2):
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    selector.unregister(key.fileobj)
                    continue
                pending += block
                total += len(block)
                if total > 8 * 1024 * 1024: raise RuntimeError("performance output limit exceeded")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    try: event = json.loads(line)
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        print(line.decode(errors="replace")[:2000], file=sys.stderr)
                        continue
                    if not isinstance(event, dict): continue
                    events.append(event)
                    if event.get("event") == "first_interactive":
                        first_ms = (time.monotonic() - began) * 1000
                    elif event.get("event") == "progress":
                        print("Performance: " + str(event.get("phase")), file=sys.stderr, flush=True)
                    elif event.get("event") == "error": raise RuntimeError(str(event.get("message")))
        if child.wait(timeout=max(0.1, deadline - time.monotonic())) != 0: raise RuntimeError("performance child failed")
        return events, first_ms, (time.monotonic() - began) * 1000
    finally:
        selector.close()
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(timeout=5)
            if child.stdout: child.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("build/Nevermore.app/Contents/MacOS/Nevermore"))
    parser.add_argument("--idle-seconds", type=bounded_integer(0, 600), default=5)
    parser.add_argument("--iterations", type=int, choices=(10, 20), default=20)
    parser.add_argument("--timeout", type=bounded_integer(1, 1200), help="total deadline; default idle+180 seconds")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.binary.is_file(): parser.error("binary missing; build Release first")
    info = metadata(args.binary)
    nonce = str(uuid.uuid4()).upper()
    info["fixture_nonce"] = nonce
    base = [str(args.binary.resolve()), "--demo"]
    fixture = ["--performance-check", "--performance-fixture-id", nonce]
    deadline = time.monotonic() + (args.timeout or args.idle_seconds + 180)
    started = False
    outcome = 1
    try:
        started = True
        events, _, seed_elapsed = run_owned(base + ["--performance-seed", nonce], deadline)
        seeds = [e for e in events if e.get("event") == "seed_complete"]
        if len(seeds) != 1: raise RuntimeError("seed mode did not confirm persisted fixture")
        info["seed_process_elapsed_ms"] = seed_elapsed
        info["seed_database_ms"] = seeds[0].get("milliseconds")
        launches = []
        main_launches = []
        for index in range(5):
            print("Performance: cached launch %d/5" % (index + 1), file=sys.stderr, flush=True)
            events, first_ms, _ = run_owned(base + fixture + ["--performance-cached-launch"], deadline)
            reports = [e for e in events if e.get("event") == "result"]
            if len(reports) != 1 or reports[0].get("configuration") != "Release" or not reports[0].get("cached_fixture") or first_ms is None:
                raise RuntimeError("cached launch probe was not a confirmed Release cached launch")
            launches.append(first_ms)
            main_launches.append(reports[0]["cached_launch_since_main_ms"])
        with LoopbackFixture() as server:
            invocation = base + fixture + ["--performance-reuse-fixture", "--performance-loopback-origin", server.origin, "--performance-idle-seconds", str(args.idle_seconds), "--performance-iterations", str(args.iterations)]
            info["invocation"] = invocation
            events, _, _ = run_owned(invocation, deadline)
            reports = [e for e in events if e.get("event") == "result"]
            if len(reports) != 1 or reports[0].get("configuration") != "Release": raise RuntimeError("Release result missing")
            report = reports[0]
            feedback = report.get("queued_send_UI_feedback")
            click_total = report.get("queued_send_perform_click_total")
            pre_action = report.get("synthetic_button_pre_action")
            click_observed = report.get("queued_send_perform_click_action_observation")
            if any(not isinstance(metric, dict) or metric.get("count") != 5 for metric in [feedback, click_total, pre_action, click_observed]) or len(server.sends) != 10 or server.failures:
                raise RuntimeError("loopback send contract or action-delivery timing failed: " + str(server.failures))
            report["loopback_fixture"] = {"unique_send_posts": len(server.sends), "requests": server.requests, "failures": server.failures}
        report["cached_relaunch_spawn_to_interactive"] = summarize(launches)
        report["cached_relaunch_since_main"] = summarize(main_launches)
        report.setdefault("targets", {})["cached_relaunch_under_2_seconds"] = "pass" if report["cached_relaunch_spawn_to_interactive"]["p95"] < 2000 else "fail"
        info["configuration"] = report["configuration"]
        result = {"metadata": info, "measurements": report}
        encoded = json.dumps(result, indent=2, sort_keys=True)
        if args.output: args.output.write_text(encoded + "\n")
        print(encoded)
        outcome = 0
    except (KeyboardInterrupt, OSError, RuntimeError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
        print(json.dumps({"metadata": info, "error": str(error)}), file=sys.stderr)
        outcome = 1
    finally:
        if started:
            cleanup_error = cleanup_fixture(args.binary, nonce)
            if cleanup_error:
                print(json.dumps({"error": cleanup_error, "fixture_nonce": nonce, "cleanup": "unverified"}), file=sys.stderr)
                outcome = 1
    return outcome


if __name__ == "__main__": raise SystemExit(main())
