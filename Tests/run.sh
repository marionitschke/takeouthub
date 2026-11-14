#!/bin/bash
# Tests downloading, resuming, sign-in, extraction and month folders against Tests/testserver.py.
# Leaves the real data alone: each scenario runs in build/test/<name> (TAKEOUTHUB_HOME) with a
# non-persistent browser, and Google is never contacted.
#
#   Tests/run.sh
set -uo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null || exit 1
FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos14.0")
[[ -f build/clt-overlay.yaml ]] && FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
SOURCES=()
for file in Sources/TakeoutHub/*.swift; do
  [[ "$file" == */TakeoutHubApp.swift ]] || SOURCES+=("$file")
done
echo "Kompiliere Test-Harness …"
swiftc "${FLAGS[@]}" -module-name TakeoutHub -o build/DownloadTest "${SOURCES[@]}" Tests/harness/main.swift || exit 1

ROOT="$PWD/build/test"
rm -rf "$ROOT"
mkdir -p "$ROOT"
export TAKEOUTHUB_RETRY_SCALE=0.02
# Month folders follow local time; the test data assumes Berlin (New Year's Eve case).
export TZ=Europe/Berlin
FAILED=0
SERVER_PID=""
PORT=""
SHA=""

json() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"; }

start_server() {
  rm -f "$ROOT/server.json"
  python3 -I Tests/testserver.py "$@" > "$ROOT/server.json" 2>> "$ROOT/server.log" &
  SERVER_PID=$!
  for _ in $(seq 100); do [[ -s "$ROOT/server.json" ]] && break; sleep 0.1; done
  PORT=$(json "$ROOT/server.json" port)
  SHA=$(json "$ROOT/server.json" sha256)
}

stop_server() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
}

stat_value() { curl -s "http://127.0.0.1:$PORT/stats" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

harness() { # <name> <mode>
  TAKEOUTHUB_HOME="$ROOT/$1" build/DownloadTest "$PORT" "$2" "$SHA" > "$ROOT/$1.out" 2>&1
  local status=$?
  grep -v '^  |' "$ROOT/$1.out" | sed 's/^/   /'
  return $status
}

check() { # <description> <condition …>
  local text="$1"; shift
  if "$@"; then echo "   ok: $text"; else echo "   FEHLER: $text"; FAILED=1; fi
}

echo "== Abbrüche alle 3 MB, Fortsetzen über die direkte Adresse"
start_server --size $((12 << 20)) --drop 3000000
harness abbrueche full; check "Datei vollständig und unverändert" test $? -eq 0
check "Takeout-Link nur einmal angefordert" test "$(stat_value link_requests)" -eq 1
check "mit Range fortgesetzt" test "$(stat_value range_requests)" -ge 3
stop_server

echo "== Direkte Adresse läuft nach jedem Abruf ab"
start_server --size $((8 << 20)) --drop 3000000 --direct-uses 1
harness ablauf full; check "Datei vollständig über neu angeforderte Links" test $? -eq 0
check "Takeout-Link mehrfach angefordert" test "$(stat_value link_requests)" -ge 3
stop_server

echo "== Ohne Anmeldung (keine Cookies)"
start_server --size $((1 << 20))
harness anmeldung login; check "Zustand „Anmeldung nötig“" test $? -eq 0
stop_server

echo "== Server ignoriert Range"
start_server --size $((8 << 20)) --no-range --drop 5000000 --drop-once
harness ohne-range full; check "beginnt von vorn und wird fertig" test $? -eq 0
check "Neubeginn im Protokoll" grep -q "beginnt von vorn" "$ROOT/ohne-range/TakeoutHub.log"
stop_server

echo "== Beenden mitten im Download, Neustart setzt fort"
start_server --size $((12 << 20)) --rate $((2 << 20))
harness neustart quit; check "Zustand gespeichert" test $? -eq 0
PART_SIZE=$(stat -f %z "$ROOT/neustart/TakeoutHub/Archive/takeout-001.zip.part" 2>/dev/null || echo 0)
check "Teildatei liegt vor ($PART_SIZE Bytes)" test "$PART_SIZE" -gt 0
harness neustart resume; check "nach dem Neustart vollständig" test $? -eq 0
check "Neustart mit Range statt von vorn" test "$(stat_value range_requests)" -ge 1
stop_server

echo "== Datei ändert auf dem Server ihre Größe"
start_server --size $((8 << 20)) --drop 3000000 --drop-once --other-size $((9 << 20))
harness andere-groesse mismatch; check "angehalten, Teildatei nicht angehängt" test $? -eq 0
stop_server
start_server --size $((8 << 20)) --drop 3000000 --drop-once --other-size $((9 << 20)) --no-range
harness andere-groesse-200 mismatch; check "angehalten, Teildatei nicht verworfen" test $? -eq 0
stop_server

echo "== Entpacken und Aufnahmedatum"
python3 -I Tests/make_takeout.py "$ROOT/takeout.zip" "$ROOT/takeout-2.zip" | sed 's/^/   /'
start_server --file "$ROOT/takeout.zip" --name takeout-001.zip
harness entpacken extract; check "entpackt" test $? -eq 0
python3 -I Tests/check_dates.py "$ROOT/entpacken/TakeoutHub/Fotos" "$ROOT/takeout.zip" | sed 's/^/   /'
check "Dateidaten" test "${PIPESTATUS[0]}" -eq 0
check "Summe im Protokoll" grep -q "bei 14 Dateien gesetzt. 2 Begleitdateien ohne passendes Foto" "$ROOT/entpacken/TakeoutHub.log"
check "ohne Option kein Monatsordner" test ! -e "$ROOT/entpacken/TakeoutHub/Fotos/Google Fotos/Fotos von 2019/05"
stop_server

echo "== Entpacken in Monatsordner, danach ein zweiter Teil"
FOTOS="$ROOT/monatsordner/TakeoutHub/Fotos"
start_server --file "$ROOT/takeout.zip" --name takeout-001.zip
harness monatsordner extract-sort; check "entpackt und einsortiert" test $? -eq 0
python3 -I Tests/check_sort.py "$FOTOS" "$ROOT/takeout.zip" sorted1 | sed 's/^/   /'
check "Ordner, Inhalt und Datum" test "${PIPESTATUS[0]}" -eq 0
check "Summe im Protokoll" grep -q "13 Dateien in 9 Monatsordner einsortiert. 2 Dateien ohne Aufnahmedatum blieben liegen. 1 Datei blieb liegen, weil" "$ROOT/monatsordner/TakeoutHub.log"
stop_server
# Extract the second part with the app's tar options (the app goes through a staging folder; same result)
/usr/bin/tar -x -k -f "$ROOT/takeout-2.zip" -C "$FOTOS" --strip-components 1 --exclude '*/archive_browser.html'
harness monatsordner sort; check "erneut einsortiert" test $? -eq 0
python3 -I Tests/check_sort.py "$FOTOS" "$ROOT/takeout.zip" sorted2 | sed 's/^/   /'
check "Nachzügler beim Original, Doppeltes liegen geblieben" test "${PIPESTATUS[0]}" -eq 0
check "Summe im Protokoll" grep -q "2 Dateien in 2 Monatsordner einsortiert. 2 Dateien ohne Aufnahmedatum blieben liegen. 2 Dateien blieben liegen, weil" "$ROOT/monatsordner/TakeoutHub.log"
harness monatsordner sort >/dev/null
python3 -I Tests/check_sort.py "$FOTOS" "$ROOT/takeout.zip" sorted2 > /dev/null
check "dritter Lauf ändert nichts" test $? -eq 0
check "Summe im Protokoll" grep -q "Nichts neu in Monatsordner einzusortieren." "$ROOT/monatsordner/TakeoutHub.log"

# Lists everything in the photos folder (hidden staging folders included) and outside of it.
contents() { find "$ROOT/$1/TakeoutHub/Fotos" "$ROOT/$1/draussen" -mindepth 1 2>/dev/null | sed "s|^$ROOT/$1/||"; }

echo "== Beschädigtes Archiv: nichts Halbes im Fotoordner"
python3 -I Tests/make_bad_archives.py corrupt "$ROOT/corrupt.zip"
start_server --file "$ROOT/corrupt.zip" --name takeout-001.zip
harness beschaedigt extract-fail; check "abgebrochen, nicht als entpackt vermerkt" test $? -eq 0
check "Fotoordner leer" test -z "$(contents beschaedigt)"
stop_server

echo "== Archiv mit Links und absolutem Pfad"
mkdir -p "$ROOT/links/draussen"
python3 -I Tests/make_bad_archives.py links "$ROOT/links.zip" "$ROOT/links/draussen"
start_server --file "$ROOT/links.zip" --name takeout-001.zip
harness links extract; check "entpackt" test $? -eq 0
check "Foto da" test -f "$ROOT/links/TakeoutHub/Fotos/Google Fotos/Fotos von 2019/OK.jpg"
check "absoluter Pfad bleibt im Fotoordner" test -f "$ROOT/links/TakeoutHub/Fotos/Takeout/Google Fotos/Absolut/ABS.jpg"
check "Foto aus schreibgeschütztem Ordner" test -f "$ROOT/links/TakeoutHub/Fotos/Google Fotos/Nur lesen/RO.jpg"
check "Links verworfen, draußen nichts" test -z "$(find "$ROOT/links" -type l; ls -A "$ROOT/links/draussen")"
stop_server

echo "== Archiv mit .. und Datei durch einen Link"
mkdir -p "$ROOT/ausbruch/draussen"
python3 -I Tests/make_bad_archives.py slip "$ROOT/slip.zip" "$ROOT/ausbruch/draussen"
start_server --file "$ROOT/slip.zip" --name takeout-001.zip
harness ausbruch extract-fail; check "abgebrochen" test $? -eq 0
check "nichts im Fotoordner und draußen" test -z "$(contents ausbruch)"
check "nichts außerhalb des Fotoordners" test -z "$(find "$ROOT" -name draussen.jpg)"
stop_server

echo "== Beenden mitten im Entpacken, danach erneut entpacken"
python3 -I Tests/make_bad_archives.py many "$ROOT/many.zip"
start_server --file "$ROOT/many.zip" --name takeout-001.zip
harness abbruch extract-quit; check "beim Beenden abgebrochen" test $? -eq 0
check "tar beendet" test -z "$(pgrep -f "$ROOT/abbruch/TakeoutHub/Archive/takeout-001.zip")"
check "nichts Halbes im Fotoordner" test -z "$(contents abbruch | grep -v '^TakeoutHub/Fotos/\.TakeoutHub-entpacken-')"
harness abbruch extract; check "danach entpackt" test $? -eq 0
check "alle 20000 Fotos, keine Reste" test "$(contents abbruch | grep -c 'jpg$')" -eq 20000 -a \
  -z "$(contents abbruch | grep 'TakeoutHub-entpacken')"
stop_server
rm -rf "$ROOT/abbruch" "$ROOT/many.zip"

echo "== Zustand einer älteren Version (ohne Monatsordner-Einstellung)"
mkdir -p "$ROOT/altstand/support"
cat > "$ROOT/altstand/support/state.json" <<EOF
{"items": [{"id": "00000000-0000-0000-0000-000000000001", "fileName": "takeout-001.zip",
  "folder": "$ROOT/altstand/Archive", "sourceURL": "http://127.0.0.1:1/takeout/download?i=1", "state": "done",
  "receivedBytes": 10, "totalBytes": 10, "addedAt": "2026-11-01T10:00:00Z", "linkRequests": 1,
  "extractedAt": "2026-11-02T10:00:00Z"}],
 "settings": {"archiveFolder": "$ROOT/altstand/Archive", "photosFolder": "$ROOT/altstand/Eigene Fotos",
  "keepAwake": true, "trashAfterExtract": true}}
EOF
harness altstand load; check "Warteschlange und Einstellungen geladen" test $? -eq 0

echo "== Unlesbare state.json"
mkdir -p "$ROOT/defekt/support"
echo '{"items": [{"fileName": ' > "$ROOT/defekt/support/state.json"
cp "$ROOT/defekt/support/state.json" "$ROOT/defekt/original.json"
harness defekt broken; check "beiseitegelegt statt überschrieben" test $? -eq 0
check "Inhalt unverändert" cmp -s "$ROOT/defekt/original.json" "$ROOT"/defekt/support/state-defekt-*.json
check "Warnung im Protokoll" grep -q "state.json ließ sich nicht lesen" "$ROOT/defekt/TakeoutHub.log"

echo "== state.json mit unsinnigen Größen"
mkdir -p "$ROOT/groessen/support"
cat > "$ROOT/groessen/support/state.json" <<EOF
{"items": [{"id": "00000000-0000-0000-0000-000000000001", "fileName": "takeout-001.zip", "folder": "$ROOT/groessen",
  "sourceURL": "http://127.0.0.1:1/takeout/download?i=1", "state": "done", "receivedBytes": 9223372036854775807,
  "totalBytes": 9223372036854775807, "addedAt": "2026-11-01T10:00:00Z", "linkRequests": 1},
 {"id": "00000000-0000-0000-0000-000000000002", "fileName": "takeout-002.zip", "folder": "$ROOT/groessen",
  "sourceURL": "http://127.0.0.1:1/takeout/download?i=2", "state": "paused", "receivedBytes": 0,
  "totalBytes": 9223372036854775807, "addedAt": "2026-11-01T10:00:00Z", "linkRequests": 1}],
 "settings": {}}
EOF
harness groessen sizes; check "geladen ohne Überlauf" test $? -eq 0

echo
if [[ $FAILED -eq 0 ]]; then echo "Alle Prüfungen bestanden."; else echo "Es gibt Fehler (Ausgaben in build/test/)."; fi
exit $FAILED
