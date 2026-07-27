#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${root}/Vendor/source/FreeRDP"
manifest="${root}/Vendor/manifest.json"
mode="${1:-all}"

case "${mode}" in
  arm64|x86_64) architectures=("${mode}"); merge_after_build=false ;;
  all) architectures=(arm64 x86_64); merge_after_build=true ;;
  --merge-only) architectures=(); merge_after_build=true ;;
  *) echo "usage: build-freerdp.sh [arm64|x86_64|all|--merge-only]" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "FreeRDP universal builds must run on macOS." >&2
  exit 1
fi

for command in plutil; do
  command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; exit 1; }
done

dependency_name="$(plutil -extract dependencies.0.name raw -o - "${manifest}")"
tag="$(plutil -extract dependencies.0.version raw -o - "${manifest}")"
commit="$(plutil -extract dependencies.0.commit raw -o - "${manifest}")"
tag_object="$(plutil -extract dependencies.0.tagObject raw -o - "${manifest}")"
source="$(plutil -extract dependencies.0.source raw -o - "${manifest}")"
deployment_target="$(plutil -extract dependencies.0.deploymentTarget raw -o - "${manifest}")"
[[ "${dependency_name}" == "FreeRDP" ]] || { echo "Unexpected dependency manifest entry" >&2; exit 1; }
[[ "${commit}" =~ ^[0-9a-f]{40}$ && "${tag_object}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "FreeRDP commit or tag object is not a pinned SHA-1" >&2
  exit 1
}

openssl_root_for_architecture() {
  local architecture="$1"
  local variable
  local configured
  case "${architecture}" in
    arm64) variable=OPENSSL_ROOT_DIR_ARM64 ;;
    x86_64) variable=OPENSSL_ROOT_DIR_X86_64 ;;
  esac
  configured="${!variable:-${OPENSSL_ROOT_DIR:-}}"
  if [[ -z "${configured}" && "$(uname -m)" == "${architecture}" ]] && command -v brew >/dev/null; then
    configured="$(brew --prefix openssl@3 2>/dev/null || true)"
  fi
  [[ -n "${configured}" ]] || {
    echo "Set ${variable} to an ${architecture} OpenSSL installation." >&2
    return 1
  }
  [[ -f "${configured}/lib/libssl.a" && -f "${configured}/lib/libcrypto.a" ]] || {
    echo "Static OpenSSL libraries are missing from ${configured}" >&2
    return 1
  }
  lipo -verify_arch "${architecture}" "${configured}/lib/libssl.a" "${configured}/lib/libcrypto.a"
  printf '%s\n' "${configured}"
}

validate_native_install() {
  local install="$1"
  local architecture="$2"
  local binary
  local dependency
  for required in libfreerdp3.dylib libfreerdp-client3.dylib libwinpr3.dylib; do
    [[ -e "${install}/lib/${required}" ]] || {
      echo "Required ${architecture} runtime is missing: ${required}" >&2
      return 1
    }
  done
  while IFS= read -r binary; do
    file "${binary}" | grep -q 'Mach-O' || continue
    lipo -verify_arch "${architecture}" "${binary}"
    while IFS= read -r dependency; do
      case "${dependency}" in
        /opt/homebrew/*|/usr/local/*)
          echo "Homebrew dependency leaked into ${binary}: ${dependency}" >&2
          return 1
          ;;
      esac
    done < <(otool -L "${binary}" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//')
  done < <(find "${install}/lib" -type f | sort)
}

build_architecture() {
  local architecture="$1"
  local openssl_root
  local build="${root}/Vendor/build/${architecture}"
  local install="${build}/install"

  openssl_root="$(openssl_root_for_architecture "${architecture}")"
  cmake -S "${source_dir}" -B "${build}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${architecture}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${deployment_target}" \
    -DCMAKE_INSTALL_PREFIX="${install}" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DCMAKE_PREFIX_PATH="${openssl_root}" \
    -DOPENSSL_ROOT_DIR="${openssl_root}" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DWITH_OPENSSL=ON \
    -DWITH_SERVER=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_COMMON=ON \
    -DWITH_CLIENT_CHANNELS=ON \
    -DWITH_CHANNELS=ON \
    -DWITH_MACAUDIO=ON \
    -DWITH_FFMPEG=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_CUPS=ON \
    -DWITH_PCSC=ON \
    -DWITH_MANPAGES=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_ABSOLUTE_PLUGIN_LOAD_PATHS=OFF
  cmake --build "${build}" --parallel
  cmake --install "${build}"
  validate_native_install "${install}" "${architecture}"
}

merge_universal() {
  local arm_install="${root}/Vendor/build/arm64/install"
  local intel_install="${root}/Vendor/build/x86_64/install"
  local universal="${root}/Vendor/build/universal"
  local arm_file
  local intel_file
  local relative
  local destination
  local arm_link
  local intel_link
  local arm_target
  local intel_target

  for command in file find install_name_tool lipo; do
    command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; return 1; }
  done
  [[ -d "${arm_install}/include" && -d "${intel_install}/include" ]] || {
    echo "Both architecture install trees are required before merging." >&2
    return 1
  }

  rm -rf "${universal}"
  mkdir -p "${universal}/lib" "${universal}/include" "${universal}/share"
  cp -R "${arm_install}/include/." "${universal}/include/"
  cp -R "${arm_install}/share/." "${universal}/share/" 2>/dev/null || true

  while IFS= read -r arm_file; do
    file "${arm_file}" | grep -q 'Mach-O' || continue
    relative="${arm_file#${arm_install}/lib/}"
    intel_file="${intel_install}/lib/${relative}"
    destination="${universal}/lib/${relative}"
    [[ -f "${intel_file}" ]] || { echo "Missing x86_64 slice: ${relative}" >&2; return 1; }
    mkdir -p "$(dirname "${destination}")"
    lipo -create "${arm_file}" "${intel_file}" -output "${destination}"
    if [[ "${destination}" == *.dylib ]]; then
      install_name_tool -id "@rpath/$(basename "${destination}")" "${destination}"
    fi
    lipo -verify_arch arm64 x86_64 "${destination}"
  done < <(find "${arm_install}/lib" -type f | sort)

  while IFS= read -r arm_link; do
    relative="${arm_link#${arm_install}/lib/}"
    intel_link="${intel_install}/lib/${relative}"
    destination="${universal}/lib/${relative}"
    [[ -L "${intel_link}" ]] || { echo "Missing x86_64 symlink: ${relative}" >&2; return 1; }
    arm_target="$(readlink "${arm_link}")"
    intel_target="$(readlink "${intel_link}")"
    [[ "${arm_target}" == "${intel_target}" ]] || {
      echo "Symlink target mismatch for ${relative}: ${arm_target} != ${intel_target}" >&2
      return 1
    }
    [[ -e "$(dirname "${destination}")/${arm_target}" ]] || continue
    mkdir -p "$(dirname "${destination}")"
    ln -sfn "${arm_target}" "${destination}"
  done < <(find "${arm_install}/lib" -type l | sort)

  for required in libfreerdp3.dylib libfreerdp-client3.dylib libwinpr3.dylib; do
    [[ -e "${universal}/lib/${required}" ]] || {
      echo "Required universal runtime is missing: ${required}" >&2
      return 1
    }
  done
  echo "Built pinned FreeRDP from ${manifest} at ${universal}"
}

if [[ ${#architectures[@]} -gt 0 ]]; then
  for command in cmake file find git lipo ninja otool; do
    command -v "${command}" >/dev/null || { echo "Missing ${command}" >&2; exit 1; }
  done
  if [[ ! -d "${source_dir}/.git" ]]; then
    git clone --filter=blob:none --no-checkout "${source}" "${source_dir}"
  fi
  git -C "${source_dir}" fetch --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}"
  actual_tag_object="$(git -C "${source_dir}" rev-parse "refs/tags/${tag}^{tag}")"
  actual_commit="$(git -C "${source_dir}" rev-parse "refs/tags/${tag}^{commit}")"
  [[ "${actual_tag_object}" == "${tag_object}" ]] || { echo "FreeRDP tag object mismatch" >&2; exit 1; }
  [[ "${actual_commit}" == "${commit}" ]] || { echo "FreeRDP tag commit mismatch" >&2; exit 1; }
  git -C "${source_dir}" checkout --detach "${commit}"
  for architecture in "${architectures[@]}"; do
    build_architecture "${architecture}"
  done
fi

if [[ "${merge_after_build}" == true ]]; then
  merge_universal
fi
