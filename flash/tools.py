"""The tools Flash's model uses on your Ember notes, through Ember's own
API: python ./flash/tools.py <tool>, the model's arguments as JSON on
standard input."""

import json
import os
import sys
from datetime import datetime
from urllib.parse import quote, urlencode

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import call  # noqa: E402


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


def note_path(args: dict) -> str:
    note_id = str(args.get("id") or "").strip()
    if not note_id:
        sys.exit("Give the note's id, as search shows it.")
    return "/notes/" + quote(note_id, safe="")


def search(args: dict) -> str:
    query = {k: str(args[k]) for k in ("since", "until", "tag", "source")
             if args.get(k)}
    query["q"] = str(args.get("query") or "")
    query["limit"] = str(min(int(args.get("limit") or 20), 100))
    found = call("GET", "/notes/search?" + urlencode(query))["notes"]
    if not found:
        return "No notes found."
    count = f"{len(found)} note{'s' if len(found) != 1 else ''}"
    return count + ":\n\n" + "\n\n".join(map(line, found))


def note(args: dict) -> str:
    return line(call("GET", note_path(args)))


def tags(_: dict) -> str:
    found = call("GET", "/tags")["tags"]
    if not found:
        return "No tags yet."
    return ", ".join(f"#{t['tag']} ({t['notes']})" for t in found)


def save(args: dict) -> str:
    made = call("POST", "/notes", {
        "text": str(args.get("text") or ""), "source": "flash",
        "tags": args.get("tags") or [],
    })
    return "Saved.\n" + line(made)


def change(args: dict) -> str:
    body = {k: args[k] for k in ("text", "tags", "add_tags", "remove_tags")
            if args.get(k) is not None}
    if not body:
        sys.exit("Say what to change: text, tags, add_tags or remove_tags.")
    return "Changed.\n" + line(call("PATCH", note_path(args), body))


def delete(args: dict) -> str:
    call("DELETE", note_path(args))
    return f"Deleted note {args.get('id')}."


TOOLS = {"search": search, "note": note, "tags": tags, "save": save,
         "change": change, "delete": delete}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in TOOLS:
        sys.exit(f"Use: tools.py {'|'.join(TOOLS)}")
    try:
        given = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        sys.exit("The arguments were not JSON.")
    print(TOOLS[sys.argv[1]](given if isinstance(given, dict) else {}))
