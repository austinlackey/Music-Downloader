#!/bin/bash
set -e

# ─── Configuration ───────────────────────────────────────────────────────────
REPO="austinlackey/Music-Downloader"
APP_NAME="Music Downloader"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST="$SCRIPT_DIR/docs/appcast.xml"
RELEASE_NOTES="$SCRIPT_DIR/RELEASE_NOTES.md"
BUILD_DIR="$SCRIPT_DIR/build/release"
SPARKLE_SIGN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/sparkle/Sparkle/bin/sign_update" -print -quit 2>/dev/null)

# ─── Input ───────────────────────────────────────────────────────────────────
if [ -z "$1" ]; then
  echo "Usage: ./release.sh <patch|minor|major|X.X.X>"
  echo "Examples:"
  echo "  ./release.sh patch   # 1.2.0 → 1.2.1"
  echo "  ./release.sh minor   # 1.2.0 → 1.3.0"
  echo "  ./release.sh major   # 1.2.0 → 2.0.0"
  echo "  ./release.sh 1.5.0   # set exact version"
  exit 1
fi

# Get current version from Xcode project
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$SCRIPT_DIR/Music Downloader.xcodeproj/project.pbxproj" | sed 's/.*= //;s/;.*//' | tr -d ' ')
echo "📌 Current version: $CURRENT_VERSION"

MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
# Default patch to 0 if version is X.Y format
PATCH=${PATCH:-0}

case "$1" in
  patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
  minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  *)     VERSION="$1" ;;
esac

echo "🚀 New version: $VERSION"
ZIP_NAME="Music-Downloader-${VERSION}.zip"

if [ ! -f "$RELEASE_NOTES" ]; then
  echo "❌ RELEASE_NOTES.md not found. Create it with your release notes before running."
  exit 1
fi

NOTES=$(cat "$RELEASE_NOTES")
if [ -z "$NOTES" ]; then
  echo "❌ Release notes are empty. Aborting."
  exit 1
fi

if [ -z "$SPARKLE_SIGN" ]; then
  echo "❌ Could not find Sparkle sign_update tool in DerivedData"
  exit 1
fi

mkdir -p "$BUILD_DIR"

# ─── Step 0: Refresh vendored binaries ──────────────────────────────────────
# Every release ships whatever yt-dlp is sitting in Vendor/, and YouTube breaks
# old builds outright rather than gracefully. Fetching here means a release can
# never quietly go out with a stale downloader, and Vendor/yt-dlp.lock records
# exactly which version this build shipped.
echo "📥 Checking vendored binaries..."
"$SCRIPT_DIR/scripts/fetch-vendor.sh"
YTDLP_VERSION=$("$SCRIPT_DIR/Vendor/yt-dlp/yt-dlp_macos" --version 2>/dev/null || echo unknown)
echo "   Shipping yt-dlp $YTDLP_VERSION"

# ─── Update version in Xcode project ───────────────────────────────────────
echo "📝 Updating MARKETING_VERSION in project.pbxproj to ${VERSION}..."
sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = ${VERSION};/g" \
  "$SCRIPT_DIR/Music Downloader.xcodeproj/project.pbxproj"

# ─── Step 1: Archive ────────────────────────────────────────────────────────
echo "🔨 Archiving ${APP_NAME} v${VERSION}..."
xcodebuild -project "$SCRIPT_DIR/Music Downloader.xcodeproj" \
  -scheme "Music Downloader" \
  -configuration Release \
  -archivePath "$BUILD_DIR/Music Downloader.xcarchive" \
  archive \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(echo "$VERSION" | awk -F. '{print $1*10000 + $2*100 + $3}')" \
  -quiet

echo "✅ Archive complete"

# ─── Step 2: Export ─────────────────────────────────────────────────────────
echo "📦 Exporting app..."
xcodebuild -exportArchive \
  -archivePath "$BUILD_DIR/Music Downloader.xcarchive" \
  -exportPath "$BUILD_DIR/export" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -quiet

APP_PATH="$BUILD_DIR/export/Music Downloader.app"
echo "✅ Export complete"

# ─── Step 3: Notarize ───────────────────────────────────────────────────────
echo "📦 Zipping app for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$ZIP_NAME"

echo "🍎 Submitting for notarization (usually 1-2 min)..."
xcrun notarytool submit "$BUILD_DIR/$ZIP_NAME" --keychain-profile "notarytool" --wait

echo "📎 Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"

# ─── Step 4: Re-zip after stapling and sign with Sparkle ────────────────────
echo "📦 Re-zipping stapled app..."
rm "$BUILD_DIR/$ZIP_NAME"
ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/$ZIP_NAME"

echo "🔑 Signing with Sparkle EdDSA key..."
SIGN_OUTPUT=$("$SPARKLE_SIGN" "$BUILD_DIR/$ZIP_NAME")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)

echo "   Signature: $ED_SIGNATURE"
echo "   Length: $LENGTH"

# ─── Step 5: Create DMG installer ──────────────────────────────────────────
DMG_NAME="Music-Downloader-${VERSION}.dmg"
echo "💿 Creating DMG installer..."
create-dmg \
  --volname "Music Downloader" \
  --background "$SCRIPT_DIR/dmg-bg.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "Music Downloader.app" 150 190 \
  --app-drop-link 450 190 \
  "$BUILD_DIR/$DMG_NAME" \
  "$APP_PATH"

echo "✅ DMG created"

# ─── Step 6: Upload to GitHub Releases ──────────────────────────────────────
echo "🚀 Creating GitHub release v${VERSION}..."
gh release create "v${VERSION}" "$BUILD_DIR/$ZIP_NAME" "$BUILD_DIR/$DMG_NAME" \
  --title "v${VERSION}" \
  --notes "$NOTES"

# ─── Step 7: Update appcast.xml ─────────────────────────────────────────────
echo "📝 Updating appcast.xml..."
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{print $1*10000 + $2*100 + $3}')

# Convert markdown list items to HTML
HTML_NOTES=$(echo "$NOTES" | sed 's/^- /          <li>/;s/$/<\/li>/')

# Build the new item XML in a temp file
ITEM_FILE=$(mktemp)
cat > "$ITEM_FILE" <<EOF

    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <h2>What's New</h2>
        <ul>
${HTML_NOTES}
        </ul>
      ]]></description>
      <pubDate>${PUB_DATE}</pubDate>
      <enclosure
        url="https://github.com/${REPO}/releases/download/v${VERSION}/${ZIP_NAME}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}"
      />
    </item>
EOF

# Insert new item after <language> line
sed -i '' "/<language>en<\/language>/r $ITEM_FILE" "$APPCAST"
rm "$ITEM_FILE"

# ─── Step 8: Commit and push ────────────────────────────────────────────────
echo "📤 Pushing appcast update..."
echo "- Bug fixes and improvements" > "$RELEASE_NOTES"
git add "$APPCAST" "$RELEASE_NOTES" "$SCRIPT_DIR/Music Downloader.xcodeproj/project.pbxproj"
git add -f "$SCRIPT_DIR/Vendor/yt-dlp.lock" 2>/dev/null || true
git commit -m "Release v${VERSION}

Ships yt-dlp ${YTDLP_VERSION}."
git push

# ─── Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"

echo ""
echo "✅ Released ${APP_NAME} v${VERSION}"
echo "   GitHub: https://github.com/${REPO}/releases/tag/v${VERSION}"
echo "   Appcast: https://austinlackey.github.io/Music-Downloader/appcast.xml"
