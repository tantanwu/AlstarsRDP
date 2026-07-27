#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This bootstrap script must run on macOS." >&2
  exit 1
fi

for command in git cmake ninja xcodebuild xcrun lipo pkg-config; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Missing xcodegen. Install the pinned compatible release before continuing." >&2
  exit 1
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
echo "macOS SDK: ${sdk_version} (${sdk_path})"
echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"

mkdir -p Artifacts TestResults Vendor/source Vendor/build
xcodegen generate --spec "${root}/project.yml"
echo "Generated RemoteDesktop.xcodeproj"
