"""This computer's names: its address on the local network, and its
.local name, for the HTTP API and for the watch to call it by."""

from __future__ import annotations

import socket


def lan_address() -> str:
    """This computer's address on the local network: the one its traffic
    leaves from. Empty when it has none."""

    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            # No packet is sent: this only picks the outgoing interface.
            probe.connect(("10.255.255.255", 1))
            return probe.getsockname()[0]
    except OSError:
        return ""


def local_name() -> str:
    """This computer's Bonjour name, which follows it when its address
    changes: studio.local."""

    name = socket.gethostname().split(".")[0]
    return f"{name}.local" if name else ""
