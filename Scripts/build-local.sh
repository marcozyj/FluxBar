#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

CONFIGURATION="${1:-debug}"
BUNDLE_IDENTIFIER="${FLUXBAR_BUNDLE_IDENTIFIER:-dev.fluxbar.FluxBar}"
APP_NAME="FluxBar"
HELPER_NAME="FluxBarTUNHelper"
APP_VERSION="${FLUXBAR_APP_VERSION:-0.1.1}"
APP_BUILD="${FLUXBAR_APP_BUILD:-100}"
MINIMUM_DEPLOYMENT_TARGET="${FLUXBAR_MINIMUM_DEPLOYMENT_TARGET:-14.0}"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUILD_ROOT="$PROJECT_DIR/BuildArtifacts"
SPM_BUILD_DIR="$BUILD_ROOT/SPMBuild"
APP_EXPORT_DIR="$BUILD_ROOT/Apps"
RESOURCES_EXPORT_DIR="$BUILD_ROOT/ResourcesSnapshot"
APP_PATH="$APP_EXPORT_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_PATH/Contents"
APP_MACOS_DIR="$APP_CONTENTS/MacOS"
APP_RESOURCES_DIR="$APP_CONTENTS/Resources"
INFO_PLIST_PATH="$APP_CONTENTS/Info.plist"
ASSET_INFO_PLIST="$BUILD_ROOT/assetcatalog-info.plist"
BUILD_HOME="$BUILD_ROOT/Home"
CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ClangModuleCache"

rm -rf "$SPM_BUILD_DIR" "$CLANG_MODULE_CACHE_PATH" "$BUILD_HOME/.cache" "$BUILD_HOME/Library"
mkdir -p "$SPM_BUILD_DIR" "$APP_EXPORT_DIR" "$RESOURCES_EXPORT_DIR" "$BUILD_HOME" "$CLANG_MODULE_CACHE_PATH"

env \
  HOME="$BUILD_HOME" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcrun swift build \
  --package-path "$PROJECT_DIR" \
  --build-path "$SPM_BUILD_DIR" \
  -c "$CONFIGURATION"

BIN_DIR="$({
  env \
    HOME="$BUILD_HOME" \
    CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift build \
      --package-path "$PROJECT_DIR" \
      --build-path "$SPM_BUILD_DIR" \
      -c "$CONFIGURATION" \
      --show-bin-path
})"
EXECUTABLE_PATH="$BIN_DIR/$APP_NAME"
HELPER_EXECUTABLE_PATH="$BIN_DIR/$HELPER_NAME"

rm -rf "$APP_PATH" "$RESOURCES_EXPORT_DIR/$APP_NAME"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR"

cp "$EXECUTABLE_PATH" "$APP_MACOS_DIR/$APP_NAME"
chmod +x "$APP_MACOS_DIR/$APP_NAME"

if [ -f "$HELPER_EXECUTABLE_PATH" ]; then
  cp "$HELPER_EXECUTABLE_PATH" "$APP_RESOURCES_DIR/$HELPER_NAME"
  chmod +x "$APP_RESOURCES_DIR/$HELPER_NAME"
fi

if [ -d "$PROJECT_DIR/Resources" ]; then
  cp -R "$PROJECT_DIR/Resources/." "$APP_RESOURCES_DIR/"
fi

if [ -f "$APP_RESOURCES_DIR/mihomo" ]; then
  chmod +x "$APP_RESOURCES_DIR/mihomo"
fi

if [ -f "$APP_RESOURCES_DIR/kernels/mihomo" ]; then
  chmod +x "$APP_RESOURCES_DIR/kernels/mihomo"
fi

if [ -d "$PROJECT_DIR/Assets.xcassets" ]; then
  if ! env DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun actool     "$PROJECT_DIR/Assets.xcassets"     --compile "$APP_RESOURCES_DIR"     --platform macosx     --target-device mac     --minimum-deployment-target "$MINIMUM_DEPLOYMENT_TARGET"     --app-icon AppIcon     --accent-color AccentColor     --output-format human-readable-text     --output-partial-info-plist "$ASSET_INFO_PLIST" >/dev/null; then
    printf 'Warning: actool failed, skipping asset catalog compilation.
' >&2
  fi
fi
cat > "$INFO_PLIST_PATH" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_DEPLOYMENT_TARGET</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF2

codesign --force --sign - --timestamp=none "$APP_MACOS_DIR/$APP_NAME"
if [ -f "$APP_RESOURCES_DIR/$HELPER_NAME" ]; then
  codesign --force --sign - --timestamp=none "$APP_RESOURCES_DIR/$HELPER_NAME"
fi
codesign --force --sign - --entitlements "$PROJECT_DIR/FluxBar.entitlements" --timestamp=none "$APP_PATH"

cp -R "$APP_RESOURCES_DIR" "$RESOURCES_EXPORT_DIR/$APP_NAME"

printf 'Build complete.\n'
printf 'App: %s\n' "$APP_PATH"
printf 'Resources: %s\n' "$RESOURCES_EXPORT_DIR/$APP_NAME"
