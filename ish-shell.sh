#!/usr/bin/env bash
# ish-shell.sh  — launcher for the cross-compiled aarch64-guest iSH on an ARM64 Linux host.
# Drops you into the bundled Alpine aarch64 fakefs as root.
# Usage:  ./ish-shell.sh [extra args passed to ish, e.g. /bin/sh -c '...']
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH="${ISH_BIN:-$DIR/ish}"
ROOTFS="${ISH_ROOTFS:-$DIR/alpine-arm64}"
exec "$ISH" -f "$ROOTFS" /bin/sh "$@"
