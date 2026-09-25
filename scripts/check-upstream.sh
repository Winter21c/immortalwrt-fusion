#!/bin/sh
#
# 检查上游有没有我们该跟的东西。
#
# ===========================================================================
# 三种上游，「会不会自动跟上」的答案不一样
# ===========================================================================
#
#   ImmortalWrt   构建时现拉分支 → **自动跟**，不需要做任何事。
#   iStoreOS 侧   feeds update 拉分支最新 → 已选中包的内容**自动跟**；
#                 但 feed 里新增的、我们没选的包不会自己进来。
#   FanchmWrt     vendored → **不会自动跟**，需要一次人工 review 的同步。
#
# 所以这个脚本的重点是第三类。前两类只做「记录与提示」。
#
# ===========================================================================
# 只把两件事当成「需要行动」
# ===========================================================================
#
#   1. vendor/fanchmwrt 与上游有差异   → 开一个 PR 让人看 diff
#   2. 内核补丁不再能应用（--deep）    → 开 Issue，这是会让所有人构建失败的
#
# feed 的 SHA 只做记录，不算变更 —— 它们本来就是滚动跟随的，
# 每周报一次「变了」等于噪音。
#
# ===========================================================================
# 用法
# ===========================================================================
#
#   ./scripts/check-upstream.sh                  # 检查 + 打印报告
#   ./scripts/check-upstream.sh --report r.md    # 同时写一份 markdown
#   ./scripts/check-upstream.sh --apply-vendor   # 把上游变化写进 vendor/
#   ./scripts/check-upstream.sh --deep           # 额外验证内核补丁仍能应用（慢）
#
# 退出码：
#   0   没有需要行动的变化
#   10  vendor 有更新（该开 PR）
#   20  内核补丁不再能应用（该修，优先级更高）
#
set -eu

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_ROOT
. "$PROJECT_ROOT/scripts/lib.sh"
load_upstreams

APPLY_VENDOR=0
DEEP=0
REPORT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--apply-vendor) APPLY_VENDOR=1 ;;
		--deep) DEEP=1 ;;
		--report) shift; REPORT="${1:-}" ;;
		*) die "未知参数：$1（见脚本头部用法）" ;;
	esac
	shift
done

VENDOR="$PROJECT_ROOT/vendor/fanchmwrt"

# ---------------------------------------------------------------------------
# 我们**故意不收**的东西
#
# 不排除的话，每次检查都会报「上游多了 fullconenat / fullconenat-nft」，
# 然后开一个毫无意义的 PR。假阳性比漏报更消耗人的注意力 ——
# 它会让人开始习惯性忽略这个工作流，那样真出问题时也没人看了。
#
# 每一项都必须写清楚为什么不要。
# ---------------------------------------------------------------------------
#   fullconenat      ImmortalWrt 树内 package/network/utils/ 下已有；
#   fullconenat-nft  同上，且与 ImmortalWrt 那份**逐字节相同**。
#                    两者同名会让构建报重复包，所以不收。
#   README.md        不是包，留着会被构建系统误扫；
#   LICENSE          同上。
VENDOR_SKIP="-x fullconenat -x fullconenat-nft -x README.md -x LICENSE"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

require_cmd curl tar diff

# ---------------------------------------------------------------------------
# 下载上游的两个来源
# ---------------------------------------------------------------------------
fetch() {
	_name="$1"; _repo="$2"; _ref="$3"; _out="$4"
	mkdir -p "$_out"
	curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o "$WORK/$_name.tar.gz" \
		"https://codeload.github.com/$_repo/tar.gz/$_ref" \
		|| die "拉取 $_repo@$_ref 失败 —— ref 是否还有效？"
	tar xzf "$WORK/$_name.tar.gz" -C "$_out" --strip-components=1
}

say "拉取上游：$FANCHMWRT_REPO@$FANCHMWRT_REF"
fetch main "$FANCHMWRT_REPO" "$FANCHMWRT_REF" "$WORK/main"
say "拉取上游：$FANCHMWRT_PACKAGES_REPO@$FANCHMWRT_PACKAGES_REF"
fetch pkgs "$FANCHMWRT_PACKAGES_REPO" "$FANCHMWRT_PACKAGES_REF" "$WORK/pkgs"

[ -d "$WORK/main/package/fcm" ] || die "上游结构变了：$FANCHMWRT_REPO 里找不到 package/fcm"
[ -d "$WORK/pkgs/luci-app-fwx-dashboard" ] || die "上游结构变了：找不到 luci-app-fwx-*"

# 只比较我们真正 vendor 的部分。整棵树对比会刷出几千行无关差异
# （上游是个完整 OpenWrt 树），那种报告没人会看。
diff_report() {
	_label="$1"; _old="$2"; _new="$3"
	if [ ! -d "$_old" ]; then
		printf '### %s\n\nvendor/ 里还没有，属于新增。\n\n' "$_label"
		return
	fi
	# shellcheck disable=SC2086  # VENDOR_SKIP 需要按空格拆成多个 -x
	_n=$(diff -rq $VENDOR_SKIP "$_old" "$_new" 2>/dev/null | wc -l)
	if [ "$_n" -eq 0 ]; then
		printf '### %s\n\n与上游一致。\n\n' "$_label"
		return
	fi
	printf '### %s\n\n有 %s 处差异：\n\n```\n' "$_label" "$_n"
	# shellcheck disable=SC2086
	diff -rq $VENDOR_SKIP "$_old" "$_new" 2>/dev/null | sed 's/^/  /' | head -40
	[ "$_n" -gt 40 ] && printf '  ...（还有 %s 处）\n' "$((_n - 40))"
	printf '```\n\n'
}

# --- 差异统计（用于判断「有没有变化」）---
VENDOR_CHANGED=0
for pair in "$VENDOR/package/fcm:$WORK/main/package/fcm" \
            "$VENDOR/feeds/fanchmwrt:$WORK/pkgs"; do
	_old=${pair%%:*}; _new=${pair#*:}
	[ -d "$_old" ] || { VENDOR_CHANGED=1; continue; }
	# shellcheck disable=SC2086
	[ "$(diff -rq $VENDOR_SKIP "$_old" "$_new" 2>/dev/null | wc -l)" -eq 0 ] || VENDOR_CHANGED=1
done

# ---------------------------------------------------------------------------
# 内核补丁：会让所有人构建失败的那件事
# ---------------------------------------------------------------------------
KERNEL_OK="未检查"
KERNEL_DETAIL=""
if [ "$DEEP" = "1" ]; then
	say "验证内核补丁是否仍能应用到 ImmortalWrt 的当前内核（会下载内核，较慢）"
	if [ -d "$PROJECT_ROOT/openwrt" ]; then
		if (cd "$PROJECT_ROOT/openwrt" && make target/linux/prepare) >"$WORK/kernel.log" 2>&1; then
			KERNEL_OK="✅ 能应用"
			KERNEL_DETAIL="\`make target/linux/prepare\` 成功，内核 + 全部补丁（含 950-fwx）都打上了。"
		else
			KERNEL_OK="❌ 打不上"
			KERNEL_DETAIL="\`make target/linux/prepare\` 失败。多半是 ImmortalWrt 换了内核版本，\
需要重新适配 \`vendor/fanchmwrt/kernel-patches/950-fwx-nf-conn-struct-user-hook.patch\`。"
			cp "$WORK/kernel.log" "$PROJECT_ROOT/.generated/kernel-prepare-failed.log" 2>/dev/null || true
		fi
	else
		KERNEL_OK="跳过"
		KERNEL_DETAIL="没有 openwrt/ 源码树。先跑一次 \`SKIP_BUILD=1 ./build.sh\` 再检查。"
	fi
fi

# ---------------------------------------------------------------------------
# feed 与底座的当前 SHA（只做记录，不算变更）
# ---------------------------------------------------------------------------
# ⚠️ 用临时文件累积，不能直接往变量里追加：
# 「管道 | while」会让 while 跑在子 shell 里，里面改的变量传不出来 ——
# 那样报告里的表格会永远是空的，而且不报错，只是静默少了内容。
FEED_ROWS_FILE="$WORK/feed-rows.txt"
: > "$FEED_ROWS_FILE"
if [ -f "$PROJECT_ROOT/feeds.conf.append" ]; then
	grep -E '^src-' "$PROJECT_ROOT/feeds.conf.append" > "$WORK/feed-lines.txt" || true
	while read -r _type _name _url; do
		[ -n "${_url:-}" ] || continue
		_repo=${_url%%;*}
		_ref=${_url#*;}
		[ "$_ref" = "$_url" ] && _ref=HEAD
		_sha=$(git ls-remote "$_repo" "$_ref" 2>/dev/null | head -1 | cut -f1)
		[ -n "$_sha" ] || _sha="（取不到）"
		printf '| `%s` | `%s` | `%.10s` | feed（自动跟） |\n' \
			"$_name" "$_ref" "$_sha" >> "$FEED_ROWS_FILE"
	done < "$WORK/feed-lines.txt"
fi

BASE_SHA=$(git ls-remote "https://github.com/$IMMORTALWRT_REPO" "$IMMORTALWRT_REF" 2>/dev/null | head -1 | cut -f1)
[ -n "$BASE_SHA" ] || BASE_SHA="（取不到）"

# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------
{
	printf '# 上游跟进检查\n\n'
	printf '底座：ImmortalWrt `%s` @ `%.10s`（构建时现拉，自动跟）\n\n' "$IMMORTALWRT_REF" "$BASE_SHA"
	printf 'FanchmWrt：`%s` @ `%s` ／ `%s` @ `%s`（vendored，需同步）\n\n' \
		"$FANCHMWRT_REPO" "$FANCHMWRT_REF" "$FANCHMWRT_PACKAGES_REPO" "$FANCHMWRT_PACKAGES_REF"

	if [ "$VENDOR_CHANGED" = "1" ]; then
		printf '## ⚠️ FanchmWrt 上游有更新\n\n'
		printf 'vendor/ 里的内容和上游对不上了。下面是按目录分开的差异，\n'
		printf '看完确认没问题的话，跑 `./scripts/check-upstream.sh --apply-vendor` 同步。\n\n'
	else
		printf '## ✅ FanchmWrt vendor 与上游一致\n\n'
	fi
	diff_report 'package/fcm（fwx 内核模块 / fwxd / 主题）' "$VENDOR/package/fcm" "$WORK/main/package/fcm"
	diff_report 'luci-app-fwx-*（17 个 LuCI 应用）' "$VENDOR/feeds/fanchmwrt" "$WORK/pkgs"

	printf '> 比较时已排除我们故意不收的：`fullconenat`、`fullconenat-nft`（ImmortalWrt 树内已有，\n'
	printf '> 同名会让构建报重复包）以及 `README.md` / `LICENSE`（不是包）。\n\n'

	printf '## 内核补丁兼容性\n\n%s\n\n%s\n\n' "$KERNEL_OK" "$KERNEL_DETAIL"

	printf '## feed 与底座当前位置（记录用，不算变更）\n\n'
	printf '| feed | ref | 当前 commit | 消费方式 |\n|---|---|---|---|\n'
	cat "$FEED_ROWS_FILE"
	printf '\n> feed 走分支滚动跟随，构建时 `feeds update` 拉最新，**不需要人工同步**。\n'
	printf '> 这里列出来是为了事后追溯「某个固件是用哪一版 feed 编的」。\n'
} > "$WORK/report.md"

cat "$WORK/report.md"
[ -n "$REPORT" ] && cp "$WORK/report.md" "$REPORT" && say "报告已写入 $REPORT"

# ---------------------------------------------------------------------------
# 应用 vendor 更新
# ---------------------------------------------------------------------------
if [ "$APPLY_VENDOR" = "1" ]; then
	if [ "$VENDOR_CHANGED" = "0" ]; then
		say "vendor/ 与上游一致，无需同步"
	else
		say "把上游内容写入 vendor/fanchmwrt/"
		rm -rf "$VENDOR/package/fcm" "$VENDOR/feeds/fanchmwrt"
		mkdir -p "$VENDOR/package" "$VENDOR/feeds"
		cp -r "$WORK/main/package/fcm" "$VENDOR/package/fcm"
		cp -r "$WORK/pkgs" "$VENDOR/feeds/fanchmwrt"
		rm -f "$VENDOR/feeds/fanchmwrt/README.md" "$VENDOR/feeds/fanchmwrt/LICENSE"
		VENDOR_CHANGED=0
		say "已同步。接下来必须做两件事："
		printf '    1. git diff 看一遍，尤其是 package/fcm/fwx 与 fwxd（内核模块）\n'
		printf '    2. 跑 ./scripts/check-all-combos.sh 确认断言仍然通过\n'
	fi
fi

# ---------------------------------------------------------------------------
# 退出码
# ---------------------------------------------------------------------------
if [ "$KERNEL_OK" = "❌ 打不上" ]; then
	say "结论：内核补丁需要修 —— 这会让所有人的构建失败"
	exit 20
fi
if [ "$VENDOR_CHANGED" = "1" ]; then
	say "结论：FanchmWrt 上游有更新，建议开一个 PR 同步"
	exit 10
fi
say "结论：没有需要行动的变化"
exit 0
