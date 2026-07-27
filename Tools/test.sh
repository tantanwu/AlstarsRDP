#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

swift test --parallel

if [[ "$(uname -s)" == "Darwin" && -d RemoteDesktop.xcodeproj ]]; then
  xcodebuild -project RemoteDesktop.xcodeproj -scheme RemoteDesktop \
    -configuration Debug -destination 'platform=macOS' \
    -resultBundlePath TestResults/RemoteDesktop.xcresult test CODE_SIGNING_ALLOWED=NO
fi

