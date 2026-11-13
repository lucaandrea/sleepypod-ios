#!/bin/sh
set -eu

source_manifest="${SRCROOT:?}/FreeSleepKit/Resources/PrivacyInfo.xcprivacy"
sdk_manifest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/AIProxy_AIProxy.bundle/PrivacyInfo.xcprivacy"
[ -f "$sdk_manifest" ] || exit 0

# Xcode may scan the embedded bundle concurrently. Never expose a truncated plist.
plutil -lint "$source_manifest" >/dev/null
pending_manifest=$(mktemp "${sdk_manifest}.XXXXXX")
trap 'rm -f "$pending_manifest"' EXIT
trap 'exit 1' HUP INT TERM
cp "$source_manifest" "$pending_manifest"
chmod 644 "$pending_manifest"
plutil -lint "$pending_manifest" >/dev/null
mv -f "$pending_manifest" "$sdk_manifest"
