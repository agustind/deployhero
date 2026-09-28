#!/bin/sh
# Build dist/DeployHero.app from the Swift package.
#
#   scripts/build.sh              ad-hoc signed .app
#   scripts/build.sh --dmg        …plus dist/deployhero-<version>.dmg
#   scripts/build.sh --notarize   …plus notarize and staple the .app and .dmg
#
# SIGN_IDENTITY   "Developer ID Application: <Name> (<TEAMID>)"; ad-hoc when unset
# NOTARY_PROFILE  a `xcrun notarytool store-credentials` profile (for --notarize)
set -eu
cd "$(dirname "$0")/.."

DMG=0
NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --dmg) DMG=1 ;;
    --notarize) DMG=1; NOTARIZE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

NAME=DeployHero
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
APP=dist/$NAME.app
IDENTITY=${SIGN_IDENTITY:--}

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/$NAME

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# icon.png (1024×1024) → AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($VERSION)"

make_dmg() {
  DMG_PATH=dist/deployhero-$VERSION.dmg
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG_PATH"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGE"
  [ "$IDENTITY" = "-" ] || codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"
  echo "built $DMG_PATH"
}

if [ "$NOTARIZE" = 1 ]; then
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
  [ "$IDENTITY" != "-" ] || { echo "--notarize needs SIGN_IDENTITY" >&2; exit 1; }
  ZIP=$(mktemp -d)/$NAME.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  make_dmg
  xcrun notarytool submit "dist/deployhero-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/deployhero-$VERSION.dmg"
elif [ "$DMG" = 1 ]; then
  make_dmg
fi
