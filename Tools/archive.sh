#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
mkdir -p "${root}/Artifacts"
xcodegen generate --spec "${root}/project.yml"
xcodebuild -project "${root}/RemoteDesktop.xcodeproj" -scheme RemoteDesktop \
  -configuration Release -archivePath "${root}/Artifacts/RemoteDesktop.xcarchive" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO archive
