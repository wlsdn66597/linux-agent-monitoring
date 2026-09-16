#!/usr/bin/env python3
"""Minimal target application for the Linux agent monitoring assignment."""

from __future__ import annotations

import getpass
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def ok(step: int, title: str, detail: str) -> None:
    print(f"[{step}/5] {title:<38} [OK]", flush=True)
    print(f"... {detail}", flush=True)


def fail(step: int, title: str, detail: str) -> None:
    print(f"[{step}/5] {title:<38} [FAIL]", flush=True)
    print(f"... {detail}", flush=True)
    raise SystemExit(1)


def boot_checks() -> tuple[str, int]:
    print("> Starting Agent Boot Sequence...", flush=True)

    expected_user = os.environ.get("AGENT_SERVICE_USER", "agent-admin")
    current_user = getpass.getuser()
    if os.geteuid() == 0 or current_user != expected_user:
        fail(1, "Checking User Account", f"Expected non-root user '{expected_user}', got '{current_user}'")
    ok(1, "Checking User Account", f"Running as service user '{current_user}' (uid={os.geteuid()})")

    required = ("AGENT_HOME", "AGENT_PORT", "AGENT_UPLOAD_DIR", "AGENT_KEY_PATH", "AGENT_LOG_DIR")
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        fail(2, "Verifying Environment Variables", f"Missing: {', '.join(missing)}")
    try:
        port = int(os.environ["AGENT_PORT"])
    except ValueError:
        fail(2, "Verifying Environment Variables", "AGENT_PORT must be an integer")
    if port != 15034:
        fail(2, "Verifying Environment Variables", f"AGENT_PORT must be 15034, got {port}")
    ok(2, "Verifying Environment Variables", "All required environment variables are set")

    key_path = Path(os.environ["AGENT_KEY_PATH"])
    upload_dir = Path(os.environ["AGENT_UPLOAD_DIR"])
    if not upload_dir.is_dir():
        fail(3, "Checking Required Files", f"Upload directory does not exist: {upload_dir}")
    try:
        key_value = key_path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        fail(3, "Checking Required Files", f"Cannot read key file: {exc}")
    if key_value != "agent_api_key_test":
        fail(3, "Checking Required Files", "Key file content is invalid")
    ok(3, "Checking Required Files", "Verified upload directory and key file")

    host = "0.0.0.0"
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind((host, port))
    except OSError as exc:
        fail(4, "Checking Port Availability", f"Port {port} is unavailable: {exc}")
    finally:
        probe.close()
    ok(4, "Checking Port Availability", f"Port {port} is available")

    log_dir = Path(os.environ["AGENT_LOG_DIR"])
    if not log_dir.is_dir() or not os.access(log_dir, os.W_OK):
        fail(5, "Verifying Log Permission", f"Log directory is not writable: {log_dir}")
    ok(5, "Verifying Log Permission", f"Log directory is writable: {log_dir}")

    print("-" * 60, flush=True)
    print("All Boot Checks Passed!", flush=True)
    print("Agent READY", flush=True)
    return host, port


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(404)
            return
        payload = json.dumps({"status": "ok"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:
        print(f"[HTTP] {self.address_string()} - {format % args}", flush=True)


if __name__ == "__main__":
    listen_host, listen_port = boot_checks()
    try:
        ThreadingHTTPServer((listen_host, listen_port), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nAgent stopped.", flush=True)
        sys.exit(0)
