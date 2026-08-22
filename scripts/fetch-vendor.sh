#!/bin/bash
#
# Fetches the vendored yt-dlp binary that ships inside the app bundle.
#
# The binaries are gitignored (they are ~35 MB and rebuilt, not authored), so
# without this script a fresh clone has no downloader and nothing records which
# version a given release shipped. Vendor/yt-dlp.lock is the committed record.
#
# yt-dlp needs re-fetching far more often than its size suggests: YouTube
# rotates the signature challenge that yt-dlp solves, and when it does, an old
# build stops working entirely — every download dies with "HTTP Error 403:
# Forbidden". That is a customer-visible outage, not a slow degradation, so
# `release.sh` runs this on every release and warns when a newer build exists.
#
# Usage:
#   ./scripts/fetch-vendor.sh            # ensure the pinned version is present
#   ./scripts/fetch-vendor.sh latest     # move the pin to the newest release
#   ./scripts/fetch-vendor.sh 2026.08.19 # pin an exact version
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$SCRIPT_DIR/Vendor"
LOCKFILE="$VENDOR/yt-dlp.lock"
YTDLP_DEST="$VENDOR/yt-dlp/yt-dlp_macos"
FFMPEG_DEST="$VENDOR/ffmpeg/ffmpeg"
ASSET="yt-dlp_macos"
REPO="yt-dlp/yt-dlp"
# Beyond this, YouTube has usually moved on at least once.
STALE_DAYS=90

REQUESTED="${1:-pinned}"

# ─── Resolve which version we want ──────────────────────────────────────────
latest_version() {
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1
}

read_pin() {
  [ -f "$LOCKFILE" ] || return 1
  sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "$LOCKFILE" | head -1
}

case "$REQUESTED" in
  pinned)
    if ! VERSION="$(read_pin)" || [ -z "$VERSION" ]; then
      echo "ℹ️  No pin in Vendor/yt-dlp.lock yet — using the latest release."
      VERSION="$(latest_version)"
    fi
    ;;
  latest) VERSION="$(latest_version)" ;;
  *)      VERSION="$REQUESTED" ;;
esac

if [ -z "$VERSION" ]; then
  echo "❌ Could not determine a yt-dlp version to fetch." >&2
  exit 1
fi
echo "📌 yt-dlp target version: $VERSION"

# ─── Fetch (unless the pin is already satisfied), then always verify ────────
BASE="https://github.com/${REPO}/releases/download/${VERSION}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "🔐 Fetching published checksums for ${VERSION}..."
if ! curl -fsSL --retry 3 -o "$TMP/SHA2-256SUMS" "${BASE}/SHA2-256SUMS"; then
  echo "❌ No yt-dlp release tagged '${VERSION}'." >&2
  echo "   Versions look like 2026.08.19. See https://github.com/${REPO}/releases" >&2
  exit 1
fi
EXPECTED="$(grep -E "[[:space:]]${ASSET}\$" "$TMP/SHA2-256SUMS" | awk '{print $1}' | head -1)"
if [ -z "$EXPECTED" ]; then
  echo "❌ ${ASSET} not listed in the release's SHA2-256SUMS. Refusing to ship it." >&2
  exit 1
fi

if [ -x "$YTDLP_DEST" ] && [ "$(shasum -a 256 "$YTDLP_DEST" | awk '{print $1}')" = "$EXPECTED" ]; then
  echo "✅ Vendor/yt-dlp/yt-dlp_macos is already ${VERSION} and matches its checksum"
else
  echo "⬇️  Downloading ${ASSET} ${VERSION}..."
  curl -fsSL --retry 3 -o "$TMP/$ASSET" "${BASE}/${ASSET}"

  ACTUAL="$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "❌ Checksum mismatch — refusing to install." >&2
    echo "   expected: $EXPECTED" >&2
    echo "   actual:   $ACTUAL" >&2
    exit 1
  fi
  echo "🔐 Checksum ok: $ACTUAL"

  mkdir -p "$(dirname "$YTDLP_DEST")"
  mv "$TMP/$ASSET" "$YTDLP_DEST"
  chmod +x "$YTDLP_DEST"
  # A freshly downloaded binary is quarantined; the app spawns it directly.
  xattr -d com.apple.quarantine "$YTDLP_DEST" 2>/dev/null || true
  echo "✅ Installed yt-dlp ${VERSION}"
fi

# The binary must actually be the version we think it is, however it got here.
INSTALLED="$("$YTDLP_DEST" --version 2>/dev/null || echo unknown)"
if [ "$INSTALLED" != "$VERSION" ]; then
  echo "❌ Installed binary reports '$INSTALLED', expected '$VERSION'." >&2
  exit 1
fi

# Written on every run, not just after a download, so the pin is recorded even
# when the right binary was already sitting there.
cat > "$LOCKFILE" <<EOF
# Vendored yt-dlp pinned for reproducible builds. Written by
# scripts/fetch-vendor.sh -- do not edit by hand.
# Refresh with: ./scripts/fetch-vendor.sh latest
version = $VERSION
sha256 = $EXPECTED
source = ${BASE}/${ASSET}
EOF
echo "🔒 Pin recorded in Vendor/yt-dlp.lock (yt-dlp ${INSTALLED})"

# ─── ffmpeg is not fetched: stable, and not published from a known URL ───────
if [ ! -x "$FFMPEG_DEST" ]; then
  echo "⚠️  Vendor/ffmpeg/ffmpeg is missing — the build phase will fail." >&2
  echo "   It is a static arm64 build (currently 6.0) and is not fetched here" >&2
  echo "   because it has no stable published download URL. Copy it from a" >&2
  echo "   previous checkout or another machine." >&2
  exit 1
fi

# ─── Warn when the pin has aged out ─────────────────────────────────────────
LATEST="$(latest_version || true)"
if [ -n "$LATEST" ] && [ "$LATEST" != "$VERSION" ]; then
  echo ""
  echo "⚠️  A newer yt-dlp is available: $LATEST (pinned: $VERSION)"
  echo "   YouTube breaks old builds outright — run:"
  echo "     ./scripts/fetch-vendor.sh latest"
fi

# yt-dlp versions are YYYY.MM.DD, so the tag itself dates the build.
PIN_EPOCH="$(date -j -f "%Y.%m.%d" "$VERSION" "+%s" 2>/dev/null || true)"
if [ -n "$PIN_EPOCH" ]; then
  AGE_DAYS=$(( ( $(date "+%s") - PIN_EPOCH ) / 86400 ))
  echo "🗓  Pinned build is ${AGE_DAYS} day(s) old."
  if [ "$AGE_DAYS" -ge "$STALE_DAYS" ]; then
    echo "⚠️  Older than ${STALE_DAYS} days — refresh before releasing, or users" >&2
    echo "   will hit 'HTTP Error 403: Forbidden' on every download." >&2
  fi
fi
