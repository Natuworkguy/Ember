"""The watch's way in: Bluetooth LE, not the network.

This computer advertises one Bluetooth LE service. The watch finds it,
connects, and sends the same requests the HTTP API takes; each is
answered by the same app, so nothing about notes differs between the
two. A request goes in as a run of frames written to one
characteristic; its answer comes back one frame per read of the other.

A message, either way, is a line of JSON and then the body:

    request:  {"m": "POST", "p": "/notes", "q": "", "h": {...}}\\n<body>
    answer:   {"s": 200, "t": "application/json"}\\n<body>

Request frames (written by the watch, without response):

    S  id:u16  total:u32  size:u16  data   the first; SIZE is the most
                                           the watch reads in one frame
    C  id:u16  offset:u32  data            the rest, in order

Answer frames (one per read of the answer characteristic):

    W                         not ready yet: read again shortly
    R  id:u16  total:u32  data  the first
    C  id:u16  offset:u32  data the rest
    E                         nothing more

The watch writes "Bluetooth" in Swift the same way, in
watch/Ember/Sync/BluetoothLink.swift: change one, change both.
"""

from __future__ import annotations

import asyncio
import json
import struct
import threading
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

SERVICE = "6c1f0001-4e8b-4a51-9d3e-656d62657201"
REQUEST = "6c1f0002-4e8b-4a51-9d3e-656d62657201"
ANSWER = "6c1f0003-4e8b-4a51-9d3e-656d62657201"
NAME = "Ember"

# The most a request may carry: a few minutes of 16 kHz recording.
MOST_BYTES = 16 * 1024 * 1024
# The smallest and largest answer frame a watch may ask for.
SMALLEST_FRAME = 20
LARGEST_FRAME = 512

_START = struct.Struct(">cHIH")
_CONTINUE = struct.Struct(">cHI")
_FIRST = struct.Struct(">cHI")


class FrameError(ValueError):
    """A frame that does not fit the request it says it is part of."""


def request_frames(message: bytes, ident: int, size: int,
                   read_size: int) -> list[bytes]:
    """MESSAGE as request frames of at most SIZE bytes: what the watch
    writes. Here for tests, and to check the two agree."""

    first = _START.pack(b"S", ident, len(message), read_size)
    room = size - len(first)
    frames = [first + message[:room]]
    at = room
    while at < len(message):
        head = _CONTINUE.pack(b"C", ident, at)
        frames.append(head + message[at:at + size - len(head)])
        at += size - len(head)
    return frames


def pack_request(method: str, path: str, query: str = "",
                 headers: Optional[dict] = None, body: bytes = b"") -> bytes:
    head = {"m": method, "p": path, "q": query, "h": headers or {}}
    return json.dumps(head).encode() + b"\n" + body


def unpack(message: bytes) -> tuple[dict, bytes]:
    line, _, body = message.partition(b"\n")
    try:
        head = json.loads(line)
    except ValueError as exc:
        raise FrameError(f"not a message: {exc}") from None
    if not isinstance(head, dict):
        raise FrameError("not a message")
    return head, body


@dataclass
class Exchange:
    """One request coming in, and then its answer going out."""

    ident: int = 0
    total: int = 0
    read_size: int = 180
    got: bytearray = field(default_factory=bytearray)
    answer: Optional[bytes] = None
    sent: int = 0
    asked: bool = False


class Link:
    """The frames of one watch's requests, put together, handed to
    HANDLE, and its answers given back a frame at a time."""

    def __init__(self, handle: Callable[[bytes], None]) -> None:
        self.handle = handle
        self.now = Exchange()
        self.lock = threading.Lock()

    def write(self, frame: bytes) -> None:
        """A frame the watch wrote. A complete request goes to HANDLE."""

        if not frame:
            return
        with self.lock:
            kind = frame[:1]
            if kind == b"S" and len(frame) >= _START.size:
                _, ident, total, read_size = _START.unpack_from(frame)
                if total > MOST_BYTES:
                    self._refuse(ident, 413, "That is too much to send.")
                    return
                self.now = Exchange(
                    ident=ident, total=total,
                    read_size=max(SMALLEST_FRAME,
                                  min(LARGEST_FRAME, read_size)),
                )
                self.now.got += frame[_START.size:]
            elif kind == b"C" and len(frame) >= _CONTINUE.size:
                _, ident, offset = _CONTINUE.unpack_from(frame)
                if ident != self.now.ident or self.now.answer is not None:
                    return  # an old request's, after a new one started
                if offset != len(self.now.got):
                    self._refuse(ident, 400, "Part of the request was lost. "
                                 "Send it again.")
                    return
                self.now.got += frame[_CONTINUE.size:]
            else:
                return
            done = (len(self.now.got) >= self.now.total
                    and not self.now.asked and self.now.answer is None)
            if done:
                self.now.asked = True
                message = bytes(self.now.got[:self.now.total])
        if done:
            self.handle(message)

    def _refuse(self, ident: int, status: int, why: str) -> None:
        self.now = Exchange(ident=ident, asked=True)
        self.now.answer = answer_message(
            status, "application/json", json.dumps({"detail": why}).encode())

    def answered(self, ident: int, message: bytes) -> None:
        with self.lock:
            if ident == self.now.ident:
                self.now.answer = message

    def read(self) -> bytes:
        """The next frame of the answer, for one read by the watch."""

        with self.lock:
            now = self.now
            if now.answer is None:
                return b"W" if now.asked else b"E"
            if now.sent >= len(now.answer) and now.sent:
                return b"E"
            if now.sent == 0:
                head = _FIRST.pack(b"R", now.ident, len(now.answer))
            else:
                head = _CONTINUE.pack(b"C", now.ident, now.sent)
            piece = now.answer[now.sent:now.sent + now.read_size - len(head)]
            now.sent += len(piece)
            return head + piece


def answer_message(status: int, kind: str, body: bytes) -> bytes:
    return json.dumps({"s": status, "t": kind}).encode() + b"\n" + body


async def ask(app: Any, message: bytes) -> bytes:
    """Put one request message to APP, the ASGI app the HTTP API is, and
    give back its answer message."""

    try:
        head, body = unpack(message)
    except FrameError as exc:
        return answer_message(400, "application/json",
                              json.dumps({"detail": str(exc)}).encode())
    headers = [(str(k).lower().encode(), str(v).encode())
               for k, v in (head.get("h") or {}).items()]
    headers.append((b"content-length", str(len(body)).encode()))
    scope = {
        "type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
        "method": str(head.get("m") or "GET").upper(),
        "scheme": "http", "path": str(head.get("p") or "/"),
        "raw_path": str(head.get("p") or "/").encode(),
        "query_string": str(head.get("q") or "").encode(),
        "root_path": "", "headers": headers,
        "client": ("bluetooth", 0), "server": ("bluetooth", 0),
    }
    sent = False

    async def receive() -> dict:
        nonlocal sent
        if sent:
            await asyncio.sleep(3600)
            return {"type": "http.disconnect"}
        sent = True
        return {"type": "http.request", "body": body, "more_body": False}

    status = 500
    kind = "application/octet-stream"
    parts: list[bytes] = []

    async def send(event: dict) -> None:
        nonlocal status, kind
        if event["type"] == "http.response.start":
            status = int(event["status"])
            for name, value in event.get("headers", []):
                if name.lower() == b"content-type":
                    kind = value.decode()
        elif event["type"] == "http.response.body":
            parts.append(event.get("body", b""))

    await app(scope, receive, send)
    return answer_message(status, kind, b"".join(parts))


class Peripheral:
    """This computer as a Bluetooth LE peripheral, answering with APP."""

    def __init__(self, app: Any) -> None:
        self.app = app
        self.server: Any = None
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        self.link = Link(self._handle)

    def _handle(self, message: bytes) -> None:
        ident = self.link.now.ident

        async def answer() -> None:
            try:
                said = await ask(self.app, message)
            except Exception as exc:  # noqa: BLE001  (said to the watch)
                said = answer_message(500, "application/json", json.dumps(
                    {"detail": f"The server had a problem: {exc}"}).encode())
            self.link.answered(ident, said)

        assert self.loop is not None  # nosec B101
        asyncio.run_coroutine_threadsafe(answer(), self.loop)

    async def start(self) -> None:
        from bless import (  # the optional "bluetooth" extra
            BlessServer,
            GATTAttributePermissions,
            GATTCharacteristicProperties,
        )

        self.loop = asyncio.get_running_loop()
        server = BlessServer(name=NAME, loop=self.loop)
        server.read_request_func = self._read
        server.write_request_func = self._write
        await server.add_new_service(SERVICE)
        await server.add_new_characteristic(
            SERVICE, REQUEST,
            GATTCharacteristicProperties.write
            | GATTCharacteristicProperties.write_without_response,
            None, GATTAttributePermissions.writeable,
        )
        await server.add_new_characteristic(
            SERVICE, ANSWER, GATTCharacteristicProperties.read, None,
            GATTAttributePermissions.readable,
        )
        await server.start()
        self.server = server

    async def stop(self) -> None:
        if self.server is not None:
            await self.server.stop()
            self.server = None

    def _read(self, characteristic: Any, **_: Any) -> bytearray:
        if str(characteristic.uuid).lower() == ANSWER:
            return bytearray(self.link.read())
        return bytearray()

    def _write(self, characteristic: Any, value: Any, **_: Any) -> None:
        if str(characteristic.uuid).lower() == REQUEST:
            self.link.write(bytes(value))


def available() -> str:
    """Why Bluetooth can't be used here, or "" when it can."""

    try:
        import bless  # noqa: F401
    except ImportError:
        return ("Bluetooth needs bless: pip install 'ember-server"
                "[bluetooth]', or run the installer again.")
    return ""
