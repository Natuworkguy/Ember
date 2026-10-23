<p align="center"><img src="assets/ember-logo-animated.svg" width="112" alt="Ember"></p>

# Ember

Raise your wrist, tap once, say the idea. Ember keeps it on the watch until it's near your computer, then hands it over Bluetooth to a small server running there. From there, [Flash](https://github.com/Natuworkguy/Flash) can search your ideas, add to them, and act on them, and you can browse them all in the terminal.

Why I built it: [I kept losing ideas, so I built an Apple Watch app that feeds my AI agent](https://dev.to/natuworkguy/i-kept-losing-ideas-so-i-built-an-apple-watch-app-that-feeds-my-ai-agent-1941).

```
 Apple Watch                      your computer                       Flash
 ───────────                      ─────────────                       ─────
 tap, speak, save  ─ Bluetooth ─▶ ember serve ◀──── MCP ──────  "what ideas did I
 kept on the watch              notes.db, recordings              have this week about
 until it's near                 a banner on each new idea         my game engine?"
```

- **Standalone watch app.** No iPhone app, and no iPhone needed at all. It even works on a Family Setup watch.
- **Never loses a note.** Every idea is saved on the watch first, in SwiftData, before anything leaves it. It syncs over Bluetooth when the watch is near your computer, and keeps trying until it does.
- **One tap to capture.** The big button, a complication, Siri ("New idea in Ember"), the Smart Stack, or the Action Button on an Ultra.
- **Local, and off the network.** The watch talks to your computer over Bluetooth LE, so neither needs Wi-Fi and nothing is open on your network. The server is one SQLite file on your computer. Recordings are transcribed there too. Nothing goes anywhere else.
- **An MCP server**, `ember mcp`, so Flash (or any MCP client) can read and write your notes, and **`ember`** in the terminal to browse them.

## How it hears you

Apple's speech APIs, the Speech framework (`SFSpeechRecognizer`) and the newer `SpeechAnalyzer` / `SpeechTranscriber`, are not available on watchOS. They exist on iPhone, iPad, Mac and Vision Pro only. So Ember uses the watch's own **system dictation**, through SwiftUI's `TextFieldLink`. It's the same dictation as Messages, and the best speech recognition a watch app can use:

- On Apple Watch Series 9 and later, and Ultra 2, dictation runs on the watch itself, with no network.
- Older watches need Wi-Fi or cellular to dictate.

For when dictation isn't there, or when you'd rather just talk, there's **Record**. Ember saves a 16 kHz WAV on the watch. When it syncs, your server hears it with [Moonshine](https://github.com/moonshine-ai/moonshine), a speech-to-text model that runs on your own computer, and the transcript comes back to the watch on its own. The watch keeps checking for a couple of minutes after the upload, so a short note's words usually show up in a few seconds, with a tap on your wrist. Until then it shows 👂. Nothing leaves your computer: the model downloads once, into `~/.ember/models`.

Moonshine comes with the installer. Installed without it, `ember hear --install` adds it later, and a running server uses it from the next recording. Without it (`--no-moonshine`, or a computer it has no build for, like an Intel Mac), the server hears recordings with Flash's listening model if Flash is installed in the same Python, or with Vosk (`EMBER_VOSK_MODEL`).

## Set up

### 1. The server

On the computer that's home when you are (macOS or Linux, Python 3.10 or later, and git):

```bash
curl -fsSL https://raw.githubusercontent.com/Natuworkguy/Ember/main/install.sh | bash
```

That installs `ember` to `~/.local/bin/ember` with Moonshine, makes a token, starts it at login, and prints a code for pairing the watch. Run it again to update. Options go after `bash -s --`:

| Option | Does |
| --- | --- |
| `--dev` | Installs from the `dev` branch instead of `main`. |
| `--no-login` | Doesn't start it at login; run `ember serve` yourself. |
| `--no-banners` | No banner for each new idea. |
| `--no-moonshine` | Doesn't install Moonshine, which hears what you record. |
| `--uninstall` | Removes `ember` and stops it starting at login. Your notes stay in `~/.ember`. |

For example, `curl -fsSL https://raw.githubusercontent.com/Natuworkguy/Ember/main/install.sh | bash -s -- --dev`. Working from a clone instead, `scripts/server.sh` does the same with the code in it, in `server/.venv`.

Each new idea gets a banner: in [Isola](https://github.com/Natuworkguy/Isola)'s island while Isola is running, and otherwise as an ordinary notification, so it works the same on a computer without Isola. Ideas that sync together get one banner. Use `--no-banners` to skip them.

| Variable | Meaning |
| --- | --- |
| `EMBER_TOKEN` | The token. If unset, the one `ember token --save` kept. |
| `EMBER_DATA` | Where the notes live. `~/.ember` unless set. |
| `EMBER_BLUETOOTH` | `0` stops answering the watch over Bluetooth (`ember serve --no-bluetooth`). On unless set. |
| `EMBER_HOST`, `EMBER_PORT` | Where the HTTP API listens, for this computer's own scripts. `127.0.0.1:8765` unless set; `0.0.0.0` opens it to your network too. The watch doesn't use it. |
| `EMBER_BANNERS` | `1` shows a banner for each new idea: in Isola's island while Isola is running (and its "Show banners from other apps and scripts" is on), otherwise a macOS notification, or `notify-send` on a Linux desktop. `EMBER_ISOLA=1` works too. |
| `EMBER_MOONSHINE` | Which Moonshine model hears recordings: `tiny` (quickest), `small` (the default) or `medium` (the most accurate). `off` turns it off. |
| `EMBER_VOSK_MODEL` | A Vosk model folder. Set, Vosk hears recordings instead of Moonshine. |

### 2. The watch

You need a Mac with Xcode 16 or later. The script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) if it's missing.

```bash
scripts/watch.sh            # check that it builds
scripts/watch.sh sim        # run it in an Apple Watch simulator
scripts/watch.sh install    # put it on your watch
```

To work in Xcode instead, run `xcodegen generate` in `watch/` and open `Ember.xcodeproj`.

For `install`, put your signing in `watch/Local.xcconfig`, which git ignores, so it never reaches the repo:

```
DEVELOPMENT_TEAM = ABCDE12345
EMBER_BUNDLE_ID = com.yourname.ember
```

A free Apple ID works (Xcode, Settings, Accounts). Its team ID is the Development Team build setting once you pick it in Signing & Capabilities. With a free Apple ID the app runs for 7 days at a time; run `scripts/watch.sh install` again to renew it. Your notes stay.

With the watch near your computer, open Ember, go to **Settings**, and type (or say) the six-digit pairing code the installer printed, like `482 913`. That's the whole setup: the watch finds your computer over Bluetooth, so there's no address to type, and it doesn't matter what network either is on. The token goes into the watch's Keychain. For a new code, run `ember pair`.

The first time, the watch asks to use Bluetooth, and so does your Mac, for whatever runs `ember serve` (the Terminal, or Python for the login service). Say yes to both. Bluetooth reaches about 10 metres, through a wall or two. On Linux, `ember serve` needs BlueZ, which most desktops have.

### 3. Flash, or any MCP client

`ember mcp` is an MCP server. In Flash:

```text
/mcp add ember ~/.local/bin/ember mcp
```

(Just `ember mcp` if `~/.local/bin` is on your PATH.) That's all. Then ask: *what ideas did I have this week about my game engine?* Flash searches Ember on its own, and asks you first before it saves, changes or deletes a note.

Any other MCP client takes the same command, in the usual config:

```json
{"mcpServers": {"ember": {"command": "/Users/you/.local/bin/ember", "args": ["mcp"]}}}
```

| Tool | Does |
| --- | --- |
| `search` | Finds notes by words (any order, word starts are enough), time (`since: "7d"`), tag and source. |
| `note` | Reads one note, whole, by its id or the start of it. |
| `tags` | Lists the tags in use. |
| `save` | Saves a note. `#hashtags` become tags. |
| `change` | Changes a note's text or tags. |
| `delete` | Moves a note to the trash. |
| `restore` | Brings a note back from the trash. |
| `delete_forever` | Deletes a note forever, recording and all. |

The first three only read, and say so, so a client can run them without asking. It works on the notes on this computer directly: it needs no token, and `ember serve` doesn't have to be running.

Only one `ember mcp` runs at a time. Starting another stops the one already running and takes over, so a client that restarts never finds an old one left holding on.

## Using it

- **Capture:** tap the big button, speak, and tap ✓. To say it again, tap ↺. You'll feel a tap on your wrist when it's saved.
- **Record:** tap the waveform at the bottom, talk, and tap ✓.
- **Siri:** "New idea in Ember" opens dictation. "Save an idea in Ember" asks for the idea and saves it without opening anything.
- **Complications:** "New idea" and "Record idea", on any watch face, as a circle, corner, line or card.
- **Action Button (Ultra):** in Settings, set the Action Button to the Shortcut "Record idea" or "New idea".
- **Tags:** say "hashtag engine", or type `#engine`, and it's tagged.
- **Notes:** the list shows each note's state:
  - 🕒 waiting to sync
  - ✓ on the server
  - 👂 the server is still hearing the recording
  - ⚠ the server refused it; tap to see why and try again

When you're away, notes wait on the watch. When you're back near your computer, Ember syncs over Bluetooth: as soon as you open it, every minute while it's open, and when watchOS wakes it in the background every half hour or so, so notes go up even if you never open the app.

## The trash

Deleting a note, on the watch, in the terminal or through MCP, moves it to the trash on your computer. It's gone from every list, search and the watch, but its words and recording are kept until you restore it or delete it forever. Deleting forever takes it out of the database and its recording off the disk; only its id is kept, so the watch hears it's gone.

## Your notes in the terminal

Run `ember` on its own and your notes open full screen: grouped by day, newest first, with the one you're on shown whole below. Ideas from your watch slide in while it's open.

| Key | Does |
| --- | --- |
| `↑` `↓` / `j` `k` | Move |
| `/` | Search, as you type |
| `t` | Pick a tag |
| `enter` | Read the note whole |
| `n` | New note |
| `e` | Edit it in `$EDITOR` |
| `#` | Change its tags |
| `d` `d` | Move it to the trash |
| `d` `f` | Delete it forever (asks first) |
| `T` | The trash, and back (`u` restores the note you're on) |
| `c` | Copy its text |
| `p` | Play its recording |
| `?` / `q` | Help / quit |

For scripts, and quick jobs:

```bash
ember list                      # newest first; ember list engine --since 7d
ember show 3f2a                 # a note, by the start of its id
ember edit 3f2a                 # in $EDITOR, or: ember edit 3f2a new words
ember tag 3f2a engine -old      # add a tag, take one away
ember rm 3f2a                   # to the trash
ember rm --forever 3f2a         # out of the database; asks first, --yes doesn't
ember trash                     # what's in the trash; ember trash empty deletes it all
ember restore 3f2a              # back from the trash
ember add an idea from here     # save one
ember export > ideas.md         # everything, as Markdown (or --json)
ember hear memo.wav             # the words in a recording, as the server hears them
ember hear --install            # add Moonshine, and download its model
```

## The API

The watch sends these same requests over Bluetooth LE (`server/ember_server/ble.py` describes how). Over HTTP, on `127.0.0.1:8765`, they're there for your own scripts. Every request needs `Authorization: Bearer <token>`, except `/pair`.

| | |
| --- | --- |
| `POST /notes` | Saves a note: `{id, text, created_at, source, tags, audio}`. The id is a UUID the client makes, so sending the same note twice saves it once. |
| `GET /notes?since=<rev>` | Everything changed after a revision, oldest first: `{notes, cursor, more}`. A note moved to the trash or deleted forever comes as `"deleted": true`. `since` can also be a time. |
| `GET /notes/search?q=&since=&until=&tag=` | Finds notes. |
| `GET` / `PATCH` / `DELETE /notes/{id}` | Gets, changes or moves one note to the trash. `DELETE /notes/{id}?forever=true` deletes it forever. |
| `POST /notes/{id}/restore` | Brings a note back from the trash. |
| `GET /trash`, `DELETE /trash` | Lists what's in the trash, or deletes all of it forever. |
| `PUT /notes/{id}/audio` | Uploads a note's WAV recording. The server transcribes it in the background. |
| `GET /notes/{id}/audio` | Gets the recording back. |
| `GET /tags`, `GET /health` | |
| `POST /pair` | Trades the secret in a code from `ember pair` for the token, and the computer's `.local` name. A code works once, for ten minutes, and five wrong tries use it up. |

A note looks like this:

```json
{
  "id": "4a9c…", "text": "Chunked terrain streaming for the #engine",
  "created_at": "2026-10-21T08:15:00.000000Z", "updated_at": "…",
  "source": "watch", "tags": ["engine"], "audio": false,
  "transcription": "none", "trashed": false, "trashed_at": "",
  "deleted": false, "rev": 12
}
```

## Development

```bash
cd server && pip install -e ".[dev]" && ruff check . && flake8 ember_server
scripts/watch.sh
```

CI runs both: the server on Linux, and the watch app on a macOS runner.

## License

MIT
