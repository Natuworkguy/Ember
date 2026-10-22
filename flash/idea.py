"""/idea: save an idea to Ember."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import call  # noqa: E402

words = " ".join(sys.argv[1:]).strip()
if not words:
    sys.exit("Say the idea after the command: /idea a level made of glass")
note = call("POST", "/notes", {"text": words, "source": "flash"})
tags = " ".join("#" + t for t in note.get("tags", []))
print("Saved to Ember." + (f" {tags}" if tags else ""))
