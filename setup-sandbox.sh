#!/usr/bin/env bash
# setup-sandbox.sh  — Pi-side provisioning of the aarch64 iSH rootfs.
# Turnkey: persistent /root home, SJTU mirror, base tooling (python3, vim).
#
# IMPORTANT (crash-safety): never force-kill the guest mid-apk. Each apk step
# must exit CLEANLY so iSH commits the SQLite WAL into meta.db. A killed guest
# leaves a half-written WAL -> "database disk image is malformed" on next boot.
# If that happens: rm the rootfs dir and re-rsync a fresh alpine-arm64.
#
# Idempotent. Run on the Orange Pi:  ~/ish-arm64/setup-sandbox.sh
set +e   # do NOT abort on apk non-zero; handle each step explicitly
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
chmod +x ish ish-shell.sh 2>/dev/null
ISH=./ish

echo "==> [1/3] write persistent home + SJTU mirror"
printf 'mkdir -p /root\ncat > /root/.profile <<PROF\n't > /tmp/ish-in.txt
cat >> /tmp/ish-in.txt <<'PROF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1="ish(aarch64):\w\$ "
export LANG=C.UTF-8
PROF
printf "printf 'https://mirror.sjtu.edu.cn/alpine/v3.21/main\\nhttps://mirror.sjtu.edu.cn/alpine/v3.21/community\\n' > /etc/apk/repositories\n" >> /tmp/ish-in.txt
timeout 60 $ISH -f alpine-arm64 /bin/sh < /tmp/ish-in.txt 2>&1 | tail -3

echo "==> [2/3] apk update (SJTU)"
printf 'apk update 2>&1 | tail -2\n' | timeout 120 $ISH -f alpine-arm64 /bin/sh 2>&1 | tail -3

echo "==> [3/3] install base tools"
printf 'command -v python3 >/dev/null || apk add python3 vim 2>&1 | tail -3\n' | timeout 280 $ISH -f alpine-arm64 /bin/sh 2>&1 | tail -4

echo "==> verify"
printf 'python3 -c "import platform,sys;print(platform.machine(),sys.version.split()[0])"; cat /etc/apk/repositories | head -1\n' | timeout 60 $ISH -f alpine-arm64 /bin/sh 2>&1 | head -4

echo "==> Done. Launch with:  ~/ish-arm64/ish-shell.sh"
