#!/bin/sh
#
# 共用函数与参数规范化。被 build.sh 与 scripts/0x-*.sh 引用。
#
# 这里集中处理一件最容易出错的事：**布尔值的传递**。
#
# GitHub Actions 的 boolean 输入经 ${{ }} 插值到 shell 里会变成字符串
# 'true' / 'false'。而 shell 里 'false' 是**非空字符串、也就是真值**，
# 于是 `[ "$x" ] && ...` 和 `${x:-默认}` 都会给出与事实相反的结果 ——
# 用户明明取消了勾选，固件里却仍然带着那个特性。
# （现有项目就踩过这个坑：任务名里显示「含 Docker」，实际编出来没有。）
#
# 所以规范是：**入口处一次性把一切都转成 1/0**，之后所有脚本只认 1 和 0。
#

set -eu

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# normalize_bool <值> [默认值]
#
# 接受 1/0、true/false、yes/no、on/off（大小写不敏感）。
# 空值取默认值（默认值本身也必须是合法的布尔字面量）。
normalize_bool() {
	_val=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
	[ -n "$_val" ] || _val=$(printf '%s' "${2:-0}" | tr 'A-Z' 'a-z')
	case "$_val" in
		1 | true | yes | on | y) echo 1 ;;
		0 | false | no | off | n) echo 0 ;;
		*) die "无法识别的布尔值 '${1}'（只接受 1/0、true/false、yes/no、on/off）" ;;
	esac
}

# require_cmd <命令名>...
require_cmd() {
	for _c in "$@"; do
		command -v "$_c" >/dev/null 2>&1 || die "缺少命令：$_c"
	done
}

# assert_pkg_on <配置文件> <包名>
assert_pkg_on() {
	grep -q "^CONFIG_PACKAGE_$2=y$" "$1"
}

# assert_pkg_off <配置文件> <包名>
#
# 关闭有两种合法写法：显式的 `# CONFIG_PACKAGE_x is not set`，
# 或者该符号在文件里根本不出现（包没被任何东西拖进来）。
# 只有出现 `CONFIG_PACKAGE_x=y` 才算「没关掉」。
assert_pkg_off() {
	! grep -q "^CONFIG_PACKAGE_$2=y$" "$1"
}
