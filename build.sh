#!/bin/bash
# Builds SimpleFaceit.app (+ widget extension) for macOS with Xcode Command Line Tools only,
# signs it and installs it to /Applications.  Usage: ./build.sh [--no-install] [--arch arm64|x86_64]
set -euo pipefail
cd "$(dirname "$0")"

NAME="SimpleFaceit"
BUNDLE_ID="com.k33ssa.SimpleFaceitWidget"
TEAM="3P6X2MU65Y"
GROUP="$TEAM.com.k33ssa.simplefaceit"
VERSION="${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)}"
BUILD="${BUILD_NUMBER:-1}"
OUT="build"
INSTALL=1
ARCH_ARGS=()
for a in "$@"; do
  case "$a" in
    --no-install) INSTALL=0 ;;
    --arch=*) ARCH_ARGS+=(--arch "${a#--arch=}") ;;
  esac
done

echo "==> swift build ($VERSION)"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product SimpleFaceit
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --product SimpleFaceitWidget
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="$OUT/$NAME.app"
APPEX="$APP/Contents/PlugIns/SimpleFaceitWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN/SimpleFaceit" "$APP/Contents/MacOS/$NAME"
cp "$BIN/SimpleFaceitWidget" "$APPEX/Contents/MacOS/SimpleFaceitWidget"

# --- icon (.icns from the asset catalog's mac PNGs) ---
ICONSET="$OUT/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="App/Shared/Assets.xcassets/AppIcon.appiconset"
cp "$SRC/mac-16.png" "$ICONSET/icon_16x16.png";       cp "$SRC/mac-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$SRC/mac-32.png" "$ICONSET/icon_32x32.png";       cp "$SRC/mac-64.png" "$ICONSET/icon_32x32@2x.png"
cp "$SRC/mac-128.png" "$ICONSET/icon_128x128.png";    cp "$SRC/mac-256.png" "$ICONSET/icon_128x128@2x.png"
cp "$SRC/mac-256.png" "$ICONSET/icon_256x256.png";    cp "$SRC/mac-512.png" "$ICONSET/icon_256x256@2x.png"
cp "$SRC/mac-512.png" "$ICONSET/icon_512x512.png";    cp "$SRC/mac-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Personal builds: API key from $FACEIT_API_KEY or Config/Secrets.xcconfig (gitignored). Release builds pass NO_BUNDLED_KEY=1.
KEY="${FACEIT_API_KEY:-}"
if [ -z "$KEY" ] && [ -f Config/Secrets.xcconfig ]; then
  KEY="$(sed -nE 's/^ *FACEIT_API_KEY *= *([^ ]+).*/\1/p' Config/Secrets.xcconfig | head -1)"
fi
[ "${NO_BUNDLED_KEY:-0}" = 1 ] && KEY=""

# --- Info.plist files ---
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.sports</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>FSAppGroupIdentifier</key><string>$GROUP</string>
  <key>FSBundledAPIKey</key><string>$KEY</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.k33ssa.simplefaceit</string>
    <key>CFBundleURLSchemes</key><array><string>faceitstats</string></array>
  </dict></array>
</dict></plist>
EOF
cat > "$APPEX/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Widget</string>
  <key>CFBundleName</key><string>SimpleFaceitWidget</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>SimpleFaceitWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>FSAppGroupIdentifier</key><string>$GROUP</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
EOF

# --- entitlements ---
ENT="$OUT/entitlements.plist"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
EOF

# --- signing: an identity of team $TEAM is required for the team-prefixed App Group ---
# The certificate's common name shows the person id, not the team: pick an "Apple Development" identity
# whose certificate OU (= team) is $TEAM.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  while IFS= read -r name; do
    ou="$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]+).*/\1/p')"
    if [ "$ou" = "$TEAM" ]; then IDENTITY="$name"; break; fi
  done < <(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development[^"]*)".*/\1/p')
fi
if [ -z "$IDENTITY" ]; then
  echo "!! No 'Apple Development' signing identity found; signing ad-hoc. Widgets may not see shared data." >&2
  IDENTITY="-"
fi
echo "==> codesign"
codesign --force --options runtime --timestamp=none --entitlements "$ENT" --sign "$IDENTITY" "$APPEX"
codesign --force --options runtime --timestamp=none --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

if [ "$INSTALL" = 1 ]; then
  echo "==> install to /Applications"
  osascript -e "quit app \"$NAME\"" >/dev/null 2>&1 || true
  rm -rf "/Applications/$NAME.app"
  ditto "$APP" "/Applications/$NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$NAME.app" || true
  pluginkit -a "/Applications/$NAME.app/Contents/PlugIns/SimpleFaceitWidget.appex" 2>/dev/null || true
  open "/Applications/$NAME.app"
  echo "Done: /Applications/$NAME.app — add the widget: right-click the desktop → Edit Widgets → SimpleFaceit."
else
  echo "Built: $APP"
fi
