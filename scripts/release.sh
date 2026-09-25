#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Aayan Agarwal
#
# Makes the installer DMG and Sparkle update for a Mix.app you exported and
# notarized yourself. Needs Homebrew's create-dmg and imagemagick.
#
#   scripts/release.sh path/to/Mix.app
#
# Writes Mix-<version>.dmg, Mix-<version>.zip and appcast.xml to build/release.
# Upload all three to the GitHub release tagged v<version> and mark it Latest.
# Installed copies read appcast.xml from the latest release.
set -euo pipefail

app="${1:?usage: scripts/release.sh path/to/Mix.app}"
repo="ion05/mix"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")

# Sparkle only offers a build number higher than the installed one. The same
# version and build is fine: that is repackaging the current release.
feed=$(curl -fsL "https://github.com/$repo/releases/latest/download/appcast.xml" 2>/dev/null || true)
published=$(printf '%s' "$feed" | sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p')
published_version=$(printf '%s' "$feed" | sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p')
if [ -n "$published" ] && { [ "$build" -lt "$published" ] || { [ "$build" -eq "$published" ] && [ "$version" != "$published_version" ]; }; }; then
    echo "Build $build is not higher than the published build $published." >&2
    echo "Raise Build in Xcode (Mix target > General) and export again." >&2
    exit 1
fi

sign_update=$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin/sign_update' 2>/dev/null | head -1)
if [ ! -x "$sign_update" ]; then
    echo "sign_update not found. Open Mix.xcodeproj in Xcode once so it downloads Sparkle." >&2
    exit 1
fi

out="build/release"
zip="Mix-$version.zip"
mkdir -p "$out"
rm -f "$out/$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$out/$zip"
# Signs with the private key generate_keys saved in your login keychain.
signature=$("$sign_update" "$out/$zip")

cat > "$out/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mix</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$repo/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$repo/releases/download/v$version/$zip" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
XML

# Installer DMG on design/dmg-background.png: a 660x400 window with Mix left
# of the drag arrow and Applications right of it. The @2x art keeps it sharp.
dmg="Mix-$version.dmg"
bg_dir=$(mktemp -d)
magick design/dmg-background.png -resize 660x400 "$bg_dir/bg.png"
cp design/dmg-background.png "$bg_dir/bg@2x.png"
tiffutil -cathidpicheck "$bg_dir/bg.png" "$bg_dir/bg@2x.png" -out "$bg_dir/background.tiff" >/dev/null
stage=$(mktemp -d)
ditto "$app" "$stage/Mix.app"
rm -f "$out/$dmg"
create-dmg \
    --volname "Mix" \
    --background "$bg_dir/background.tiff" \
    --window-size 660 400 \
    --icon-size 112 \
    --text-size 13 \
    --icon "Mix.app" 165 185 \
    --hide-extension "Mix.app" \
    --app-drop-link 495 185 \
    --no-internet-enable \
    "$out/$dmg" "$stage" >/dev/null
rm -rf "$bg_dir" "$stage"

echo "Mix $version (build $build) is ready in $out:"
echo "  $dmg"
echo "  $zip"
echo "  appcast.xml"
echo "Upload all three to the release tagged v$version."
