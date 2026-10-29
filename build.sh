#!/bin/bash
# Builds Ledge with the Xcode Command Line Tools: no Xcode project, no dependencies.
# The one exception is the Siri and Shortcuts actions, which need a tool that only full Xcode ships (see
# appintents() below). Without it everything else is built as usual, and the build says so.
#   ./build.sh          → dist/Ledge.app (universal: Apple silicon + Intel)
#   ./build.sh run      → build, then open it (quits a running copy first)
#   ./build.sh test     → run the tests
#   ./build.sh dist     → the app, plus dist/Ledge-<version>.zip and dist/Ledge-<version>.pkg
#   ./build.sh check    → fail if the app has grown past its size budget (run after app or dist)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)" # the one place the version lives
BUNDLE_ID="com.techreignera.ledge"
MIN_MACOS="13.0"
APP="dist/Ledge.app"
FLAGS=(-swift-version 5 -Osize -whole-module-optimization)

test_() {
  mkdir -p .build
  swiftc "${FLAGS[@]}" tests/main.swift Sources/ShelfStore.swift Sources/TodoStore.swift Sources/Layout.swift Sources/Activities.swift Sources/Updates.swift -o .build/tests
  .build/tests
}

# Siri and Shortcuts: the actions in Sources/Intents.swift reach the system through a Metadata.appintents
# bundle, built from the compiler's const values by a processor that only full Xcode ships. With just the
# Command Line Tools there is nothing to run it with, so the bundle is left out: the todo list, ledge://todo
# and every other part of Ledge work exactly the same, and only Siri, Shortcuts and Spotlight go without.
appintents() {
  # The processor ships with full Xcode only. Look where the developer directory points, then where Xcode
  # usually is, so a Mac with Xcode installed but the Command Line Tools selected still gets the actions.
  local proc="" tc dir
  for dir in "$(xcode-select -p 2>/dev/null)" /Applications/Xcode.app/Contents/Developer; do
    [ -n "$dir" ] || continue
    if [ -x "$dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor" ]; then
      proc="$dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor"
      tc="$dir/Toolchains/XcodeDefault.xctoolchain"
      break
    fi
  done
  if [ -z "$proc" ]; then
    echo "note: no appintentsmetadataprocessor (that one needs full Xcode) — building without the Siri and Shortcuts actions"
    return 0
  fi
  # Absolute paths: the processor resolves them against its own working directory, not ours.
  ls "$PWD"/Sources/*.swift > .build/appintents-sources.txt
  echo "$PWD/.build/bin/Ledge-arm64.swiftconstvalues" > .build/appintents-constvalues.txt
  "$proc" --output "$APP/Contents/Resources" \
    --toolchain-dir "$tc" \
    --module-name Ledge \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(plutil -extract ProductBuildVersion raw "$(dirname "$tc")/../../version.plist" 2>/dev/null || echo 0)" \
    --platform-family macOS \
    --deployment-target "$MIN_MACOS" \
    --target-triple "arm64-apple-macos$MIN_MACOS" \
    --source-file-list .build/appintents-sources.txt \
    --swift-const-vals-list .build/appintents-constvalues.txt \
    --force --quiet-warnings >.build/appintents.log 2>&1
  [ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ] \
    || { echo "appintentsmetadataprocessor produced no metadata:"; cat .build/appintents.log; exit 1; }
  echo "Siri and Shortcuts actions: Metadata.appintents"
}

app() {
  rm -rf "$APP" .build/bin
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web" .build/bin
  for arch in arm64 x86_64; do
    # -module-name keeps the App Intents metadata's type names stable (Ledge.AddTodoIntent), and
    # the const values are what the metadata processor reads to find the intents.
    swiftc "${FLAGS[@]}" -module-name Ledge -target "$arch-apple-macos$MIN_MACOS" \
      -Xfrontend -const-gather-protocols-file -Xfrontend scripts/appintents-protocols.json \
      -emit-const-values-path ".build/bin/Ledge-$arch.swiftconstvalues" \
      Sources/*.swift -o ".build/bin/Ledge-$arch"
  done
  lipo -create .build/bin/Ledge-arm64 .build/bin/Ledge-x86_64 -output "$APP/Contents/MacOS/Ledge"
  strip -x "$APP/Contents/MacOS/Ledge"
  cp web/*.html web/*.css web/*.js "$APP/Contents/Resources/web/"
  appintents

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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Ledge live activities</string>
      <key>CFBundleURLSchemes</key><array><string>ledge</string></array>
    </dict>
  </array>
  <key>NSAudioCaptureUsageDescription</key><string>Ledge listens to Music or Spotify while a song plays, so the bars in the island move to the music. Nothing is recorded or saved.</string>
  <key>NSMicrophoneUsageDescription</key><string>Ledge listens when you ask it to (⌃⌥T), so you can say a todo instead of typing it. It listens only while you hold the island open for it, and nothing is recorded or saved.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Ledge turns what you say into a todo using the recogniser built into macOS. It runs on this Mac: nothing you say is sent anywhere.</string>
  <key>NSAppleEventsUsageDescription</key><string>Ledge plays, pauses and skips songs in Music and Spotify when you use the controls in the island.</string>
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

# Ledge's whole point is being small: keep an eye on it.
SIZE_BUDGET_KB=2048
check() {
  local kb
  kb=$(du -sk "$APP" | cut -f1)
  if [ "$kb" -gt "$SIZE_BUDGET_KB" ]; then echo "Ledge.app is ${kb} KB, over the ${SIZE_BUDGET_KB} KB budget"; exit 1; fi
  echo "Ledge.app is ${kb} KB (budget ${SIZE_BUDGET_KB} KB)"
}

case "${1:-app}" in
  app) app ;;
  run) app; pkill -x Ledge || true; open "$APP" ;;
  test) test_ ;;
  dist) test_ && dist && check ;;
  check) check ;;
  *) echo "usage: ./build.sh [app|run|test|dist|check]"; exit 1 ;;
esac
