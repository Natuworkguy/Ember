"""What the Ember extension's commands share: where the server is, and
its token, from the extension's settings or this computer's ~/.ember."""

import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def server() -> str:
    url = os.environ.get("FLASH_SETTING_URL", "").strip()
    return (url or "http://localhost:8765").rstrip("/")


def token() -> str:
    given = os.environ.get("FLASH_SETTING_TOKEN", "").strip()
    if given:
        return given
    if os.environ.get("EMBER_TOKEN", "").strip():
        return os.environ["EMBER_TOKEN"].strip()
    data = Path(os.environ.get("EMBER_DATA") or Path.home() / ".ember")
    try:
        return (data / "token").read_text(encoding="utf-8").strip()
    except OSError:
        sys.exit(
            "No Ember token. Run `ember token --save` on the computer that "
            "runs Ember, or set the token in this extension's settings."
        )


def call(method: str, path: str, body=None) -> dict:
    request = Request(  # nosec B310 -- the server the user set
        server() + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"},
    )
    try:
        with urlopen(request, timeout=10) as answer:  # nosec B310
            return json.loads(answer.read().decode("utf-8"))
    except HTTPError as exc:
        if exc.code == 401:
            sys.exit("Ember did not take the token. Check it in this "
                     "extension's settings.")
        try:
            said = json.loads(exc.read().decode("utf-8")).get("detail")
        except (ValueError, OSError, AttributeError):
            said = None
        sys.exit(said if isinstance(said, str) else
                 f"Ember answered {exc.code}.")
    except (URLError, OSError) as exc:
        sys.exit(f"Could not reach Ember at {server()}: "
                 f"{getattr(exc, 'reason', exc)}. Is `ember serve` running?")
