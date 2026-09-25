#!/bin/sh
#
# 把 vendor/fanchmwrt/ 同步到上游的最新状态。
#
# ===========================================================================
# 这不是构建流程的一部分 —— 它是给人手动跑的
# ===========================================================================
#
# 构建**从不**访问 fanchmwrt 的仓库，用的永远是仓库里 vendor/ 下的那份。
# 好处写在 docs/BUILD-NOTES.md 第 3 节：构建不受上游 force-push / 删分支
# 影响，内核模块需要为 ImmortalWrt 适配时也能就地改。
#
# 代价是上游更新不会自动流进来。这个脚本就是补这个代价的。
#
# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
#
#   ./scripts/sync-vendor.sh              # 同步到上游默认分支最新
#   ./scripts/sync-vendor.sh <ref>        # 同步到指定分支 / tag / commit
#
# 脚本只**下载并暂存**到临时目录，然后打印差异摘要，最后问你要不要应用。
# 不会静默覆盖 vendor/ —— 上游改了 fwx 的话，那是一定要看 diff 的。
#
set -eu
. "$(dirname "$0")/lib.sh"

REF="${1:-fanchmwrt-25.12.4}"
VENDOR="$PROJECT_ROOT/vendor/fanchmwrt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

require_cmd curl tar

say "拉取 fanchmwrt @ $REF（主仓库：fwx 内核模块 / fwxd / 主题）"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o "$TMP/main.tar.gz" \
	"https://codeload.github.com/fanchmwrt/fanchmwrt/tar.gz/$REF" \
	|| die "拉取失败。ref 是否有效？分支名形如 fanchmwrt-25.12.4"
mkdir -p "$TMP/main"
tar xzf "$TMP/main.tar.gz" -C "$TMP/main" --strip-components=1

say "拉取 fanchmwrt/fanchmwrt-packages @ master（17 个 luci-app-fwx-*）"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o "$TMP/pkgs.tar.gz" \
	"https://codeload.github.com/fanchmwrt/fanchmwrt-packages/tar.gz/master" \
	|| die "拉取 fanchmwrt-packages 失败"
mkdir -p "$TMP/pkgs"
tar xzf "$TMP/pkgs.tar.gz" -C "$TMP/pkgs" --strip-components=1

[ -d "$TMP/main/package/fcm" ] || die "上游结构变了：找不到 package/fcm"
[ -d "$TMP/pkgs/luci-app-fwx-dashboard" ] || die "上游结构变了：找不到 luci-app-fwx-*"

# 记录来源，便于日后追溯「这份 vendor 是从哪来的」。
cat > "$TMP/SOURCE" <<EOF
# vendor/fanchmwrt 的来源
#
# 由 scripts/sync-vendor.sh 记录，不要手工编辑。
#
# 主仓库    https://github.com/fanchmwrt/fanchmwrt  @ $REF
# 应用 feed https://github.com/fanchmwrt/fanchmwrt-packages  @ master
#
# 收录范围：
#   package/fcm/*            fwx 内核模块、fwxd、libfwx_common、
#                            fullconenat(-nft)、luci-theme-fanchmwrt
#   luci-app-fwx-*/          17 个 LuCI 应用（上游在 fanchmwrt-packages feed 里）
#
# 授权：见 README「授权与声明」。转载固件时必须附上
#       https://github.com/fanchmwrt/fanchmwrt
EOF

say "差异摘要（vendor/ 现状 vs 上游）"
for pair in \
	"$VENDOR/package/fcm:$TMP/main/package/fcm:fcm" \
	"$VENDOR/feeds/fanchmwrt:$TMP/pkgs:luci-app-fwx-*"
do
	old=${pair%%:*}; rest=${pair#*:}
	new=${rest%%:*}; label=${rest#*:}
	if [ ! -d "$old" ]; then
		printf '  %-22s vendor/ 里还没有，将新增\n' "$label"
		continue
	fi
	n=$(diff -rq "$old" "$new" 2>/dev/null | wc -l)
	if [ "$n" -eq 0 ]; then
		printf '  %-22s 无变化\n' "$label"
	else
		printf '  %-22s 有 %s 处差异：\n' "$label" "$n"
		diff -rq "$old" "$new" 2>/dev/null | sed 's/^/      /' | head -30
		[ "$n" -gt 30 ] && printf '      ...（还有 %s 处）\n' "$((n - 30))"
	fi
done

printf '\n'
printf '要把上面的上游版本覆盖到 vendor/ 吗？\n'
printf '上游改了 fwx 的话，那是一定要看 diff 的 —— 尤其是 kmod-fwx。\n'
printf '确认请输入 yes：'
read -r ans
[ "$ans" = "yes" ] || { say "已取消，vendor/ 未改动"; exit 0; }

rm -rf "$VENDOR/package/fcm" "$VENDOR/feeds/fanchmwrt"
mkdir -p "$VENDOR/package" "$VENDOR/feeds"
cp -r "$TMP/main/package/fcm" "$VENDOR/package/fcm"
cp -r "$TMP/pkgs" "$VENDOR/feeds/fanchmwrt"
rm -f "$VENDOR/feeds/fanchmwrt/README.md" "$VENDOR/feeds/fanchmwrt/LICENSE"
cp "$TMP/SOURCE" "$VENDOR/SOURCE"

say "vendor/ 已更新。接下来请："
printf '    1. git diff 看一遍改动，尤其是 vendor/fanchmwrt/package/fcm/fwx 与 fwxd\n'
printf '    2. 至少跑一次 SKIP_BUILD=1 ./build.sh 确认断言仍然通过\n'
printf '    3. 有条件的话编一次，确认 kmod-fwx 仍能编到 ImmortalWrt 的内核上\n'
