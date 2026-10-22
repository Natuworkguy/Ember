"""The pairing code: the one-time secret, and where the server is, in one
string of digits, so the watch needs nothing typed but the code.

    [where][secret][check]

The secret is the last six digits before the check. Before it, a number
holds the server's IPv4 address, packed small for the ranges home
networks use (192.168.x.x takes 3 to 6 digits), and its port when it is
not 8765. The check digit (Damm's) catches any one digit typed wrong and
any two neighbours swapped. Six digits alone are still a code: the
secret, for a watch that already has the address.

The watch reads it the same way, in Swift: change one, change both.
"""

from __future__ import annotations

import ipaddress
import socket

DEFAULT_PORT = 8765
SECRET_DIGITS = 6

# Damm's table: a totally anti-symmetric quasigroup of order 10.
_DAMM = (
    (0, 3, 1, 7, 5, 9, 8, 6, 4, 2),
    (7, 0, 9, 2, 1, 5, 4, 8, 6, 3),
    (4, 2, 0, 6, 8, 7, 1, 3, 5, 9),
    (1, 7, 5, 0, 9, 8, 3, 4, 2, 6),
    (6, 1, 2, 3, 0, 4, 5, 9, 7, 8),
    (3, 6, 7, 4, 2, 0, 9, 5, 8, 1),
    (5, 8, 6, 9, 7, 2, 0, 1, 3, 4),
    (8, 9, 4, 5, 3, 6, 2, 0, 1, 7),
    (9, 4, 3, 8, 6, 1, 7, 2, 0, 5),
    (2, 5, 8, 1, 4, 3, 6, 7, 9, 0),
)


class BadCode(ValueError):
    """A pairing code that cannot be read, and why."""


def damm(digits: str) -> int:
    interim = 0
    for digit in digits:
        interim = _DAMM[interim][int(digit)]
    return interim


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


def make(secret: str, host: str, port: int = DEFAULT_PORT) -> str:
    """SECRET and where to find the server, as one code. Raises BadCode
    for a HOST that is not an IPv4 address."""

    try:
        address = ipaddress.IPv4Address(host)
    except ValueError:
        raise BadCode(f"{host!r} is not an IPv4 address.") from None
    a, b, c, d = address.packed
    if a == 192 and b == 168:
        kind, rest = 0, c << 8 | d
    elif a == 10:
        kind, rest = 1, b << 16 | c << 8 | d
    elif a == 172 and 16 <= b <= 31:
        kind, rest = 2, (b - 16) << 16 | c << 8 | d
    else:
        kind, rest = 3, int(address)
    where = rest * 4 + kind
    if port != DEFAULT_PORT:
        where = (where * 65536 + port) * 2 + 1
    else:
        where *= 2
    body = f"{where}{int(secret):0{SECRET_DIGITS}d}"
    return body + str(_check_digit(body))


def _check_digit(body: str) -> int:
    for digit in range(10):
        if damm(body + str(digit)) == 0:
            return digit
    raise AssertionError("Damm always has a check digit")


def read(code: str) -> tuple[str, int, str]:
    """The address, port and secret in CODE: the address empty for a
    bare six-digit secret."""

    digits = "".join(ch for ch in code if ch.isdigit())
    if len(digits) == SECRET_DIGITS:
        return "", DEFAULT_PORT, digits
    if len(digits) < SECRET_DIGITS + 2 or damm(digits) != 0:
        raise BadCode("That code isn't right. Check it, or make a new one.")
    body = digits[:-1]
    secret = body[-SECRET_DIGITS:]
    where = int(body[:-SECRET_DIGITS])
    port = DEFAULT_PORT
    if where % 2:
        where //= 2
        port = where % 65536
        where //= 65536
    else:
        where //= 2
    kind, rest = where % 4, where // 4
    if kind == 0:
        host = f"192.168.{rest >> 8 & 255}.{rest & 255}"
    elif kind == 1:
        host = f"10.{rest >> 16 & 255}.{rest >> 8 & 255}.{rest & 255}"
    elif kind == 2:
        host = (f"172.{16 + (rest >> 16 & 15)}."
                f"{rest >> 8 & 255}.{rest & 255}")
    else:
        host = str(ipaddress.IPv4Address(rest))
    return host, port, secret


def spaced(code: str) -> str:
    """CODE in fours, to read off a screen."""

    return " ".join(code[i:i + 4] for i in range(0, len(code), 4))
