#!/bin/bash
# Assembles GW Switch installer (GWSwitch-1.0.pkg) from the compiled artifacts in
# dist/build. The installer prompts for an admin password ONCE; after that, route
# changes go through the root helper with no further prompts.
set -euo pipefail

cd "$(dirname "$0")/.."   # project root
BUILD="dist/build"
APP="$BUILD/GWSwitch.app"
DAEMON="$BUILD/libexec/gatewayd"
VERSION="1.0.3"
IDENTIFIER="com.gatewaytray.pkg"
COMPONENT="dist/GWSwitch-component.pkg"
OUT="dist/GWSwitch-${VERSION}.pkg"

if [[ ! -d "$APP" || ! -x "$DAEMON" ]]; then
  echo "Build artifacts missing. Run ./build.sh first." >&2
  exit 1
fi

# Stage the install payload mirroring the target filesystem layout.
ROOT="dist/pkgroot"
rm -rf "$ROOT"
mkdir -p "$ROOT/Applications" \
         "$ROOT/usr/local/libexec" \
         "$ROOT/Library/LaunchDaemons" \
         "$ROOT/Library/LaunchAgents"

cp -R "$APP" "$ROOT/Applications/"
cp "$DAEMON" "$ROOT/usr/local/libexec/gatewayd"
cp "packaging/com.gatewaytray.daemon.plist" "$ROOT/Library/LaunchDaemons/"
cp "packaging/com.gatewaytray.app.plist" "$ROOT/Library/LaunchAgents/"

chmod +x packaging/scripts/preinstall packaging/scripts/postinstall

# Strip extended attributes so pkgbuild doesn't emit AppleDouble (._*) sidecars.
# The Mach-O code signatures are embedded in the binaries, so they survive this.
xattr -cr "$ROOT"

# Generate a component plist and disable bundle relocation. Without this,
# pkgbuild marks the .app relocatable and the installer may drop it wherever
# LaunchServices last saw the bundle id — NOT /Applications.
COMP="dist/component.plist"
pkgbuild --analyze --root "$ROOT" "$COMP" >/dev/null
count=$(/usr/libexec/PlistBuddy -c "Print" "$COMP" | grep -c "BundleIsRelocatable" || true)
i=0
while [[ $i -lt $count ]]; do
  /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$COMP" 2>/dev/null || true
  i=$((i + 1))
done

# 1) Build the raw component package.
pkgbuild \
  --root "$ROOT" \
  --component-plist "$COMP" \
  --scripts "packaging/scripts" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT"
rm -f "$COMP"

# 2) Wrap it with a distribution so the Installer window shows a friendly title
#    ("GW Switch") instead of the raw file name.
DIST="dist/distribution.xml"
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>GW Switch</title>
    <options customize="never" require-scripts="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="${IDENTIFIER}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${IDENTIFIER}" visible="false">
        <pkg-ref id="${IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${IDENTIFIER}" version="${VERSION}" onConclusion="none">GWSwitch-component.pkg</pkg-ref>
</installer-gui-script>
XML

echo "Building $OUT …"
productbuild \
  --distribution "$DIST" \
  --package-path "dist" \
  "$OUT"

rm -f "$DIST" "$COMPONENT"
rm -rf "$ROOT"

# The staged dist/build/GWSwitch.app is a build artifact, not an installed app.
# Unregister it from LaunchServices so it doesn't show up as a duplicate.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREG" ]] && "$LSREG" -u "$PWD/$APP" 2>/dev/null || true

# Delete the compiled intermediate so it can't linger as a duplicate app in
# Spotlight/Launchpad. Re-run ./build.sh to regenerate before packaging again.
rm -rf "$BUILD"

echo
echo "Created $OUT"
echo "Install with:  sudo installer -pkg \"$OUT\" -target /    (or double-click it)"
echo "Note: unsigned pkg — users may need to right-click > Open, or approve in"
echo "      System Settings > Privacy & Security."
