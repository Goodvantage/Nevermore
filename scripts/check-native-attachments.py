#!/usr/bin/env python3
"""Check native attachments and optional poll, reaction and avatar fixtures over credential-free loopback.

On this shared Mac, hold the desktop lease. Add --save-panel to drive the
real save dialog through Peekaboo and test an export outside the sandbox.
The default fixture also runs on an isolated CI Mac without Peekaboo.
Use --user-session when CI starts from a system LaunchDaemon, so App Sandbox
can reach its per-user initialization services.
"""
import argparse
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit, unquote
import uuid
import zlib


REACTION_CHANNEL = "reaction-fixture-channel"
REACTION_ELSEWHERE = "reaction-fixture-elsewhere"
REACTION_MESSAGE = "reaction-message-fixture"
# A conversation of its own with two messages, for reactions that overlap.
REACTION_PAIR_CHANNEL = "reaction-fixture-pair"
REACTION_PAIR = ("reaction-pair-first", "reaction-pair-second")
REACTION_USER = "reaction-fixture-user"
# Profile photos are told apart by shape: the old one is tall, the new wide.
AVATAR_SHAPES = {"old": (8, 16), "new": (16, 8)}
# A slow photo or a held message list waits until the check has acted. The
# limit only keeps a check that failed before releasing it from tying up a
# server thread.
HOLD_LIMIT = 10


def png(width, height):
    """A solid gray PNG of the given pixel size."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = (b"\x00" + b"\x80\x80\x80" * width) * height
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


class Fixture(BaseHTTPRequestHandler):
    def reply_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        path = urlsplit(self.path).path
        routes = {
            "/api/method/raven.api.raven_poll.add_vote": self.add_vote,
            "/api/method/raven.api.reactions.react": self.react,
            "/api/method/raven.api.raven_channel_member.track_visit": lambda _value: self.reply_json({"message": True}),
        }
        if path not in routes:
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if not 0 < length < 65536:
            self.send_error(413)
            return
        try:
            value = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            self.send_error(400)
            return
        if not isinstance(value, dict):
            self.send_error(400)
            return
        routes[path](value)

    def add_vote(self, value):
        choices = value.get("option_id", [])
        if value.get("message_id") != "poll-message-fixture" or choices != ["option-1"]:
            self.reply_json({"exc_type": "ValidationError"}, 400)
            return
        with self.server.poll_lock:
            self.server.poll_state["vote_requests"] += 1
            self.server.poll_state["selected"] = choices
        time.sleep(.15)  # Keep the real POST suspended across repeated UI clicks.
        self.reply_json({"message": "ok"})

    def react(self, value):
        reaction = value.get("reaction")
        if value.get("message_id") not in self.server.reaction_state["mine"] or value.get("is_custom") is not False or not isinstance(reaction, str) or not reaction:
            self.reply_json({"exc_type": "ValidationError"}, 400)
            return
        with self.server.poll_lock:
            state = self.server.reaction_state
            state["react_requests"] += 1
            state["last_reaction"], state["last_is_custom"] = reaction, value.get("is_custom")
            # Raven toggles the caller's reaction.
            mine = state["mine"][value["message_id"]]
            if reaction in mine:
                mine.remove(reaction)
            else:
                mine.append(reaction)
        time.sleep(.15)  # Keep the real POST suspended across repeated UI clicks.
        self.reply_json({"message": "Ok"})

    def avatar(self, path):
        """Serve /files/avatar-<words>.png. "slow" answers only after
        nevermore_fixture.avatar_release, so a check can change the user
        directory while the download is in flight; "old" and "new" choose the
        picture; anything else is a missing file."""
        words = Path(path).stem.split("-")
        with self.server.poll_lock:
            self.server.avatar_requests[path] = self.server.avatar_requests.get(path, 0) + 1
            hold = self.server.avatar_holds.setdefault(path, threading.Event()) if "slow" in words else None
        if hold:
            hold.wait(HOLD_LIMIT)
        shape = next((AVATAR_SHAPES[word] for word in words if word in AVATAR_SHAPES), None)
        if shape is None:
            self.send_error(404)
            return
        body = png(*shape)
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reaction_message(self, name=REACTION_MESSAGE, channel=REACTION_CHANNEL, minute=40):
        with self.server.poll_lock:
            mine = list(self.server.reaction_state["mine"][name])
        reactions = {emoji: {"count": 1, "users": [REACTION_USER], "reaction": emoji, "is_custom": 0} for emoji in mine}
        return {"name": name, "channel_id": channel, "owner": "alex@example.com",
                "creation": "2026-11-07 10:%d:00.000000" % minute, "text": "<p>Loopback reaction fixture</p>",
                "message_type": "Text", "message_reactions": json.dumps(reactions)}

    def pair_messages(self):
        """Answer the pair conversation's message list. After
        nevermore_fixture.hold_messages the next answer waits for
        nevermore_fixture.release_messages. It is taken before the wait, so
        a check can let it arrive after a newer one that shows more."""
        messages = [self.reaction_message(name, REACTION_PAIR_CHANNEL, 41 + index) for index, name in enumerate(REACTION_PAIR)]
        with self.server.poll_lock:
            state = self.server.reaction_state
            held = state["hold_messages"]
            if held:
                state["hold_messages"] = False
                state["held_messages"] += 1
        if held:
            self.server.message_release.wait(HOLD_LIMIT)
        self.reply_json({"message": {"messages": messages, "has_old_messages": False, "last_visit": None}})

    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        query = parse_qs(urlsplit(self.path).query)
        for channel in ("poll-fixture-channel", REACTION_CHANNEL, REACTION_PAIR_CHANNEL):
            if path == "/api/resource/Raven Channel/" + channel:
                self.reply_json({"data": {"name": channel, "is_archived": 0, "is_thread": 0}})
                return
        if path.startswith("/files/avatar-"):
            self.avatar(path)
            return
        if path == "/api/method/nevermore_fixture.avatar_stats":
            with self.server.poll_lock:
                result = dict(self.server.avatar_requests)
            self.reply_json({"message": result})
            return
        if path == "/api/method/nevermore_fixture.avatar_release":
            with self.server.poll_lock:
                for hold in self.server.avatar_holds.values():
                    hold.set()
            self.reply_json({"message": "Ok"})
            return
        if path == "/api/method/nevermore_fixture.reaction_stats":
            with self.server.poll_lock:
                state = self.server.reaction_state
                result = {key: state[key] for key in ("react_requests", "last_reaction", "last_is_custom", "held_messages")}
            self.reply_json({"message": result})
            return
        if path in ("/api/method/nevermore_fixture.hold_messages", "/api/method/nevermore_fixture.release_messages"):
            with self.server.poll_lock:
                if path.endswith("hold_messages"):
                    self.server.message_release.clear()
                    self.server.reaction_state["hold_messages"] = True
                else:
                    self.server.message_release.set()
            self.reply_json({"message": "Ok"})
            return
        if path.startswith("/api/method/nevermore_fixture."):
            with self.server.poll_lock:
                if path.endswith("fail_next_poll"):
                    self.server.poll_state["fail_next"] = True
                result = {"vote_requests": self.server.poll_state["vote_requests"]}
            self.reply_json({"message": result})
            return
        if path == "/api/method/raven.api.reactions.most_used_reactions":
            if query.get("limit") != ["6"]:
                self.reply_json({"exc_type": "ValidationError"}, 400)
                return
            self.reply_json({"message": [
                {"reaction": "🚀", "is_custom": 0, "reaction_escaped": "1f680", "uses": 5},
                {"reaction": "👍", "is_custom": 0, "reaction_escaped": "1f44d", "uses": 3},
                {"reaction": "/files/party.png", "is_custom": 1, "reaction_escaped": "party", "uses": 2},
            ]})
            return
        if path == "/api/method/raven.api.chat_stream.get_messages":
            if query.get("channel_id") == [REACTION_ELSEWHERE]:
                # An empty conversation to switch to while a reaction is in flight.
                self.reply_json({"message": {"messages": [], "has_old_messages": False, "last_visit": None}})
                return
            if query.get("channel_id") == [REACTION_PAIR_CHANNEL]:
                self.pair_messages()
                return
            if query.get("channel_id") != [REACTION_CHANNEL]:
                self.send_error(404)
                return
            self.reply_json({"message": {"messages": [self.reaction_message()], "has_old_messages": False, "last_visit": None}})
            return
        if path == "/api/method/raven.api.raven_poll.get_poll":
            with self.server.poll_lock:
                failed = self.server.poll_state.pop("fail_next", False)
                selected = list(self.server.poll_state["selected"])
            if failed:
                self.reply_json({"exc_type": "FixtureReadError"}, 503)
                return
            self.reply_json({"message": {
                "poll": {"name": "poll-fixture", "owner": "poll-fixture-user", "question": "Loopback poll fixture",
                         "is_multi_choice": 0, "is_anonymous": 0, "is_disabled": 0, "max_choices": 0,
                         "total_votes": int(bool(selected)), "options": [
                             {"name": f"option-{i}", "option": f"Option {i}", "votes": int(f"option-{i}" in selected)} for i in range(1, 4)]},
                "current_user_votes": [{"option": choice} for choice in selected],
                "votes": {choice: ["poll-fixture-user"] for choice in selected}
            }})
            return
        fixtures = {
            "/fixture.txt": ("text/plain", b"Nevermore native attachment fixture\n"),
            "/compressed.txt": ("text/plain", gzip.compress(b"Nevermore native attachment fixture\n")),
            "/fixture.txt.gz": ("text/plain", gzip.compress(b"Nevermore native attachment fixture\n")),
            "/fixture.svg": ("image/svg+xml", b'<svg xmlns="http://www.w3.org/2000/svg"/>'),
        }
        value = fixtures.get(self.path)
        if value is None:
            self.send_error(404)
            return
        mime, body = value
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        if self.path.endswith(".gz") or self.path == "/compressed.txt":
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Disposition", 'attachment; filename="' + self.path[1:] + '"')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def desktop(*args):
    result = subprocess.run(["desktop", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
    if result.returncode:
        raise RuntimeError("Desktop automation failed: " + result.stdout[:1000])
    return result.stdout


def drive_save_panel(ready, stopped, export_dir, errors, app_pid):
    try:
        while not ready.wait(.1):
            if stopped.is_set():
                return
        # Observe the real remote panel before sending any input. Invoking
        # NSSavePanel.ok directly is unsupported by the sandbox's proxy.
        for _ in range(40):
            inventory = json.loads(desktop("window", "list", "--app", f"PID:{app_pid}", "--json"))
            windows = (inventory.get("data") or {}).get("windows", [])
            panel = next((w for w in windows if w.get("window_title") == "Save" and w.get("is_on_screen")), None)
            if panel:
                break
            if stopped.wait(.25):
                return
        else:
            raise RuntimeError("The native Save As dialog did not appear")
        # The real remote panel starts in the fixture directory. The app still
        # receives no sandbox extension until the user action accepts this panel.
        applications = json.loads(desktop("app", "list", "--json"))
        def active_own_app(value):
            if isinstance(value, dict):
                if value.get("pid") == app_pid and value.get("is_active"):
                    return True
                return any(active_own_app(child) for child in value.values())
            return isinstance(value, list) and any(active_own_app(child) for child in value)
        if not active_own_app(applications.get("data")):
            raise RuntimeError("Nevermore is not the active application for Save As")
        # Sandboxed panels may have no matching AX window. Under the exclusive
        # desktop lease, accept only this observed, active app's default action.
        desktop("press", "Return", "--foreground")
    except Exception as error:
        errors.append(str(error))
        print("FAIL Save As automation: " + str(error), file=sys.stderr, flush=True)
        try:
            desktop("dialog", "click", "--button", "Cancel", "--app", f"PID:{app_pid}")
        except Exception:
            pass


def _run_in_user_session(args):
    """Keep the fixture in its own UID's GUI login, not the system daemon's.

    App Sandbox initialization traps before main in the system bootstrap.
    A Background agent starts but cannot exercise keyboard focus reliably.
    Require the runner's Aqua session without changing UID or passing CI
    credentials into that independent launchd job.
    """
    prefix = "ch.goodvantage.Nevermore.native-fixture."
    label = os.environ.get("NATIVE_FIXTURE_LABEL", prefix + uuid.uuid4().hex)
    if not re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9][A-Za-z0-9.-]{0,127}", label):
        print("FAIL invalid native fixture service label", file=sys.stderr)
        return 1

    domain = f"gui/{os.getuid()}"
    directory = Path(tempfile.mkdtemp(prefix="nevermore-native-agent-", dir=os.environ.get("RUNNER_TEMP")))
    status_file, log_file = directory / "status", directory / "output"
    registered, cleanup_ok, status = False, True, 1
    handlers = {}

    def interrupted(_signal, _frame):
        raise InterruptedError("native fixture interrupted")

    try:
        command = [sys.executable, str(Path(__file__).resolve()), "--app", str(args.app.resolve())]
        command.extend("--" + flag for flag in ("polls", "reactions", "avatars") if getattr(args, flag))
        wrapper = directory / "run.sh"
        # Publish completion atomically: seeing an empty, newly opened status
        # file must not turn a successful check into a parse error.
        temporary_status = shlex.quote(str(status_file) + ".tmp")
        wrapper.write_text("#!/bin/sh\n" + shlex.join(command) + "\nstatus=$?\n"
                           "printf '%s\\n' \"$status\" > " + temporary_status + "\n"
                           "/bin/mv " + temporary_status + " " + shlex.quote(str(status_file)) + "\n"
                           "exit \"$status\"\n", encoding="utf-8")
        wrapper.chmod(0o700)
        job = {"Label": label, "ProgramArguments": ["/bin/sh", str(wrapper)],
               "WorkingDirectory": str(Path.cwd()), "LimitLoadToSessionType": "Aqua",
               "RunAtLoad": True, "ExitTimeOut": 10,
               "StandardOutPath": str(log_file), "StandardErrorPath": str(log_file),
               "EnvironmentVariables": {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                                        "HOME": str(Path.home()), "PYTHONUTF8": "1", "NSUnbufferedIO": "YES"}}
        plist = directory / "agent.plist"
        with plist.open("wb") as output:
            plistlib.dump(job, output)
        for sig in (signal.SIGINT, signal.SIGTERM):
            handlers[sig] = signal.signal(sig, interrupted)
        result = subprocess.run(["/bin/launchctl", "bootstrap", domain, str(plist)],
                                capture_output=True, text=True, timeout=30)
        registered = result.returncode == 0
        if not registered:
            raise RuntimeError("native fixture bootstrap failed (the runner user needs an active GUI login): "
                               + result.stderr.strip())
        # The fixture bounds the app to 150s; leave time for its process,
        # thread and HTTP-server cleanup before unloading the agent.
        deadline = time.monotonic() + 210
        while not status_file.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError("native fixture user session did not finish within 210 seconds")
            time.sleep(.1)
        status = int(status_file.read_text())
        if not 0 <= status <= 255:
            raise ValueError("invalid native fixture exit status")
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        status = 1
        print("FAIL native user-session check: " + str(error), file=sys.stderr)
    finally:
        # A second cancellation must not interrupt bounded launchd cleanup.
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        if registered:
            try:
                result = subprocess.run(["/bin/launchctl", "bootout", domain + "/" + label],
                                        capture_output=True, text=True, timeout=20)
                cleanup_ok = result.returncode == 0
                if not cleanup_ok:
                    print("FAIL native user-session cleanup: " + result.stderr.strip(), file=sys.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                cleanup_ok = False
                print("FAIL native user-session cleanup: " + str(error), file=sys.stderr)
        try:
            if log_file.exists():
                print(log_file.read_text(encoding="utf-8", errors="replace"), end="", flush=True)
            if cleanup_ok:
                shutil.rmtree(directory)
            else:
                status = 1
                print(f"Retained native agent files for cleanup: {directory}", file=sys.stderr)
        except OSError as error:
            status = 1
            print("FAIL native user-session file cleanup: " + str(error), file=sys.stderr)
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/Nevermore.app/Contents/MacOS/Nevermore"))
    parser.add_argument("--save-panel", action="store_true")
    parser.add_argument("--polls", action="store_true")
    parser.add_argument("--reactions", action="store_true")
    parser.add_argument("--avatars", action="store_true")
    parser.add_argument("--user-session", action="store_true", help="Run from CI's LaunchDaemon through an owned agent in the runner user's GUI login")
    args = parser.parse_args()
    if args.user_session:
        if args.save_panel:
            parser.error("--save-panel requires the direct desktop session, without --user-session")
        return _run_in_user_session(args)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    server.poll_lock = threading.Lock()
    server.poll_state = {"vote_requests": 0, "selected": []}
    server.reaction_state = {"react_requests": 0, "last_reaction": None, "last_is_custom": None,
                             "mine": {name: [] for name in (REACTION_MESSAGE, *REACTION_PAIR)},
                             "hold_messages": False, "held_messages": 0}
    server.message_release = threading.Event()
    server.avatar_requests = {}
    server.avatar_holds = {}
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    ready, stopped = threading.Event(), threading.Event()
    output = {"complete": False}
    errors = []
    process = reader = driver = None

    def stop_application():
        stopped.set()
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for thread, timeout in [(reader, 5), (driver, 25)]:
            if thread is not None and thread.ident is not None:
                thread.join(timeout=timeout)

    try:
        with tempfile.TemporaryDirectory(prefix="NevermoreNativeExport-") as export_dir:
            command = [str(args.app.resolve()), "--demo", "--self-check", "--attachment-fixture-origin", f"http://127.0.0.1:{server.server_port}"]
            if args.polls:
                command.extend(["--poll-fixture-origin", f"http://127.0.0.1:{server.server_port}"])
            if args.reactions:
                command.extend(["--reaction-fixture-origin", f"http://127.0.0.1:{server.server_port}"])
            if args.avatars:
                command.extend(["--avatar-fixture-origin", f"http://127.0.0.1:{server.server_port}"])
            if args.save_panel:
                command.extend(["--attachment-export-directory", export_dir])
            process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, "NSUnbufferedIO": "YES"})

            def stream():
                for line in process.stdout:
                    print(line, end="", flush=True)
                    if line.strip() == "NEVERMORE_SAVE_PANEL_READY":
                        ready.set()
                    if line.strip() == "PASS native attachment fixture completed":
                        output["complete"] = True

            reader = threading.Thread(target=stream, daemon=True)
            driver = threading.Thread(target=drive_save_panel, args=(ready, stopped, export_dir, errors, process.pid), daemon=True) if args.save_panel else None
            reader.start()
            if driver:
                driver.start()
            try:
                deadline = time.monotonic() + 150
                while process.poll() is None and not errors and time.monotonic() < deadline:
                    time.sleep(.1)
                if errors or process.poll() is None:
                    raise subprocess.TimeoutExpired(command, 150)
                status = process.wait()
            except subprocess.TimeoutExpired:
                print("FAIL native attachment automation failed" if errors else "FAIL native attachment checks timed out", file=sys.stderr)
                return 1
            finally:
                stop_application()
            if status:
                print(f"FAIL native application exited with status {status}", file=sys.stderr)
                return 1
            if errors:
                print("FAIL " + "; ".join(errors), file=sys.stderr)
                return 1
            if args.save_panel:
                target = Path(export_dir) / "fixture.txt"
                if not target.is_file() or target.read_bytes() != b"Nevermore native attachment fixture\n":
                    print("FAIL sandboxed Save As did not create the expected export", file=sys.stderr)
                    return 1
            else:
                print("SKIP external Save As: use --save-panel while holding the shared desktop")
            if not output["complete"]:
                print("FAIL native attachment fixture did not complete", file=sys.stderr)
                return 1
            return 0
    finally:
        # This scope also covers failures while constructing/starting threads
        # immediately after Popen, before the inner wait-loop scope is entered.
        stop_application()
        server.shutdown(); server.server_close(); server_thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
