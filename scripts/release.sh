#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Aayan Agarwal
#
# Makes the Sparkle update for a Mix.app you exported and notarized yourself.
#
#   scripts/release.sh path/to/Mix.app
#
# Writes Mix-<version>.zip and appcast.xml to build/release. Upload both, next
# to your DMG, to the GitHub release tagged v<version> and mark it Latest.
# Installed copies read appcast.xml from the latest release.
set -euo pipefail

app="${1:?usage: scripts/release.sh path/to/Mix.app}"
repo="ion05/mix"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")

# Sparkle only offers a build number higher than the installed one.
published=$(curl -fsL "https://github.com/$repo/releases/latest/download/appcast.xml" 2>/dev/null \
    | sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' || true)
if [ -n "$published" ] && [ "$build" -le "$published" ]; then
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

echo "Mix $version (build $build) is ready in $out:"
echo "  $zip"
echo "  appcast.xml"
echo "Upload both with your DMG to the release tagged v$version."
