"""What a recording said.

The watch sends audio when it could not get words for it there: no
dictation offline on an older watch, or you chose to record. The words
are found here, on your own computer, with the listening model Flash
uses, if Flash is installed in the same Python, or with Vosk and the
model folder in EMBER_VOSK_MODEL. Nothing is sent anywhere.
"""

from __future__ import annotations

import array
import io
import json
import os
import sys
import wave
from pathlib import Path

RATE = 16_000


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
    for way in (_with_flash, _with_vosk):
        done, text = way(pcm)
        if done:
            if not text:
                raise Unheard("No words were heard in the recording.")
            return _sentence(text)
    raise Unheard(
        "No listening model here. Install Flash with voice in this "
        "Python, or set EMBER_VOSK_MODEL to a Vosk model folder."
    )


def _sentence(text: str) -> str:
    """TEXT starting with a capital and ending with a stop, as dictation
    on the watch would give it."""

    text = " ".join(text.split())
    if not text:
        return text
    text = text[0].upper() + text[1:]
    return text if text[-1] in ".!?" else text + "."
