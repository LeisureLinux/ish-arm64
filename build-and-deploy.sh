#!/usr/bin/env bash
# build-and-deploy.sh
# Cross-compile OpenMinis/ish-arm64 (AArch64 guest backend) on an x86_64 Debian box
# and deploy the aarch64 `ish` + an aarch64 Alpine fakefs to an internal ARM64 host
# (Orange Pi / wpad.lan).
#
# What this does (all steps are idempotent / resumable):
#   1. Clone the fork (via proxy if direct fails) + submodules.
#   2. Self-build a static arm64 libsqlite3.a (arm64 libs not in apt on this box).
#   3. Apply linux-port.patch (Darwin->Linux source fixes for the kernel=ish path).
#   4. Cross-configure + ninja with clang IAS (gadget .S need clang, not gcc).
#   5. Build a native x86_64 fakefsify to pack an aarch64 Alpine minirootfs.
#   6. Download aarch64 Alpine minirootfs, fakefsify it.
#   7. rsync binary + rootfs + launcher to the target host.
#
# Usage:  ./build-and-deploy.sh [TARGET_HOST] [TARGET_DIR]
#   TARGET_HOST default: axu@wpad.lan
#   TARGET_DIR  default: ~/ish-arm64

set -euo pipefail

# ---- config -----------------------------------------------------------------
REPO_URL="https://github.com/OpenMinis/ish-arm64"
PROXY="${http_proxy:-http://wpad.lan:8888}"
ALPINE_VER="3.21.3"
ALPINE_TAR="alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/${ALPINE_TAR}"
SQLITE_VER="3500200"   # sqlite-autoconf-3500200
SQLITE_TAR="sqlite-autoconf-${SQLITE_VER}.tar.gz"
SQLITE_URL="https://www.sqlite.org/2025/${SQLITE_TAR}"

TARGET_HOST="${1:-axu@wpad.lan}"
TARGET_DIR="${2:-ish-arm64}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${WORKDIR}/ish-arm64-build"
CROSS_INI="${WORKDIR}/cross-arm64.ini"

echo "==> Workdir: ${WORKDIR}"
echo "==> Target: ${TARGET_HOST}:${TARGET_DIR}"

# ---- helpers ----------------------------------------------------------------
fetch() {  # fetch <url> <outfile>
  local url="$1" out="$2"
  if curl -fsSL --max-time 90 -o "$out" "$url" 2>/dev/null; then return 0; fi
  echo "    direct failed, trying proxy ${PROXY}"
  curl -fsSL --max-time 120 -x "$PROXY" -o "$out" "$url"
}

# ---- 1. clone ----------------------------------------------------------------
if [ ! -d "${BUILD_DIR}/.git" ]; then
  echo "==> [1/7] Cloning ${REPO_URL}"
  rm -rf "${BUILD_DIR}"
  git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}" || \
    GIT_HTTP_PROXY="$PROXY" GIT_HTTPS_PROXY="$PROXY" git clone --depth 1 "${REPO_URL}" "${BUILD_DIR}"
  git -C "${BUILD_DIR}" submodule update --init --recursive || \
    GIT_HTTP_PROXY="$PROXY" GIT_HTTPS_PROXY="$PROXY" git -C "${BUILD_DIR}" submodule update --init --recursive
fi

cd "${BUILD_DIR}"

# ---- 2. static arm64 sqlite3 -------------------------------------------------
if [ ! -f arm64-prefix/lib/libsqlite3.a ]; then
  echo "==> [2/7] Building static arm64 libsqlite3.a"
  [ -f "/tmp/${SQLITE_TAR}" ] || fetch "${SQLITE_URL}" "/tmp/${SQLITE_TAR}"
  rm -rf "/tmp/sqlite-build" && mkdir -p "/tmp/sqlite-build"
  tar xzf "/tmp/${SQLITE_TAR}" -C /tmp/sqlite-build
  sd=$(tar tzf "/tmp/${SQLITE_TAR}" | head -1 | cut -d/ -f1)
  ( cd "/tmp/sqlite-build/$sd"
    CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar ./configure \
      --host=aarch64-linux-gnu --prefix="${BUILD_DIR}/arm64-prefix" \
      --enable-static --disable-shared CFLAGS="-O2 -fPIC" >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null )
fi
echo "    sqlite3.a: $(file arm64-prefix/lib/libsqlite3.a 2>/dev/null | head -1)"

# ---- 3. apply linux port patch (idempotent) ----------------------------
# The port is normally already merged into the committed source. Only apply the
# standalone patch if it still applies cleanly (i.e. a pristine checkout). Never
# fail the build just because the patch is already in the tree.
if git apply --check "${WORKDIR}/linux-port.patch" 2>/dev/null; then
  echo "==> [3/7] Applying linux-port.patch"
  git apply "${WORKDIR}/linux-port.patch"
else
  echo "==> [3/7] linux-port.patch already applied / not applicable (skipping)"
fi

# ---- 4. cross build ----------------------------------------------------------
echo "==> [4/7] Cross-building aarch64 ish (clang IAS)"
export LDFLAGS="-L${BUILD_DIR}/arm64-prefix/lib"
export CPPFLAGS="-I${BUILD_DIR}/arm64-prefix/include"
export CFLAGS="-I${BUILD_DIR}/arm64-prefix/include"
if [ ! -d build-arm64 ]; then
  meson setup build-arm64 --cross-file "${CROSS_INI}" \
    -Dguest_arch=arm64 -Dengine=asbestos -Dkernel=ish
fi
ninja -C build-arm64
echo "    ish: $(file build-arm64/ish | head -1)"

# ---- 5. native fakefsify -----------------------------------------------------
echo "==> [5/7] Building native fakefsify"
if [ ! -x build-native/tools/fakefsify ]; then
  meson setup build-native --wipe >/dev/null
  ninja -C build-native tools/fakefsify
fi

# ---- 6. aarch64 alpine rootfs ----------------------------------------------
if [ ! -d alpine-arm64 ]; then
  echo "==> [6/7] Fetching aarch64 Alpine minirootfs"
  [ -f "/tmp/${ALPINE_TAR}" ] || fetch "${ALPINE_URL}" "/tmp/${ALPINE_TAR}"
  ./build-native/tools/fakefsify "/tmp/${ALPINE_TAR}" alpine-arm64
fi

# ---- 7. deploy ---------------------------------------------------------------
echo "==> [7/7] rsync to ${TARGET_HOST}:${TARGET_DIR}"
ssh -o StrictHostKeyChecking=no "${TARGET_HOST}" "mkdir -p ~/${TARGET_DIR}"
rsync -rp --info=progress2 \
  build-arm64/ish \
  alpine-arm64 \
  "${WORKDIR}/ish-shell.sh" \
  "${WORKDIR}/cross-arm64.ini" \
  "${TARGET_HOST}:~/${TARGET_DIR}/"

echo "==> DONE. On target:  cd ~/${TARGET_DIR} && ./ish-shell.sh"
