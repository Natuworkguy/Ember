"""The server the watch syncs with, and AI tools talk to.

Every request needs the token, as `Authorization: Bearer <token>`. The
token comes from EMBER_TOKEN, or from the file `ember token --save`
wrote. Notes are kept in EMBER_DATA (~/.ember unless set): ember.db, and
the recordings in audio/.

  POST   /notes                  save a note (its id is the client's)
  GET    /notes?since=           what changed since a revision, to sync
  GET    /notes/search?q=        find notes
  GET    /notes/{id}             one note
  PATCH  /notes/{id}             change its text or tags
  DELETE /notes/{id}             delete it
  PUT    /notes/{id}/audio       its recording, a WAV file
  GET    /notes/{id}/audio       the recording back
  GET    /tags                   the tags in use
  GET    /health                 whether the server and the token work
  POST   /pair                   trade a code from `ember pair` for the
                                 token: the one request without it
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import secrets
import threading
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from . import __version__
from .banners import Banners
from .pairing import local_name
from .store import MAX_TEXT, NoteError, Store
from .transcribe import Unheard, transcribe, warm

MAX_AUDIO = 25 * 1024 * 1024
PAIR_MINUTES = 10
PAIR_TRIES = 5
_pairing = threading.Lock()


def home() -> Path:
    return Path(os.environ.get("EMBER_DATA") or Path.home() / ".ember")


def token_file() -> Path:
    return home() / "token"


def new_pairing(data: Path) -> str:
    """A six-digit code the watch can trade for the token, once, in the
    next ten minutes."""

    code = f"{secrets.randbelow(10**6):06d}"
    path = data / "pairing.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    with _pairing:
        path.write_text(json.dumps({
            "code": code, "until": time.time() + PAIR_MINUTES * 60,
            "tries": 0,
        }), encoding="utf-8")
        os.chmod(path, 0o600)
    return code


def redeem(data: Path, code: str) -> bool:
    """Whether CODE is the one `ember pair` made. It works once, and five
    wrong tries use it up."""

    path = data / "pairing.json"
    with _pairing:
        try:
            pairing = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        if time.time() > pairing.get("until", 0):
            path.unlink(missing_ok=True)
            return False
        if hmac.compare_digest(str(code).strip().encode(),
                               str(pairing.get("code")).encode()):
            path.unlink(missing_ok=True)
            return True
        pairing["tries"] = pairing.get("tries", 0) + 1
        if pairing["tries"] >= PAIR_TRIES:
            path.unlink(missing_ok=True)
        else:
            path.write_text(json.dumps(pairing), encoding="utf-8")
        return False


def configured_token() -> str:
    """The token from EMBER_TOKEN, or the one `ember token --save` kept."""

    token = os.environ.get("EMBER_TOKEN", "").strip()
    if token:
        return token
    try:
        return token_file().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


@dataclass
class Config:
    token: str
    data: Path
    # A banner for each new idea: in Isola's island when it's running,
    # otherwise as this computer's own notification.
    banners: bool = False
    # Answer the watch over Bluetooth LE (ble.py), beside HTTP.
    bluetooth: bool = False
    # Where the watch can reach the API over Wi-Fi, when it is open to the
    # network: told to the watch in /health, so it can fall back on them
    # when Bluetooth can't reach this computer.
    addresses: list[str] = field(default_factory=list)


class NoteIn(BaseModel):
    id: Optional[str] = None
    text: str = Field("", max_length=MAX_TEXT)
    created_at: Optional[str] = None
    source: str = "api"
    tags: list[str] = Field(default_factory=list)
    # The recording follows, at PUT /notes/{id}/audio.
    audio: bool = False


class Pairing(BaseModel):
    code: str = Field(max_length=12)


class NoteChange(BaseModel):
    text: Optional[str] = Field(None, max_length=MAX_TEXT)
    tags: Optional[list[str]] = None
    add_tags: Optional[list[str]] = None
    remove_tags: Optional[list[str]] = None


def create_app(config: Optional[Config] = None) -> FastAPI:
    if config is None:
        config = Config(
            token=configured_token(), data=home(),
            # EMBER_ISOLA is its first name, from when only Isola had them.
            banners="1" in (os.environ.get("EMBER_BANNERS", ""),
                            os.environ.get("EMBER_ISOLA", "")),
        )
    if not config.token:
        raise SystemExit(
            "Ember needs a token: run `ember token --save`, or set "
            "EMBER_TOKEN."
        )
    store = Store(config.data / "ember.db")
    audio_dir = config.data / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)

    banners = Banners()

    def added(note: dict) -> None:
        if config.banners:
            banners.add(note)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        threading.Thread(target=warm, name="ember-warm", daemon=True).start()
        peripheral = None
        starting = None
        if config.bluetooth:
            from .ble import Peripheral

            async def start_bluetooth() -> None:
                # In the background: HTTP answers at once, even where
                # Bluetooth is slow to start, or never does (no radio, or
                # no permission yet).
                nonlocal peripheral
                made = Peripheral(app)
                try:
                    await made.start()
                except Exception as exc:  # noqa: BLE001  (said, and HTTP goes on)
                    print(f"Bluetooth could not start: {exc}", flush=True)
                    return
                peripheral = made
                print("Bluetooth: waiting for the watch.", flush=True)

            starting = asyncio.create_task(start_bluetooth())
        yield
        if starting is not None and not starting.done():
            starting.cancel()
        if peripheral is not None:
            await peripheral.stop()
        store.close()

    app = FastAPI(title="Ember", version=__version__, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store = store
    app.state.config = config

    def authorized(request: Request) -> None:
        given = request.headers.get("authorization", "")
        scheme, _, token = given.partition(" ")
        if scheme.lower() != "bearer" or not hmac.compare_digest(
            token.strip().encode(), config.token.encode()
        ):
            raise HTTPException(
                401, "Wrong or missing token.",
                headers={"WWW-Authenticate": "Bearer"},
            )

    @app.exception_handler(NoteError)
    async def note_error(_: Request, exc: NoteError) -> JSONResponse:
        status = 404 if str(exc).startswith("No note") else 400
        return JSONResponse({"detail": str(exc)}, status_code=status)

    @app.post("/pair")
    def pair(pairing: Pairing) -> dict:
        if not redeem(config.data, pairing.code):
            raise HTTPException(
                403, "That code is wrong, or has run out. Run `ember pair` "
                "for a new one.",
            )
        # Its name too: the watch falls back on it if the address it
        # paired with changes.
        return {"token": config.token, "name": local_name(),
                "addresses": config.addresses}

    @app.get("/health", dependencies=[Depends(authorized)])
    def health() -> dict:
        return {"ok": True, "name": "ember", "version": __version__,
                "search": "fts5" if store.searchable else "like",
                "addresses": config.addresses}

    @app.post("/notes", dependencies=[Depends(authorized)])
    def create(note: NoteIn) -> JSONResponse:
        made, new = store.create(
            note.text, note_id=note.id or "", source=note.source,
            tags=note.tags, created_at=note.created_at or "",
            audio=note.audio,
        )
        if new and (made["text"] or not note.audio):
            added(made)
        return JSONResponse(made, status_code=201 if new else 200)

    @app.get("/notes", dependencies=[Depends(authorized)])
    def changes(since: str = "", limit: int = 200) -> dict:
        return store.changes(since, limit)

    @app.get("/notes/search", dependencies=[Depends(authorized)])
    def search(q: str = "", since: str = "", until: str = "", tag: str = "",
               source: str = "", limit: int = 20) -> dict:
        return {"notes": store.find(q, since=since, until=until, tag=tag,
                                    source=source, limit=limit)}

    @app.get("/notes/{note_id}", dependencies=[Depends(authorized)])
    def one(note_id: str) -> dict:
        # One in the trash too, saying so.
        note = store.get(note_id, trashed=True)
        if note is None:
            raise NoteError(f"No note {note_id}.")
        return note

    @app.patch("/notes/{note_id}", dependencies=[Depends(authorized)])
    def change(note_id: str, change: NoteChange) -> dict:
        return store.update(note_id, text=change.text, tags=change.tags,
                            add_tags=change.add_tags,
                            remove_tags=change.remove_tags)

    @app.delete("/notes/{note_id}", dependencies=[Depends(authorized)])
    def delete(note_id: str, forever: bool = False) -> dict:
        """To the trash; with ?forever=true, out of the database."""

        if forever:
            return store.delete_forever(note_id)
        return store.delete(note_id)

    @app.post("/notes/{note_id}/restore", dependencies=[Depends(authorized)])
    def restore(note_id: str) -> dict:
        return store.restore(note_id)

    @app.get("/trash", dependencies=[Depends(authorized)])
    def trash(limit: int = 200) -> dict:
        return {"notes": store.find(trashed=True, limit=limit)}

    @app.delete("/trash", dependencies=[Depends(authorized)])
    def empty_trash() -> dict:
        return {"deleted": store.empty_trash()}

    def hear(note_id: str, path: Path) -> None:
        try:
            text, ok = transcribe(path.read_bytes()), True
        except (Unheard, OSError) as exc:
            text, ok = str(exc), False
        note = store.transcribed(note_id, text if ok else "", ok)
        if note and ok:
            added(note)

    @app.put("/notes/{note_id}/audio", dependencies=[Depends(authorized)])
    async def put_audio(note_id: str, request: Request,
                        later: BackgroundTasks) -> dict:
        note = store.get(note_id)
        if note is None:
            raise NoteError(f"No note {note_id}.")
        body = bytearray()
        async for piece in request.stream():
            body += piece
            if len(body) > MAX_AUDIO:
                raise HTTPException(413, "A recording can be at most 25 MB.")
        if not body:
            raise NoteError("No recording was sent.")
        path = audio_dir / f"{note['id']}.wav"
        partial = path.with_suffix(".part")
        partial.write_bytes(bytes(body))
        partial.replace(path)
        note = store.set_audio(note["id"], path)
        if note["transcription"] == "pending":
            later.add_task(hear, note["id"], path)
        return note

    @app.get("/notes/{note_id}/audio", dependencies=[Depends(authorized)])
    def get_audio(note_id: str) -> FileResponse:
        path = store.audio_path(note_id)
        if path is None or not path.is_file():
            raise HTTPException(404, "That note has no recording.")
        return FileResponse(path, media_type="audio/wav")

    @app.get("/tags", dependencies=[Depends(authorized)])
    def tags() -> dict:
        return {"tags": store.tags()}

    return app
