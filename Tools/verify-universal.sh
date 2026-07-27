#!/usr/bin/env bash
set -euo pipefail
app="${1:?usage: verify-universal.sh path/to/RemoteDesktop.app [--pre-notarization]}"
mode="${2:-}"
[[ -z "${mode}" || "${mode}" == "--pre-notarization" ]] || { echo "Unknown option: ${mode}" >&2; exit 2; }

[[ -d "${app}" ]] || { echo "App not found: ${app}" >&2; exit 1; }
app="$(cd -P "${app}" && pwd)"
main="${app}/Contents/MacOS/RemoteDesktop"
[[ -f "${main}" ]] || { echo "App executable not found: ${main}" >&2; exit 1; }
for command in codesign file find lipo otool plutil sort spctl xcrun; do
  command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; exit 1; }
done

minimum_version() {
  local binary="$1"
  local arch="$2"
  xcrun vtool -arch "${arch}" -show-build "${binary}" | awk '
    $1 == "platform" { platform = $2; next }
    $1 == "minos" && platform == "MACOS" { print $2; found = 1; exit }
    $1 == "version" && fallback == "" { fallback = $2 }
    END { if (!found && fallback != "") print fallback }
  ' | head -n 1
}

supports_macos_11() {
  local version="$1"
  awk -v version="${version}" 'BEGIN {
    count = split(version, parts, ".")
    if (count < 2) exit 1
    major = parts[1] + 0
    minor = parts[2] + 0
    exit ! (major < 11 || (major == 11 && minor == 0))
  }'
}

expanded_rpath() {
  local rpath="$1"
  local binary="$2"
  case "${rpath}" in
    @loader_path) dirname "${binary}" ;;
    @loader_path/*) printf '%s/%s\n' "$(dirname "${binary}")" "${rpath#@loader_path/}" ;;
    @executable_path) printf '%s\n' "${app}/Contents/MacOS" ;;
    @executable_path/*) printf '%s/%s\n' "${app}/Contents/MacOS" "${rpath#@executable_path/}" ;;
    /*) printf '%s\n' "${rpath}" ;;
    *) return 1 ;;
  esac
}

resolved_bundle_path() {
  local path="$1"
  local target
  local hops=0
  [[ -e "${path}" ]] || return 1
  while [[ -L "${path}" ]]; do
    hops=$((hops + 1))
    [[ ${hops} -le 40 ]] || return 1
    target="$(readlink "${path}")"
    case "${target}" in
      /*) path="${target}" ;;
      *) path="$(dirname "${path}")/${target}" ;;
    esac
  done
  path="$(cd -P "$(dirname "${path}")" && pwd)/$(basename "${path}")"
  case "${path}" in
    "${app}"/Contents/*) printf '%s\n' "${path}" ;;
    *) return 1 ;;
  esac
}

resolves_rpath_dependency() {
  local binary="$1"
  local relative="$2"
  local rpath
  local expanded
  local candidate
  while IFS= read -r rpath; do
    [[ -n "${rpath}" ]] || continue
    expanded="$(expanded_rpath "${rpath}" "${binary}")" || continue
    candidate="${expanded}/${relative}"
    resolved_bundle_path "${candidate}" >/dev/null && return 0
  done < <(
    { otool -l "${main}"; [[ "${binary}" == "${main}" ]] || otool -l "${binary}"; } |
      awk '$1 == "cmd" && $2 == "LC_RPATH" { wanted = 1; next } wanted && $1 == "path" { print $2; wanted = 0 }' |
      sort -u
  )
  resolved_bundle_path "${app}/Contents/Frameworks/${relative}" >/dev/null
}

while IFS= read -r binary; do
  file "${binary}" | grep -q 'Mach-O' || continue
  lipo "${binary}" -verify_arch arm64 x86_64
  codesign --verify --strict --verbose=2 "${binary}"

  for arch in arm64 x86_64; do
    version="$(minimum_version "${binary}" "${arch}")"
    supports_macos_11 "${version}" || {
      echo "Minimum macOS version exceeds 11.0 for ${binary} (${arch}): ${version:-missing}" >&2
      exit 1
    }
  done

  while IFS= read -r dependency; do
    case "${dependency}" in
      /System/Library/*|/usr/lib/*) continue ;;
      /opt/homebrew/*|/usr/local/*|*/Vendor/build/*)
        echo "Build-machine dependency leaked into ${binary}: ${dependency}" >&2
        exit 1
        ;;
      @rpath/*)
        relative="${dependency#@rpath/}"
        resolves_rpath_dependency "${binary}" "${relative}" || {
          echo "Unresolved bundled dependency for ${binary}: ${dependency}" >&2
          exit 1
        }
        ;;
      @loader_path/*)
        relative="${dependency#@loader_path/}"
        resolved_bundle_path "$(dirname "${binary}")/${relative}" >/dev/null || {
          echo "Unresolved loader dependency for ${binary}: ${dependency}" >&2
          exit 1
        }
        ;;
      @executable_path/*)
        relative="${dependency#@executable_path/}"
        resolved_bundle_path "${app}/Contents/MacOS/${relative}" >/dev/null || {
          echo "Unresolved executable dependency for ${binary}: ${dependency}" >&2
          exit 1
        }
        ;;
      /*)
        echo "Unexpected absolute dependency in ${binary}: ${dependency}" >&2
        exit 1
        ;;
      *)
        echo "Unsupported dependency path in ${binary}: ${dependency}" >&2
        exit 1
        ;;
    esac
  done < <(
    otool -L "${binary}" | awk '
      /^[[:space:]]+/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/ \(compatibility version.*$/, "", line)
        print line
      }
    '
  )
done < <(find "${app}/Contents" -type f | sort)
codesign --verify --deep --strict --verbose=2 "${app}"
if [[ "${mode}" != "--pre-notarization" ]]; then
  spctl --assess --type execute --verbose=2 "${app}"
fi
plutil -p "${app}/Contents/Info.plist" | grep 'LSMinimumSystemVersion.*11.0'
