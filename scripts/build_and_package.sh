#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT_DIR/Resources/Info.plist")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT_DIR/Resources/Info.plist")"
BUILD_PRODUCT="CallTone"
ARTIFACT_NAME="${APP_NAME// /-}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$ARTIFACT_NAME-$VERSION.dmg"
PKG_PATH="$DIST_DIR/$ARTIFACT_NAME-$VERSION.pkg"
COMPONENT_PKG="$DIST_DIR/${ARTIFACT_NAME}-component.pkg"

DMGBUILD="${DMGBUILD:-dmgbuild}"
if ! command -v "$DMGBUILD" >/dev/null 2>&1; then
    echo "dmgbuild is required to create the installer DMG. See README.md." >&2
    exit 1
fi

echo "==> Building $APP_NAME ($VERSION) for Apple Silicon (arm64)..."
cd "$ROOT_DIR"
swift build --disable-sandbox -c release --arch arm64

BIN_PATH="$ROOT_DIR/.build/out/Products/Release/$BUILD_PRODUCT"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH="$ROOT_DIR/.build/arm64-apple-macosx/release/$BUILD_PRODUCT"
fi
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH="$ROOT_DIR/.build/release/$BUILD_PRODUCT"
fi

echo "==> Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE" "$DMG_PATH" "$PKG_PATH" "$COMPONENT_PKG"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" "$ROOT_DIR/LICENSE" "$ROOT_DIR/PRIVACY.md" "$APP_BUNDLE/Contents/Resources/"
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"
sips -Z 64 "$ROOT_DIR/Resources/MenuBarIcon.png" \
    --out "$APP_BUNDLE/Contents/Resources/MenuBarIcon.png" >/dev/null

# Build the Finder and Dock icon from the same artwork used in the README.
ICON_TEMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TEMP"' EXIT
ICON_SET="$ICON_TEMP/AppIcon.iconset"
mkdir "$ICON_SET"
for size in 16 32 128 256 512; do
    doubled=$((size * 2))
    sips -z "$size" "$size" "$ROOT_DIR/Resources/Logo.png" \
        --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
    sips -z "$doubled" "$doubled" "$ROOT_DIR/Resources/Logo.png" \
        --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_SET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Use only explicitly selected signing identities for public builds.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"

ENTITLEMENTS="$ROOT_DIR/Resources/CallTone.entitlements"

if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "==> Signing $APP_BUNDLE with '$SIGNING_IDENTITY' (Hardened Runtime)..."
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE"
else
    echo "==> Using ad-hoc signing..."
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP_BUNDLE"
fi

echo "==> Creating DMG ($DMG_PATH)..."
"$DMGBUILD" -s "$ROOT_DIR/scripts/dmg_settings.py" -D "app=$APP_BUNDLE" \
    -D "background=$ROOT_DIR/Resources/DMGBackground.png" "$APP_NAME" "$DMG_PATH"

echo "==> Creating PKG ($PKG_PATH)..."
PKG_ROOT="$DIST_DIR/pkg-root"
rm -rf "$PKG_ROOT" "$DIST_DIR/pkg-components.plist"
mkdir -p "$PKG_ROOT/Applications"
cp -R "$APP_BUNDLE" "$PKG_ROOT/Applications/"

pkgbuild \
    --root "$PKG_ROOT" \
    --identifier "com.calltone.macos.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG"

if [ -n "$INSTALLER_IDENTITY" ]; then
    echo "==> Signing PKG with '$INSTALLER_IDENTITY'..."
    productbuild \
        --package "$COMPONENT_PKG" \
        --sign "$INSTALLER_IDENTITY" \
        "$PKG_PATH"
else
    productbuild \
        --package "$COMPONENT_PKG" \
        "$PKG_PATH"
fi

rm -rf "$PKG_ROOT" "$COMPONENT_PKG"

# Optional notarization when NOTARY_PROFILE is set (e.g., NOTARY_PROFILE="CallToneNotary")
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "==> Notarizing and stapling $PKG_PATH..."
    xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PKG_PATH"
    if [ -f "$DMG_PATH" ]; then
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_PATH"
    fi
fi

echo "==> Done!"
echo "App: $APP_BUNDLE"
echo "DMG: $DMG_PATH"
echo "PKG: $PKG_PATH"
