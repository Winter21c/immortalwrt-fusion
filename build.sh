#!/bin/sh
#
# immortalwrt-fusion 的统一构建入口。
#
# 本地与 CI 走的是**同一条路径**，所以不会出现「本地能编、CI 编不出来」。
#
# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
#
#   ./build.sh                         # 默认：两个特性都要、含 Docker
#   ./build.sh 12                      # 指定并发数（默认 $(nproc)）
#
#   只要 iStoreOS，不要 FanchmWrt：
#     WITH_FANCHMWRT=0 ./build.sh
#
#   只要底座：
#     WITH_FANCHMWRT=0 WITH_ISTOREOS=0 ENABLE_DOCKER=0 ./build.sh
#
#   自定义管理地址与固件大小：
#     LAN_IP=192.168.100.1/24 ROOTFS_PARTSIZE=2048 ./build.sh
#
#   只做到「准备就绪」，不下载也不编译（CI 用它把日志和重试边界分开）：
#     SKIP_BUILD=1 ./build.sh
#
# ---------------------------------------------------------------------------
# 参数（全部可用环境变量覆盖）
# ---------------------------------------------------------------------------
#
#   WITH_FANCHMWRT  1/0  是否并入 FanchmWrt 特性（fwx 内核模块 + 主题 + 17 个应用）
#   WITH_ISTOREOS   1/0  是否并入 iStoreOS 特性（QuickStart 首页 + iStore 商店 + argon 主题）
#   ENABLE_DOCKER   1/0  是否包含 Docker
#   LAN_IP          字符串 管理地址，可带前缀长度；空 = 保持 ImmortalWrt 默认
#   ROOTFS_PARTSIZE 数字  rootfs 分区大小（MB）
#   IMMORTALWRT_REF 字符串 ImmortalWrt 的 ref（分支或 tag）
#   SKIP_BUILD      1/0  只准备不编译
#   SKIP_FEEDS_UPDATE 1/0 跳过 feeds update（复用已有 feeds/）
#
set -eu

# ⚠️ 变量名是 PROJECT_ROOT 而不是 TOPDIR，这是有意的。
#
# OpenWrt 的脚本自己会用环境变量 TOPDIR：`scripts/feeds` 第 13 行就是
# `chdir $ENV{TOPDIR};`，也就是「如果外面设了 TOPDIR，就切到那里去工作」。
# 如果我们把项目根导成 TOPDIR，feeds 就会跑进本仓库根目录，
# 而那里没有 feeds.conf.default —— 报错是
# "Unable to open feeds configuration at ./scripts/feeds line 91"，
# 行号指向 feeds 脚本内部，完全看不出是环境变量被劫持了。
#
# 同理，make 也有自己的 TOPDIR。名字撞车这种事一次就够了。
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
export PROJECT_ROOT

. "$PROJECT_ROOT/scripts/lib.sh"

# 独占锁：防止同一个工作区里两个构建互相踩（原因见 scripts/lib.sh）。
acquire_lock

JOBS="${1:-$(nproc)}"

# --- 参数规范化 -------------------------------------------------------------
# GitHub Actions 的 boolean 输入到这里是字符串 'true'/'false'，
# 而 shell 里 'false' 是真值 —— 入口处一次性转成 1/0，后面不再有歧义。
WITH_FANCHMWRT=$(normalize_bool "${WITH_FANCHMWRT:-1}" 1)
WITH_ISTOREOS=$(normalize_bool "${WITH_ISTOREOS:-1}" 1)
ENABLE_DOCKER=$(normalize_bool "${ENABLE_DOCKER:-1}" 1)
SKIP_BUILD=$(normalize_bool "${SKIP_BUILD:-0}" 0)
SKIP_FEEDS_UPDATE=$(normalize_bool "${SKIP_FEEDS_UPDATE:-0}" 0)

LAN_IP="${LAN_IP:-192.168.1.1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
IMMORTALWRT_REF="${IMMORTALWRT_REF:-openwrt-25.12}"

export WITH_FANCHMWRT WITH_ISTOREOS ENABLE_DOCKER SKIP_FEEDS_UPDATE
export LAN_IP ROOTFS_PARTSIZE IMMORTALWRT_REF

# 慢镜像保护。
#
# scripts/download.pl 会把 CURL_OPTIONS 拼进每一次 curl 调用，并逐个镜像重试。
# 裸 curl 没有速率下限，一个「能用但极慢」的镜像会让 make download 永久挂住，
# 而不是自动换下一个 —— 现有项目实测 cdn.kernel.org 只有约 20 KB/s，
# 曾把 kernel 和 611MB 的 linux-firmware 两个包卡死几小时。
export CURL_OPTIONS="${CURL_OPTIONS:---speed-limit 51200 --speed-time 60}"

if [ "$WITH_FANCHMWRT" = "0" ] && [ "$WITH_ISTOREOS" = "0" ]; then
	FLAVOR="纯底座 ImmortalWrt"
elif [ "$WITH_FANCHMWRT" = "1" ] && [ "$WITH_ISTOREOS" = "0" ]; then
	FLAVOR="FanchmWrt"
elif [ "$WITH_FANCHMWRT" = "0" ] && [ "$WITH_ISTOREOS" = "1" ]; then
	FLAVOR="iStoreOS"
else
	FLAVOR="FanchmWrt + iStoreOS"
fi

printf '\n'
say "immortalwrt-fusion"
printf '    风味      : %s\n' "$FLAVOR"
printf '    管理地址  : %s\n' "$LAN_IP"
printf '    rootfs    : %s MB\n' "$ROOTFS_PARTSIZE"
printf '    Docker    : %s\n' "$([ "$ENABLE_DOCKER" = 1 ] && echo 包含 || echo 不含)"
printf '    并发      : %s\n' "$JOBS"
printf '    底座      : ImmortalWrt %s\n' "$IMMORTALWRT_REF"
printf '\n'

require_cmd curl tar patch make

# --- 1. 取源码 --------------------------------------------------------------
sh "$PROJECT_ROOT/scripts/01-fetch.sh"

# --- 2. feed ----------------------------------------------------------------
sh "$PROJECT_ROOT/scripts/02-feeds.sh"

# --- 3. 特性层 --------------------------------------------------------------
sh "$PROJECT_ROOT/scripts/03-overlay.sh"

# --- 4. 配置与断言 ----------------------------------------------------------
sh "$PROJECT_ROOT/scripts/04-config.sh"

if [ "$SKIP_BUILD" = "1" ]; then
	say "SKIP_BUILD=1，停在准备阶段（源码 / feed / 特性层 / .config 均已就绪）"
	exit 0
fi

# --- 5. 下载与编译 ----------------------------------------------------------
cd "$PROJECT_ROOT/openwrt"

say "下载源码包（失败不致命，编译阶段会重试）"
make -j"$JOBS" download || warn "部分源码包下载失败，编译阶段 make 会重试"

say "开始编译，约 1.5~3 小时，去喝杯茶"
make -j"$JOBS" BUILD_LOG=1

# --- 6. 核验 ----------------------------------------------------------------
cd "$PROJECT_ROOT"
sh "$PROJECT_ROOT/scripts/09-verify.sh"

say "完成。镜像在 openwrt/bin/targets/x86/64/"
