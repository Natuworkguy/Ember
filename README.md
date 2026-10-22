<p align="center"><img src="assets/ember-logo-animated.svg" width="112" alt="Ember"></p>

# Ember

Raise your wrist, tap once, say the idea. Ember keeps it on the watch until it can reach home, then hands it to a small server on your own computer. From there, [Flash](https://github.com/Natuworkguy/Flash) can search your ideas, add to them, and act on them, and you can browse them all in the terminal.

Why I built it: [I kept losing ideas, so I built an Apple Watch app that feeds my AI agent](https://dev.to/natuworkguy/i-kept-losing-ideas-so-i-built-an-apple-watch-app-that-feeds-my-ai-agent-1941).

```
 Apple Watch                      your computer                       Flash
 ───────────                      ─────────────                       ─────
 tap, speak, save  ── Wi-Fi ──▶  ember serve  ◀──── MCP ──────  "what ideas did I
 kept on the watch               notes.db, recordings              have this week about
 until home                      a banner on each new idea         my game engine?"
```

- **Standalone watch app.** No iPhone app, and no iPhone needed at all. It even works on a Family Setup watch.
- **Never loses a note.** Every idea is saved on the watch first, in SwiftData, before anything touches the network. It syncs when you get home, and keeps trying until it does.
- **One tap to capture.** The big button, a complication, Siri ("New idea in Ember"), the Smart Stack, or the Action Button on an Ultra.
- **Local.** The server is one SQLite file on your computer. Recordings are transcribed there too. Nothing goes anywhere else.
- **An MCP server**, `ember mcp`, so Flash (or any MCP client) can read and write your notes, and **`ember`** in the terminal to browse them.

## How it hears you

Apple's speech APIs, the Speech framework (`SFSpeechRecognizer`) and the newer `SpeechAnalyzer` / `SpeechTranscriber`, are not available on watchOS. They exist on iPhone, iPad, Mac and Vision Pro only. So Ember uses the watch's own **system dictation**, through SwiftUI's `TextFieldLink`. It's the same dictation as Messages, and the best speech recognition a watch app can use:

- On Apple Watch Series 9 and later, and Ultra 2, dictation runs on the watch itself, with no network.
- Older watches need Wi-Fi or cellular to dictate.

For when dictation isn't there, or when you'd rather just talk, there's **Record**. Ember saves a 16 kHz WAV on the watch. When it syncs, your server finds the words with Flash's local listening models (Moonshine or Vosk) if Flash is installed in the same Python, or with Vosk directly (`EMBER_VOSK_MODEL`). The text then syncs back to the watch.

## Set up

### 1. The server

On the computer that's home when you are (macOS or Linux, Python 3.10 or later, and git):

```bash
curl -fsSL https://raw.githubusercontent.com/Natuworkguy/Ember/main/install.sh | bash
```

That installs `ember` to `~/.local/bin/ember`, makes a token, starts it at login, and prints a code for pairing the watch. Run it again to update. Options go after `bash -s --`:

| Option | Does |
| --- | --- |
| `--dev` | Installs from the `dev` branch instead of `main`. |
| `--no-login` | Doesn't start it at login; run `ember serve` yourself. |
| `--no-banners` | No banner for each new idea. |
| `--uninstall` | Removes `ember` and stops it starting at login. Your notes stay in `~/.ember`. |

For example, `curl -fsSL https://raw.githubusercontent.com/Natuworkguy/Ember/main/install.sh | bash -s -- --dev`. Working from a clone instead, `scripts/server.sh` does the same with the code in it, in `server/.venv`.

Each new idea gets a banner: in [Isola](https://github.com/Natuworkguy/Isola)'s island while Isola is running, and otherwise as an ordinary notification, so it works the same on a computer without Isola. Ideas that sync together get one banner. Use `--no-banners` to skip them.

| Variable | Meaning |
| --- | --- |
| `EMBER_TOKEN` | The token. If unset, the one `ember token --save` kept. |
| `EMBER_DATA` | Where the notes live. `~/.ember` unless set. |
| `EMBER_HOST`, `EMBER_PORT` | Where to listen. `0.0.0.0:8765` unless set. |
| `EMBER_BANNERS` | `1` shows a banner for each new idea: in Isola's island while Isola is running (and its "Show banners from other apps and scripts" is on), otherwise a macOS notification, or `notify-send` on a Linux desktop. `EMBER_ISOLA=1` works too. |
| `EMBER_VOSK_MODEL` | A Vosk model folder, for hearing recordings without Flash. |

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

On the watch, open Ember, go to **Settings**, and type (or say) the pairing code the installer printed, like `2232 4829 136`. That's the whole setup. The code carries your computer's address, so you never type an IP or a `.local` name, and its last digit catches typos. The token goes into the watch's Keychain. For a new code, run `ember pair`.

If your router later gives the computer a new address, the watch tries the computer's `.local` name, which it learned when pairing, and keeps whichever answers.

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
| `delete` | Deletes a note and its recording. |

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

When you're away, notes wait on the watch. When the watch joins your home Wi-Fi, Ember syncs. watchOS also wakes it every half hour or so to try in the background, so notes go up even if you never open the app.

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
| `d` | Delete it |
| `c` | Copy its text |
| `p` | Play its recording |
| `?` / `q` | Help / quit |

For scripts, and quick jobs:

```bash
ember list                      # newest first; ember list engine --since 7d
ember show 3f2a                 # a note, by the start of its id
ember edit 3f2a                 # in $EDITOR, or: ember edit 3f2a new words
ember tag 3f2a engine -old      # add a tag, take one away
ember rm 3f2a                   # asks first; --yes doesn't
ember add an idea from here     # save one
ember export > ideas.md         # everything, as Markdown (or --json)
```

## The API

Every request needs `Authorization: Bearer <token>`, except `/pair`.

| | |
| --- | --- |
| `POST /notes` | Saves a note: `{id, text, created_at, source, tags, audio}`. The id is a UUID the client makes, so sending the same note twice saves it once. |
| `GET /notes?since=<rev>` | Everything changed after a revision, deletions included, oldest first: `{notes, cursor, more}`. `since` can also be a time. |
| `GET /notes/search?q=&since=&until=&tag=` | Finds notes. |
| `GET` / `PATCH` / `DELETE /notes/{id}` | Gets, changes or deletes one note. |
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
  "transcription": "none", "deleted": false, "rev": 12
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
