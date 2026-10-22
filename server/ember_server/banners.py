"""A banner for each new idea, wherever this computer can show one.

On a Mac with Isola running, in its island, through an isola://notify
link. Isola is only asked when it's running, so Ember never launches it,
and only when its "Show banners from other apps and scripts" is on.
Anywhere else, or when Isola can't take it: a Mac's own notification, or
a desktop notification on Linux (notify-send). No way to show one: none.

Ideas that arrive together, as a watch syncs when you get home, make one
banner, not a burst of them.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess  # nosec B404
import threading
from typing import Optional
from urllib.parse import urlencode

ISOLA_ID = "com.natuworkguy.isola"
GATHER_SECONDS = 2.0


def _run(*command: str, timeout: float = 5) -> Optional[str]:
    """What COMMAND printed, or None if it couldn't run or failed."""

    try:
        done = subprocess.run(  # nosec B603
            command, capture_output=True, text=True, timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def isola_ready() -> bool:
    """Whether Isola is running, and takes banners from other apps."""

    if _run("pgrep", "-x", "Isola") is None:
        return False
    said = _run("defaults", "read", ISOLA_ID, "notifyLinks")
    # Unset is Isola's default: on.
    return said is None or said.strip() not in ("0", "false", "NO")


def words(notes: list[dict]) -> tuple[str, str]:
    """A banner's title and text, for NOTES that arrived together."""

    def said(note: dict) -> str:
        return " ".join((note["text"] or "A recording, being heard.").split())

    if len(notes) == 1:
        title = "New idea" if notes[0]["source"] == "watch" else "Note saved"
        return title, said(notes[0])[:140]
    first = said(notes[0])[:100]
    return f"{len(notes)} new ideas", f"{first} and {len(notes) - 1} more"


def show(title: str, text: str, system: str = "") -> str:
    """Show one banner. Where it went: isola, mac, linux, or none."""

    system = system or platform.system()
    if system == "Darwin":
        if isola_ready():
            query = urlencode({"title": title, "text": text,
                               "symbol": "flame.fill", "color": "orange"})
            if _run("open", "-g", f"isola://notify?{query}") is not None:
                return "isola"
        # The text goes in as arguments, never into the script itself.
        script = ("on run argv\n"
                  "display notification (item 2 of argv) "
                  "with title (item 1 of argv)\n"
                  "end run")
        if _run("osascript", "-e", script, title, text) is not None:
            return "mac"
        return "none"
    if system == "Linux":
        desktop = os.environ.get("DISPLAY") or os.environ.get(
            "WAYLAND_DISPLAY")
        if desktop and shutil.which("notify-send") and _run(
            "notify-send", "--app-name=Ember", title, text,
        ) is not None:
            return "linux"
    return "none"


class Banners:
    """Gathers new notes for a moment, then shows one banner for them."""

    def __init__(self, system: str = "",
                 seconds: float = GATHER_SECONDS) -> None:
        self.system = system
        self.seconds = seconds
        self._waiting: list[dict] = []
        self._lock = threading.Lock()
        self._timer: Optional[threading.Timer] = None
        self.shown: list[tuple[str, str, str]] = []

    def add(self, note: dict) -> None:
        with self._lock:
            self._waiting.append(note)
            if self._timer is None:
                self._timer = threading.Timer(self.seconds, self.flush)
                self._timer.daemon = True
                self._timer.start()

    def flush(self) -> None:
        with self._lock:
            notes, self._waiting = self._waiting, []
            self._timer = None
        if notes:
            title, text = words(notes)
            self.shown.append((title, text, show(title, text, self.system)))
