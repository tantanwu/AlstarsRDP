#!/usr/bin/env bash
set -euo pipefail
dmg="${1:?usage: notarize.sh path/to/RemoteDesktop.dmg}"
profile="${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to an xcrun notarytool profile}"
xcrun notarytool submit "${dmg}" --keychain-profile "${profile}" --wait
xcrun stapler staple "${dmg}"
xcrun stapler validate "${dmg}"
codesign --verify --strict --verbose=2 "${dmg}"
spctl --assess --type open --context context:primary-signature --verbose=2 "${dmg}"
