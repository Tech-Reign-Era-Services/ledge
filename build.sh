#!/bin/bash
# Builds Ledge with the Xcode Command Line Tools: no Xcode project, no dependencies.
#   ./build.sh          → dist/Ledge.app (universal: Apple silicon + Intel)
#   ./build.sh run      → build, then open it (quits a running copy first)
#   ./build.sh test     → run the tests
#   ./build.sh dist     → the app, plus dist/Ledge-<version>.zip and dist/Ledge-<version>.pkg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUNDLE_ID="com.techreignera.ledge"
MIN_MACOS="13.0"
APP="dist/Ledge.app"
FLAGS=(-swift-version 5 -Osize -whole-module-optimization)

test_() {
  mkdir -p .build
  swiftc "${FLAGS[@]}" tests/main.swift Sources/ShelfStore.swift Sources/Layout.swift -o .build/tests
  .build/tests
}

app() {
  rm -rf "$APP" .build/bin
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" .build/bin
  for arch in arm64 x86_64; do
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o ".build/bin/Ledge-$arch"
  done
  lipo -create .build/bin/Ledge-arm64 .build/bin/Ledge-x86_64 -output "$APP/Contents/MacOS/Ledge"
  strip -x "$APP/Contents/MacOS/Ledge"
  cp web/*.html web/*.css web/*.js "$APP/Contents/Resources/web/"

  # The icon: drawn once, then cached in .build (delete .build/AppIcon.icns to redraw it).
  if [ ! -f .build/AppIcon.icns ]; then
    local set=.build/AppIcon.iconset
    rm -rf "$set" && mkdir -p "$set"
    swift scripts/make-icon.swift .build/icon-1024.png
    for s in 16 32 128 256 512; do
      sips -z $s $s .build/icon-1024.png --out "$set/icon_${s}x${s}.png" >/dev/null
      sips -z $((s * 2)) $((s * 2)) .build/icon-1024.png --out "$set/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o .build/AppIcon.icns
  fi
  cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ledge</string>
  <key>CFBundleDisplayName</key><string>Ledge</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Ledge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Tech Reign Era Services. MIT License.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Any file</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

  # Ad-hoc signed: Apple silicon won't run an unsigned binary. (Not notarized.)
  codesign --force --sign - "$APP"
  echo "Built $APP ($(du -sh "$APP" | cut -f1))"
}

dist() {
  app
  local zip="dist/Ledge-$VERSION.zip" pkg="dist/Ledge-$VERSION.pkg"
  rm -f "$zip" "$pkg"
  ditto -c -k --keepParent "$APP" "$zip"

  # An installer that always puts Ledge in /Applications (even if a copy exists elsewhere), then opens it.
  rm -rf .build/pkgroot && mkdir -p .build/pkgroot
  cp -R "$APP" .build/pkgroot/
  pkgbuild --analyze --root .build/pkgroot .build/components.plist >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO .build/components.plist
  pkgbuild --root .build/pkgroot --component-plist .build/components.plist --install-location /Applications \
    --scripts scripts/pkg --identifier "$BUNDLE_ID" --version "$VERSION" "$pkg" >/dev/null

  echo "Built $zip ($(du -h "$zip" | cut -f1)) and $pkg ($(du -h "$pkg" | cut -f1))"
}

case "${1:-app}" in
  app) app ;;
  run) app; pkill -x Ledge || true; open "$APP" ;;
  test) test_ ;;
  dist) test_ && dist ;;
  *) echo "usage: ./build.sh [app|run|test|dist]"; exit 1 ;;
esac
