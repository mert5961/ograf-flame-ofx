#!/bin/bash
# Builds OGrafFlame.ofx.bundle (plugin + embedded Chromium + helper apps), ad-hoc signed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
CEF="$HERE/third_party/cef"
BUNDLE="$BUILD/OGrafFlame.ofx.bundle"

"$HERE/scripts/fetch-deps.sh"

cmake -S "$HERE" -B "$BUILD/cmake" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD/cmake" -j 10

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources"
cp "$BUILD/cmake/OGrafFlame.ofx" "$BUNDLE/Contents/MacOS/"
cat > "$BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OGrafFlame.ofx</string>
  <key>CFBundleIdentifier</key><string>org.ograf.flame.ofx</string>
  <key>CFBundleName</key><string>OGraf Flame</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
EOF

cp -R "$CEF/Release/Chromium Embedded Framework.framework" "$BUNDLE/Contents/Frameworks/"
# Licence notices: this project, CEF, and Chromium's third-party credits.
cp "$HERE/LICENSE" "$BUNDLE/Contents/Resources/LICENSE.txt"
cp "$HERE/THIRD_PARTY.md" "$BUNDLE/Contents/Resources/THIRD_PARTY.md"
cp "$CEF/LICENSE.txt" "$BUNDLE/Contents/Resources/CEF-LICENSE.txt"
cp "$CEF/CREDITS.html" "$BUNDLE/Contents/Resources/CHROMIUM-CREDITS.html"

# Chromium launches a helper variant per process type; all share one executable.
for VARIANT in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  NAME="OGraf Helper$VARIANT"
  APP="$BUNDLE/Contents/Frameworks/$NAME.app"
  mkdir -p "$APP/Contents/MacOS"
  cp "$BUILD/cmake/ograf_helper" "$APP/Contents/MacOS/$NAME"
  ID_SUFFIX=$(echo "$VARIANT" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>org.ograf.flame.helper${ID_SUFFIX:+.$ID_SUFFIX}</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
done

# Ad-hoc signatures, inside out (Apple Silicon refuses unsigned code).
codesign --force --sign - "$BUNDLE/Contents/Frameworks/Chromium Embedded Framework.framework" >/dev/null
for APP in "$BUNDLE/Contents/Frameworks/"*.app; do codesign --force --sign - "$APP" >/dev/null; done
codesign --force --sign - "$BUNDLE" >/dev/null
echo "built $BUNDLE"
