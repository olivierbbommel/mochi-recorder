#!/usr/bin/env bash
# Build Mochi.app: release binary, app bundle, stable code signature.
#
#   ./build.sh            -> build/Mochi.app
#   ./build.sh --install  -> also copies it to /Applications/Mochi.app (replaces old Mochi)
#
# Settings come from mochi.env (copy mochi.env.example) or the environment. The signature must
# stay the same across rebuilds: macOS ties the microphone and system audio permissions to it.
set -euo pipefail
cd "$(dirname "$0")"
[ -f mochi.env ] && { set -a; . ./mochi.env; set +a; }

IDENTITY=${MOCHI_SIGN_IDENTITY:--}
BUNDLE_ID=${MOCHI_BUNDLE_ID:-com.example.mochi}
SUPABASE_URL=${MOCHI_SUPABASE_URL:-}
SUPABASE_KEY=${MOCHI_SUPABASE_KEY:-}
VERSION=2.0.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
APP=build/Mochi.app

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "unknown option $arg"; exit 2 ;;
  esac
done

swift build -c release --product Mochi
BIN=$(swift build -c release --product Mochi --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mochi" "$APP/Contents/MacOS/Mochi"
# SwiftPM resource bundles (FluidAudio) sit next to the binary.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|" -e "s|__SUPABASE_URL__|$SUPABASE_URL|" -e "s|__SUPABASE_KEY__|$SUPABASE_KEY|" \
    -e "s|__VERSION__|$VERSION|" -e "s|__BUILD__|$BUILD|" -e "s|__COMMIT__|$COMMIT|" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --entitlements Resources/Mochi.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
[ "$IDENTITY" = "-" ] && echo "note: signed ad hoc. Set MOCHI_SIGN_IDENTITY in mochi.env to keep permissions across rebuilds."
[ -z "$SUPABASE_URL" ] && echo "note: no Supabase project set, so this build runs local only."
echo "built $APP ($BUNDLE_ID $VERSION build $BUILD)"

if [ "$INSTALL" = 1 ]; then
  rm -rf /Applications/Mochi.app
  cp -R "$APP" /Applications/Mochi.app
  echo "installed /Applications/Mochi.app"
fi
