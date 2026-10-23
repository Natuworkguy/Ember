#!/usr/bin/env bash
# Install Ember's server on this computer, the one at home:
#
#   curl -fsSL https://raw.githubusercontent.com/Natuworkguy/Ember/main/install.sh | bash
#
# It installs `ember` to ~/.local/bin/ember (its Python packages in
# ~/.local/share/ember), with Moonshine to hear recordings, makes a
# token, starts the server at login, and prints the code that pairs the
# watch. Run it again to update.
#
#   --dev          install from the dev branch instead of main
#   --no-login     don't start it at login (run `ember serve` yourself)
#   --no-banners   no banner for each new idea (in Isola's island when it
#                  runs, otherwise a notification)
#   --no-moonshine don't install Moonshine, which hears what you record
#   --uninstall    remove ember and stop it starting at login (your notes,
#                  in ~/.ember, stay)
#
# After `| bash`, give them as: curl ... | bash -s -- --dev
# Needs Python 3.10 or later, and git.
set -euo pipefail

repo="https://github.com/Natuworkguy/Ember"
share="${XDG_DATA_HOME:-$HOME/.local/share}/ember"
venv="$share/venv"
bin="$HOME/.local/bin"
ember="$bin/ember"

say() { printf '\033[1;38;5;208m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

branch=main
login=1
banners=1
moonshine=1
uninstall=0
for arg in "$@"; do
    case "$arg" in
    --dev) branch=dev ;;
    --no-login) login=0 ;;
    --no-banners) banners=0 ;;
    --no-moonshine) moonshine=0 ;;
    --uninstall) uninstall=1 ;;
    *) printf 'Unknown option: %s\n\n' "$arg" >&2
       sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' >&2 || true
       exit 2 ;;
    esac
done

if [ "$uninstall" = 1 ]; then
    if [ -x "$ember" ]; then
        say "Stopping Ember starting at login"
        "$ember" service remove >/dev/null 2>&1 || true
    fi
    say "Removing $ember and $share"
    rm -f "$ember"
    rm -rf "$share"
    say "Done. Your notes are still in ${EMBER_DATA:-$HOME/.ember}."
    exit 0
fi

python="$(command -v python3 || command -v python || true)"
[ -n "$python" ] || die "Install Python 3.10 or later first."
"$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
    || die "Ember needs Python 3.10 or later; $("$python" --version) is too old."
command -v git >/dev/null || die "Install git first."

source="git+$repo@$branch#subdirectory=server"
mkdir -p "$share" "$bin"
has_pip() { "$venv/bin/python" -m pip --version >/dev/null 2>&1; }

if command -v uv >/dev/null; then
    say "Installing Ember from $branch, with uv"
    [ -x "$venv/bin/python" ] || uv venv --quiet --python "$python" "$venv"
    get() {
        # Again even when the version is the same: the branch may have moved.
        uv pip install --quiet --python "$venv/bin/python" \
            --reinstall-package ember-server "$1"
    }
else
    say "Installing Ember from $branch"
    [ -x "$venv/bin/python" ] || "$python" -m venv "$venv"
    # A venv from uv, or one an earlier run left half made: give it pip,
    # or failing that, make it again.
    has_pip || "$venv/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
    has_pip || { rm -rf "$venv"; "$python" -m venv "$venv"; }
    has_pip || die "This Python makes venvs without pip. Install uv (brew install uv) and run this again."
    "$venv/bin/python" -m pip install --quiet --upgrade pip
    get() {
        "$venv/bin/python" -m pip install --quiet --upgrade "$1" &&
        # Again even when the version is the same: the branch may have moved.
        "$venv/bin/python" -m pip install --quiet --force-reinstall --no-deps "$source"
    }
fi

# Moonshine has no build for every computer (an Intel Mac, an old Linux):
# without it, Ember still saves what the watch heard itself.
if [ "$moonshine" = 1 ] && ! get "ember-server[moonshine] @ $source"; then
    say "Moonshine isn't available here, so recordings won't be heard on this computer"
    moonshine=0
fi
[ "$moonshine" = 1 ] || get "$source"

# The watch syncs over Bluetooth, with bless.
get "ember-server[bluetooth] @ $source" ||
    say "Bluetooth isn't available here, so the watch can't sync with this computer"

ln -sf "$venv/bin/ember" "$ember"
say "Installed $("$ember" --version) to $ember"
# Everything below finds this ember first, and so does the login service.
export PATH="$bin:$PATH"

if [ "$moonshine" = 1 ]; then
    say "Getting Moonshine's listening model ready"
    ember hear || say "It will download when your first recording comes in"
fi

data="${EMBER_DATA:-$HOME/.ember}"
if [ -z "${EMBER_TOKEN:-}" ] && [ ! -s "$data/token" ]; then
    say "Making a token"
    ember token --save >/dev/null
else
    say "Keeping the token you have"
fi

if [ "$login" = 1 ]; then
    say "Starting Ember at login"
    extra=()
    [ "$banners" = 1 ] && extra+=(--banners)
    # Installing it again restarts it, on the code just installed.
    ember service install "${extra[@]+"${extra[@]}"}" \
        || say "Start it yourself instead: ember serve"
else
    say "Start it with: ember serve"
fi

echo
ember pair

case ":${PATH#"$bin:"}:" in
*":$bin:"*) ;;
*)
    echo
    say "$bin is not on your PATH. Add it, then open a new terminal:"
    case "${SHELL:-}" in
    */zsh) echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
    */fish) echo "    fish_add_path ~/.local/bin" ;;
    *) echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
    esac
    ;;
esac
