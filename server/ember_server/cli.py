"""ember: run the server, make a token, pair the watch, and browse,
save, find and change notes from the terminal."""

from __future__ import annotations

import argparse
import os
import platform
import plistlib
import secrets
import shutil
import subprocess  # nosec B404
import sys
from pathlib import Path

from . import __version__

DEFAULT_PORT = 8765


def _addresses(port: int) -> list[str]:
    """The addresses the watch can reach this computer at, on the same
    network: its .local name first, which follows it to a new network."""

    from .pairing import lan_address, local_name

    return [f"http://{where}:{port}"
            for where in (local_name(), lan_address()) if where]


def serve(args: argparse.Namespace) -> None:
    import uvicorn

    from . import ble
    from .app import Config, configured_token, create_app, home

    bluetooth = args.bluetooth
    if bluetooth:
        missing = ble.available()
        if missing:
            print(missing)
            bluetooth = False
    open_to_network = args.host not in ("127.0.0.1", "localhost", "::1")
    addresses = _addresses(args.port) if open_to_network else []
    app = create_app(Config(
        token=configured_token(), data=home(),
        banners="1" in (os.environ.get("EMBER_BANNERS", ""),
                        os.environ.get("EMBER_ISOLA", "")),
        bluetooth=bluetooth, addresses=addresses,
    ))
    print(f"Ember {__version__}: notes in {home()}")
    if bluetooth:
        print("The watch syncs over Bluetooth, when it is near this "
              "computer.")
    if open_to_network:
        print("The API is open on the network too, at:")
        for address in addresses:
            print(f"  {address}")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


def token(args: argparse.Namespace) -> None:
    from .app import token_file

    made = secrets.token_urlsafe(32)
    if args.save:
        path = token_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(mode=0o600)
        path.write_text(made + "\n", encoding="utf-8")
        os.chmod(path, 0o600)
        print(f"Saved to {path}. Pair the watch with `ember pair`.")
    print(made)


def pair(args: argparse.Namespace) -> None:
    from .app import PAIR_MINUTES, configured_token, home, new_pairing

    if not configured_token():
        sys.exit("Make a token first: ember token --save")
    secret = new_pairing(home())
    print("With the watch near this computer, open Ember's settings and "
          "enter this pairing code:")
    print(f"\n    {secret[:3]} {secret[3:]}\n")
    print("The watch finds this computer over Bluetooth. Keep `ember "
          "serve` running.")
    print(f"It works once, for the next {PAIR_MINUTES} minutes.")


LABEL = "io.ember.server"


def launch_agent(program: str, banners: bool, log: Path) -> bytes:
    """A launchd job that keeps `ember serve` running while you are
    logged in on a Mac."""

    job = {
        "Label": LABEL,
        "ProgramArguments": [program, "serve"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
    }
    if banners:
        job["EnvironmentVariables"] = {"EMBER_BANNERS": "1"}
    return plistlib.dumps(job)


def systemd_unit(program: str, banners: bool = False) -> str:
    return (
        "[Unit]\nDescription=Ember, your watch's ideas\n"
        "After=network-online.target\n\n"
        f"[Service]\nExecStart={program} serve\nRestart=on-failure\n"
        + ("Environment=EMBER_BANNERS=1\n" if banners else "")
        + "\n[Install]\nWantedBy=default.target\n"
    )


def _run(*command: str) -> bool:
    """Run COMMAND quietly: whether it worked."""

    try:
        done = subprocess.run(  # nosec B603
            command, check=False, capture_output=True, text=True,
        )
    except OSError:
        return False
    return done.returncode == 0


def service(args: argparse.Namespace) -> None:
    from .app import configured_token, home

    program = shutil.which("ember") or os.path.abspath(sys.argv[0])
    system = platform.system()
    if system == "Darwin":
        path = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
        where = f"gui/{os.getuid()}"
        _run("launchctl", "bootout", where, str(path))
        if args.action == "remove":
            path.unlink(missing_ok=True)
            print("Ember no longer starts at login.")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        home().mkdir(parents=True, exist_ok=True)
        path.write_bytes(launch_agent(program, args.banners,
                                      home() / "server.log"))
        started = _run("launchctl", "bootstrap", where, str(path))
    elif system == "Linux":
        path = Path.home() / ".config" / "systemd" / "user" / "ember.service"
        if args.action == "remove":
            _run("systemctl", "--user", "disable", "--now", "ember.service")
            path.unlink(missing_ok=True)
            print("Ember no longer starts at login.")
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(systemd_unit(program, args.banners),
                        encoding="utf-8")
        started = _run("systemctl", "--user", "daemon-reload") and _run(
            "systemctl", "--user", "enable", "--now", "ember.service")
    else:
        sys.exit("Run `ember serve` at login with Task Scheduler.")
    if not configured_token():
        print("It needs a token first: ember token --save")
    if not started:
        sys.exit(f"Wrote {path}, but it could not be started. Run "
                 "`ember serve` yourself instead.")
    print(f"Ember starts at login now, and is running. ({path})")
    if args.banners:
        from .banners import isola_ready

        where = ("in Isola's island while Isola runs, otherwise as "
                 "notifications" if system == "Darwin" and isola_ready()
                 else "as notifications")
        print(f"New ideas show {where}.")


def _store():
    from .app import home
    from .store import Store

    return Store(home() / "ember.db")


def mcp(_: argparse.Namespace) -> None:
    from .mcp import main as run_mcp

    run_mcp()


def install_moonshine() -> None:
    """Install Moonshine into the Python Ember runs in: with its pip, or
    with uv for a venv uv made, which has none. Exits saying why when it
    cannot."""

    from .transcribe import MOONSHINE_PACKAGE

    print(f"Installing Moonshine into {sys.prefix}")
    has_pip = subprocess.run(  # nosec B603  (this Python, a fixed module)
        [sys.executable, "-m", "pip", "--version"],
        capture_output=True, check=False,
    ).returncode == 0
    uv = shutil.which("uv")
    if has_pip:
        argv = [sys.executable, "-m", "pip", "install", "--upgrade",
                MOONSHINE_PACKAGE]
    elif uv:
        argv = [uv, "pip", "install", "--python", sys.executable,
                "--upgrade", MOONSHINE_PACKAGE]
    else:
        sys.exit("This Python has no pip, and uv isn't installed. Install "
                 "uv (brew install uv), then try again.")
    if subprocess.run(argv, check=False).returncode:  # nosec B603
        sys.exit(
            "Moonshine could not be installed. It has builds for Apple "
            "Silicon Macs, Linux (x86 and ARM) and Windows, but not for "
            "an Intel Mac. There, set EMBER_VOSK_MODEL to a Vosk model "
            "folder instead."
        )


def hear(args: argparse.Namespace) -> None:
    from .transcribe import Unheard, moonshine, moonshine_size, transcribe

    if args.install:
        install_moonshine()
    try:
        if not args.wav:
            # Just getting it ready, so the first recording isn't kept
            # waiting on the download.
            size = moonshine_size()
            if not size:
                sys.exit("Moonshine is off (EMBER_MOONSHINE).")
            try:
                moonshine(size, quiet=False)
            except ImportError:
                sys.exit("Moonshine isn't installed: ember hear --install "
                         "adds it.")
            print(f"Moonshine's {size} model is ready."
                  + (" A running `ember serve` uses it from the next "
                     "recording." if args.install else ""))
            return
        print(transcribe(Path(args.wav).expanduser().read_bytes()))
    except (Unheard, OSError) as exc:
        sys.exit(str(exc))


def add(args: argparse.Namespace) -> None:
    text = " ".join(args.text) or sys.stdin.read()
    note, _ = _store().create(text, source="cli", tags=args.tag)
    print(note["id"])


def find(args: argparse.Namespace) -> None:
    """The notes matching, each whole: for reading, where list skims."""

    from .store import NoteError
    from .tui import about, shown_text

    try:
        found = _store().find(" ".join(args.query), since=args.since,
                              tag=args.tag, limit=args.limit)
    except NoteError as exc:
        sys.exit(str(exc))
    if not found:
        print("No notes found.")
        return
    for k, note in enumerate(found):
        if k:
            print()
        print(_paint(about(note), "2"))
        print(shown_text(note))


def notes(_: argparse.Namespace) -> None:
    from .tui import browse

    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        sys.exit("The notes browser needs a terminal. Try `ember list`.")
    browse(_store())


def _paint(text: str, code: str) -> str:
    """TEXT in a colour, when printing to a terminal."""

    if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
        return text
    return f"\033[{code}m{text}\033[0m"


def list_notes(args: argparse.Namespace) -> None:
    found = _store().find(" ".join(args.query), since=args.since,
                          tag=args.tag, limit=args.limit)
    if not args.query:
        found.sort(key=lambda n: n["created_at"], reverse=True)
    if not found:
        print("No notes.")
        return
    _print_list(found)


def _print_list(found: list[dict]) -> None:
    from datetime import datetime

    from .tui import extra_tags, fit, short_time, shown_text, when

    now = datetime.now().astimezone()
    room = shutil.get_terminal_size((100, 20)).columns
    for note in found:
        stamp = short_time(when(note["created_at"]), now)
        tags = " ".join("#" + t for t in extra_tags(note))
        text = shown_text(note)
        rest = room - 22 - (len(tags) + 1 if tags else 0)
        print(_paint(note["id"][:8], "38;5;208"),
              _paint(f"{stamp:>9}", "2"),
              " " + fit(text, max(10, rest)),
              _paint(tags, "38;5;214") if tags else "")


def _one(store, start: str, *, trash: bool = False) -> dict:
    """The note START begins its id: one in the trash if TRASH, or, for
    TRASH None, either."""

    from .store import NoteError

    try:
        if trash is None:
            try:
                return store.get(store.resolve(start))
            except NoteError:
                trash = True
        return store.get(store.resolve(start, trashed=bool(trash)),
                         trashed=bool(trash))
    except NoteError as exc:
        sys.exit(str(exc))


def show(args: argparse.Namespace) -> None:
    from .tui import about, shown_text

    note = _one(_store(), args.id)
    print(_paint(about(note), "2"))
    if note["tags"]:
        print(_paint(" ".join("#" + t for t in note["tags"]), "38;5;214"))
    print()
    print(shown_text(note))


def edit(args: argparse.Namespace) -> None:
    import shlex
    import subprocess  # nosec B404
    import tempfile

    store = _store()
    note = _one(store, args.id)
    text = " ".join(args.text).strip()
    if not text:
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or (
            "nano" if shutil.which("nano") else "vi")
        with tempfile.NamedTemporaryFile("w", suffix=".md", prefix="ember-",
                                         delete=False,
                                         encoding="utf-8") as file:
            file.write(note["text"])
        try:
            subprocess.call([*shlex.split(editor), file.name])  # nosec B603
            with open(file.name, encoding="utf-8") as done:
                text = done.read().strip()
        finally:
            os.unlink(file.name)
    if not text or text == note["text"]:
        print("Left as it was.")
        return
    store.update(note["id"], text=text)
    print("Changed.")


def remove(args: argparse.Namespace) -> None:
    from .tui import fit

    store = _store()
    if not args.forever:
        note = store.delete(_one(store, args.id)["id"])
        print(f"Moved to the trash. ember restore {note['id'][:8]} brings "
              "it back.")
        return
    note = _one(store, args.id, trash=None)
    if not args.yes:
        if not sys.stdin.isatty():
            sys.exit("Add --yes to delete forever without asking.")
        answer = input(f"Delete “{fit(note['text'] or 'a recording', 50)}”"
                       " forever? It can't be brought back. [y/N] ")
        if answer.strip().lower() not in ("y", "yes"):
            print("Kept.")
            return
    store.delete_forever(note["id"])
    print("Deleted forever.")


def restore(args: argparse.Namespace) -> None:
    store = _store()
    note = store.restore(_one(store, args.id, trash=True)["id"])
    print(f"Restored {note['id'][:8]}.")


def trash(args: argparse.Namespace) -> None:
    store = _store()
    if args.action == "empty":
        count = len(store.find(trashed=True, limit=500))
        if not count:
            print("The trash is empty.")
            return
        if not args.yes:
            if not sys.stdin.isatty():
                sys.exit("Add --yes to empty the trash without asking.")
            noun = "note" if count == 1 else "notes"
            answer = input(f"Delete the {count} {noun} in the trash "
                           "forever? [y/N] ")
            if answer.strip().lower() not in ("y", "yes"):
                print("Kept.")
                return
        print(f"Deleted {store.empty_trash()} forever.")
        return
    found = store.find(trashed=True, limit=500)
    if not found:
        print("The trash is empty.")
        return
    _print_list(found)
    print(_paint("ember restore <id> brings one back; ember trash empty "
                 "deletes them forever.", "2"))


def tag(args: argparse.Namespace) -> None:
    if not args.tags:
        sys.exit("Give tags to add, or -tag to remove: ember tag 3f2a idea")
    store = _store()
    note = _one(store, args.id)
    adding = [t for t in args.tags if not t.startswith("-")]
    removing = [t[1:] for t in args.tags if t.startswith("-")]
    note = store.update(note["id"], add_tags=[t.lstrip("+") for t in adding],
                        remove_tags=removing)
    print(" ".join("#" + t for t in note["tags"]) or "No tags.")


def export(args: argparse.Namespace) -> None:
    import json

    from .tui import when

    found = _store().find(since=args.since, tag=args.tag, limit=500)
    found.sort(key=lambda n: n["created_at"])
    if args.json:
        print(json.dumps(found, indent=2, ensure_ascii=False))
        return
    print("# Ember notes\n")
    for note in found:
        moment = when(note["created_at"]).strftime("%a %b %d %Y, %H:%M")
        tags = " ".join("#" + t for t in note["tags"])
        print(f"## {moment}{'  ' + tags if tags else ''}\n")
        print((note["text"] or "_(a recording that has no words yet)_")
              + "\n")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="ember", description="Ideas you say to your watch, kept here.",
    )
    parser.add_argument("--version", action="version",
                        version=f"ember {__version__}")
    commands = parser.add_subparsers(dest="command")

    commands.add_parser(
        "notes", help="browse your notes, full screen (just `ember` too)",
    ).set_defaults(go=notes)

    listed = commands.add_parser("list", help="list notes, newest first")
    listed.add_argument("query", nargs="*")
    listed.add_argument("--since", default="")
    listed.add_argument("--tag", default="")
    listed.add_argument("-n", "--limit", type=int, default=30)
    listed.set_defaults(go=list_notes)

    one = commands.add_parser("show", help="show one note, by its id")
    one.add_argument("id", help="its id, or the start of it")
    one.set_defaults(go=show)

    change = commands.add_parser(
        "edit", help="change a note: in $EDITOR, or give the new text")
    change.add_argument("id")
    change.add_argument("text", nargs="*")
    change.set_defaults(go=edit)

    gone = commands.add_parser(
        "rm", help="move a note to the trash, or delete it forever")
    gone.add_argument("id")
    gone.add_argument("-f", "--forever", action="store_true",
                      help="out of the database, recording and all; asks "
                      "first")
    gone.add_argument("-y", "--yes", action="store_true",
                      help="don't ask first")
    gone.set_defaults(go=remove)

    binned = commands.add_parser(
        "trash", help="the notes in the trash; empty deletes them forever")
    binned.add_argument("action", nargs="?", choices=["empty"])
    binned.add_argument("-y", "--yes", action="store_true",
                        help="don't ask first")
    binned.set_defaults(go=trash)

    back = commands.add_parser("restore", help="bring a note back from the "
                               "trash")
    back.add_argument("id")
    back.set_defaults(go=restore)

    tags = commands.add_parser(
        "tag", help="tag a note: ember tag 3f2a engine -old")
    tags.add_argument("id")
    # The rest as given, so -tag isn't taken for an option.
    tags.add_argument("tags", nargs=argparse.REMAINDER,
                      help="tags to add, or -tag to remove")
    tags.set_defaults(go=tag)

    out = commands.add_parser("export", help="every note, as Markdown")
    out.add_argument("--json", action="store_true")
    out.add_argument("--since", default="")
    out.add_argument("--tag", default="")
    out.set_defaults(go=export)

    run = commands.add_parser("serve", help="run the server")
    # The API, for this computer's own scripts: the watch comes over
    # Bluetooth. 0.0.0.0 opens it to the network too.
    run.add_argument("--host", default=os.environ.get("EMBER_HOST",
                                                      "127.0.0.1"))
    run.add_argument("--no-bluetooth", dest="bluetooth",
                     action="store_false",
                     default=os.environ.get("EMBER_BLUETOOTH", "1") != "0",
                     help="don't answer the watch over Bluetooth")
    run.add_argument("--port", type=int,
                     default=int(os.environ.get("EMBER_PORT", DEFAULT_PORT)))
    run.set_defaults(go=serve)

    made = commands.add_parser("token", help="make a new token")
    made.add_argument("--save", action="store_true",
                      help="keep it for `ember serve`, in ~/.ember/token")
    made.set_defaults(go=token)

    keep = commands.add_parser(
        "service", help="start the server at login, so the watch can "
        "always sync when you get home")
    keep.add_argument("action", nargs="?", choices=["install", "remove"],
                      default="install",
                      help="install (the default) starts it at login and "
                      "now; remove stops that")
    keep.add_argument("--banners", "--isola", action="store_true",
                      dest="banners",
                      help="a banner for each new idea: in Isola's island "
                      "when it's running, otherwise a notification")
    keep.set_defaults(go=service)

    link = commands.add_parser(
        "pair", help="make a code to pair the watch with")
    link.set_defaults(go=pair)

    note = commands.add_parser("add", help="save a note")
    note.add_argument("text", nargs="*")
    note.add_argument("--tag", action="append", default=[])
    note.set_defaults(go=add)

    tools = commands.add_parser(
        "mcp", help="your notes as tools for Flash or any MCP client, "
        "over standard input and output; stops one already running")
    tools.set_defaults(go=mcp)

    listen = commands.add_parser(
        "hear", help="the words in a WAV recording, as the server hears "
        "them; with none, download Moonshine's model ahead of time")
    listen.add_argument("wav", nargs="?", default="")
    listen.add_argument("--install", action="store_true",
                        help="install Moonshine first, which hears "
                        "recordings on this computer")
    listen.set_defaults(go=hear)

    look = commands.add_parser("find", help="find notes")
    look.add_argument("query", nargs="*")
    look.add_argument("--since", default="")
    look.add_argument("--tag", default="")
    look.add_argument("--limit", type=int, default=20)
    look.set_defaults(go=find)

    args = parser.parse_args(argv)
    if not args.command:
        # Just `ember`: the notes, in a terminal; otherwise, the commands.
        if sys.stdin.isatty() and sys.stdout.isatty():
            args.go = notes
        else:
            parser.print_help()
            return
    args.go(args)


if __name__ == "__main__":
    main()
