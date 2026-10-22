#!/usr/bin/env bash
# Build Ember for the watch. Needs a Mac with Xcode 16 or later.
#
#   scripts/watch.sh            check that it builds (no signing needed)
#   scripts/watch.sh sim        run it in an Apple Watch simulator
#   scripts/watch.sh install    put it on your watch
#   scripts/watch.sh screens    screenshots on the smallest and largest
#                               watches, in watch/build/screens
#
# For `install`, put your team in watch/Local.xcconfig first (a free Apple
# ID works, signed in under Xcode, Settings, Accounts):
#
#   DEVELOPMENT_TEAM = ABCDE12345
#   EMBER_BUNDLE_ID = com.yourname.ember
#
# With more than one watch, pick one by name: EMBER_WATCH="User's Watch".
set -euo pipefail

self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
here="$(cd "$(dirname "$0")/../watch" && pwd)"
cd "$here"
built="$here/build"

say() { printf '\033[1;38;5;208m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

what="${1:-check}"
case "$what" in
check | sim | install | screens) ;;
*) sed -n '2,16p' "$self" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

[ "$(uname)" = Darwin ] || die "This needs a Mac with Xcode."

# The command line tools alone can't build for the watch: use the Xcode
# app, even when xcode-select points at the tools.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    case "$(xcode-select -p 2>/dev/null || true)" in
    "" | *CommandLineTools*)
        xcode="$(ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null | sort | tail -n 1 || true)"
        [ -n "$xcode" ] || die "Ember needs the Xcode app, not just the command line tools. Install Xcode from the App Store, open it once, then run this again."
        export DEVELOPER_DIR="$xcode/Contents/Developer"
        say "Using $(basename "$xcode")"
        ;;
    esac
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    # sudo drops DEVELOPER_DIR, so name this Xcode's own xcodebuild.
    tool="$(xcode-select -p 2>/dev/null || true)"
    case "${DEVELOPER_DIR:-$tool}" in
    "" | *CommandLineTools*) tool=xcodebuild ;;
    *) tool="${DEVELOPER_DIR:-$tool}/usr/bin/xcodebuild" ;;
    esac
    die "Xcode isn't finished installing. Run this, then this script again:
    sudo $tool -runFirstLaunch"
fi
if ! xcodebuild -showsdks 2>/dev/null | grep -q watchsimulator; then
    say "Downloading watchOS for Xcode (a few GB, once)"
    xcodebuild -downloadPlatform watchOS
fi

if ! command -v xcodegen >/dev/null; then
    command -v brew >/dev/null || die "Install XcodeGen: https://github.com/yonaskolb/XcodeGen"
    say "Installing XcodeGen"
    brew install xcodegen
fi

say "Making the Xcode project"
xcodegen generate --quiet

build() {
    xcodebuild build \
        -project Ember.xcodeproj \
        -scheme EmberWatch \
        -configuration Debug \
        -derivedDataPath "$built" \
        -quiet \
        "$@"
}

# Show the simulator. Xcode 27 and later have Device Hub instead of the
# Simulator app: a devices:// link brings one device to the front. Older
# Xcodes have Simulator, inside Xcode or wherever Spotlight knows it. Not
# finding either stops nothing: the app is on the simulator already.
open_simulator() {
    local dev xcode app
    dev="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
    xcode="${dev%/Contents/Developer}"

    app="$xcode/Contents/Applications/DeviceHub.app"
    [ -d "$app" ] || app="$(mdfind "kMDItemFSName == 'DeviceHub.app'" 2>/dev/null | head -n 1 || true)"
    if [ -n "$app" ] && [ -d "$app" ] && open "$app"; then
        open "devices://device/open?id=$1" 2>/dev/null || true
        return
    fi

    app="$dev/Applications/Simulator.app"
    [ -d "$app" ] || app="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.iphonesimulator'" 2>/dev/null | head -n 1 || true)"
    if [ -n "$app" ] && [ -d "$app" ]; then
        open "$app" --args -CurrentDeviceUDID "$1" && return
    fi

    # Neither found by path: ask macOS for whichever it knows.
    open "devices://device/open?id=$1" 2>/dev/null && return
    open -a DeviceHub 2>/dev/null && return
    open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$1" 2>/dev/null && return
    say "Couldn't find Device Hub or Simulator to show it. Ember is on the simulator anyway:"
    say "in Xcode, open Window > Devices and Simulators."
}

bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Info.plist"
}

case "$what" in
check)
    say "Building for the simulator"
    build -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
    say "It builds."
    ;;

sim)
    udid="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
found = json.load(sys.stdin)["devices"]
watches = [(runtime, d) for runtime, ds in found.items() if "watchOS" in runtime
           for d in ds if d.get("isAvailable", True)]
if not watches:
    sys.exit("No Apple Watch simulator. Add one in Xcode, Settings, Components.")
watches.sort(key=lambda w: [int(n) for n in w[0].rsplit("watchOS-", 1)[-1].split("-")])
print(watches[-1][1]["udid"])
')"
    say "Building for the simulator"
    build -destination "id=$udid" CODE_SIGNING_ALLOWED=NO
    app="$built/Build/Products/Debug-watchsimulator/Ember.app"
    say "Starting the simulator"
    xcrun simctl boot "$udid" 2>/dev/null || true
    open_simulator "$udid"
    xcrun simctl install "$udid" "$app"
    xcrun simctl launch "$udid" "$(bundle_id "$app")" >/dev/null
    say "Ember is running in the simulator."
    ;;

screens)
    # The newest watchOS's smallest and largest watches: what fits on one
    # must fit on the other.
    picks="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
found = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in found if "watchOS" in r),
                  key=lambda r: [int(n) for n in r.rsplit("watchOS-", 1)[-1].split("-")])
if not runtimes:
    sys.exit("No Apple Watch simulator. Add one in Xcode, Settings, Components.")
watches = [d for d in found[runtimes[-1]] if d.get("isAvailable", True)]
size = lambda d: int((re.search(r"(\d+)mm", d["name"]) or [0, 0])[1])
watches.sort(key=size)
for d in {watches[0]["udid"]: watches[0], watches[-1]["udid"]: watches[-1]}.values():
    print(d["udid"], size(d))
')"
    first="$(echo "$picks" | head -n 1 | cut -d' ' -f1)"
    say "Building for the simulator"
    build -destination "id=$first" CODE_SIGNING_ALLOWED=NO
    app="$built/Build/Products/Debug-watchsimulator/Ember.app"
    shots="$built/screens"
    mkdir -p "$shots"
    while read -r udid mm; do
        say "Ember on the ${mm}mm watch"
        xcrun simctl boot "$udid" 2>/dev/null || true
        xcrun simctl bootstatus "$udid" -b >/dev/null
        xcrun simctl install "$udid" "$app"
        xcrun simctl launch "$udid" "$(bundle_id "$app")" >/dev/null
        sleep 6
        xcrun simctl io "$udid" screenshot "$shots/capture-${mm}mm.png" >/dev/null
    done <<< "$picks"
    say "Screenshots in watch/build/screens"
    ;;

install)
    [ -f Local.xcconfig ] || die "Make watch/Local.xcconfig with your DEVELOPMENT_TEAM first (see the top of this script)."
    listing="$(mktemp)"
    trap 'rm -f "$listing"' EXIT
    xcrun devicectl list devices --json-output "$listing" >/dev/null
    read -r device udid < <(python3 - "$listing" "${EMBER_WATCH:-}" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
wanted = sys.argv[2].lower()
watches = [d for d in devices
           if d.get("hardwareProperties", {}).get("platform") == "watchOS"
           and (not wanted or wanted in d.get("deviceProperties", {}).get("name", "").lower())]
if not watches:
    sys.exit("No watch found. Keep it on its charger, unlocked, near the iPhone "
             "it is paired with, with Developer Mode on (Settings, Privacy & Security).")
if len(watches) > 1:
    names = ", ".join(d["deviceProperties"]["name"] for d in watches)
    sys.exit(f"More than one watch ({names}). Pick one: EMBER_WATCH=name")
w = watches[0]
print(w["identifier"], w["hardwareProperties"]["udid"])
PY
    ) || exit 1
    say "Building for your watch"
    build -destination "id=$udid" -allowProvisioningUpdates
    app="$built/Build/Products/Debug-watchos/Ember.app"
    say "Installing (the first time can take a few minutes)"
    xcrun devicectl device install app --device "$device" "$app"
    xcrun devicectl device process launch --device "$device" "$(bundle_id "$app")" >/dev/null || true
    say "Ember is on your watch."
    say "With a free Apple ID it runs for 7 days. Run this again to renew it; your notes stay."
    ;;
esac
