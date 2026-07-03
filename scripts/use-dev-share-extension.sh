#!/bin/sh
#
# Make Finder > Share > QuickDrop use the app Xcode just built (not a stale Release/archive copy).
#
# macOS LaunchServices registers EVERY QuickDrop.app on disk that shares the bundle id
# (com.leonboettger.neardrop) -- Debug build, Release build, archives, old DerivedData, ... -- and the
# share sheet then picks among those duplicates heuristically, so a stale copy can run instead of the
# one you just built. This script makes the freshly built app the ONLY registered copy of that bundle id.
#
# Usage:
#   - Standalone:  scripts/use-dev-share-extension.sh        (re-points Finder at the newest Debug build)
#   - Xcode:       add as a Run post-action (Product > Scheme > Edit Scheme > Run > Post-actions >
#                  "+" > New Run Script Action; "Provide build settings from: QuickDrop"; paste:
#                      "${SRCROOT}/scripts/use-dev-share-extension.sh"
#                  Post-actions run outside the build sandbox, so lsregister/mdfind work there even
#                  though ENABLE_USER_SCRIPT_SANDBOXING is YES for build phases.
#
# `set -u` (not -e): a transient lsregister hiccup shouldn't fail the Xcode Run post-action (red dialog).
set -u

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BUNDLE_ID="com.leonboettger.neardrop"

# Prefer the app Xcode just built (post-action provides these); else the newest Debug build on disk.
APP=""
if [ "${BUILT_PRODUCTS_DIR:-}" != "" ] && [ "${WRAPPER_NAME:-}" != "" ] && [ -d "${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}" ]; then
  APP="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
else
  APP="$(mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null | grep '/Build/Products/Debug/QuickDrop.app$' | head -1)"
fi

if [ -z "${APP}" ] || [ ! -d "${APP}" ]; then
  echo "use-dev-share-extension: no QuickDrop Debug build found -- build it in Xcode first." >&2
  exit 0
fi

# Unregister every OTHER on-disk copy of the bundle id, then (re)register only this one.
mdfind "kMDItemCFBundleIdentifier == '${BUNDLE_ID}'" 2>/dev/null | while IFS= read -r other; do
  [ "${other}" = "${APP}" ] && continue
  "${LSREGISTER}" -u "${other}" 2>/dev/null || true
done
"${LSREGISTER}" -f "${APP}"

# Drop any stale running extension so the next Share rebuilds against the fresh registration.
pkill -f "${BUNDLE_ID}.ShareExtension" 2>/dev/null || true

echo "use-dev-share-extension: Finder Share -> QuickDrop now points at:"
echo "  ${APP}"
