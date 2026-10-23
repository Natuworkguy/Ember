"""The Bluetooth way in: frames put together, requests answered by the
same app as HTTP, and answers read back a frame at a time."""

import asyncio
import json
import struct

import pytest

from ember_server import ble
from ember_server.app import Config, create_app

TOKEN = "t0ken"


@pytest.fixture
def app(tmp_path):
    return create_app(Config(token=TOKEN, data=tmp_path))


def through(app, message, size=60, read_size=40):
    """MESSAGE sent as the watch sends it, and its answer read back."""

    loop = asyncio.new_event_loop()
    asked = []
    link = ble.Link(asked.append)
    for frame in ble.request_frames(message, 7, size, read_size):
        assert len(frame) <= size
        link.write(frame)
    assert link.read() == b"W"  # asked, not answered yet
    assert len(asked) == 1
    link.answered(7, loop.run_until_complete(ble.ask(app, asked[0])))
    loop.close()

    frames = []
    while True:
        frame = link.read()
        if frame == b"E":
            break
        assert len(frame) <= read_size
        frames.append(frame)
    _, ident, total = struct.unpack_from(">cHI", frames[0])
    body = frames[0][7:] + b"".join(f[7:] for f in frames[1:])
    assert ident == 7 and len(body) == total
    return ble.unpack(body)


def signed(method, path, body=b"", query=""):
    return ble.pack_request(method, path, query, {
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json"}, body)


def test_a_note_goes_up_and_comes_back(app):
    note = json.dumps({"id": "0b1e8c52-5f4f-4b0b-9a3e-1b2c3d4e5f60",
                       "text": "a game engine that runs in the browser "
                       "#engine", "created_at": "2026-10-23T09:00:00Z",
                       "source": "watch", "tags": [], "audio": False})
    head, body = through(app, signed("POST", "/notes", note.encode()))
    assert head["s"] in (200, 201)
    assert json.loads(body)["tags"] == ["engine"]

    head, body = through(app, signed("GET", "/notes", query="since=0"))
    assert head["s"] == 200 and head["t"].startswith("application/json")
    assert [n["text"][:6] for n in json.loads(body)["notes"]] == ["a game"]


def test_the_token_is_still_needed(app):
    head, _ = through(app, ble.pack_request("GET", "/health"))
    assert head["s"] == 401


def test_a_lost_frame_is_refused_not_guessed(app):
    message = signed("GET", "/health")
    asked = []
    link = ble.Link(asked.append)
    frames = ble.request_frames(message, 3, 30, 40)
    link.write(frames[0])
    link.write(frames[2])  # the second never came
    assert not asked
    first = link.read()
    rest = b""
    while (frame := link.read()) != b"E":
        rest += frame[7:]
    head, body = ble.unpack(first[7:] + rest)
    assert head["s"] == 400 and b"lost" in body


def test_too_much_is_refused(app):
    link = ble.Link(lambda m: pytest.fail("asked"))
    link.write(struct.pack(">cHIH", b"S", 1, ble.MOST_BYTES + 1, 40))
    frame = link.read()
    assert frame[:1] == b"R" and b"413" in frame


def test_nothing_asked_reads_as_the_end():
    assert ble.Link(lambda m: None).read() == b"E"
