#!/usr/bin/env bash
# Set up the Ember server on this computer, the one at home:
#
#   scripts/server.sh             install, make a token, start at login,
#                                 and print the code that pairs the watch
#   scripts/server.sh --no-login  the same, but don't start it at login
#                                 (run server/.venv/bin/ember serve yourself)
#   scripts/server.sh --no-banners  no banner for each new idea (in Isola's
#                                 island when it runs, else a notification)
#
# Needs Python 3.10 or later. Everything goes in server/.venv; notes are
# kept in ~/.ember.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
venv="$root/server/.venv"
ember="$venv/bin/ember"

say() { printf '\033[1;38;5;208m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

login=1
banners=1
for arg in "$@"; do
    case "$arg" in
    --no-login) login=0 ;;
    --no-banners) banners=0 ;;
    *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done

python="$(command -v python3 || command -v python || true)"
[ -n "$python" ] || die "Install Python 3.10 or later first."
"$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || die "Ember needs Python 3.10 or later; $("$python" --version) is too old."

has_pip() { "$venv/bin/python" -m pip --version >/dev/null 2>&1; }

if command -v uv >/dev/null; then
    # uv makes venvs without pip, and needs none.
    say "Installing into server/.venv, with uv"
    [ -x "$venv/bin/python" ] || uv venv --quiet --python "$python" "$venv"
    uv pip install --quiet --python "$venv/bin/python" -e "$root/server"
else
    say "Installing into server/.venv"
    [ -x "$venv/bin/python" ] || "$python" -m venv "$venv"
    # A venv from uv, or one an earlier run left half made: give it pip,
    # or failing that, make it again.
    has_pip || "$venv/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
    has_pip || { rm -rf "$venv"; "$python" -m venv "$venv"; }
    has_pip || die "This Python makes venvs without pip. Install uv (brew install uv) and run this again."
    "$venv/bin/python" -m pip install --quiet --upgrade pip
    "$venv/bin/python" -m pip install --quiet -e "$root/server"
fi

data="${EMBER_DATA:-$HOME/.ember}"
if [ -z "${EMBER_TOKEN:-}" ] && [ ! -s "$data/token" ]; then
    say "Making a token"
    "$ember" token --save >/dev/null
else
    say "Keeping the token you have"
fi

if [ "$login" = 1 ]; then
    say "Starting Ember at login"
    extra=()
    # A banner for each new idea: in Isola's island when it runs, and
    # otherwise as a notification, so it suits a computer without Isola.
    [ "$banners" = 1 ] && extra+=(--banners)
    "$ember" service install "${extra[@]+"${extra[@]}"}" \
        || say "Start it yourself instead: $ember serve"
else
    say "Start it with: $ember serve"
fi

echo
"$ember" pair
