#!/bin/bash
# Builds a snapshot variant (with Tests/Snapshot.swift) and saves images of the windows.
# Leaves the real data alone: own data folder (TAKEOUTHUB_HOME), own bundle ID, non-persistent
# browser; the running download comes from the local test server.
#
#   scripts/snapshot.sh [output folder]   → default: build/snapshot/
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/snapshot}"
HOME_DIR="$PWD/build/snapshot-home"
./build.sh >/dev/null

FLAGS=(-O -swift-version 5 -parse-as-library -D SNAPSHOT -target "$(uname -m)-apple-macos14.0")
[[ -f build/clt-overlay.yaml ]] && FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
swiftc "${FLAGS[@]}" -module-name TakeoutHub -o build/TakeoutHubSnapshot Sources/TakeoutHub/*.swift Tests/Snapshot.swift

APP="build/TakeoutHubSnapshot.app"
rm -rf "$APP"
cp -R build/TakeoutHub.app "$APP"
cp build/TakeoutHubSnapshot "$APP/Contents/MacOS/TakeoutHub"
plutil -replace CFBundleIdentifier -string local.takeouthub.snapshot "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" 2>/dev/null

rm -rf "$HOME_DIR" "$OUT"
mkdir -p "$HOME_DIR" "$OUT"
python3 -I Tests/testserver.py --size $((60 << 20)) --rate 400000 --no-auth \
  --name takeout-20261105T081512Z-003.zip > "$HOME_DIR/server.json" 2> "$HOME_DIR/server.log" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null; rm -rf "$HOME_DIR"' EXIT
for _ in $(seq 100); do [[ -s "$HOME_DIR/server.json" ]] && break; sleep 0.1; done

# Sample state: done + extracted, done, running, paused, needs sign-in, waiting
python3 -I - "$HOME_DIR" <<'EOF'
import json, os, sys
from datetime import datetime, timedelta, timezone
home = sys.argv[1]
port = json.load(open(f"{home}/server.json"))["port"]
archive = f"{home}/TakeoutHub/Archive"
os.makedirs(archive, exist_ok=True)
now = datetime.now(timezone.utc).replace(microsecond=0)
iso = lambda d: d.isoformat().replace("+00:00", "Z")
GB = 1 << 30
def item(n, state, total, **extra):
    name = f"takeout-20261105T081512Z-00{n}.zip"
    base = {"id": f"00000000-0000-0000-0000-00000000000{n}", "fileName": name, "folder": archive,
            "sourceURL": f"http://127.0.0.1:{port}/takeout/download?i={n}", "state": state,
            "receivedBytes": 0, "addedAt": iso(now - timedelta(days=1)), "linkRequests": 1}
    if total: base["totalBytes"] = total
    base.update(extra)
    return base
items = [
    item(1, "done", 50 * GB, receivedBytes=50 * GB, finishedAt=iso(now - timedelta(hours=20)),
         extractedAt=iso(now - timedelta(hours=2))),
    item(2, "done", 50 * GB, receivedBytes=50 * GB, finishedAt=iso(now - timedelta(hours=6))),
    item(3, "queued", None),
    item(4, "paused", 50 * GB),
    item(5, "needsLogin", 31 * GB, message="Link abgelaufen (HTTP 403). In „Google Takeout“ unter „Exporte verwalten“ "
         "noch einmal auf „Herunterladen“ klicken – es geht an derselben Stelle weiter."),
    item(6, "waiting", 50 * GB, message="Verbindung abgebrochen"),
]
for n in (1, 2):
    open(f"{archive}/takeout-20261105T081512Z-00{n}.zip", "wb").close()
for n, size in ((4, 18 * GB), (5, 7 * GB), (6, 2 * GB)):
    with open(f"{archive}/takeout-20261105T081512Z-00{n}.zip.part", "wb") as handle:
        handle.truncate(size)  # sparse file on APFS
os.makedirs(f"{home}/support", exist_ok=True)
json.dump({"items": items, "settings": {"archiveFolder": archive, "photosFolder": f"{home}/TakeoutHub/Fotos",
           "keepAwake": True, "trashAfterExtract": False}}, open(f"{home}/support/state.json", "w"))
EOF

TAKEOUTHUB_HOME="$HOME_DIR" TAKEOUTHUB_SNAPSHOT="$(cd "$OUT" && pwd)" "$APP/Contents/MacOS/TakeoutHub"
echo "Bilder: $OUT"
