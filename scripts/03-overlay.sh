#!/bin/sh
#
# 第 3 步：把特性层铺进 ImmortalWrt 源码树。
#
# 这是「可勾选」真正落地的地方 —— 三个特性层各自只在被勾选时才动手：
#
#   FanchmWrt 层  vendor/fanchmwrt/package/fcm/*        -> package/fcm/
#                 vendor/fanchmwrt/feeds/fanchmwrt/*    -> package/fanchmwrt-packages/
#   iStoreOS 层   不需要拷文件，全部来自 feed；
#                 只改一处：quickstart 的菜单序号（见下）
#   Docker 层     vendor/istoreos/package/istoreos-merge -> package/istoreos-merge/
#
# 另外还有一个总在的包：overlay/package/build-defaults（承载管理地址）。
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
[ -d "$SRC" ] || die "没找到 $SRC，请先跑 scripts/01-fetch.sh"

# ---------------------------------------------------------------------------
# 铺包之前先查重名
#
# 这是一个真踩过的坑：vendor/ 里原本带了 fanchmwrt 的 fullconenat 与
# fullconenat-nft，而 ImmortalWrt 树内 package/network/utils/ 下**已经有**
# 这两个包（且 fullconenat-nft 逐字节相同）。两份同名包同时存在，构建系统
# 会报重复包 —— 而报错发生在很后面的阶段，中间隔着几十分钟编译。
#
# 所以在这里提前拦：任何一个要铺进去的包目录名，如果在底座树里已经存在，
# 就直接中止并指名道姓。宁可现在失败，也不要编到一半才炸。
#
# 排除项说明：
#   package/feeds/  是 feeds install 生成的软链接，由 02-feeds.sh 的剪枝管
#   package/fcm、package/fanchmwrt-packages  是我们要铺的目标本身
# ---------------------------------------------------------------------------
guard_no_collision() {
	_src_dir="$1"
	_dest_rel="$2"
	_bad=0
	for _d in "$_src_dir"/*/; do
		[ -d "$_d" ] || continue
		_n=$(basename "$_d")
		_hit=$(find "$SRC/package" -maxdepth 4 -type d -name "$_n" \
			-not -path "$SRC/package/feeds/*" \
			-not -path "$SRC/package/fcm/*" \
			-not -path "$SRC/package/fanchmwrt-packages/*" \
			2>/dev/null | head -1)
		if [ -n "$_hit" ]; then
			warn "重名：$_n 要铺到 $_dest_rel/，但底座树里已有 ${_hit#"$SRC/"}"
			_bad=1
		fi
	done
	[ "$_bad" = "0" ] || die "vendor/ 里的包与 ImmortalWrt 树内重名，拒绝继续。
     同名包只允许存在一个，两个都在会让构建系统报重复包。
     先确认两边是不是同一份东西：
       * 如果内容相同（或底座的更新更全）—— 直接从 vendor/ 里删掉，用底座的；
       * 如果确实需要我们的版本 —— 那也得先把底座那份屏蔽掉，
         并在 scripts/03-overlay.sh 里写清楚为什么。"
}

# ---------------------------------------------------------------------------
# 管理地址的载体：build-defaults
#
# 单独开一个包、而不是塞进 docker-defaults，是因为后者是 Docker 的附属
# （DEPENDS 挂着 dockerd），关掉 Docker 时会被一起移除；
# 而管理地址跟 Docker 没有关系，必须在任何组合下都存在。
# ---------------------------------------------------------------------------
rm -rf "$SRC/package/build-defaults"
cp -r "$PROJECT_ROOT/overlay/package/build-defaults" "$SRC/package/build-defaults"
say "已铺入 build-defaults（承载管理地址）"

# ---------------------------------------------------------------------------
# FanchmWrt 层
# ---------------------------------------------------------------------------
if [ "$WITH_FANCHMWRT" = "1" ]; then
	guard_no_collision "$PROJECT_ROOT/vendor/fanchmwrt/package/fcm" "package/fcm"
	guard_no_collision "$PROJECT_ROOT/vendor/fanchmwrt/feeds/fanchmwrt" "package/fanchmwrt-packages"

	# 内核模块 + 守护进程 + 公共库 + 主题
	#
	# 注意这里**没有** fullconenat / fullconenat-nft：ImmortalWrt 树内
	# package/network/utils/ 下已经有一份，而且 firewall4 的 DEPENDS 里
	# 就挂着 +kmod-nft-fullcone，也就是它本来就一直在。fanchmwrt 自带那两份
	# 是为了补上游没有的缺口，在 ImmortalWrt 上纯属重复。
	rm -rf "$SRC/package/fcm"
	mkdir -p "$SRC/package/fcm"
	cp -r "$PROJECT_ROOT"/vendor/fanchmwrt/package/fcm/. "$SRC/package/fcm/"
	# 17 个 LuCI 应用。上游把它们放在一个叫 fanchmwrt-packages 的 feed 里，
	# 这里改为直接放进 package/ —— 效果一样（构建系统会递归扫描 package/），
	# 但少一个外部 feed，也少一处会腐烂的依赖。
	rm -rf "$SRC/package/fanchmwrt-packages"
	mkdir -p "$SRC/package/fanchmwrt-packages"
	cp -r "$PROJECT_ROOT"/vendor/fanchmwrt/feeds/fanchmwrt/. "$SRC/package/fanchmwrt-packages/"
	# 上游 feed 里的 README/LICENSE 不是包，避免构建系统误扫。
	rm -rf "$SRC/package/fanchmwrt-packages/README.md" \
	       "$SRC/package/fanchmwrt-packages/LICENSE"
	say "已铺入 FanchmWrt 层：$(ls -1 "$SRC/package/fanchmwrt-packages" | wc -l) 个 LuCI 应用 + $(ls -1 "$SRC/package/fcm" | wc -l) 个基础包"

	# -------------------------------------------------------------------
	# 内核补丁：这一层**会改动内核**，必须说清楚
	# -------------------------------------------------------------------
	# fwx 不是普通的包。它的内核模块直接读写 `struct nf_conn`（连接跟踪
	# 结构体）里的一个自定义字段 fwx_data —— 这个字段是 FanchmWrt 自己给
	# 内核加的，ImmortalWrt 的内核里没有。不加这个补丁，编译会在
	#     error: 'struct nf_conn' has no member named 'fwx_data'
	# 上失败，报错指向 fwx_main.c，看不出根因在内核侧。
	#
	# 补丁取自 fanchmwrt 的 target/linux/generic/hack-6.12/，是它对内核的
	# **唯一**改动（对比过整个 hack-6.12 目录，只有这一个文件是它独有的）。
	# 实测能干净地落到 ImmortalWrt 的 6.12.108 上：4 个文件、10 个 hunk，
	# 其中两个 hunk 偏移 43 行，patch 自动处理。
	#
	# 放在 hack-6.12/ 而不是 x86 专属目录：hack-* 是对所有目标生效的，
	# 与上游把 950 编在系列末尾的做法一致。编号 950 在 ImmortalWrt 里是空的。
	FWX_KERNEL_PATCH="950-fwx-nf-conn-struct-user-hook.patch"
	KERNEL_PATCH_DIR="$SRC/target/linux/generic/hack-6.12"
	[ -d "$KERNEL_PATCH_DIR" ] || die "找不到内核补丁目录 $KERNEL_PATCH_DIR —— ImmortalWrt 的内核目录结构变了，需要人工核对。"
	cp "$PROJECT_ROOT/vendor/fanchmwrt/kernel-patches/$FWX_KERNEL_PATCH" "$KERNEL_PATCH_DIR/"
	say "已装内核补丁 $FWX_KERNEL_PATCH（给 struct nf_conn 加 fwx_data 字段）"
	say "  ⚠️ 勾选 FanchmWrt = 内核被改动，这是 fwx 的硬性前提，无法绕过"
else
	rm -rf "$SRC/package/fcm" "$SRC/package/fanchmwrt-packages"
	# 内核补丁也要卸掉：不勾 FanchmWrt 时内核必须是 ImmortalWrt 原样，
	# 否则「不勾就没有 fwx」这句话只对了一半 —— 内核里还留着它的字段。
	rm -f "$SRC/target/linux/generic/hack-6.12/950-fwx-nf-conn-struct-user-hook.patch"
	say "未勾选 FanchmWrt 特性：不铺入 fwx 内核模块与主题，内核保持 ImmortalWrt 原样"
fi

# ---------------------------------------------------------------------------
# Docker 层
# ---------------------------------------------------------------------------
if [ "$ENABLE_DOCKER" = "1" ]; then
	rm -rf "$SRC/package/docker-defaults"
	cp -r "$PROJECT_ROOT/vendor/istoreos/package/docker-defaults" "$SRC/package/docker-defaults"
	say "已铺入 docker-defaults（squashfs 上的数据目录落点、容器日志封顶）"
else
	rm -rf "$SRC/package/docker-defaults"
	say "未勾选 Docker：不铺入 docker-defaults"
fi

# ---------------------------------------------------------------------------
# 打补丁
# ---------------------------------------------------------------------------
# 幂等：正向打不上、反向能打上就认为是「已应用」，跳过而不是报错。
# 两边都打不上才中止 —— 那说明上游形态变了，需要人工看一眼。
apply_patch() {
	_patch="$1"
	_dir="$2"
	[ -f "$_patch" ] || die "补丁不存在：$_patch"
	[ -d "$_dir" ] || { warn "补丁目标不存在，跳过：$_dir"; return 0; }

	if patch -p1 -R --dry-run -s -f -d "$_dir" < "$_patch" >/dev/null 2>&1; then
		say "已应用，跳过：$(basename "$_patch")"
	elif patch -p1 --dry-run -s -f -d "$_dir" < "$_patch" >/dev/null 2>&1; then
		patch -p1 -E -s -d "$_dir" < "$_patch"
		say "已打上：$(basename "$_patch") -> ${_dir#"$SRC/"}"
	else
		die "$(basename "$_patch") 在 ${_dir#"$SRC/"} 上既不匹配正向也不匹配反向。
     多半是 ImmortalWrt 上游改了同一个文件。请人工核对后更新补丁。"
	fi
}

# --- 关于 dockerd：本项目**没有**对它打任何补丁 ------------------------------
#
# 原本计划照搬 iStoreOS 的 dockerd 定制（关掉 docker 自带的 iptables、
# 改由 fw4 统一管、补 172.16.0.0/12 的出网 NAT）。核对 ImmortalWrt 的
# dockerd 之后放弃了这个方案：
#
#   * ImmortalWrt 的 dockerd.init 自带 uciadd/ucidel，会创建 docker firewall
#     zone、把接口加进去，并且在 postinst 里自动调用（第 85-100 行）。
#     它默认 iptables='1'，让 docker 自己管 NAT。
#   * 也就是说两边的做法是**相反的**。把一套能用的机制拆掉换成另一套，
#     收益不明而风险很实在。
#   * 版本也对不上：ImmortalWrt 是 29.6.1，那份定制针对 27.3.1，patch 打不上。
#
# 保留下来的是两件与 dockerd 版本无关、纯粹由镜像布局决定的事，
# 放在 vendor/istoreos/package/docker-defaults 里，不修改上游任何文件。
#
# 这条经验值得记住：**能跟随底座的就跟随底座**，别为了「和某个发行版一致」
# 去替换一个本来就能工作的实现。

# --- quickstart 菜单序号 ----------------------------------------------------
# 上游 luci-app-quickstart 的 order 是 1，也就是 iStoreOS 里「打开就进
# 快速设置页」。但同时勾了 FanchmWrt 时，首页应该是 FanchmWrt 仪表盘，
# 所以把它压到 2。
#
# 只勾 iStoreOS（或都不勾）时保持上游的 1 —— 那正是 iStoreOS 的原样行为，
# 不去动它。这样「主题 + 首页」两件事都随勾选走，且各自用的是各自上游的
# 默认行为，没有我们自己发明的东西。
# 补丁里的路径是 `a/luci/luci-app-quickstart/...`，`-p1` 剥掉 `a/` 之后
# 剩下 `luci/luci-app-quickstart/...`，所以 -d 要给**feed 根目录**
# （feeds/nas_luci），不是 feeds/nas_luci/luci —— 后者会让路径变成
# feeds/nas_luci/luci/luci/luci-app-quickstart/...，patch 报「既不匹配正向
# 也不匹配反向」，看起来像上游改了文件，其实是层级给错了。
QUICKSTART_FEED="$SRC/feeds/nas_luci"
if [ "$WITH_ISTOREOS" = "1" ] && [ "$WITH_FANCHMWRT" = "1" ]; then
	apply_patch "$PROJECT_ROOT/patches/0002-quickstart-menu-order.patch" \
		"$QUICKSTART_FEED"
	say "QuickStart 菜单序号压到 2（首页让位给 FanchmWrt 仪表盘）"
else
	# 反向还原：上一次构建可能压过，避免同一个工作区里反复切换时残留。
	if [ -d "$QUICKSTART_FEED" ] \
		&& patch -p1 -R --dry-run -s -f -d "$QUICKSTART_FEED" \
			< "$PROJECT_ROOT/patches/0002-quickstart-menu-order.patch" >/dev/null 2>&1; then
		patch -p1 -R -s -d "$QUICKSTART_FEED" \
			< "$PROJECT_ROOT/patches/0002-quickstart-menu-order.patch"
		say "QuickStart 菜单序号还原为 1（首页是 QuickStart）"
	else
		say "QuickStart 菜单序号保持上游的 1（首页是 QuickStart）"
	fi
fi

# --- v2ray-geodata 改用滚动地址 ---------------------------------------------
#
# 这个包提供 geoip / geosite 规则数据，而 luci-app-mosdns **依赖它**
# （LUCI_DEPENDS 里有 +v2ray-geoip +v2ray-geosite），所以不能拿掉。
#
# 问题是它的数据源是「滚动发布 + 定期删旧 tag」：
#   v2fly/geoip                   保留约一年
#   v2fly/domain-list-community   只保留约三个月
# feed 里 pin 死的版本到点就 404，构建直接失败。而失败现象是「编译不过」，
# 原因却是「一个规则数据包没了」，两者隔得很远，很难查。
#
# 改成 releases/latest/download/ 之后地址永不失效。
#
# ---------------------------------------------------------------------------
# 为什么这里用「带校验的重写」而不是一个 .patch 文件
# ---------------------------------------------------------------------------
# 上一版就是个 patch，而它正好死在「上游改了这个文件」上 ——
# ImmortalWrt 更新了 pin 的版本号和 HASH，补丁上下文对不上，构建直接停。
# 一个会在上游改文件时失效的补丁，等于给未来埋一颗定时炸弹。
#
# 所以改成重写 + 事后校验：
#   * 重写用 sed，只认「结构」不认「具体版本号」，上游更新版本号不影响它；
#   * 重写完**逐项校验结果**，结构真变了就明确报错中止 ——
#     宁可在这里失败，也不要产出一个看起来正常、实际下错数据的 Makefile。
#
# 代价：这三个数据文件不再校验哈希（HASH:=skip），内容随上游滚动。
# 它们只是 DNS 分流规则数据，不参与编译，也不影响其它包。
# 版本号固定为 1 而不是 latest：apk 只接受数字开头的版本号。
GD_MK="$SRC/feeds/packages/net/v2ray-geodata/Makefile"
if [ -f "$GD_MK" ]; then
	sed -i \
		-e 's|^GEOIP_VER:=.*|GEOIP_VER:=1|' \
		-e 's|^GEOSITE_VER:=.*|GEOSITE_VER:=1|' \
		-e 's|^GEOSITE_IRAN_VER:=.*|GEOSITE_IRAN_VER:=1|' \
		-e 's|^GEOIP_FILE:=.*|GEOIP_FILE:=geoip.dat.rolling|' \
		-e 's|^GEOSITE_FILE:=.*|GEOSITE_FILE:=dlc.dat.rolling|' \
		-e 's|^GEOSITE_IRAN_FILE:=.*|GEOSITE_IRAN_FILE:=iran.dat.rolling|' \
		-e 's|releases/download/\$(GEOIP_VER)/|releases/latest/download/|' \
		-e 's|releases/download/\$(GEOSITE_VER)/|releases/latest/download/|' \
		-e 's|releases/download/\$(GEOSITE_IRAN_VER)/|releases/latest/download/|' \
		-e 's|^  HASH:=.*|  HASH:=skip|' \
		"$GD_MK"

	# 逐项校验。这里失败是好事：说明上游把 Makefile 重构了，
	# 需要人看一眼再决定怎么改，而不是让构建带着半截改动跑下去。
	gd_ok=1
	[ "$(grep -c 'releases/latest/download/' "$GD_MK")" -eq 3 ] || gd_ok=0
	[ "$(grep -c '^  HASH:=skip$' "$GD_MK")" -eq 3 ] || gd_ok=0
	grep -q 'releases/download/\$(' "$GD_MK" && gd_ok=0 || true
	grep -qE '^(GEOIP|GEOSITE|GEOSITE_IRAN)_VER:=1$' "$GD_MK" || gd_ok=0

	if [ "$gd_ok" != "1" ]; then
		die "v2ray-geodata 的滚动地址重写结果不符合预期，已中止。
     期望：3 个 releases/latest/download/、3 个 HASH:=skip、3 个 *_VER:=1，
           且不残留 releases/download/\$(...)/。
     实测：
$(grep -nE 'VER:=|HASH:=|releases/' "$GD_MK" | sed 's/^/       /')
     多半是 ImmortalWrt 重构了这个 Makefile。人工核对后更新本段逻辑。"
	fi
	say "v2ray-geodata 已改为滚动地址（geoip / geosite / iran，共 3 个数据源）"
else
	warn "没找到 feeds/packages/net/v2ray-geodata/Makefile，跳过滚动地址改写"
	warn "如果它被移到了别处，luci-app-mosdns 的依赖会在 defconfig 阶段报出来。"
fi

say "特性层铺装完成"
