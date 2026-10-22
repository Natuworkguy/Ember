"""Your notes, full screen in the terminal: `ember`, or `ember notes`.

Grouped by day, newest first, with the one you're on shown whole below.
Ideas from the watch slide in while it's open.

  ↑ ↓  j k     move              /     search, as you type
  enter        read it whole     t     pick a tag
  n            new note          e     edit in $EDITOR
  #            change tags       d     delete
  c            copy the text     p     play its recording
  ?            these keys        q     quit
"""

from __future__ import annotations

import curses
import os
import platform
import shlex
import shutil
import subprocess  # nosec B404
import tempfile
import textwrap
import time
import unicodedata
from datetime import datetime
from typing import Optional

from .store import NoteError, Store

# A flame, and "ember" in figlet's small font.
LOGO = (
    ("   )   ", r"           _             "),
    ("  ) \\  ", r" ___ _ __ | |__  ___ _ _ "),
    (" / ) ( ", r"/ -_) '  \| '_ \/ -_) '_|"),
    (" \\(_)/ ", r"\___|_|_|_|_.__/\___|_|  "),
)
LOGO_WIDTH = max(len(f) + len(w) for f, w in LOGO)

POLL_SECONDS = 1.5
FRESH_SECONDS = 4.0

ORANGE, AMBER, DIM, PICKED, GOOD, BAD, FRESH = range(1, 8)


def width(text: str) -> int:
    """How many columns TEXT takes: wide characters, emoji, take two."""

    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1
               for c in text)


def fit(text: str, room: int) -> str:
    """TEXT on one line, cut to ROOM columns with an ellipsis."""

    # One line: but spaces are kept, for padding and boxes.
    text = text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    if width(text) <= room:
        return text
    out, used = "", 0
    for c in text:
        w = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if used + w > room - 1:
            break
        out += c
        used += w
    return out + "…"


def when(stamp: str) -> datetime:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()


def day_of(moment: datetime, now: datetime) -> str:
    days = (now.date() - moment.date()).days
    if days == 0:
        return "Today"
    if days == 1:
        return "Yesterday"
    if days < 7:
        return "This week"
    if days < 31:
        return "This month"
    return "Earlier"


def short_time(moment: datetime, now: datetime) -> str:
    days = (now.date() - moment.date()).days
    if days < 1:
        return moment.strftime("%H:%M")
    if days < 7:
        return moment.strftime("%a %H:%M")
    if moment.year == now.year:
        return moment.strftime("%b %d")
    return moment.strftime("%b %Y")


def about(note: dict) -> str:
    """Its id, when, where from, and its recording."""

    bits = [note["id"][:8], when(note["created_at"]).strftime(
        "%a %b %d %Y, %H:%M"), f"from {note['source']}"]
    if note["audio"]:
        bits.append({"pending": "recording, being heard",
                     "failed": "recording, not heard"}.get(
            note["transcription"], "recording"))
    return " · ".join(bits)


def extra_tags(note: dict) -> list[str]:
    """Its tags that its text doesn't already show as #hashtags."""

    said = note["text"].lower()
    return [t for t in note["tags"] if f"#{t}" not in said]


def shown_text(note: dict) -> str:
    if note["text"]:
        return note["text"]
    if note["transcription"] == "pending":
        return "(a recording, being heard)"
    return "(a recording that could not be heard)"


class Browser:
    def __init__(self, store: Store, screen) -> None:
        self.store = store
        self.screen = screen
        self.query = ""
        self.tag = ""
        self.notes: list[dict] = []
        self.rows: list[Optional[dict]] = []  # None: a day's heading
        self.labels: dict[int, str] = {}
        self.at = 0            # the selected row
        self.top = 0           # the first row on screen
        self.reading = False
        self.said = ""         # a line at the bottom, for a while
        self.said_good = True
        self.said_until = 0.0
        self.seen: set[str] = set()
        self.fresh: dict[str, float] = {}
        self.rev = -1
        self.started = False

    # --- Data -------------------------------------------------------------

    def load(self, keep: Optional[str] = None) -> None:
        keep = keep or (self.current or {}).get("id")
        self.notes = self.store.find(self.query, tag=self.tag, limit=500)
        if not self.query:
            self.notes.sort(key=lambda n: n["created_at"], reverse=True)
        now = datetime.now().astimezone()
        ids = {n["id"] for n in self.notes}
        if self.started:
            for new in ids - self.seen:
                self.fresh[new] = time.monotonic() + FRESH_SECONDS
        self.seen |= ids
        self.started = True
        self.rows, self.labels = [], {}
        heading = None
        for note in self.notes:
            day = "Matches" if self.query else day_of(
                when(note["created_at"]), now)
            if day != heading:
                self.labels[len(self.rows)] = day
                self.rows.append(None)
                heading = day
            self.rows.append(note)
        self.rev = self.store.latest()
        place = next((i for i, n in enumerate(self.rows)
                      if n and n["id"] == keep), None)
        self.at = place if place is not None else self.first()
        self.at = min(self.at, max(0, len(self.rows) - 1))

    def first(self) -> int:
        return next((i for i, n in enumerate(self.rows) if n), 0)

    @property
    def current(self) -> Optional[dict]:
        if 0 <= self.at < len(self.rows):
            return self.rows[self.at]
        return None

    def wait_key(self):
        """The next key. The screen's timeout, there for the live list,
        isn't a key: keep waiting."""

        while True:
            try:
                return self.screen.get_wch()
            except curses.error:
                continue

    def say(self, text: str, good: bool = True) -> None:
        self.said, self.said_good = text, good
        self.said_until = time.monotonic() + 3

    # --- Drawing ----------------------------------------------------------

    def put(self, y: int, x: int, text: str, attr: int = 0) -> None:
        h, w = self.screen.getmaxyx()
        if 0 <= y < h and x < w:
            try:
                self.screen.addstr(y, x, fit(text, w - x) if text else "",
                                   attr)
            except curses.error:
                pass  # the bottom-right cell can't be written

    def head_rows(self, h: int, w: int) -> int:
        """How many rows the header takes: the whole logo when there's
        room for it, a line when there isn't."""

        return len(LOGO) + 1 if h >= 20 and w >= LOGO_WIDTH + 20 else 2

    def draw(self) -> None:
        s = self.screen
        s.erase()
        h, w = s.getmaxyx()
        if h < 8 or w < 30:
            self.put(0, 0, "Make the window bigger.", curses.A_BOLD)
            s.refresh()
            return
        top = self.head_rows(h, w)
        self.draw_head(top, w)
        if self.reading and self.current:
            self.draw_reading(top, h - 2, w)
        else:
            split = max(top + 2, h - 2 - min(9, (h - top - 1) // 3))
            self.draw_list(top, split, w)
            self.draw_preview(split, h - 2, w)
        self.draw_foot(h - 1, w)
        s.refresh()

    def draw_head(self, top: int, w: int) -> None:
        count = f"{len(self.notes)} note{'s' if len(self.notes) != 1 else ''}"
        bits = [count]
        if self.query:
            bits.append(f"matching “{self.query}”")
        if self.tag:
            bits.append(f"#{self.tag}")
        about = " · ".join(bits)
        if top == 2:
            self.put(0, 1, ")\\ ember", curses.color_pair(ORANGE)
                     | curses.A_BOLD)
            self.put(0, 11, about, curses.color_pair(DIM))
        else:
            for y, (flame, word) in enumerate(LOGO):
                # The flame shades from its tip down: amber, then orange.
                tip = AMBER if y < 2 else ORANGE
                self.put(y, 1, flame, curses.color_pair(tip) | curses.A_BOLD)
                self.put(y, 1 + len(flame), word,
                         curses.color_pair(ORANGE) | curses.A_BOLD)
            self.put(len(LOGO) - 1, LOGO_WIDTH + 4, about,
                     curses.color_pair(DIM))
        self.put(top - 1, 0, "─" * w, curses.color_pair(DIM))

    def draw_list(self, y0: int, y1: int, w: int) -> None:
        room = y1 - y0
        if not self.rows:
            empty = ("Nothing matches." if self.query or self.tag else
                     "No ideas yet. Say one to your watch, or press n.")
            self.put(y0 + 1, 3, empty, curses.color_pair(DIM))
            return
        if self.at < self.top:
            self.top = self.at
            # Keep a note's day heading in sight above it.
            if self.top > 0 and self.rows[self.top - 1] is None:
                self.top -= 1
        if self.at >= self.top + room:
            self.top = self.at - room + 1
        now = datetime.now().astimezone()
        shown = range(self.top, len(self.rows))
        for y, i in zip(range(y0, y1), shown, strict=False):
            note = self.rows[i]
            if note is None:
                self.put(y, 2, self.labels[i].upper(),
                         curses.color_pair(DIM) | curses.A_BOLD)
                continue
            picked = i == self.at
            fresh = self.fresh.get(note["id"], 0) > time.monotonic()
            base = curses.color_pair(PICKED) if picked else 0
            if picked:
                self.put(y, 0, " " * (w - 1), base)
                self.put(y, 1, "▌", curses.color_pair(ORANGE) | base)
            stamp = short_time(when(note["created_at"]), now)
            self.put(y, 3, f"{stamp:>9}", curses.color_pair(DIM) | base)
            tags = " ".join("#" + t for t in extra_tags(note)[:3])
            tag_room = min(width(tags), max(0, w // 3)) if tags else 0
            text_room = w - 15 - (tag_room + 2 if tag_room else 0)
            words = fit(shown_text(note), max(8, text_room))
            look = base | (curses.color_pair(FRESH) | curses.A_BOLD
                           if fresh else 0)
            if not note["text"]:
                look |= curses.color_pair(DIM)
            if note["audio"]:
                self.put(y, 13, "♪", curses.color_pair(AMBER) | base)
            self.put(y, 15, words, look)
            if tag_room:
                self.put(y, w - tag_room - 1, fit(tags, tag_room),
                         curses.color_pair(AMBER) | base)

    def draw_preview(self, y0: int, y1: int, w: int) -> None:
        self.put(y0, 0, "─" * w, curses.color_pair(DIM))
        note = self.current
        if not note:
            return
        self.put(y0 + 1, 2, about(note), curses.color_pair(DIM))
        lines = textwrap.wrap(shown_text(note), max(10, w - 4)) or [""]
        room = y1 - y0 - 2
        for k, line in enumerate(lines[:room]):
            more = k == room - 1 and len(lines) > room
            self.put(y0 + 2 + k, 2, line + (" …" if more else ""))

    def draw_reading(self, y0: int, y1: int, w: int) -> None:
        note = self.current
        self.put(y0, 2, about(note), curses.color_pair(DIM))
        if note["tags"]:
            self.put(y0 + 1, 2, " ".join("#" + t for t in note["tags"]),
                     curses.color_pair(AMBER))
        lines: list[str] = []
        for para in shown_text(note).split("\n"):
            lines += textwrap.wrap(para, max(10, min(w - 4, 88))) or [""]
        for k, line in enumerate(lines[: y1 - y0 - 3]):
            self.put(y0 + 3 + k, 2, line)

    def draw_foot(self, y: int, w: int) -> None:
        if self.said and time.monotonic() < self.said_until:
            colour = GOOD if self.said_good else BAD
            self.put(y, 1, self.said, curses.color_pair(colour))
            return
        keys = ("enter back  e edit  # tags  d delete  c copy  q quit"
                if self.reading else
                "/ search  t tag  n new  e edit  # tags  d delete  "
                "c copy  p play  ? help  q quit")
        self.put(y, 1, keys, curses.color_pair(DIM))

    # --- Asking -----------------------------------------------------------

    def ask(self, prompt: str, start: str = "", live=None) -> Optional[str]:
        """A line typed at the bottom: None if Esc. LIVE hears each
        change, for search as you type."""

        text = start
        curses.curs_set(1)
        try:
            while True:
                self.draw()
                h, w = self.screen.getmaxyx()
                self.put(h - 1, 0, " " * (w - 1))
                self.put(h - 1, 1, prompt, curses.color_pair(ORANGE)
                         | curses.A_BOLD)
                shown = text[-(w - width(prompt) - 4):]
                self.put(h - 1, 2 + width(prompt), shown)
                try:
                    self.screen.move(h - 1, min(
                        w - 2, 2 + width(prompt) + width(shown)))
                except curses.error:
                    pass
                key = self.wait_key()
                if key in ("\x1b",):
                    return None
                if key in ("\n", "\r", curses.KEY_ENTER):
                    return text
                if key in (curses.KEY_BACKSPACE, "\x7f", "\b"):
                    text = text[:-1]
                elif key == "\x15":  # ctrl-u
                    text = ""
                elif isinstance(key, str) and key.isprintable():
                    text += key
                else:
                    continue
                if live:
                    live(text)
        finally:
            curses.curs_set(0)

    def confirm(self, prompt: str) -> bool:
        h, w = self.screen.getmaxyx()
        self.put(h - 1, 0, " " * (w - 1))
        self.put(h - 1, 1, prompt + "  y / n",
                 curses.color_pair(BAD) | curses.A_BOLD)
        self.screen.refresh()
        return self.wait_key() in ("y", "Y")

    def pick_tag(self) -> None:
        tags = self.store.tags()
        if not tags:
            self.say("No tags yet. Say #something in a note.", False)
            return
        choices = [{"tag": "", "notes": None}] + tags
        at = next((i for i, t in enumerate(choices)
                   if t["tag"] == self.tag), 0)
        while True:
            self.draw()
            h, w = self.screen.getmaxyx()
            box_h = min(len(choices) + 2, h - 4)
            box_w = min(max(width(t["tag"]) for t in choices) + 16, w - 4)
            y0, x0 = self.head_rows(h, w), max(2, w - box_w - 2)
            top = max(0, at - (box_h - 3))
            for y in range(box_h):
                self.put(y0 + y, x0, " " * box_w, curses.color_pair(PICKED))
            self.put(y0, x0 + 2, "Tags", curses.color_pair(ORANGE)
                     | curses.color_pair(PICKED) | curses.A_BOLD)
            for k, t in enumerate(choices[top: top + box_h - 2]):
                i = top + k
                label = "All notes" if not t["tag"] else f"#{t['tag']}"
                count = "" if t["notes"] is None else str(t["notes"])
                look = (curses.A_REVERSE if i == at else
                        curses.color_pair(PICKED))
                line = f" {fit(label, box_w - 8):<{box_w - 8}}{count:>4} "
                self.put(y0 + 1 + k, x0 + 1, line, look)
            key = self.wait_key()
            if key in ("\x1b", "q", "t"):
                return
            if key in (curses.KEY_UP, "k"):
                at = max(0, at - 1)
            elif key in (curses.KEY_DOWN, "j"):
                at = min(len(choices) - 1, at + 1)
            elif key in ("\n", "\r", curses.KEY_ENTER):
                self.tag = choices[at]["tag"]
                self.load()
                return

    # --- Doing ------------------------------------------------------------

    def move(self, by: int) -> None:
        if not self.rows:
            return
        i = self.at
        while True:
            i += by
            if not 0 <= i < len(self.rows):
                return
            if self.rows[i] is not None:
                self.at = i
                return

    def page(self, by: int) -> None:
        h, _ = self.screen.getmaxyx()
        for _ in range(max(1, h // 2)):
            self.move(by)

    def search(self) -> None:
        before = self.query

        def live(text: str) -> None:
            self.query = text.strip()
            self.load()

        got = self.ask("/", self.query, live)
        if got is None:
            self.query = before
        else:
            self.query = got.strip()
        self.load()

    def new(self) -> None:
        text = self.ask("New idea:")
        if text and text.strip():
            note, _ = self.store.create(text, source="cli")
            self.seen.add(note["id"])
            self.load(keep=note["id"])
            self.say("Saved.")

    def edit(self) -> None:
        note = self.current
        if not note:
            return
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or (
            "nano" if shutil.which("nano") else "vi")
        with tempfile.NamedTemporaryFile(
            "w+", suffix=".md", prefix="ember-", delete=False,
            encoding="utf-8",
        ) as file:
            file.write(note["text"])
            path = file.name
        curses.endwin()
        try:
            subprocess.call([*shlex.split(editor), path])  # nosec B603
            with open(path, encoding="utf-8") as file:
                text = file.read().strip()
        finally:
            os.unlink(path)
            # The editor had the terminal: paint it all again.
            self.screen.clear()
        if text and text != note["text"]:
            self.store.update(note["id"], text=text)
            self.load()
            self.say("Changed.")
        elif not text:
            self.say("Left as it was: a note can't be empty.", False)

    def retag(self) -> None:
        note = self.current
        if not note:
            return
        now = " ".join("#" + t for t in note["tags"])
        got = self.ask("Tags:", now + (" " if now else ""))
        if got is None:
            return
        tags = [w.lstrip("#") for w in got.split() if w.lstrip("#")]
        self.store.update(note["id"], tags=tags)
        self.load()
        self.say("Tagged." if tags else "Tags cleared.")

    def delete(self) -> None:
        note = self.current
        if note and self.confirm("Delete this note?"):
            self.move(1) if self.at + 1 < len(self.rows) else self.move(-1)
            self.store.delete(note["id"])
            self.load()
            self.say("Deleted.")

    def copy(self) -> None:
        note = self.current
        if not note or not note["text"]:
            return
        for command in (["pbcopy"], ["wl-copy"],
                        ["xclip", "-selection", "clipboard"], ["clip"]):
            if shutil.which(command[0]):
                subprocess.run(command, input=note["text"],  # nosec B603
                               text=True, check=False)
                self.say("Copied.")
                return
        self.say("No clipboard command here (pbcopy, wl-copy, xclip).", False)

    def play(self) -> None:
        note = self.current
        path = note and self.store.audio_path(note["id"])
        if not path or not path.exists():
            self.say("That note has no recording.", False)
            return
        player = {"Darwin": ["afplay"], "Linux": ["paplay"]}.get(
            platform.system(), [])
        if player and not shutil.which(player[0]):
            player = ["aplay", "-q"] if shutil.which("aplay") else []
        if not player:
            self.say(f"Its recording is at {path}", True)
            return
        subprocess.Popen(  # nosec B603
            [*player, str(path)], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        self.say("Playing.")

    def help(self) -> None:
        self.draw()
        h, w = self.screen.getmaxyx()
        lines = __doc__.split("\n\n", 2)[2].rstrip().split("\n")
        box_w = min(max(width(x) for x in lines) + 6, w - 2)
        y0 = max(2, (h - len(lines) - 4) // 2)
        x0 = max(1, (w - box_w) // 2)
        for y in range(len(lines) + 4):
            self.put(y0 + y, x0, " " * box_w, curses.color_pair(PICKED))
        self.put(y0 + 1, x0 + 3, "Keys", curses.color_pair(ORANGE)
                 | curses.color_pair(PICKED) | curses.A_BOLD)
        for k, line in enumerate(lines):
            self.put(y0 + 3 + k, x0 + 1, line, curses.color_pair(PICKED))
        self.screen.refresh()
        self.wait_key()

    # --- Running ----------------------------------------------------------

    def run(self) -> None:
        self.load()
        self.screen.timeout(int(POLL_SECONDS * 1000))
        last_poll = time.monotonic()
        while True:
            self.draw()
            try:
                key = self.screen.get_wch()
            except curses.error:
                key = None  # no key before the timeout
            if time.monotonic() - last_poll >= POLL_SECONDS:
                last_poll = time.monotonic()
                if self.store.latest() != self.rev:
                    self.load()
            if key is None:
                continue
            try:
                if self.handle(key) is False:
                    return
            except NoteError as exc:
                self.say(str(exc), False)

    def handle(self, key) -> Optional[bool]:
        if key in ("q", "Q") or (key == "\x1b" and not self.reading
                                 and not self.query and not self.tag):
            return False
        if key == "\x1b":
            if self.reading:
                self.reading = False
            else:
                self.query, self.tag = "", ""
                self.load()
        elif key in (curses.KEY_UP, "k"):
            self.move(-1)
        elif key in (curses.KEY_DOWN, "j"):
            self.move(1)
        elif key in (curses.KEY_PPAGE,):
            self.page(-1)
        elif key in (curses.KEY_NPAGE, " "):
            self.page(1)
        elif key in (curses.KEY_HOME, "g"):
            self.at = self.first()
        elif key in (curses.KEY_END, "G"):
            self.at = len(self.rows) - 1
        elif key in ("\n", "\r", curses.KEY_ENTER):
            self.reading = not self.reading and self.current is not None
        elif key == "/":
            self.search()
        elif key == "t":
            self.pick_tag()
        elif key == "n":
            self.new()
        elif key == "e":
            self.edit()
        elif key == "#":
            self.retag()
        elif key == "d":
            self.delete()
        elif key == "c":
            self.copy()
        elif key == "p":
            self.play()
        elif key == "?":
            self.help()
        elif key == "r":
            self.load()
        return None


def _colours() -> None:
    curses.start_color()
    try:
        curses.use_default_colors()
        back = -1
    except curses.error:
        back = curses.COLOR_BLACK
    rich = curses.COLORS >= 256
    curses.init_pair(ORANGE, 208 if rich else curses.COLOR_RED, back)
    curses.init_pair(AMBER, 214 if rich else curses.COLOR_YELLOW, back)
    curses.init_pair(DIM, 244 if rich else curses.COLOR_WHITE, back)
    curses.init_pair(PICKED, -1 if back == -1 else curses.COLOR_WHITE,
                     236 if rich else curses.COLOR_BLUE)
    curses.init_pair(GOOD, 114 if rich else curses.COLOR_GREEN, back)
    curses.init_pair(BAD, 203 if rich else curses.COLOR_RED, back)
    curses.init_pair(FRESH, 215 if rich else curses.COLOR_YELLOW, back)


def browse(store: Store) -> None:
    def main(screen) -> None:
        curses.curs_set(0)
        if curses.has_colors():
            _colours()
        Browser(store, screen).run()

    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(main)
