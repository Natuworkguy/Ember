"""What a recording said.

The watch sends audio when it could not get words for it there: no
dictation offline on an older watch, or you chose to record. The words
are found here, on your own computer, with Moonshine (the `moonshine`
extra, which the installer adds), with the listening model Flash uses
if Flash is installed in the same Python, or with Vosk and the model
folder in EMBER_VOSK_MODEL. Nothing is sent anywhere: Moonshine's model
is downloaded once, into ~/.ember/models, and runs here.
"""

from __future__ import annotations

import array
import importlib
import io
import json
import os
import sys
import threading
import wave
from pathlib import Path

RATE = 16_000

# Moonshine's package, as `ember hear --install` installs it.
MOONSHINE_PACKAGE = "moonshine-voice>=0.1.5"
# Moonshine's English models, by the name EMBER_MOONSHINE takes, and the
# architecture each is as moonshine_voice.ModelArch names it. Small is
# the default: much more accurate than tiny, and a few seconds of speech
# takes it well under a second on a laptop.
MOONSHINE = {
    "tiny": "TINY_STREAMING",
    "small": "SMALL_STREAMING",
    "medium": "MEDIUM_STREAMING",
}
MOONSHINE_DEFAULT = "small"


class Unheard(Exception):
    """A recording that could not be heard, and why."""


def pcm16k(data: bytes) -> bytes:
    """DATA, a WAV file, as 16 kHz mono 16-bit samples."""

    try:
        with wave.open(io.BytesIO(data)) as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError) as exc:
        raise Unheard(f"Not a WAV recording Ember can read: {exc}") from None
    if width != 2:
        raise Unheard("Ember reads 16-bit recordings only.")
    samples = array.array("h")
    samples.frombytes(frames[: len(frames) - len(frames) % 2])
    if sys.byteorder == "big":
        samples.byteswap()
    if channels > 1:
        samples = array.array("h", (
            sum(samples[i:i + channels]) // channels
            for i in range(0, len(samples) - channels + 1, channels)
        ))
    if rate != RATE and samples:
        step = rate / RATE
        count = int(len(samples) / step)
        samples = array.array("h", (
            samples[min(int(i * step), len(samples) - 1)]
            for i in range(count)
        ))
    if sys.byteorder == "big":
        samples.byteswap()
    return samples.tobytes()


def _with_flash(pcm: bytes) -> tuple[bool, str]:
    try:
        from flash import voice
    except ImportError:
        return False, ""
    text, why = voice.transcribe(pcm)
    if why:
        raise Unheard(why)
    return True, text


def moonshine_size() -> str:
    """The Moonshine model EMBER_MOONSHINE names, "" when it is off.
    Raises Unheard for a name it does not know."""

    size = os.environ.get("EMBER_MOONSHINE", "").strip().lower()
    if size in ("off", "0", "no", "false"):
        return ""
    size = size or MOONSHINE_DEFAULT
    if size not in MOONSHINE:
        raise Unheard(f"EMBER_MOONSHINE is {size!r}; it can be "
                      f"{', '.join(MOONSHINE)} or off.")
    return size


_moonshine: dict[str, object] = {}
_moonshine_lock = threading.Lock()


def moonshine(size: str, quiet: bool = True):
    """Moonshine's SIZE model, downloaded into ~/.ember/models the first
    time, and kept loaded after. Raises ImportError without the
    moonshine extra, Unheard when the model cannot be had."""

    try:
        from moonshine_voice import ModelArch, Transcriber
    except ImportError:
        # Installed since this server started (ember hear --install):
        # Python only looks again once told the folders have changed.
        importlib.invalidate_caches()
        from moonshine_voice import ModelArch, Transcriber
    from moonshine_voice.download import get_model_for_language

    with _moonshine_lock:
        if size not in _moonshine:
            from .app import home

            arch = ModelArch[MOONSHINE[size]]
            try:
                folder, arch = get_model_for_language(
                    "en", arch, cache_root=home() / "models",
                    on_progress=(lambda *_: None) if quiet else None)
                _moonshine[size] = Transcriber(str(folder), arch)
            except Exception as exc:  # the network, the disk, the model
                raise Unheard(f"Could not get Moonshine's {size} model: "
                              f"{exc}") from None
        return _moonshine[size]


def warm() -> None:
    """Have Moonshine's model ready before the first recording comes, if
    it can be; a recording that comes first tries again itself."""

    try:
        size = moonshine_size()
        if size:
            moonshine(size)
    except (ImportError, Unheard):
        pass


def _with_moonshine(pcm: bytes) -> tuple[bool, str]:
    size = moonshine_size()
    if not size:
        return False, ""
    try:
        transcriber = moonshine(size)
    except ImportError:
        return False, ""
    samples = array.array("h")
    samples.frombytes(pcm[: len(pcm) - len(pcm) % 2])
    if sys.byteorder == "big":
        samples.byteswap()
    floats = [sample / 32768.0 for sample in samples]
    # Through a stream, as Flash hears with these models: the recording
    # in tenths of a second, each line kept as it is heard, and the last
    # of them once it has all been.
    lines: dict[int, str] = {}
    failed: list[Exception] = []

    def heard(event) -> None:
        if getattr(event, "error", None) is not None:
            failed.append(event.error)
        elif getattr(event, "line", None) is not None:
            lines[event.line.line_id] = str(event.line.text or "").strip()

    with _moonshine_lock:
        stream = transcriber.create_stream()
        try:
            stream.add_listener(heard)
            stream.start()
            for start in range(0, len(floats), RATE // 10):
                stream.add_audio(floats[start:start + RATE // 10], RATE)
            last = stream.stop()
        finally:
            stream.close()
    for line in getattr(last, "lines", None) or ():
        lines[line.line_id] = str(line.text or "").strip()
    if failed and not any(lines.values()):
        raise Unheard(f"Moonshine could not hear it: {failed[0]}")
    return True, " ".join(text for text in lines.values() if text)


def _with_vosk(pcm: bytes) -> tuple[bool, str]:
    folder = os.environ.get("EMBER_VOSK_MODEL", "").strip()
    if not folder:
        return False, ""
    try:
        import vosk
    except ImportError:
        raise Unheard("EMBER_VOSK_MODEL is set, but Vosk is not "
                      "installed: pip install vosk") from None
    if not Path(folder).is_dir():
        raise Unheard(f"No Vosk model in {folder}.")
    vosk.SetLogLevel(-1)
    hearing = vosk.KaldiRecognizer(vosk.Model(folder), RATE)
    said = []
    for start in range(0, len(pcm), 8000):
        if hearing.AcceptWaveform(pcm[start:start + 8000]):
            said.append(json.loads(hearing.Result()).get("text", ""))
    said.append(json.loads(hearing.FinalResult()).get("text", ""))
    return True, " ".join(s for s in said if s).strip()


def transcribe(data: bytes) -> str:
    """What DATA, a WAV recording, said. Raises Unheard saying why not."""

    pcm = pcm16k(data)
    # Vosk only when its model is set, which is asking for it; then
    # Moonshine, then whatever Flash listens with.
    for way in (_with_vosk, _with_moonshine, _with_flash):
        done, text = way(pcm)
        if done:
            if not text:
                raise Unheard("No words were heard in the recording.")
            return _sentence(text)
    raise Unheard(
        "No listening model here. `ember hear --install` adds Moonshine, "
        "which hears recordings on this computer."
    )


def _sentence(text: str) -> str:
    """TEXT starting with a capital and ending with a stop, as dictation
    on the watch would give it."""

    text = " ".join(text.split())
    if not text:
        return text
    text = text[0].upper() + text[1:]
    return text if text[-1] in ".!?" else text + "."
