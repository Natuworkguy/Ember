"""Pictures kept with a note: over HTTP, from the terminal and through Flash's tools."""

import base64
import struct
import zlib

import pytest
from fastapi.testclient import TestClient

from ember_server import mcp
from ember_server.app import Config, create_app
from ember_server.store import NoteError, Store, image_kind

TOKEN = "t0ken"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def png(colour=(255, 0, 0)):
    """A one-pixel PNG of COLOUR."""

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    raw = b"\x00" + bytes(colour)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


@pytest.fixture
def client(tmp_path):
    return TestClient(create_app(Config(token=TOKEN, data=tmp_path)))


def test_kinds_are_known_by_their_bytes():
    assert image_kind(png()) == "png"
    assert image_kind(b"\xff\xd8\xff\xe0rest") == "jpg"
    assert image_kind(b"RIFF\x00\x00\x00\x00WEBPVP8 ") == "webp"
    assert image_kind(b"\x00\x00\x00\x18ftypheic") == "heic"
    assert image_kind(b"hello") == ""


def test_a_picture_goes_up_comes_back_and_comes_off(client):
    note = client.post("/notes", json={"text": "Logo idea #brand"}, headers=AUTH).json()
    made = client.post(f"/notes/{note['id']}/images", content=png(), headers=AUTH).json()
    assert len(made["images"]) == 1 and made["images"][0].endswith(".png")
    assert made["rev"] > note["rev"]  # the watch hears of it at its next sync
    name = made["images"][0]
    got = client.get(f"/notes/{note['id']}/images/{name}", headers=AUTH)
    assert got.status_code == 200 and got.headers["content-type"] == "image/png" and got.content == png()
    # the same picture twice is kept once
    assert client.post(f"/notes/{note['id']}/images", content=png(), headers=AUTH).json()["images"] == [name]
    assert client.get(f"/notes/{note['id']}", headers=AUTH).json()["images"] == [name]
    gone = client.delete(f"/notes/{note['id']}/images/{name}", headers=AUTH).json()
    assert gone["images"] == []
    assert client.get(f"/notes/{note['id']}/images/{name}", headers=AUTH).status_code == 404


def test_what_is_not_a_picture_is_refused(client):
    note = client.post("/notes", json={"text": "x"}, headers=AUTH).json()
    said = client.post(f"/notes/{note['id']}/images", content=b"not a picture", headers=AUTH)
    assert said.status_code in (400, 422) and "picture" in said.text
    assert client.post(f"/notes/{note['id']}/images", content=png(), headers={}).status_code in (401, 403)


def test_deleting_forever_takes_its_pictures_too(tmp_path):
    store = Store(tmp_path / "notes.db")
    note, _ = store.create("Kitchen layout", source="cli")
    note = store.add_image(note["id"], png())
    folder = store.images_dir(note["id"])
    assert folder.is_dir()
    store.delete_forever(note["id"])
    assert not folder.exists()
    with pytest.raises(NoteError):
        store.add_image("nope", png())


def test_flash_attaches_a_picture_and_sees_it(tmp_path):
    store = Store(tmp_path / "notes.db")
    note, _ = store.create("Poster for the gig", source="watch")
    picture = tmp_path / "poster.png"
    picture.write_bytes(png((0, 128, 255)))
    tools = mcp.Tools(store)
    said = mcp.answer(tools, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                              "params": {"name": "attach_image", "arguments": {"id": note["id"], "path": str(picture)}}})
    assert not said["result"]["isError"] and "1 picture attached" in said["result"]["content"][0]["text"]
    seen = mcp.answer(tools, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                              "params": {"name": "note", "arguments": {"id": note["id"]}}})["result"]["content"]
    assert seen[0]["type"] == "text" and seen[1]["type"] == "image" and seen[1]["mimeType"] == "image/png"
    assert base64.b64decode(seen[1]["data"]) == png((0, 128, 255))
    missing = mcp.answer(tools, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                 "params": {"name": "attach_image", "arguments": {"id": note["id"], "path": "/no/such.png"}}})
    assert missing["result"]["isError"]
