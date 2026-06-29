#!/usr/bin/env bash
set -euo pipefail

TERMUX_PACKAGES_COMMIT="${TERMUX_PACKAGES_COMMIT:-ac296452b8ebec390cad3bce9060577c96099b10}"
TERMUX_PACKAGES_REPO="${TERMUX_PACKAGES_REPO:-https://github.com/termux/termux-packages.git}"
TERMUX_PACKAGES_DIR="${TERMUX_PACKAGES_DIR:-${CONDUIT_TERMUX_PACKAGES_DIR:-}}"
UPDATE_CHECKSUMS=0
SETUP_UBUNTU=0
SETUP_ANDROID=0
NO_ANDROID_SETUP=0
SETUP_ONLY=0

usage() {
  cat <<'USAGE'
Usage: tools/build-local-shell-binaries.sh [options]

Build Conduit's Android/aarch64 local-shell native payload from the pinned
Termux package recipes, copy/rename the outputs into android jniLibs, rewrite
Android loader names, and verify bundled-binaries.sha256.

Options:
  --setup              Run Termux host and Android SDK/NDK setup before building.
  --setup-ubuntu-only  Patch Termux setup scripts, run setup-ubuntu.sh, and exit.
  --no-android-setup   Do not download Android SDK/NDK if NDK is missing.
  --update-checksums   Refresh bundled-binaries.sha256.

Environment:
  TERMUX_PACKAGES_DIR          Existing termux-packages checkout, such as an
                               F-Droid srclib. If unset, the script clones it.
  TERMUX_PACKAGES_COMMIT       Pinned termux-packages commit.
  ANDROID_HOME                 Android SDK directory. Defaults to
                               build/local-shell-native/android-sdk-9123335.
  NDK                          Android NDK directory. Defaults to
                               build/local-shell-native/android-ndk-r29.
  TERMUX_TOPDIR                Termux package build root. Defaults to
                               /tmp/conduit-termux-build for reproducible paths.
  CONDUIT_KEEP_LOCAL_SHELL_BUILD_ARTIFACTS=1
                               Keep extracted Termux package outputs for debugging.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --setup) SETUP_UBUNTU=1; SETUP_ANDROID=1 ;;
    --setup-ubuntu-only) SETUP_UBUNTU=1; SETUP_ONLY=1 ;;
    --no-android-setup) NO_ANDROID_SETUP=1 ;;
    --update-checksums) UPDATE_CHECKSUMS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JNI_DIR="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
BUILD_ROOT="$ROOT/build/local-shell-native"
STAGE_DIR="$BUILD_ROOT/stage"
export ANDROID_HOME="${ANDROID_HOME:-$BUILD_ROOT/android-sdk-9123335}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export NDK="${NDK:-$BUILD_ROOT/android-ndk-r29}"
export TERMUX_TOPDIR="${TERMUX_TOPDIR:-${CONDUIT_TERMUX_TOPDIR:-/tmp/conduit-termux-build}}"

if [ -z "$TERMUX_PACKAGES_DIR" ]; then
  TERMUX_PACKAGES_DIR="$BUILD_ROOT/termux-packages"
fi

if [ ! -d "$TERMUX_PACKAGES_DIR/.git" ]; then
  mkdir -p "$(dirname "$TERMUX_PACKAGES_DIR")"
  git clone "$TERMUX_PACKAGES_REPO" "$TERMUX_PACKAGES_DIR"
fi

git -C "$TERMUX_PACKAGES_DIR" fetch --tags --force origin "$TERMUX_PACKAGES_COMMIT" || true
git -C "$TERMUX_PACKAGES_DIR" checkout -f "$TERMUX_PACKAGES_COMMIT"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$TERMUX_PACKAGES_DIR" show -s --format=%ct "$TERMUX_PACKAGES_COMMIT")}"
export TZ=UTC
export LC_ALL=C
export LANG=C
export KCONFIG_NOTIMESTAMP=1

termux_env() {
  TERMUX_PKGS__BUILD__REPO_ROOT_DIR="$TERMUX_PACKAGES_DIR" "$@"
}

if command -v apt-cache >/dev/null 2>&1 &&
  ! apt-cache show python3.14-venv >/dev/null 2>&1; then
  sed -i 's/python3\.14-venv/python3-venv/g' \
    "$TERMUX_PACKAGES_DIR/scripts/setup-ubuntu.sh"
fi

sed -i -E \
  '/LLVM_PACKAGES\+=" (llvm|clang|lld)-\$\{TERMUX_HOST_LLVM_MAJOR_VERSION\}/s/^/# /' \
  "$TERMUX_PACKAGES_DIR/scripts/setup-ubuntu.sh"

sed -i -E \
  's/(^|[[:space:]])coreutils-from-uutils([[:space:]]|$)/ /g' \
  "$TERMUX_PACKAGES_DIR/scripts/setup-ubuntu.sh"

perl -0pi -e 's#local TERMUX_ARCH_FILE=/data/TERMUX_ARCH#local TERMUX_ARCH_FILE="\$\{TERMUX_TOPDIR\}/TERMUX_ARCH"\n\tmkdir -p "\$\{TERMUX_TOPDIR\}"#' \
  "$TERMUX_PACKAGES_DIR/scripts/build/termux_step_handle_buildarch.sh"

perl -0pi -e 's#if ! mountpoint -q "\$\{TERMUX_STANDALONE_TOOLCHAIN\}"; then\n\t\tfuse-overlayfs \\\n\t\t\t"\$\{TERMUX_STANDALONE_TOOLCHAIN\}" \\\n\t\t\t-o lowerdir="\$\{NDK\}/toolchains/llvm/prebuilt/linux-x86_64" \\\n\t\t\t-o upperdir="\$\{TERMUX_STANDALONE_TOOLCHAIN\}-upper" \\\n\t\t\t-o workdir="\$\{TERMUX_STANDALONE_TOOLCHAIN\}-work"\n\tfi#if [ ! -e "\${TERMUX_STANDALONE_TOOLCHAIN}/bin/clang" ]; then\n\t\tcp -a "\${NDK}/toolchains/llvm/prebuilt/linux-x86_64/." "\${TERMUX_STANDALONE_TOOLCHAIN}/"\n\tfi#' \
  "$TERMUX_PACKAGES_DIR/scripts/build/toolchain/termux_setup_toolchain_29.sh"

if [ "$SETUP_UBUNTU" -eq 1 ]; then
  termux_env bash "$TERMUX_PACKAGES_DIR/scripts/setup-ubuntu.sh"
fi

if [ "$SETUP_ONLY" -eq 1 ]; then
  exit 0
fi

if [ "$SETUP_ANDROID" -eq 1 ]; then
  termux_env bash "$TERMUX_PACKAGES_DIR/scripts/setup-android-sdk.sh"
fi

if [ ! -d "$NDK" ] && [ "$NO_ANDROID_SETUP" -eq 0 ]; then
  echo "Android NDK r29 not found at $NDK; installing Termux Android SDK/NDK."
  termux_env bash "$TERMUX_PACKAGES_DIR/scripts/setup-android-sdk.sh"
fi

if [ ! -d "$NDK" ]; then
  echo "Android NDK r29 not found at $NDK." >&2
  echo "Provide NDK or omit --no-android-setup." >&2
  exit 1
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  android_sdk_dir="$ANDROID_HOME"
  if [ -n "$android_sdk_dir" ]; then
    {
      echo "ANDROID_HOME=$android_sdk_dir"
      echo "ANDROID_SDK_ROOT=$android_sdk_dir"
    } >> "$GITHUB_ENV"
    if [ -n "${GITHUB_PATH:-}" ]; then
      {
        echo "$android_sdk_dir/platform-tools"
        echo "$android_sdk_dir/cmdline-tools/bin"
      } >> "$GITHUB_PATH"
    fi
  fi
fi

rm -rf "$BUILD_ROOT/output" "$STAGE_DIR"
mkdir -p "$BUILD_ROOT/output" "$STAGE_DIR" "$JNI_DIR"

packages=(
  libandroid-shmem
  libtalloc
  proot
  pcre2
  libandroid-selinux
  libandroid-glob
  libiconv
  attr
  libacl
  liblzma
  busybox
  tar
)

"$TERMUX_PACKAGES_DIR/build-package.sh" \
  -a aarch64 \
  -F \
  -o "$BUILD_ROOT/output" \
  "${packages[@]}"

shopt -s nullglob
debs=("$BUILD_ROOT"/output/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "No Termux .deb outputs found in $BUILD_ROOT/output" >&2
  exit 1
fi

for deb in "${debs[@]}"; do
  dpkg-deb -x "$deb" "$STAGE_DIR"
done

rm -rf "$JNI_DIR"
mkdir -p "$JNI_DIR"

copy_output() {
  local suffix="$1" target="$2" match
  match="$(find "$STAGE_DIR" \( -type f -o -type l \) -path "*/$suffix" | sort | head -n 1)"
  if [ -z "$match" ]; then
    echo "Missing Termux output matching */$suffix for $target" >&2
    exit 1
  fi
  cp -L "$match" "$JNI_DIR/$target"
  chmod 755 "$JNI_DIR/$target"
}

copy_output "bin/proot" "libproot.so"
copy_output "libexec/proot/loader" "libproot_loader.so"
copy_output "bin/tar" "libtarbin.so"
copy_output "bin/xz" "libxzbin.so"
copy_output "bin/busybox" "libbusyboxbin.so"
copy_output "lib/libbusybox.so*" "libbusybox.so"
copy_output "lib/libtalloc.so*" "libtalloc.so"
copy_output "lib/liblzma.so*" "liblzma.so"
copy_output "lib/libacl.so*" "libacl.so"
copy_output "lib/libattr.so*" "libattr.so"
copy_output "lib/libiconv.so*" "libiconv.so"
copy_output "lib/libcharset.so*" "libcharset.so"
copy_output "lib/libandroid-glob.so*" "libandroid-glob.so"
copy_output "lib/libandroid-selinux.so*" "libandroid-selinux.so"
copy_output "lib/libandroid-shmem.so*" "libandroid-shmem.so"
copy_output "lib/libpcre2-8.so*" "libpcre2-8.so"

(cd "$ROOT" && third_party/source-offer/rewrite-soname.sh)

verify_checksums() {
  local expected path actual failed=0

  while read -r expected path; do
    if [ -z "$expected" ] || [ -z "$path" ]; then
      continue
    fi

    actual="$(sha256sum "$path" | awk '{print $1}')"
    if [ "$actual" = "$expected" ]; then
      echo "$path: OK"
    else
      echo "$path: FAILED"
      echo "  expected: $expected"
      echo "  actual:   $actual"
      failed=1
    fi
  done < third_party/source-offer/bundled-binaries.sha256

  return "$failed"
}

if [ "$UPDATE_CHECKSUMS" -eq 1 ]; then
  (cd "$ROOT" && sha256sum android/app/src/main/jniLibs/arm64-v8a/*.so \
    > third_party/source-offer/bundled-binaries.sha256)
else
  (cd "$ROOT" && verify_checksums)
fi

(cd "$ROOT" && third_party/source-offer/rewrite-soname.sh --verify)

if [ "${CONDUIT_KEEP_LOCAL_SHELL_BUILD_ARTIFACTS:-0}" != "1" ]; then
  rm -rf "$BUILD_ROOT/output" "$STAGE_DIR"
fi
