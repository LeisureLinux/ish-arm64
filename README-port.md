# aarch64 iSH (OpenMinis/ish-arm64) — 交叉编译与 Orange Pi 部署

把 `OpenMinis/ish-arm64` fork（带 **AArch64 客户机后端** 的 iSH）在 x86_64 Debian 上交叉编译成 aarch64 二进制，
跑在 Orange Pi（wpad-02, aarch64/sunxi64）上，提供一个**原生 AArch64 Alpine Linux** 沙箱终端。

## 验证结果（在真实 Orange Pi 上）
- `uname -m` → `aarch64`（客户机是 AArch64，不是 i686）
- `apk add python3` 成功：`python3 -c "import platform; print(platform.machine())"` → `aarch64 3.12.15`
- fork/exec/subshell、`/proc/self/stat`、`date` 等系统调用正常
- 持久化 home (`/root`) + 上海交大镜像源 (mirror.sjtu.edu.cn)

## 网络接口可见性：`ip` / `ifconfig` 现在能显示真实 IP（iOS 关键需求）

**问题**：iSH 的 guest 没有真正的 netlink 套接字，`ip addr` / `ifconfig` 会报
`Address family not supported by protocol`（AF_NETLINK）或 `ioctl ... failed`。

guest 的 socket 调用被翻译成 **宿主进程的 socket 调用**（iOS 上宿主进程就是 App 本身，
guest 共享 App 的网络），所以最忠实的实现是：把宿主 `getifaddrs()` 的接口/IP 列表
**合成**成 netlink dump 与 SIOCIF* ioctl 返回给 guest。

**改动**（`fs/sock.c` + `fs/real.c` + `fs/sock.h` + `fs/fd.h`）：
- `ish_netlink_stub_enabled()` 默认开启（无需 `ISH_NETLINK_STUB=1`，设 `=0` 可关闭）。
- `fs/sock.c` 合成 `RTM_NEWLINK` / `RTM_NEWADDR` dump（按接口名去重，一个接口一条 link；
  地址字节从 `sin_addr`/`sin6_addr` 取，MAC 用接口名 hash 生成稳定的本地管理地址）。
- `ip` 通过 `write()` 发请求，在 `sock_write()` 拦截并触发合成回复（存入 fd 内 buffer）。
- **iproute2 的 `ip` 也能用了**：iproute2 的 `rtnl_recvmsg()` 先用
  `recvmsg(MSG_PEEK|MSG_TRUNC)` 发一个零长度 iovec探测包大小，再用真实 buffer 读。
  合成 dump 在探测调用时**只返回长度不消耗**，真实调用才拷贝并消耗；同时
  `NLMSG_DONE` 必须带 4 字节 error-code 负载（`nlmsg_len=20`），否则 iproute2 报
  `DONE truncated`。`rtattr` 用未对齐的 `vlen+sizeof(rtattr)` 长度，buffer 推进用对齐值。
- `fs/real.c` 转发 `SIOC{G}IF*` ioctl，并实现 `SIOCGIFHWADDR`（合成 MAC，
  `sa_family=ARPHRD_ETHER(1)` 让 net-tools 只打印 6 字节）与 `SIOCGIFCONF`
  （从 `getifaddrs()` 构建 ifreq 列表，支持 `ifc_len==0` 大小探测）。
- **`struct ifreq_` 布局对齐真实 aarch64 musl**（40 字节：name[16] + ifru union[24]，
  其中含 24 字节 `ifmap` 成员；`sockaddr_` 为 16 字节 family[2]+data[14]），
  否则 ioctl buffer 拷贝尺寸错位，`ifconfig` 会把 `sa_data` 的陈旧字节也打印出来
  （16 字节 HWaddr）。

**在 Pi（aarch64 宿主）上的实测输出**：
```
$ ip -o -4 addr show
1: lo    inet 127.0.0.1/24 scope global dynamic lo
2: eth0  inet 192.168.68.68/24 scope global dynamic eth0
$ ifconfig eth0 | head -2
eth0      Link encap:Ethernet  HWaddr 02:67:B1:97:24:43
          inet addr:192.168.68.68  Bcast:192.168.68.255  Mask:255.255.255.0
$ ip addr          # 真实 iproute2 6.11 也能解析合成 dump
$ ip link
$ ss               # 干净返回空表（不再崩溃）
```

> 注：`ip route` 在 guest 里会打印 `Not a route: ...`（guest 的 iproute2 对
> `RTM_GETROUTE` 的合成 dump 不解析，属 guest 侧噪音，非 iSH 错误；可选实现
> `RTM_GETROUTE` 合成来消除）。

## 文件清单
| 文件 | 作用 |
|------|------|
| `build-and-deploy.sh` | x86_64 构建机用：clone fork → 自编译 arm64 sqlite3 → 打 linux-port.patch → clang 交叉编译 → 打包 aarch64 Alpine → rsync 到目标机 |
| `cross-arm64.ini` | meson 交叉文件。**必须用 clang**（gadget .S 是 clang IAS 语法，GNU as 拒绝） |
| `linux-port.patch` | Darwin→Linux 源码补丁（`fs/fake.c` 的 st_*tim、main.c 的 mach/sysctl/crash_handler ucontext、meson 去掉 cross-build 的 ish 二进制屏蔽） |
| `ish-shell.sh` | 目标机上启动器：`~/ish-arm64/ish-shell.sh` 进入 aarch64 Alpine |
| `setup-sandbox.sh` | 目标机上一次性开通：持久 home + SJTU 镜像 + 基础工具（python3/vim） |
| `alpine-arm64/` | fakefs 格式 aarch64 Alpine rootfs（meta.db + data/） |

## 关键坑（已解决）
1. **汇编器用 clang 不用 gcc**：fork 的 gadget `.S`（`asbestos/guest-arm64/gadgets-aarch64/*.S`）是 clang 集成汇编器语法（`ldr x8,[_pc],#8`、符号当立即数），GNU `as` 报错。交叉文件改用 `c=['clang','--target=aarch64-linux-gnu']`。
2. **本机无 arm64 多架构源**：Debian 只挂了第三方源，apt 装不了 `libsqlite3-dev:arm64`。自编译静态 arm64 `libsqlite3.a`（sqlite-autoconf-3500200）。
3. **crash_handler 的 ucontext**：Darwin 的 `uc->uc_mcontext->__ss.__x/__es.__esr` 在 glibc 上是结构体（`uc->uc_mcontext.regs[].sp.pc`），已加 `#if __APPLE__ ... #else ...` 分支；WnR 读写用 `info->si_code==SEGV_ACCERR` 近似。

## ⚠️ crash-safety（重要！）
**绝不要**在 guest 跑 `apk` 中途 kill 掉 `ish`。强制杀进程会让 SQLite WAL 半写，下次启动报
`database disk image is malformed` 并崩溃。每个 apk 步骤都要**干净退出**以提交 WAL。
- 若已损坏：`rm -rf alpine-arm64` 后重新 rsync 一份干净的（由 `build-and-deploy.sh` 第 6 步生成）。
- 之前手动 `timeout 300` 杀管道导致 ish 残留 + DB 损坏，已用干净 rootfs 重建。

## 复现流程
构建机（x86_64）：
```bash
./build-and-deploy.sh axu@wpad.lan ~/ish-arm64
```
目标机（Orange Pi）：
```bash
cd ~/ish-arm64
./setup-sandbox.sh      # 持久化 home + 镜像 + python3/vim
./ish-shell.sh          # 进入 aarch64 Alpine
```

## 平台说明
- 客户机架构：`aarch64`（AArch64 Linux），由 OpenMinis arm64 后端提供。
- 宿主架构：aarch64（Orange Pi）。交叉编译只是在 x86_64 上产出 aarch64 二进制。
- 不是 iOS/OpenShell 模拟；这是 iSH 用户态模拟器在 ARM64 Linux 上的真实 AArch64 guest。
