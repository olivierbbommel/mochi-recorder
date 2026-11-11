#!/usr/bin/env bash
# Publish a Mochi release that every Mac picks up (Updater.swift):
#   SUPABASE_PAT=... ./release.sh "What changed, one line"
# Builds and signs Mochi.app, zips it, uploads Mochi-<build>.zip and latest.json to the PRIVATE
# "releases" bucket of your Supabase project (MOCHI_SUPABASE_URL in mochi.env). Macs fetch them
# through mochi-api, which hands out a short-lived download link. Needs a real signing identity:
# the updater only installs builds signed by the same team as the running app.
set -euo pipefail
cd "$(dirname "$0")"
[ -f mochi.env ] && { set -a; . ./mochi.env; set +a; }
NOTES=${1:-"Bug fixes and improvements."}
: "${MOCHI_SUPABASE_URL:?set MOCHI_SUPABASE_URL in mochi.env}"
: "${SUPABASE_PAT:?set SUPABASE_PAT to your Supabase access token}"
[ "${MOCHI_SIGN_IDENTITY:--}" != "-" ] || { echo "Set MOCHI_SIGN_IDENTITY: ad-hoc builds cannot be installed as updates." >&2; exit 1; }
REF=$(echo "$MOCHI_SUPABASE_URL" | sed -E 's|https://([^.]+)\.supabase\.co/?|\1|')
[ -z "$(git status --porcelain)" ] || { echo "Commit first: releases are built from a clean tree." >&2; exit 1; }

./build.sh
# Smoke test: the signed app must still be running 10 s after launch (build 222 crashed at launch
# and was published). Uses a throwaway data folder, so sync and real calls are untouched.
SMOKE=$(mktemp -d)
open -n build/Mochi.app --env MOCHI_ROOT="$SMOKE"
sleep 10
PID=$(pgrep -f "$(pwd)/build/Mochi.app/Contents/MacOS/Mochi" | head -1 || true)
[ -n "$PID" ] || { echo "Smoke test failed: the app is not running 10 s after launch. Not released." >&2; exit 1; }
kill "$PID"; rm -rf "$SMOKE"

BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/Mochi.app/Contents/Info.plist)
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Mochi.app/Contents/Info.plist)
ZIP=build/Mochi-$BUILD.zip
rm -f "$ZIP"
ditto -c -k --keepParent build/Mochi.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)

KEY=$(curl -s -H "Authorization: Bearer $SUPABASE_PAT" "https://api.supabase.com/v1/projects/$REF/api-keys?reveal=true" \
  | python3 -c "import json,sys; print(next(k['api_key'] for k in json.load(sys.stdin) if k['name']=='service_role'))")
STORAGE=https://$REF.supabase.co/storage/v1
upload() {  # upload <local file> <path in bucket> <content type>
  curl -sf -X POST "$STORAGE/object/releases/$2" -H "Authorization: Bearer $KEY" -H "x-upsert: true" \
    -H "Content-Type: $3" --data-binary "@$1" >/dev/null
}
upload "$ZIP" "mochi/Mochi-$BUILD.zip" application/zip
python3 - "$VERSION" "$BUILD" "$SHA" "$NOTES" > build/latest.json <<'PY'
import json, sys
version, build, sha, notes = sys.argv[1:]
print(json.dumps({"version": version, "build": int(build), "sha256": sha, "notes": notes,
                  "path": f"mochi/Mochi-{build}.zip"}))
PY
upload build/latest.json mochi/latest.json application/json
echo "released Mochi $VERSION build $BUILD"
