#!/bin/sh
#
# 第 1 步：取 ImmortalWrt 源码。
#
# 用 tarball 而不是 git clone，两个原因：
#   * clone 要拉完整历史；tarball 只有约 13MB，构建并不需要 git 历史
#     （scripts/getver.sh 是 try_version || try_git，version 文件已够用）；
#   * 本机实测 git clone 这个仓库会被 SSL EOF 打断，而 curl 带
#     --retry 与 -C - 可以续传断点，在这种大仓库 + 弱网下稳得多。
#
set -eu
. "$(dirname "$0")/lib.sh"

REF="${IMMORTALWRT_REF:-openwrt-25.12}"
SRC="$PROJECT_ROOT/openwrt"
STAMP="$SRC/.immortalwrt-ref"

require_cmd curl tar

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$REF" ] && [ -f "$SRC/Makefile" ]; then
	say "ImmortalWrt 源码已就位：$REF（要重取就删掉 openwrt/）"
	exit 0
fi

say "下载 ImmortalWrt 源码：$REF"
rm -rf "$SRC"
mkdir -p "$SRC"

TARBALL="$(mktemp -t immortalwrt-XXXXXX.tar.gz)"
# codeload 的 /tar.gz/<ref> 形式对分支名和 tag 都成立。
URL="https://codeload.github.com/immortalwrt/immortalwrt/tar.gz/$REF"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - -o "$TARBALL" "$URL" \
	|| die "下载失败：$URL"

tar xzf "$TARBALL" -C "$SRC" --strip-components=1
rm -f "$TARBALL"

[ -f "$SRC/Makefile" ] || die "解压后没找到 Makefile，源码不完整"
[ -f "$SRC/feeds.conf.default" ] || die "解压后没找到 feeds.conf.default，源码不完整"

printf '%s' "$REF" > "$STAMP"

# 记录真正落到哪个提交，供 Release 说明与事后追溯使用。
# 用 tarball 拿不到 SHA，所以问一次 API；失败不算错 —— 这只是溯源信息，
# 不该因为 GitHub API 限流就让整个构建挂掉。
if command -v curl >/dev/null 2>&1; then
	SHA=$(curl -fsSL "https://api.github.com/repos/immortalwrt/immortalwrt/commits/$REF" 2>/dev/null \
		| grep -o '"sha": *"[0-9a-f]\{40\}"' \
		| sed -n '1s/.*"\([0-9a-f]\{40\}\)".*/\1/p')
	[ -n "$SHA" ] && printf '%s' "$SHA" > "$SRC/.immortalwrt-sha" \
		&& say "对应提交：$SHA" || true
fi

say "ImmortalWrt 源码就绪：$SRC"
