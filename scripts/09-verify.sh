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
. "$(dirname "$0")/lib.sh"

SRC="$PROJECT_ROOT/openwrt"
GEN="$PROJECT_ROOT/.generated"
OUT="$SRC/bin/targets/x86/64"

[ -d "$OUT" ] || die "没找到产物目录：$OUT"
[ -f "$GEN/expectations.env" ] || die "没找到期望清单，请先跑 scripts/04-config.sh"
# shellcheck disable=SC1090
. "$GEN/expectations.env"

FAILED=0
note_fail() { warn "$*"; FAILED=1; }

# ---------------------------------------------------------------------------
# 1. 四个镜像，一个不多一个不少
# ---------------------------------------------------------------------------
say "核对镜像"
IMAGES=""
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
		[ "$FAILED" = "0" ] && say "四个镜像校验和全部通过" || true
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
# 4. 主题与首页
#
# 主题不是靠包名就够的 —— uci-defaults 得真的在 rootfs 里，
# 否则刷上去以后是默认主题，用户看到的和勾的不是一回事。
# ---------------------------------------------------------------------------
say "核对主题与首页（期望：$THEME）"
ROOTFS_IMG=$(ls -1 "$OUT"/*-rootfs.img 2>/dev/null | head -1)
if [ -n "$ROOTFS_IMG" ]; then
	# rootfs 是 squashfs / ext4，挂载需要 root，CI 里代价太大。
	# 退而求其次：确认 uci-defaults 脚本进了包文件清单。
	if printf '%s\n' "$PKGS" | grep -qx "build-defaults"; then
		say "build-defaults 在固件里（承载管理地址与主题锁定）"
	else
		note_fail "build-defaults 不在固件里，管理地址与主题都不会生效"
	fi
else
	say "跳过 rootfs 内容检查（没找到 rootfs 镜像）"
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
