#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Paperwork Replica requires Apple silicon macOS"; exit 2; }
./Engine/build.sh
swift build -c release --jobs 2
app='build/Paperwork Replica.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
bin_path="$(swift build -c release --show-bin-path)"
cp "$bin_path/Paperwork" "$app/Contents/MacOS/Paperwork"
xcrun strip -S -x "$app/Contents/MacOS/Paperwork"
if LC_ALL=C grep -aqE '(/Users/|/home/)' "$app/Contents/MacOS/Paperwork"; then
  echo 'Release executable contains a private home path; refusing package' >&2; exit 1
fi
cp LICENSE "$app/Contents/Resources/LICENSE"
cp Sources/PaperworkCore/Resources/starter.pdf "$app/Contents/Resources/starter.pdf"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R Engine/Notices "$app/Contents/Resources/ThirdPartyNotices"
cp Engine/build/canonical-pdf "$app/Contents/Resources/canonical-pdf"
codesign --force --sign - "$app/Contents/Resources/canonical-pdf"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.ghostzy0.paperwork.replica</string><key>CFBundleName</key><string>Paperwork Replica</string><key>CFBundleDisplayName</key><string>Paperwork Replica</string><key>CFBundleExecutable</key><string>Paperwork</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>PaperworkReleaseVersion</key><string>0.1.0-alpha.1</string><key>PaperworkDataDirectory</key><string>PaperworkReplica</string><key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>PDF document</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict></array></dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
