#!/bin/bash
# Builds this fork and swaps it into /Applications, replacing the running Tinybar.
# Signed with this Mac's Apple Development identity: a stable signature keeps the login item and
# privacy grants across rebuilds, which ad-hoc signing would reset each time.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
[[ -n "$IDENTITY" ]] || { echo "No Apple Development signing identity in the keychain; sign in to Xcode with your Apple ID to create one." >&2; exit 1; }
SIGN_IDENTITY="$IDENTITY" Scripts/build-app.sh

if pgrep -xq Tinybar; then
    osascript -e 'quit app "Tinybar"'
    for _ in $(seq 50); do pgrep -xq Tinybar || break; sleep 0.2; done
    pkill -x Tinybar || true
fi
rm -rf /Applications/Tinybar.app
ditto build/Tinybar.app /Applications/Tinybar.app
open /Applications/Tinybar.app
echo "Installed $(git rev-parse --short HEAD) to /Applications/Tinybar.app"
