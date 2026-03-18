#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
VERSION="${FLUXBAR_APP_VERSION:-0.1.1}"
DMG_ROOT="$PROJECT_DIR/BuildArtifacts/DMG"
STAGING_DIR="$DMG_ROOT/Staging"
OUTPUT_DMG="$DMG_ROOT/FluxBar-$VERSION.dmg"

sh "$SCRIPT_DIR/build-local.sh"

rm -rf "$STAGING_DIR" "$OUTPUT_DMG"
mkdir -p "$STAGING_DIR"
cp -R "$PROJECT_DIR/BuildArtifacts/Apps/FluxBar.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "FluxBar $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DMG" >/dev/null

printf 'DMG: %s\n' "$OUTPUT_DMG"
