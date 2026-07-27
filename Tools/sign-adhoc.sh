#!/usr/bin/env bash
set -euo pipefail

app="${1:?usage: sign-adhoc.sh path/to/RemoteDesktop.app}"
entitlements="${2:-}"
[[ -d "${app}" ]] || { echo "App not found: ${app}" >&2; exit 1; }
command -v codesign >/dev/null || { echo "Missing codesign" >&2; exit 1; }

while IFS= read -r -d '' symlink; do
  [[ -e "${symlink}" ]] && continue
  case "${symlink}" in
    *.framework/Headers|*.framework/Modules)
      echo "Removing build-only dangling symlink: ${symlink}"
      rm -- "${symlink}"
      ;;
    *)
      echo "Unexpected dangling symlink in app bundle: ${symlink}" >&2
      exit 1
      ;;
  esac
done < <(find "${app}/Contents" -type l -print0)

while IFS= read -r binary; do
  file "${binary}" | grep -q 'Mach-O' || continue
  codesign --force --sign - --timestamp=none "${binary}"
done < <(find "${app}/Contents" -type f | sort)

while IFS= read -r framework; do
  codesign --force --sign - --timestamp=none "${framework}"
done < <(find "${app}/Contents" -type d -name '*.framework' | sort -r)

arguments=(--force --sign - --timestamp=none)
if [[ -n "${entitlements}" ]]; then
  [[ -f "${entitlements}" ]] || { echo "Entitlements not found: ${entitlements}" >&2; exit 1; }
  arguments+=(--entitlements "${entitlements}")
fi
codesign "${arguments[@]}" "${app}"
codesign --verify --deep --strict --verbose=2 "${app}"
