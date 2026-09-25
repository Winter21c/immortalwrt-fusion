#!/bin/sh
#
# 第 2 步：配置并安装 feed。
#
# 做三件事：
#   1. 把 feeds.conf.append 追加到 ImmortalWrt 自带的 feeds.conf.default 后面
#      （istore 只在勾选 iStoreOS 特性时追加）；
#   2. feeds update -a；
#   3. 删掉与 ImmortalWrt 自带包撞名的那一份（mosdns），再 feeds install -a。
#
set -eu
. "$(dirname "$0")/lib.sh"

SRC="$PROJECT_ROOT/openwrt"
PRISTINE="$SRC/feeds.conf.immortalwrt"

[ -d "$SRC" ] || die "没找到 $SRC，请先跑 scripts/01-fetch.sh"

# --- 1. 生成 feeds.conf.default --------------------------------------------
# 第一次运行时把 ImmortalWrt 的原件留一份底，之后每次都从它重新拼，
# 这样反复运行不会把 append 内容叠加多次。
[ -f "$PRISTINE" ] || cp "$SRC/feeds.conf.default" "$PRISTINE"
cp "$PRISTINE" "$SRC/feeds.conf.default"

# 兜底过滤：去掉「只有单个 # 的行」。
#
# scripts/feeds 的解析器是 s/#.+$// 再判空，而 `#.+` 要求 # 后面至少还有一个
# 字符 —— 光秃秃一个 `#` 不会被剥掉，会原样进语法检查、报
# "Syntax error in feeds.conf.default, line N"。那个报错的行号指向一行注释，
# 极难联想，所以在这里直接拦掉。
strip_bare_hash() {
	sed '/^#[[:space:]]*$/d'
}

{
	printf '\n'
	printf '# ===== 以下由 immortalwrt-fusion 追加，勿手工编辑 =====\n'
	strip_bare_hash < "$PROJECT_ROOT/feeds.conf.append"
	if [ "$WITH_ISTOREOS" = "1" ]; then
		printf '# iStore 应用商店：只在勾选 iStoreOS 特性时才有意义\n'
		printf 'src-git istore https://github.com/linkease/istore.git;main\n'
	fi
} >> "$SRC/feeds.conf.default"

say "本次启用的 feed："
sed -n 's/^src-[a-z]* \([a-z_0-9]*\).*/  \1/p' "$SRC/feeds.conf.default" | tr '\n' ' '
printf '\n'

# --- 2. update --------------------------------------------------------------
cd "$SRC"
if [ "${SKIP_FEEDS_UPDATE:-0}" = "1" ]; then
	say "SKIP_FEEDS_UPDATE=1，跳过 feeds update"
else
	say "feeds update -a"
	./scripts/feeds update -a
fi

# --- 3. 剪掉与底座撞名的第三方包 -------------------------------------------
#
# **第三方 feed 里的包不允许顶掉底座。**
#
# 两个原因：
#   * 底座（ImmortalWrt 自带的 5 个 feed + 树内 package/）里的版本，是与
#     它自己的构建系统、内核、LuCI 配套的；第三方那份是给别的底座准备的，
#     拿过来顶掉只会引入难以定位的问题。
#   * 同名包只允许存在一个，两边都在会让构建系统报重复包。
#
# 已知的两个具体例子：
#   * sbwml/luci-app-mosdns 同时提供二进制 mosdns 与界面 luci-app-mosdns，
#     而底座已有 net/mosdns —— 二进制用底座的（跟着底座走、更好维护），
#     界面用 sbwml 的（底座没有 mosdns 的 LuCI 应用）。
#   * linkease/openwrt-apps 里有 luci-app-cpufreq，底座 package/emortal
#     与 feeds/luci 里各有一份，三处重名。
#
# 规则写成通用的而不是逐个点名：上游哪天新增了重名包，也是自动让位给底座，
# 而不是在 defconfig 阶段以很难懂的形式炸掉。
say "剪掉第三方 feed 里与底座撞名的包"
BASE_LIST=$(mktemp)
{
	for d in packages luci routing telephony video; do
		[ -d "feeds/$d" ] || continue
		find "feeds/$d" -mindepth 1 -maxdepth 4 -name Makefile -printf '%h\n' 2>/dev/null \
			| xargs -r -n1 basename
	done
	find package -mindepth 1 -maxdepth 3 -name Makefile -not -path 'package/feeds/*' \
		-printf '%h\n' 2>/dev/null | xargs -r -n1 basename
} | sort -u > "$BASE_LIST"

PRUNED_ANY=0
for f in mosdns nas nas_luci istoreapps istore; do
	[ -d "feeds/$f" ] || continue
	# 先收集再处理：find 一边删一边遍历同一个目录树不可靠。
	PKG_DIRS=$(find "feeds/$f" -mindepth 1 -maxdepth 4 -name Makefile -printf '%h\n' 2>/dev/null)
	for d in $PKG_DIRS; do
		n=$(basename "$d")
		# 只把**真正定义包的**目录当成包目录。像 luci-lib-mac-vendor/src
		# 这种子目录里也有 Makefile，但它是编译单元不是包，剪掉会把包弄坏。
		grep -qE '(BuildPackage|KernelPackage|define +Package/)' "$d/Makefile" 2>/dev/null || continue
		grep -qx "$n" "$BASE_LIST" || continue
		rm -rf "$d"
		printf '  剪掉 [%s] %s\n' "$f" "$n"
		PRUNED_ANY=1
	done
done
rm -f "$BASE_LIST"

# 上一轮 install 留下的断链也要清掉。
#
# package/feeds/<feed>/<pkg> 是指向 feeds/<feed>/.../<pkg> 的软链接。
# 剪掉源目录之后，这些链接就成了断链，而断链会在构建系统扫 package/ 时
# 以 "No such file or directory" 的形式报出来，指向一个看起来存在、
# 实际打不开的路径。只在重复运行时才会出现，最难查。
for f in mosdns nas nas_luci istoreapps istore; do
	[ -d "package/feeds/$f" ] || continue
	for link in "package/feeds/$f"/*; do
		[ -e "$link" ] || { rm -rf "$link"; printf '  清掉断链 %s\n' "$link"; }
	done
done

# 剪完之后**必须重建这几个 feed 的索引**。
#
# feeds install 是照 feeds/<name>.index 装的，不是现扫目录。索引还是剪枝前
# 生成的那一份，install 就会去装已经被删掉的路径 —— 报错信息会指向一个
# 根本不存在的目录，很难联想到是「索引没更新」。
#
# `-i` 是「只重建索引、不拉 git」，正合适；顺带把 .tmp 清掉，
# 避免残留的逐包信息混进新索引。
if [ "$PRUNED_ANY" = "1" ]; then
	for f in mosdns nas nas_luci istoreapps istore; do
		[ -d "feeds/$f" ] || continue
		rm -rf "feeds/$f.tmp" "feeds/$f.index" "feeds/$f.targetindex"
	done
	say "重建被剪枝 feed 的索引"
	./scripts/feeds update -i mosdns nas nas_luci istoreapps istore
fi

say "feeds install -a"
./scripts/feeds install -a

# --- 收尾自检 ---------------------------------------------------------------
# 撞名如果没解除干净，会在 make defconfig 阶段以很难懂的形式报出来。
# 这里提前扫一遍，把「同名包出现在多个 feed 里」直接点名。
say "检查 feed 之间的同名包"
DUP=$(find feeds -mindepth 2 -maxdepth 4 -name Makefile -not -path '*/.git/*' -printf '%h\n' 2>/dev/null \
	| xargs -r -n1 basename | sort | uniq -d)
if [ -n "$DUP" ]; then
	warn "以下包名在多个 feed 目录里重复出现（可能引发重复包错误）："
	printf '  %s\n' $DUP >&2
	warn "如果构建在 defconfig 或 package/compile 阶段报重复包，从这里查起。"
fi

say "feed 准备完成"
