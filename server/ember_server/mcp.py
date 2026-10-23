"""ember mcp: your notes as tools, over the Model Context Protocol.

An MCP client (Flash, or any other) starts `ember mcp` and talks to it
over its standard input and output, a JSON-RPC message a line. It works
on the notes in ~/.ember directly, so it needs no `ember serve`, and no
token: it is a program on this computer, run by you.

Only one runs at a time. A new one stops the one already running and
takes over, so a client started again never finds an old one left behind
holding on.
"""

from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess  # nosec B404
import sys
import time
from datetime import datetime
from typing import Callable

from . import __version__
from .store import NoteError, Store

PROTOCOL = "2025-06-18"
PID_FILE = "mcp.pid"
# How long the one already running has to stop before it is made to.
STOP_SECONDS = 3.0

INSTRUCTIONS = (
    "The user keeps ideas in Ember, mostly said aloud to their Apple "
    "Watch. When they ask what they thought, planned or noted about "
    "something, search Ember before answering, and quote the notes you "
    "use with their dates. \"This week\" is since 7d."
)

WHEN = ("An ISO date or time (2026-10-21), or how long ago: 24h, 7d, 2w, "
        "3m.")
TAGS = {"type": "array", "items": {"type": "string"}}
ID = {"type": "string",
      "description": "The note's id as search shows it, or its first 4 "
      "or more characters."}

TOOLS: list[dict] = [
    {
        "name": "search",
        "description": (
            "Search the user's Ember notes: ideas they said to their watch, "
            "and notes saved for them. By words (any order, the start of a "
            "word will do), time, tag and source; with no query, the "
            "newest. Best matches first. Use it whenever the user asks "
            "what they thought, planned or noted about something."
        ),
        "inputSchema": {"type": "object", "properties": {
            "query": {"type": "string",
                      "description": "Words to look for. Leave out for the "
                      "newest."},
            "since": {"type": "string",
                      "description": "Made at or after this. " + WHEN},
            "until": {"type": "string",
                      "description": "Made before this. " + WHEN},
            "tag": {"type": "string", "description": "Only with this tag."},
            "source": {"type": "string",
                       "description": "Only from here: watch, cli, mcp or "
                       "api."},
            "limit": {"type": "integer",
                      "description": "At most this many, up to 100. 20 "
                      "unless set."},
        }},
        "annotations": {"title": "Search Ember", "readOnlyHint": True},
    },
    {
        "name": "note",
        "description": "One Ember note, whole, by its id from search.",
        "inputSchema": {"type": "object", "properties": {"id": ID},
                        "required": ["id"]},
        "annotations": {"title": "Read an Ember note", "readOnlyHint": True},
    },
    {
        "name": "tags",
        "description": "Every tag in use in Ember, with how many notes "
        "have it.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"title": "Ember's tags", "readOnlyHint": True},
    },
    {
        "name": "save",
        "description": "Save a new note to Ember for the user. #hashtags "
        "in the text become tags too.",
        "inputSchema": {"type": "object", "properties": {
            "text": {"type": "string"}, "tags": TAGS,
        }, "required": ["text"]},
        "annotations": {"title": "Save to Ember", "readOnlyHint": False,
                        "destructiveHint": False},
    },
    {
        "name": "change",
        "description": "Change an Ember note: text replaces its text, tags "
        "replaces every tag, add_tags and remove_tags change some.",
        "inputSchema": {"type": "object", "properties": {
            "id": ID, "text": {"type": "string"}, "tags": TAGS,
            "add_tags": TAGS, "remove_tags": TAGS,
        }, "required": ["id"]},
        "annotations": {"title": "Change an Ember note",
                        "readOnlyHint": False, "destructiveHint": True},
    },
    {
        "name": "delete",
        "description": "Move an Ember note to the trash. restore brings it "
        "back.",
        "inputSchema": {"type": "object", "properties": {"id": ID},
                        "required": ["id"]},
        "annotations": {"title": "Move an Ember note to the trash",
                        "readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "restore",
        "description": "Bring an Ember note back from the trash.",
        "inputSchema": {"type": "object", "properties": {"id": ID},
                        "required": ["id"]},
        "annotations": {"title": "Restore an Ember note",
                        "readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "delete_forever",
        "description": "Delete an Ember note forever, from the trash or "
        "not, recording and all. It cannot be undone: only when the user "
        "asks for exactly that.",
        "inputSchema": {"type": "object", "properties": {"id": ID},
                        "required": ["id"]},
        "annotations": {"title": "Delete an Ember note forever",
                        "readOnlyHint": False, "destructiveHint": True},
    },
]


# --- What the tools say ---------------------------------------------------


def when(stamp: str) -> str:
    try:
        moment = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return stamp
    return moment.astimezone().strftime("%a %b %d %Y, %H:%M")


def line(note: dict) -> str:
    tags = " ".join("#" + t for t in note.get("tags", []))
    head = (f"[{note['id']}] {when(note['created_at'])}, "
            f"from {note['source']}")
    text = note.get("text") or (
        "(a recording, not yet heard)"
        if note.get("transcription") == "pending"
        else "(a recording that could not be heard)")
    return f"{head}{'  ' + tags if tags else ''}\n{text}"


class Tools:
    """The tools, on the notes in STORE."""

    def __init__(self, store: Store) -> None:
        self.store = store
        self.run: dict[str, Callable[[dict], str]] = {
            "search": self.search, "note": self.note, "tags": self.tags,
            "save": self.save, "change": self.change, "delete": self.delete,
            "restore": self.restore, "delete_forever": self.delete_forever,
        }

    def _id(self, args: dict, trashed: bool = False) -> str:
        given = str(args.get("id") or "").strip()
        if not given:
            raise NoteError("Give the note's id, as search shows it.")
        found = self.store.get(given, trashed=trashed)
        if found is not None and found["trashed"] == trashed:
            return found["id"]
        return self.store.resolve(given, trashed=trashed)

    def search(self, args: dict) -> str:
        found = self.store.find(
            str(args.get("query") or ""),
            since=str(args.get("since") or ""),
            until=str(args.get("until") or ""),
            tag=str(args.get("tag") or ""),
            source=str(args.get("source") or ""),
            limit=min(int(args.get("limit") or 20), 100),
        )
        if not found:
            return "No notes found."
        count = f"{len(found)} note{'s' if len(found) != 1 else ''}"
        return count + ":\n\n" + "\n\n".join(map(line, found))

    def note(self, args: dict) -> str:
        return line(self.store.get(self._id(args)))

    def tags(self, _: dict) -> str:
        found = self.store.tags()
        if not found:
            return "No tags yet."
        return ", ".join(f"#{t['tag']} ({t['notes']})" for t in found)

    def save(self, args: dict) -> str:
        made, _ = self.store.create(str(args.get("text") or ""),
                                    source="mcp", tags=args.get("tags"))
        return "Saved.\n" + line(made)

    def change(self, args: dict) -> str:
        changes = {k: args[k] for k in ("text", "tags", "add_tags",
                                        "remove_tags")
                   if args.get(k) is not None}
        if not changes:
            raise NoteError(
                "Say what to change: text, tags, add_tags or remove_tags.")
        return "Changed.\n" + line(self.store.update(self._id(args),
                                                     **changes))

    def delete(self, args: dict) -> str:
        note_id = self._id(args)
        self.store.delete(note_id)
        return f"Moved note {note_id} to the trash. restore brings it back."

    def restore(self, args: dict) -> str:
        return "Restored.\n" + line(self.store.restore(
            self._id(args, trashed=True)))

    def delete_forever(self, args: dict) -> str:
        try:
            note_id = self._id(args)
        except NoteError:
            note_id = self._id(args, trashed=True)
        self.store.delete_forever(note_id)
        return f"Deleted note {note_id} forever."


# --- The protocol ---------------------------------------------------------


def answer(tools: Tools, message: dict) -> dict | None:
    """The reply to one MESSAGE, or None for a notification."""

    method = message.get("method")
    params = message.get("params") or {}
    if "id" not in message:
        return None

    def ok(result: dict) -> dict:
        return {"jsonrpc": "2.0", "id": message["id"], "result": result}

    def error(code: int, text: str) -> dict:
        return {"jsonrpc": "2.0", "id": message["id"],
                "error": {"code": code, "message": text}}

    if method == "initialize":
        return ok({
            "protocolVersion": params.get("protocolVersion") or PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "ember", "version": __version__},
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        name = str(params.get("name") or "")
        if name not in tools.run:
            return error(-32602, f"No tool called {name!r}.")
        args = params.get("arguments")
        try:
            text, failed = tools.run[name](
                args if isinstance(args, dict) else {}), False
        except (NoteError, ValueError, TypeError) as exc:
            text, failed = str(exc), True
        return ok({"content": [{"type": "text", "text": text}],
                   "isError": failed})
    return error(-32601, f"No method {method!r}.")


def serve(tools: Tools, reading=None, writing=None) -> None:
    """Answer each line of READING on WRITING, until it closes."""

    reading = reading or sys.stdin
    writing = writing or sys.stdout
    for raw in reading:
        if not raw.strip():
            continue
        try:
            message = json.loads(raw)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None,
                     "error": {"code": -32700, "message": "Not JSON."}}
        else:
            reply = answer(tools, message) if isinstance(message, dict) \
                else None
        if reply is not None:
            writing.write(json.dumps(reply) + "\n")
            writing.flush()


# --- One at a time --------------------------------------------------------


def _is_ours(pid: int) -> bool:
    """Whether PID is a running `ember mcp`, not some other program that
    has since been given its number."""

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    except OSError:
        # Windows: os.kill with 0 is not a check there.
        return os.name == "nt"
    if os.name == "nt":
        return True
    try:
        command = subprocess.run(  # nosec B603 B607
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return "ember" in command and "mcp" in command


def _gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return True
    return False


def take_over(pid_file) -> None:
    """Stop the `ember mcp` already running, if there is one, and mark
    this one as the one running."""

    try:
        old = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        old = 0
    if old and old != os.getpid() and _is_ours(old):
        print(f"ember mcp: stopping the one already running ({old}).",
              file=sys.stderr)
        try:
            os.kill(old, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + STOP_SECONDS
        while time.monotonic() < deadline and not _gone(old):
            time.sleep(0.1)
        if not _gone(old) and hasattr(signal, "SIGKILL"):
            try:
                os.kill(old, signal.SIGKILL)
            except OSError:
                pass
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    pid_file.write_text(str(os.getpid()), encoding="utf-8")

    def let_go() -> None:
        # Only this one's mark: a newer one may have taken over since.
        try:
            if pid_file.read_text(encoding="utf-8").strip() == \
                    str(os.getpid()):
                pid_file.unlink()
        except OSError:
            pass

    atexit.register(let_go)
    # Stopped by a newer one: leave through atexit, which lets go only
    # of a mark that is still this one's.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def main() -> None:
    from .app import home

    take_over(home() / PID_FILE)
    store = Store(home() / "ember.db")
    try:
        serve(Tools(store))
    finally:
        store.close()
