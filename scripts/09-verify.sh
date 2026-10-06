#!/bin/sh
#
# 第 9 步（编译之后）：核验产物。
#
# 编译通过只证明「能编出来」，不证明「编出来的东西对」。
# 这一步拿 scripts/04-config.sh 留下的期望清单，去比对**固件里真实的
# 软件包列表**（bin/targets/x86/64/*.manifest）—— 那才是最终事实。
#
# .config 里写了 y 而被依赖解析丢掉、或者某个包安装了却因为冲突被移除，
# 都是在这一步才会暴露。
#
set -eu
# 自己推导项目根，不依赖调用方 export。
#
# 这些脚本都能单独运行（CI 就是把 09-verify.sh 拆成一个独立 step 调的），
# 而 build.sh 里那句 export 只在经过它时才有效。漏了这两行的后果是
#     ./scripts/09-verify.sh: PROJECT_ROOT: parameter not set
# —— 编译全过、核验步骤直接挂掉。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT

. "$PROJECT_ROOT/scripts/lib.sh"

SRC="$PROJECT_ROOT/openwrt"
GEN="$PROJECT_ROOT/.generated"
OUT="$SRC/$(target_outdir "$TARGET")"

[ -d "$OUT" ] || die "没找到产物目录：$OUT"
[ -f "$GEN/expectations.env" ] || die "没找到期望清单，请先跑 scripts/04-config.sh"
# shellcheck disable=SC1090
. "$GEN/expectations.env"

FAILED=0
note_fail() { warn "$*"; FAILED=1; }

# ---------------------------------------------------------------------------
# 1. 镜像清单
#
# 两个目标的产物形态**完全不同**，所以期望的镜像名不能共用一份：
#
#   x86_64          4 个：squashfs / ext4 各含 efi 与非 efi。
#                   TARGZ / INITRAMFS / CPIOGZ / ISO 在 00-target.config 里
#                   显式关掉了，出现就是配置没生效。
#   rockchip-armv8  1 个：<设备>-sysupgrade.img.gz。
#                   它是一个 GPT（boot + rootfs），u-boot 写在前面 32768 扇区里
#                   —— 没有 efi / 非 efi 之分，也没有单独的 rootfs 镜像。
#                   这个形态由 target/linux/rockchip/image/Makefile 的
#                   IMAGE/sysupgrade.img.gz 决定，不归 .config 管。
# ---------------------------------------------------------------------------
say "核对镜像（目标：$TARGET）"
IMAGES=""
case "$TARGET" in
x86_64)
	for pat in '*-squashfs-combined-efi.img.gz' '*-squashfs-combined.img.gz' \
	           '*-ext4-combined-efi.img.gz' '*-ext4-combined.img.gz'; do
		# shellcheck disable=SC2086
		f=$(ls -1 $OUT/$pat 2>/dev/null | head -1)
		[ -n "$f" ] || { note_fail "缺少镜像：$pat"; continue; }
		IMAGES="$IMAGES $f"
		printf '  %-52s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
	done

	# targz 与 rootfs.tar.gz 在配置里关掉了，不该出现。出现了说明配置没生效。
	if ls -1 "$OUT"/*targz* >/dev/null 2>&1; then
		note_fail "出现了 targz 产物，配置里的 TARGZ 关闭没生效"
	fi
	;;
rockchip-armv8)
	# rockchip 目标会**为每个启用的文件系统类型各出一个** sysupgrade 镜像。
	# defconfig 默认把 squashfs 与 ext4 都打开，所以实际是两个：
	#     …-hinlink_ht2-squashfs-sysupgrade.img.gz
	#     …-hinlink_ht2-ext4-sysupgrade.img.gz
	#
	# 这一条是**实测出来的**：最初按「只有一个镜像」写，结果报表里只列出
	# `ls | head -1` 拿到的那一个（ext4，字典序在前），squashfs 那个静默漏掉。
	# 少列一个不会让构建失败，但 Release 说明与附件清单就与事实不符了。
	#
	# 必须点名 hinlink_ht2：这个目录是所有 rockchip 设备共用的，
	# 只数「有几个 sysupgrade.img.gz」会把别人编的镜像也算进来。
	for fs in squashfs ext4; do
		f=$(ls -1 "$OUT"/*hinlink_ht2-${fs}-sysupgrade.img.gz 2>/dev/null | head -1)
		[ -n "$f" ] || { note_fail "缺少 ${fs} 镜像：*hinlink_ht2-${fs}-sysupgrade.img.gz"; continue; }
		IMAGES="$IMAGES $f"
		printf '  %-52s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
	done

	# 别的文件系统的镜像不该出现 —— 出现了说明顶层的 fs-type 配置被改过，
	# 而 Release 附件清单是按上面两种写死的。
	_extra=$(ls -1 "$OUT"/*hinlink_ht2*sysupgrade.img.gz 2>/dev/null \
		| grep -vE -- '-(squashfs|ext4)-sysupgrade\.img\.gz$' || true)
	if [ -n "$_extra" ]; then
		warn "出现了预期之外的镜像："
		printf '  %s\n' $_extra >&2
		note_fail "rockchip 目标只应有 squashfs 与 ext4 两种 sysupgrade 镜像"
	fi

	# 这里不再单独核对 U-Boot：rockchip 的 u-boot-rockchip.bin 不是独立产物，
	# 它由 pine64-img 直接 dd 进 sysupgrade.img 开头的 32768 个扇区
	# （见 target/linux/rockchip/image/Makefile）。所以「镜像存在」这一条
	# 已经隐含了「U-Boot 存在」。真正该在实机上确认的是能不能起来 ——
	# 那属于刷机后的验证，离线核验做不到。
	;;
esac

# ---------------------------------------------------------------------------
# 2. 校验和
# ---------------------------------------------------------------------------
if [ -f "$OUT/sha256sums" ]; then
	say "校验 sha256sums"
	if (cd "$OUT" && sha256sum -c --quiet sha256sums 2>/dev/null); then
		say "全部文件校验和通过"
	else
		# sha256sum -c 会把没进 Release 的 rootfs.img.gz 也算进去，
		# 那些文件可能已被清理，所以只对四个镜像逐个算。
		say "整体校验有出入，改为逐个核对四个镜像"
		for f in $IMAGES; do
			b=$(basename "$f")
			want=$(sed -n "s/^\([0-9a-f]\{64\}\)  \*\?$b$/\1/p" "$OUT/sha256sums")
			[ -n "$want" ] || { note_fail "sha256sums 里没有 $b"; continue; }
			got=$(sha256sum "$f" | cut -d' ' -f1)
			[ "$want" = "$got" ] || note_fail "$b 校验和不符"
		done
		[ "$FAILED" = "0" ] && say "镜像校验和全部通过" || true
	fi
else
	note_fail "没有 sha256sums 文件"
fi

# ---------------------------------------------------------------------------
# 3. 固件里真实的包列表
# ---------------------------------------------------------------------------
MANIFEST=$(ls -1 "$OUT"/*.manifest 2>/dev/null | head -1)
[ -n "$MANIFEST" ] || die "没找到 .manifest，无法核对固件内容"
say "核对固件包列表：$(basename "$MANIFEST")（$(wc -l < "$MANIFEST") 个包）"

# manifest 每行形如 "luci-app-mosdns - 1.7.14-r1"，取第一列做包名集合。
PKGS=$(awk '{print $1}' "$MANIFEST" | sort)

missing=0
for pkg in $MUST_HAVE; do
	printf '%s\n' "$PKGS" | grep -qx "$pkg" || { note_fail "固件里没有：$pkg"; missing=$((missing + 1)); }
done

unwanted=0
for pkg in $MUST_NOT_HAVE; do
	if printf '%s\n' "$PKGS" | grep -qx "$pkg"; then
		note_fail "固件里不该有却有：$pkg"
		unwanted=$((unwanted + 1))
	fi
done

# ---------------------------------------------------------------------------
# 3b. 期望清单是不是过期的？
#
# 本地很容易踩：先跑 build.sh 编了一个组合，之后跑 check-all-combos.sh ——
# 那会把 .generated/expectations.env 覆盖成**最后一个组合**的，而产物还是
# 原来那份。再跑核验就会拿错清单去比对，报出一长串「不该有却有」，
# 看起来像构建错了，其实是清单过期。
#
# 判据刻意做成**单向**的：只看「标志为关、产物里却有对应的代表包」。
# 反过来（标志为开、产物里却没有）仍然是真正的失败，照常报错 ——
# 不能因为怀疑清单过期就放过真问题。
# ---------------------------------------------------------------------------
STALE_HINTS=0
if [ "$WITH_FANCHMWRT" = "0" ] && printf '%s\n' "$PKGS" | grep -qx "kmod-fwx"; then
	STALE_HINTS=$((STALE_HINTS + 1))
fi
if [ "$WITH_ISTOREOS" = "0" ] && printf '%s\n' "$PKGS" | grep -qx "luci-app-quickstart"; then
	STALE_HINTS=$((STALE_HINTS + 1))
fi
if [ "$ENABLE_DOCKER" = "0" ] && printf '%s\n' "$PKGS" | grep -qx "dockerd"; then
	STALE_HINTS=$((STALE_HINTS + 1))
fi

if [ "$STALE_HINTS" -ge 2 ]; then
	printf '\n' >&2
	warn "════════════════════════════════════════════════════════════"
	warn "两个以上「没勾选、产物里却有」的迹象，**期望清单多半是过期的**："
	warn "  .generated/expectations.env 记录的参数是："
	warn "    FanchmWrt=$WITH_FANCHMWRT  iStoreOS=$WITH_ISTOREOS  Docker=$ENABLE_DOCKER"
	warn "  而产物里同时存在多个未勾选特性的包。"
	warn ""
	warn "本地最常见的原因：编完之后又跑了 check-all-combos.sh，"
	warn "它会把 expectations.env 覆盖成最后一个组合的。"
	warn ""
	warn "确认清单与产物是同一个组合，或干脆重跑一次完整构建："
	warn "    WITH_FANCHMWRT=... WITH_ISTOREOS=... ENABLE_DOCKER=... ./build.sh"
	warn "════════════════════════════════════════════════════════════"
fi

# ---------------------------------------------------------------------------
# 4. 主题与首页
#
# 主题不是靠包名就够的 —— uci-defaults 得真的在 rootfs 里，
# 否则刷上去以后是默认主题，用户看到的和勾的不是一回事。
# ---------------------------------------------------------------------------
say "核对主题与首页（期望：$THEME）"
# 判据是**包清单**，不是 rootfs 镜像文件。
#
# 原先这里用 `ls *-rootfs.img` 是否存在来门控，在 x86 上碰巧成立 ——
# x86 会出独立的 rootfs.img.gz。但 rockchip 只出一个 sysupgrade.img.gz
# （rootfs 被拼在里面），于是这条断言会掉进 else 分支「跳过」。
# 那正是这个项目最反对的失败模式：构建全绿、断言静默失效。
#
# manifest 是编译系统自己产出的最终包列表，两个目标都有，直接用它。
if printf '%s\n' "$PKGS" | grep -qx "build-defaults"; then
	say "build-defaults 在固件里（承载管理地址与主题锁定）"
else
	note_fail "build-defaults 不在固件里，管理地址与主题都不会生效"
fi

# 主题包本身也必须真在。
if [ -n "${THEME_PKG:-}" ]; then
	if printf '%s\n' "$PKGS" | grep -qx "$THEME_PKG"; then
		say "主题包在固件里：$THEME_PKG"
	else
		note_fail "主题包不在固件里：$THEME_PKG（勾选与实际不符）"
	fi
fi

# ---------------------------------------------------------------------------
say "报告"
for f in $IMAGES; do
	printf '  %-52s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
printf '  参数：FanchmWrt=%s iStoreOS=%s Docker=%s LAN=%s rootfs=%sMB\n' \
	"$WITH_FANCHMWRT" "$WITH_ISTOREOS" "$ENABLE_DOCKER" "${LAN_IP:-默认}" "$ROOTFS_PARTSIZE"

if [ "$FAILED" = "1" ]; then
	printf '\n' >&2
	die "产物核验未通过。上面的每一条都是「编译过了但东西不对」的证据，
     请修掉再发布 —— 不要让用户当第一个发现的人。"
fi

say "产物核验全部通过"
