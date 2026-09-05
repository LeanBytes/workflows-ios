#!/usr/bin/env bash
# Erzeugt die manifest.plist, auf die ein itms-services-Link zeigt.
#
# iOS lädt zuerst dieses Plist und daraus die IPA — beide MÜSSEN über HTTPS mit
# gültigem Zertifikat erreichbar sein, sonst bricht die Installation ohne
# brauchbare Meldung ab. display-image/full-size-image sind optional und werden
# bewusst weggelassen: fehlen sie, zeigt iOS den Platzhalter, und ein toter
# Bildlink wäre schlimmer als keiner.
#
# Aufruf: manifest.sh <ipa-url> <bundle-id> <bundle-version> <title>
set -euo pipefail

IPA_URL="$1"
BUNDLE_ID="$2"
BUNDLE_VERSION="$3"
TITLE="$4"

cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${IPA_URL}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${BUNDLE_ID}</string>
        <key>bundle-version</key>
        <string>${BUNDLE_VERSION}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${TITLE}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
