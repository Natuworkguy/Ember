"""The notes, in one SQLite file.

A note is what was said: its text, when, where it came from (the watch,
Flash, the command line), its tags, and the recording it
came from, if it came as audio. Every change takes the next revision
number, so a client syncs by asking for everything after the last one it
saw, deletions included: a deleted note is kept as a tombstone with no
text, so the watch hears it is gone.

A note's id is the client's: the watch makes it when you save, so sending
the same note twice, after a dropped connection, saves it once.
"""

from __future__ import annotations

import json
import re
import sqlite3
import threading
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

SOURCES = ("watch", "cli", "flash", "api")
MAX_TEXT = 20_000
MAX_TAGS = 20
TAG_CHARS = 40
MAX_LIMIT = 500

# Transcription of a note that came as audio.
NONE = "none"
PENDING = "pending"
DONE = "done"
FAILED = "failed"

_HASHTAG = re.compile(r"(?<![\w#])#([A-Za-z][\w-]{0,39})")
_RELATIVE = re.compile(r"^\s*(\d+)\s*([hdwm])\s*$", re.IGNORECASE)
_WORD = re.compile(r"[\w']+", re.UNICODE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'api',
    tags TEXT NOT NULL DEFAULT '[]',
    audio_path TEXT,
    transcription TEXT NOT NULL DEFAULT 'none',
    deleted INTEGER NOT NULL DEFAULT 0,
    rev INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS notes_rev ON notes (rev);
CREATE INDEX IF NOT EXISTS notes_created ON notes (created_at);
"""

FTS = """
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5 (
    text, tags, content='notes', content_rowid='rowid'
);
CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts (rowid, text, tags)
    VALUES (new.rowid, new.text, new.tags);
END;
CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts (notes_fts, rowid, text, tags)
    VALUES ('delete', old.rowid, old.text, old.tags);
END;
CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts (notes_fts, rowid, text, tags)
    VALUES ('delete', old.rowid, old.text, old.tags);
    INSERT INTO notes_fts (rowid, text, tags)
    VALUES (new.rowid, new.text, new.tags);
END;
"""


class NoteError(ValueError):
    """A request that cannot be done as asked, and why."""


def now() -> str:
    return stamp(datetime.now(timezone.utc))


def stamp(when: datetime) -> str:
    """WHEN as the notes keep it: UTC, to the microsecond, so the text
    sorts as the time does."""

    if when.tzinfo is None:
        when = when.astimezone()
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_time(text: str, *, end: bool = False) -> str:
    """A time a client gave: ISO 8601 (a date alone is its start, or
    with END its end), or how long ago, as 24h, 7d, 2w, 3m."""

    text = str(text or "").strip()
    found = _RELATIVE.match(text)
    if found:
        amount, unit = int(found.group(1)), found.group(2).lower()
        days = {"h": amount / 24, "d": amount, "w": amount * 7,
                "m": amount * 30}[unit]
        return stamp(datetime.now(timezone.utc) - timedelta(days=days))
    try:
        when = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise NoteError(
            f"{text!r} is not a time: give 2026-10-21, 2026-10-21T14:05, "
            "or how long ago, as 7d."
        ) from None
    if len(text) == 10 and end:
        when += timedelta(days=1)
    return stamp(when)


def clean_tags(tags: Any, text: str = "") -> list[str]:
    """TAGS as kept: lowercase, no #, each once, with the #hashtags in
    TEXT added."""

    found: list[str] = []
    given = tags if isinstance(tags, (list, tuple)) else (
        str(tags).split(",") if tags else []
    )
    for tag in [*given, *_HASHTAG.findall(text or "")]:
        tag = str(tag).strip().lstrip("#").lower()[:TAG_CHARS]
        if tag and tag not in found:
            found.append(tag)
    return found[:MAX_TAGS]


def key(note_id: str) -> str:
    """A note's id as kept: a UUID, in lowercase. Clients may send it in
    capitals: Swift's UUID does."""

    text = str(note_id or "").strip()
    try:
        return str(uuid.UUID(text))
    except ValueError:
        return text.lower()


class Store:
    """The notes in the SQLite file at PATH, safe to use from threads."""

    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(
            str(self.path), check_same_thread=False, isolation_level=None,
        )
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._lock:
            self._db.execute("PRAGMA journal_mode=WAL")
            self._db.executescript(SCHEMA)
            try:
                self._db.executescript(FTS)
                self.searchable = True
            except sqlite3.OperationalError:
                # An SQLite built without FTS5 searches by LIKE instead.
                self.searchable = False

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # --- Reading ------------------------------------------------------

    @staticmethod
    def _note(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "text": row["text"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "source": row["source"],
            "tags": json.loads(row["tags"] or "[]"),
            "audio": bool(row["audio_path"]),
            "transcription": row["transcription"],
            "deleted": bool(row["deleted"]),
            "rev": row["rev"],
        }

    def get(self, note_id: str, *, deleted: bool = False) -> Optional[dict]:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM notes WHERE id = ?", (key(note_id),),
            ).fetchone()
        if row is None or (row["deleted"] and not deleted):
            return None
        return self._note(row)

    def audio_path(self, note_id: str) -> Optional[Path]:
        with self._lock:
            row = self._db.execute(
                "SELECT audio_path FROM notes WHERE id = ? AND deleted = 0",
                (key(note_id),),
            ).fetchone()
        return Path(row["audio_path"]) if row and row["audio_path"] else None

    def changes(self, since: str = "", limit: int = 200) -> dict:
        """Every note changed after SINCE, deletions included, oldest
        change first: SINCE a revision from an earlier answer, or a
        time. The revision to ask after next, and whether there is
        more."""

        limit = max(1, min(int(limit or 200), MAX_LIMIT))
        since = str(since or "").strip()
        if since.isdigit() or not since:
            where, value = "rev > ?", int(since or 0)
        else:
            where, value = "updated_at > ?", parse_time(since)
        with self._lock:
            rows = self._db.execute(
                f"SELECT * FROM notes WHERE {where} "  # nosec B608
                "ORDER BY rev LIMIT ?", (value, limit + 1),
            ).fetchall()
            top = self._db.execute(
                "SELECT COALESCE(MAX(rev), 0) FROM notes",
            ).fetchone()[0]
        more = len(rows) > limit
        notes = [self._note(r) for r in rows[:limit]]
        cursor = notes[-1]["rev"] if notes else (
            value if isinstance(value, int) else top
        )
        return {"notes": notes, "cursor": cursor, "more": more}

    def find(
        self, query: str = "", *, since: str = "", until: str = "",
        tag: str = "", source: str = "", limit: int = 20,
    ) -> list[dict]:
        """Notes matching QUERY's words (any order, the start of a word
        will do), made between SINCE and UNTIL, with TAG, from SOURCE:
        the best matches first, or with no QUERY, the newest."""

        limit = max(1, min(int(limit or 20), MAX_LIMIT))
        clauses = ["n.deleted = 0"]
        values: list[Any] = []
        if since:
            clauses.append("n.created_at >= ?")
            values.append(parse_time(since))
        if until:
            clauses.append("n.created_at < ?")
            values.append(parse_time(until, end=True))
        if tag:
            clauses.append("EXISTS (SELECT 1 FROM json_each(n.tags) "
                           "WHERE json_each.value = ?)")
            values.append(clean_tags([tag])[0] if clean_tags([tag]) else "")
        if source:
            clauses.append("n.source = ?")
            values.append(source)
        words = _WORD.findall(query or "")
        with self._lock:
            if words and self.searchable:
                match = " ".join(
                    '"' + w.replace('"', "") + '"*' for w in words
                )
                rows = self._db.execute(
                    "SELECT n.* FROM notes_fts f JOIN notes n "
                    "ON n.rowid = f.rowid WHERE notes_fts MATCH ? AND "
                    + " AND ".join(clauses)  # nosec B608
                    + " ORDER BY bm25(notes_fts), n.created_at DESC LIMIT ?",
                    (match, *values, limit),
                ).fetchall()
            else:
                for word in words:
                    clauses.append("(n.text LIKE ? OR n.tags LIKE ?)")
                    values += [f"%{word}%", f"%{word.lower()}%"]
                rows = self._db.execute(
                    "SELECT n.* FROM notes n WHERE "
                    + " AND ".join(clauses)  # nosec B608
                    + " ORDER BY n.created_at DESC LIMIT ?",
                    (*values, limit),
                ).fetchall()
        return [self._note(r) for r in rows]

    def latest(self) -> int:
        """The newest revision: when it moves, something changed."""

        with self._lock:
            return self._db.execute(
                "SELECT COALESCE(MAX(rev), 0) FROM notes",
            ).fetchone()[0]

    def resolve(self, start: str) -> str:
        """The id of the one note whose id starts with START, as git takes
        a short hash."""

        start = str(start or "").strip().lower()
        if len(start) < 4:
            raise NoteError("Give at least 4 characters of the note's id.")
        with self._lock:
            rows = self._db.execute(
                "SELECT id FROM notes WHERE deleted = 0 AND id LIKE ?"
                " LIMIT 2", (start.replace("%", "").replace("_", "") + "%",),
            ).fetchall()
        if not rows:
            raise NoteError(f"No note {start}.")
        if len(rows) > 1:
            raise NoteError(f"More than one note starts {start}: give more.")
        return rows[0]["id"]

    def tags(self) -> list[dict]:
        """Every tag in use, with how many notes have it, most first."""

        with self._lock:
            rows = self._db.execute(
                "SELECT json_each.value AS tag, COUNT(*) AS notes "
                "FROM notes, json_each(notes.tags) WHERE notes.deleted = 0 "
                "GROUP BY json_each.value ORDER BY notes DESC, tag",
            ).fetchall()
        return [{"tag": r["tag"], "notes": r["notes"]} for r in rows]

    # --- Writing ------------------------------------------------------

    def _next_rev(self) -> int:
        return self._db.execute(
            "SELECT COALESCE(MAX(rev), 0) + 1 FROM notes",
        ).fetchone()[0]

    def create(
        self, text: str = "", *, note_id: str = "", source: str = "api",
        tags: Any = None, created_at: str = "", audio: bool = False,
    ) -> tuple[dict, bool]:
        """Save a note. With NOTE_ID, the client's own, a note already
        saved under it is given back as it is. The note, and whether it
        is new."""

        text = str(text or "").strip()
        if len(text) > MAX_TEXT:
            raise NoteError(f"A note can be at most {MAX_TEXT} characters.")
        if not text and not audio:
            raise NoteError("A note needs its text, or a recording.")
        source = source if source in SOURCES else "api"
        if note_id:
            try:
                note_id = str(uuid.UUID(str(note_id)))
            except ValueError:
                raise NoteError("A note's id has to be a UUID.") from None
        else:
            note_id = str(uuid.uuid4())
        made = parse_time(created_at) if created_at else now()
        with self._lock:
            had = self.get(note_id, deleted=True)
            if had is not None:
                return had, False
            self._db.execute(
                "INSERT INTO notes (id, text, created_at, updated_at, source,"
                " tags, transcription, rev) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (note_id, text, made, now(), source,
                 json.dumps(clean_tags(tags, text)),
                 PENDING if audio and not text else NONE, self._next_rev()),
            )
            return self.get(note_id), True

    def update(
        self, note_id: str, *, text: Optional[str] = None,
        tags: Any = None, add_tags: Any = None, remove_tags: Any = None,
    ) -> dict:
        with self._lock:
            note = self.get(note_id)
            if note is None:
                raise NoteError(f"No note {note_id}.")
            new_text = note["text"] if text is None else str(text).strip()
            if len(new_text) > MAX_TEXT:
                raise NoteError(
                    f"A note can be at most {MAX_TEXT} characters."
                )
            kept = clean_tags(note["tags"] if tags is None else tags)
            for tag in clean_tags(add_tags):
                if tag not in kept:
                    kept.append(tag)
            gone = set(clean_tags(remove_tags))
            kept = [t for t in clean_tags(kept, new_text if text is not None
                                          else "") if t not in gone]
            self._db.execute(
                "UPDATE notes SET text = ?, tags = ?, updated_at = ?, rev = ?"
                " WHERE id = ?",
                (new_text, json.dumps(kept[:MAX_TAGS]), now(),
                 self._next_rev(), note["id"]),
            )
            return self.get(note["id"])

    def delete(self, note_id: str) -> dict:
        """Delete a note, keeping a tombstone for clients to sync. Its
        recording goes with it."""

        with self._lock:
            note = self.get(note_id)
            if note is None:
                raise NoteError(f"No note {note_id}.")
            path = self.audio_path(note["id"])
            self._db.execute(
                "UPDATE notes SET text = '', tags = '[]', audio_path = NULL,"
                " deleted = 1, updated_at = ?, rev = ? WHERE id = ?",
                (now(), self._next_rev(), note["id"]),
            )
        if path is not None:
            path.unlink(missing_ok=True)
        return self.get(note["id"], deleted=True)

    def set_audio(self, note_id: str, path: Path) -> dict:
        with self._lock:
            note = self.get(note_id)
            if note is None:
                raise NoteError(f"No note {note_id}.")
            self._db.execute(
                "UPDATE notes SET audio_path = ?, transcription = ?,"
                " updated_at = ?, rev = ? WHERE id = ?",
                (str(path), PENDING if not note["text"] else NONE, now(),
                 self._next_rev(), note["id"]),
            )
            return self.get(note["id"])

    def transcribed(self, note_id: str, text: str, ok: bool) -> Optional[dict]:
        """What its recording said, written in, unless the note was
        given text meanwhile."""

        with self._lock:
            note = self.get(note_id)
            if note is None:
                return None
            body = note["text"] or (text.strip() if ok else "")
            self._db.execute(
                "UPDATE notes SET text = ?, tags = ?, transcription = ?,"
                " updated_at = ?, rev = ? WHERE id = ?",
                (body, json.dumps(clean_tags(note["tags"], body)),
                 DONE if ok else FAILED, now(), self._next_rev(), note["id"]),
            )
            return self.get(note["id"])
