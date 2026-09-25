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

# ---------------------------------------------------------------------------
# load_upstreams
#
# 读 upstreams.conf，把里面的上游仓库与 ref 变成环境变量。
#
# **只设置尚未设置的变量** —— 这样优先级是：
#     环境变量（CI 输入 / 命令行） > upstreams.conf > 调用处的兜底
# 显式指定的永远赢，文件只提供默认值。
#
# 用 eval 而不是 `. file` 的原因是：source 会无条件覆盖已设置的变量，
# 那样环境变量就压不过文件了。
# ---------------------------------------------------------------------------
load_upstreams() {
	_conf="${PROJECT_ROOT:?PROJECT_ROOT 未设置}/upstreams.conf"
	[ -f "$_conf" ] || die "找不到上游清单：$_conf"

	while IFS= read -r _line || [ -n "$_line" ]; do
		# 去注释与空行
		case "$_line" in
			'' | '#'*) continue ;;
		esac
		_k="${_line%%=*}"
		_v="${_line#*=}"
		# 变量名只允许字母数字下划线，挡掉一切奇怪的输入
		case "$_k" in
			'' | *[!A-Za-z0-9_]*) continue ;;
		esac
		eval "_cur=\${$_k:-}"
		[ -n "$_cur" ] || eval "$_k=\$_v"
	done < "$_conf"

	# 导出，让子脚本（01-fetch.sh 等）也能读到
	export IMMORTALWRT_REPO IMMORTALWRT_REF
	export FANCHMWRT_REPO FANCHMWRT_REF
	export FANCHMWRT_PACKAGES_REPO FANCHMWRT_PACKAGES_REF
}

# acquire_lock
#
# 独占锁：同一个工作区同时只能有一个构建在跑。
#
# 为什么需要：两个构建共用一个 openwrt/ 树，而 .config、package/、tmp/、dl/
# 全是共享的。交叉写入产出的错误极难解释 —— 典型现象是「参数明明选了不含
# Docker，编出来的固件里却有 Docker」，因为另一个进程把 tmp/ 里的元数据换了。
#
# 用 mkdir 而不是 flock：mkdir 在所有 POSIX 系统上都是原子的，
# 而且锁目录里能留一个 pid 文件，排查时知道是谁占着。
acquire_lock() {
	# 用固定的全局名，不用 _lock：trap 是在脚本退出时才展开这个变量的，
	# 中间任何一个函数用到同名变量都会把锁指到别处去。
	BUILD_LOCK_DIR="${PROJECT_ROOT:?PROJECT_ROOT 未设置}/.build-lock"
	if ! mkdir "$BUILD_LOCK_DIR" 2>/dev/null; then
		_owner=$(cat "$BUILD_LOCK_DIR/pid" 2>/dev/null || echo "未知")
		die "已有构建在运行（PID $_owner）。
     锁目录：$BUILD_LOCK_DIR

     同一个工作区同时只能跑一个构建 —— 两个进程共用 openwrt/ 树会互相踩，
     而产出的错误往往指向别处，很难查。

     确认确实没有构建在跑（比如上次异常退出没清掉锁）的话：
         rm -rf '$BUILD_LOCK_DIR'
     然后再试。"
	fi
	printf '%s' "$$" > "$BUILD_LOCK_DIR/pid"
	trap 'rm -rf "$BUILD_LOCK_DIR"' EXIT INT TERM HUP
}
