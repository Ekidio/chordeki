#!/bin/zsh
# Builds the DMG and a Sparkle appcast for one GitHub release.
# Output: dist/release-<version>/ with the DMG and appcast.xml, ready to upload.
set -euo pipefail
cd "$(dirname "$0")"
source ./release.conf

if [[ -z "$GITHUB_REPO" ]]; then
    echo "✗ Előbb írd be a GitHub repó nevét a release.conf fájlba (GITHUB_REPO=\"felhasznalo/repo\")."
    exit 1
fi

./make-dmg.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
OUT="dist/release-$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "dist/CHORDEKI-$VERSION.dmg" "$OUT/"

echo "→ appcast.xml (EdDSA aláírással a kulcskarikából)"
.vendor/Sparkle-*/bin/generate_appcast \
    --account exe-futtato \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/$TAG/" \
    --link "https://github.com/$GITHUB_REPO" \
    -o "$OUT/appcast.xml" \
    "$OUT"

# A copy with a fixed name, so the website's button (…/releases/latest/download/CHORDEKI.dmg) always gets the newest.
# Made after the appcast, so the appcast lists the versioned DMG only.
cp "$OUT/CHORDEKI-$VERSION.dmg" "$OUT/CHORDEKI.dmg"

cat <<EOF

✓ Kiadás előkészítve: $OUT

Feltöltés a GitHubra:
  1. https://github.com/$GITHUB_REPO/releases/new
  2. Tag: $TAG   Cím: CHORDEKI $VERSION
  3. Húzd be MINDHÁROM fájlt:  $OUT/CHORDEKI-$VERSION.dmg,  $OUT/CHORDEKI.dmg  és  $OUT/appcast.xml
  4. „Set as the latest release” legyen bejelölve → Publish release

A meglévő felhasználók appja 24 órán belül felajánlja a frissítést.
EOF
