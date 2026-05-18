#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
PHONE_RE = re.compile(r"\b\d{3}[-.]?\d{3}[-.]?\d{4}\b")


def redact_text(text: str) -> tuple[str, dict[str, int]]:
    counts: dict[str, int] = {}

    def replace_email(match: re.Match[str]) -> str:
        counts["private_email"] = counts.get("private_email", 0) + 1
        return "<PRIVATE_EMAIL>"

    def replace_phone(match: re.Match[str]) -> str:
        counts["private_phone"] = counts.get("private_phone", 0) + 1
        return "<PRIVATE_PHONE>"

    text = EMAIL_RE.sub(replace_email, text)
    text = PHONE_RE.sub(replace_phone, text)
    return text, counts


class Handler(BaseHTTPRequestHandler):
    server: "MockServer"

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def _log(self, event: dict[str, object]) -> None:
        with open(self.server.log_file, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(event, sort_keys=True) + "\n")

    def _read_json(self) -> object:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        return json.loads(raw) if raw else {}

    def do_GET(self) -> None:
        self._log({"method": "GET", "path": self.path})
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps({"ready": True, "device": "cpu", "uptime_s": 1.0, "version": "test"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        self._log({"method": "POST", "path": self.path})
        if self.server.mode == "drop-on-redact" and self.path.startswith("/redact"):
            os._exit(0)

        payload = self._read_json()
        if isinstance(payload, dict):
            text = str(payload.get("text", ""))
        elif isinstance(payload, str):
            text = payload
        else:
            text = ""

        redacted, counts = redact_text(text)
        span_count = sum(counts.values())

        if self.path == "/redact/text":
            body = redacted.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if self.path == "/redact":
            body = json.dumps(
                {
                    "text": text,
                    "redacted_text": redacted,
                    "summary": {"span_count": span_count, "by_label": counts},
                }
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()


class MockServer(ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], handler_class: type[Handler], *, mode: str, log_file: str) -> None:
        super().__init__(server_address, handler_class)
        self.mode = mode
        self.log_file = log_file


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=["normal", "drop-on-redact"], default="normal")
    parser.add_argument("--log-file", required=True)
    args = parser.parse_args()

    server = MockServer(("127.0.0.1", args.port), Handler, mode=args.mode, log_file=args.log_file)
    server.serve_forever()


if __name__ == "__main__":
    main()
