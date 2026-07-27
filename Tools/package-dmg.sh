#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
archive="${1:-${root}/Artifacts/RemoteDesktop.xcarchive}"
identity="${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the Developer ID Application identity}"
app="${archive}/Products/Applications/RemoteDesktop.app"
staging="${root}/Artifacts/dmg-root"
dmg="${root}/Artifacts/RemoteDesktop.dmg"
trap 'rm -rf "${staging}"' EXIT

[[ "$(uname -s)" == "Darwin" ]] || { echo "DMG packaging must run on macOS." >&2; exit 1; }
for command in codesign ditto hdiutil lipo; do
  command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; exit 1; }
done
[[ -d "${app}" ]] || { echo "Archived app not found: ${app}" >&2; exit 1; }

"${root}/Tools/verify-universal.sh" "${app}" --pre-notarization
codesign --verify --deep --strict --verbose=2 "${app}"

rm -rf "${staging}"
mkdir -p "${staging}"
ditto "${app}" "${staging}/RemoteDesktop.app"
ln -s /Applications "${staging}/Applications"
rm -f "${dmg}"
hdiutil create -fs HFS+ -format UDZO -volname RemoteDesktop -srcfolder "${staging}" "${dmg}"
codesign --force --sign "${identity}" --timestamp "${dmg}"
codesign --verify --strict --verbose=2 "${dmg}"

echo "Created signed DMG: ${dmg}"
