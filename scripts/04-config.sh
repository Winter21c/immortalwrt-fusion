#!/bin/sh
#
# 第 4 步：按勾选拼出 .config，跑 defconfig，然后逐项核对。
#
# 这里是「可勾选」这件事的收口处。设计上有三条硬规矩：
#
#   1. **不用 include/target.mk 的 DEFAULT_PACKAGES，全部走 .config。**
#      包清单写在配置文件里，勾了哪个层就拼哪个文件，一眼能看出这个固件
#      是怎么来的。改 target.mk 是隐式的，隔一层看不见。
#
#   2. **每个组合都要双向断言。**
#      只断言「该有的在」是不够的：漏装会报错，但**多装不会**。
#      你明确说了不要 ddns / hd-idle / wol / smb 界面，那就必须同时断言
#      「这些东西确实不在」，否则某天上游把它们拖进来，构建照样绿。
#
#   3. **断言失败就中止，不出固件。**
#      一个缺了主题或混进 Samba 界面的固件，比一次失败的构建更浪费时间。
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
[ -d "$SRC" ] || die "没找到 $SRC，请先跑 scripts/01-fetch.sh"

# --- 参数校验 ---------------------------------------------------------------
case "$ROOTFS_PARTSIZE" in
	'' | *[!0-9]*) die "固件大小必须是整数（MB），收到：'$ROOTFS_PARTSIZE'" ;;
esac
[ "$ROOTFS_PARTSIZE" -ge 128 ] && [ "$ROOTFS_PARTSIZE" -le 8192 ] \
	|| die "固件大小必须落在 128~8192 MB，收到：$ROOTFS_PARTSIZE"

case "$LAN_IP" in
	'') : ;;
	*[!0-9./]*) die "管理地址只允许数字、点、斜杠，收到：'$LAN_IP'" ;;
esac

# ---------------------------------------------------------------------------
# 前缀长度必须显式带上，没写就补 /24
#
# 这一条是真机验证（QEMU）抓出来的 —— 编译、断言、离线翻镜像**都看不出来**。
#
# OpenWrt 的 config_generate 生成 lan 时写的是
#     add_list network.lan.ipaddr='192.168.1.1/24'
# 前缀长度是写在 ipaddr 里的，**没有单独的 netmask 选项**
# （见 package/base-files/files/bin/config_generate 第 170-177 行）。
#
# 而我们为了改管理地址必须先 delete 再 add_list（config_generate 把它生成成了
# list，不 delete 会同时留下两个地址）。这时只写 '192.168.1.1' 的话前缀就丢了，
# netifd 按 /32 配置，结果是：
#
#     br-lan: inet 192.168.1.1/32 brd 255.255.255.255
#     ip route: 只有 docker0 那条，**没有 192.168.1.0/24**
#
# 也就是说路由器连不上局域网里的任何设备，LuCI 也打不开 —— 而界面看起来
# 一切正常，配置里也写着 192.168.1.1。这个 bug 只有真启动一次才会暴露。
#
# /24 是 OpenWrt 的默认值（config_generate 里 netmask 默认 255.255.255.0）。
# 用户显式写了前缀（如 10.0.0.1/16）就原样尊重。
# ---------------------------------------------------------------------------
case "$LAN_IP" in
	'') : ;;
	*/*) ;;
	*) LAN_IP="$LAN_IP/24" ;;
esac

mkdir -p "$GEN"

# ---------------------------------------------------------------------------
# enumerate_fanchmwrt_pkgs
#
# 从 vendor/fanchmwrt/ 枚举这一层实际提供的包。输出每行一个包名。
#
# 为什么枚举而不是写死清单：上游新增一个 luci-app-fwx-* 时，写死的清单会
# **静默地**把它漏掉 —— 构建成功、断言全过、固件里却没有新功能。这种漏掉
# 比构建失败更糟，因为没有任何信号。枚举之后「vendor 里有什么就编什么」。
#
# 之所以安全：vendor/ 的内容不会自己变，上游更新要走 upstream-watch 开的
# PR、人工看过 diff 才合并。所以自动跟上不等于自动引入没看过的东西。
#
# 唯一不枚举的是 fwx 内核模块：它是 KernelPackage/fwx，产出的包名是
# kmod-fwx，与源码目录名不同，写死在 config/20-fanchmwrt.config 里。
# ---------------------------------------------------------------------------
enumerate_fanchmwrt_pkgs() {
	for _d in "$PROJECT_ROOT"/vendor/fanchmwrt/package/fcm/*/ \
	          "$PROJECT_ROOT"/vendor/fanchmwrt/feeds/fanchmwrt/*/; do
		[ -f "$_d/Makefile" ] || continue
		# tr 里必须带 \r：上游有 7 个 luci-app-fwx-* 的 Makefile 是 CRLF 行尾，
		# PKG_NAME 取出来会带一个回车。不删掉的话写进 .config 就是
		#     CONFIG_PACKAGE_luci-app-fwx-app-center\r=y
		# kconfig 认不出这个符号，**静默丢弃** —— 构建成功、固件里却没有那几个
		# 应用。这个坑真踩过：17 个应用丢了 7 个，只有断言把「该有却没有」
		# 报出来才被发现。
		_n=$(sed -n 's/^PKG_NAME:=//p' "$_d/Makefile" 2>/dev/null | head -1 | tr -d ' \t\r\n')
		# luci.mk 建包的主题/应用可能没有 PKG_NAME，包名就等于目录名。
		[ -n "$_n" ] || _n=$(basename "$_d")
		# 内核模块由 config 片段显式声明，这里跳过，免得重复。
		[ "$_n" = "fwx" ] && continue

		# 格式哨兵：包名只允许字母数字与 . _ + -
		# 上面那个 CR 的教训是「带进来的脏字符会导致静默丢弃」，所以这里
		# 宁可当场失败，也不要把一个 kconfig 认不出的名字写进配置。
		case "$_n" in
			*[!A-Za-z0-9._+-]*)
				die "从 $_d 解析出的包名含有非法字符，已中止：
     '$_n'
     多半是 Makefile 的行尾符或空白没清干净。修 enumerate_fanchmwrt_pkgs 里的 tr。" ;;
		esac
		printf '%s\n' "$_n"
	done | sort -u
}

# ---------------------------------------------------------------------------
# 1. 拼 .config
# ---------------------------------------------------------------------------
say "生成 .config（FanchmWrt=$WITH_FANCHMWRT iStoreOS=$WITH_ISTOREOS Docker=$ENABLE_DOCKER）"

{
	printf '# 由 scripts/04-config.sh 生成 —— 不要手工编辑，下次构建会覆盖。\n'
	printf '# 本次参数：FanchmWrt=%s iStoreOS=%s Docker=%s LAN=%s rootfs=%sMB\n\n' \
		"$WITH_FANCHMWRT" "$WITH_ISTOREOS" "$ENABLE_DOCKER" "${LAN_IP:-默认}" "$ROOTFS_PARTSIZE"
	cat "$PROJECT_ROOT/config/00-target.config"
	printf '\n# 固件大小：用户在 Actions 里选的，覆盖 00-target.config 里的默认值\n'
	printf 'CONFIG_TARGET_ROOTFS_PARTSIZE=%s\n\n' "$ROOTFS_PARTSIZE"
	cat "$PROJECT_ROOT/config/10-base.config"

	if [ "$WITH_FANCHMWRT" = "1" ]; then
		printf '\n'
		cat "$PROJECT_ROOT/config/20-fanchmwrt.config"
		printf '\n# --- 以下由 scripts/04-config.sh 从 vendor/fanchmwrt/ 枚举生成 ---\n'
		printf '# 上游新增应用会自动出现在这里，不需要改任何配置文件。\n'
		for _p in $(enumerate_fanchmwrt_pkgs); do
			printf 'CONFIG_PACKAGE_%s=y\n' "$_p"
		done
	fi

	if [ "$WITH_ISTOREOS" = "1" ]; then
		printf '\n'
		if [ "$WITH_FANCHMWRT" = "1" ]; then
			# 主题规则：勾了 FanchmWrt 就用 FanchmWrt 主题。
			#
			# 做法是：先把 iStoreOS 层里那两行 argon 摘掉，再显式关掉它们。
			# 不是「删干净」，是留下痕迹 —— 看 .config 的人能直接读到这个决定。
			#
			# 注意关闭行必须**干干净净**地写 `# CONFIG_X is not set`，
			# 后面不能跟中文说明：kconfig 是按这个固定串去匹配的，
			# 多一个尾注就可能整行被当成普通注释忽略掉。
			# 说明只能另起一行写。
			grep -v -e '^CONFIG_PACKAGE_luci-theme-argon=' \
			        -e '^CONFIG_PACKAGE_luci-app-argon-config=' \
				"$PROJECT_ROOT/config/30-istoreos.config" || true
			cat <<-'EOF'

				# 勾了 FanchmWrt，主题让位给 luci-theme-fanchmwrt。
				# 两个主题都装的话，各自的 uci-defaults 都会去抢
				# luci.main.mediaurlbase，谁后跑谁赢 —— 那种不确定性不该留在固件里。
				# CONFIG_PACKAGE_luci-theme-argon is not set
				# CONFIG_PACKAGE_luci-app-argon-config is not set
			EOF
		else
			cat "$PROJECT_ROOT/config/30-istoreos.config"
		fi
	fi

	if [ "$ENABLE_DOCKER" = "1" ]; then
		printf '\n'
		cat "$PROJECT_ROOT/config/40-docker.config"
	fi
} > "$SRC/.config"

cp "$SRC/.config" "$GEN/config.raw"

# ---------------------------------------------------------------------------
# 2. 生成 build-defaults 要装进固件的文件
#
# 三样东西：
#   /etc/uci-defaults/25_lan_ip            首次启动套用管理地址
#   /etc/uci-defaults/99_build-defaults-theme  首次启动锁定主题
#   /etc/build-options                     把本次参数留在设备上，便于排查
# ---------------------------------------------------------------------------
BD="$SRC/package/build-defaults/files"
rm -rf "$BD"
mkdir -p "$BD/etc/uci-defaults"

if [ -n "$LAN_IP" ]; then
	# 为什么用 uci-defaults 而不是改 bin/config_generate：
	# config_generate 是首次启动时才生成 /etc/config/network 的，uci-defaults
	# 紧随其后、且在 network 服务启动之前执行，所以在这里改既生效又不必去动
	# base-files 的核心脚本。
	#
	# config_generate 把 network.lan.ipaddr 生成成了 list，所以必须先 delete
	# 再 add_list，否则会同时留下两个地址。
	cat > "$BD/etc/uci-defaults/25_lan_ip" <<EOF
#!/bin/sh
#
# 由 scripts/04-config.sh 按构建参数生成 —— 不要手工编辑。
#
uci -q batch <<-UCIEOF
	delete network.lan.ipaddr
	set network.lan.proto='static'
	add_list network.lan.ipaddr='$LAN_IP'
	commit network
UCIEOF

exit 0
EOF
	chmod 755 "$BD/etc/uci-defaults/25_lan_ip"
	say "已生成管理地址 uci-defaults：$LAN_IP"
fi

# 主题锁定。
#
# 主题包自己也会写 uci-defaults（luci-theme-fanchmwrt 是 31_ 开头的），
# 这里用 99_ 开头，保证后跑、以本次勾选为准。这样「勾什么就得到什么主题」
# 不依赖上游主题包的默认值是什么 —— 那些默认值随时可能变。
if [ "$WITH_FANCHMWRT" = "1" ]; then
	THEME_NAME="FanchmWrt"
	THEME_PATH="/luci-static/fanchmwrt"
elif [ "$WITH_ISTOREOS" = "1" ]; then
	THEME_NAME="Argon"
	THEME_PATH="/luci-static/argon"
else
	THEME_NAME=""
	THEME_PATH=""
fi

if [ -n "$THEME_PATH" ]; then
	cat > "$BD/etc/uci-defaults/99_build-defaults-theme" <<EOF
#!/bin/sh
#
# 由 scripts/04-config.sh 按勾选生成 —— 不要手工编辑。
#
# 勾了 FanchmWrt  -> FanchmWrt 主题（仪表盘 + 高级/普通模式都在这个主题里）
# 只勾 iStoreOS  -> argon 主题 + QuickStart 作首页
# 都不勾         -> 本文件不存在，保持 ImmortalWrt 原样
#
uci -q batch <<-UCIEOF
	set luci.themes.$THEME_NAME='$THEME_PATH'
	set luci.main.mediaurlbase='$THEME_PATH'
	commit luci
UCIEOF

exit 0
EOF
	chmod 755 "$BD/etc/uci-defaults/99_build-defaults-theme"
	say "已生成主题 uci-defaults：$THEME_NAME ($THEME_PATH)"
else
	say "两个特性都没勾：不锁主题，保持 ImmortalWrt 默认"
fi

cat > "$BD/etc/build-options" <<EOF
# 本次固件是用什么参数编出来的。
#
# 设备上直接 cat 这个文件，比去翻 GitHub Actions 的日志快得多。
# 由 scripts/04-config.sh 生成，改它没有用，下次构建会覆盖。
WITH_FANCHMWRT=$WITH_FANCHMWRT
WITH_ISTOREOS=$WITH_ISTOREOS
ENABLE_DOCKER=$ENABLE_DOCKER
LAN_IP=${LAN_IP:-（未指定，保持 ImmortalWrt 默认 192.168.1.1）}
ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE
IMMORTALWRT_REF=${IMMORTALWRT_REF:-（未设置）}
IMMORTALWRT_SHA=$(cat "$SRC/.immortalwrt-sha" 2>/dev/null || echo unknown)
THEME=${THEME_NAME:-ImmortalWrt 默认}
EOF

# ---------------------------------------------------------------------------
# 3. defconfig
#
# 删掉 tmp/ 是刻意的：tmp/.packageinfo 之类的元数据记录了「有哪些包」，
# 切换勾选（比如这次不要 FanchmWrt 了）时它是过期的，defconfig 会据此
# 算出错的依赖关系。现有项目就踩过这个坑 —— 参数改成不含 Docker，
# 固件里却仍然有 Docker。重新生成元数据多花一两分钟，换一个确定性。
# ---------------------------------------------------------------------------
say "清理过期的构建元数据"
rm -rf "$SRC/tmp"

cd "$SRC"
say "make defconfig"
make defconfig >/dev/null

cp "$SRC/.config" "$GEN/config.final"

# ---------------------------------------------------------------------------
# 4. 双向断言
# ---------------------------------------------------------------------------
MUST_HAVE="luci uhttpd build-defaults"
MUST_HAVE="$MUST_HAVE mosdns luci-app-mosdns v2ray-geoip v2ray-geosite luci-app-openclash"
MUST_HAVE="$MUST_HAVE luci-app-ttyd ttyd"
MUST_HAVE="$MUST_HAVE luci-app-diskman luci-app-nfs nfs-kernel-server"
MUST_HAVE="$MUST_HAVE luci-app-mergerfs mergerfs luci-app-unishare unishare webdav2 wsdd2"
# 这两个不是特性层的东西，是底座本来就会带上的：
#   kmod-nft-fullcone  firewall4 的依赖（提供者在树内 fullconenat-nft）
#   luci-compat        上面几个旧式 Lua 应用的依赖
# 放进「永远必须有」的清单，是为了让「没勾 FanchmWrt 时不该有 fwx 相关包」
# 这条断言保持精确 —— 否则会把它俩误判成 FanchmWrt 层带进来的。
MUST_HAVE="$MUST_HAVE kmod-nft-fullcone luci-compat"
MUST_NOT_HAVE="luci-app-ddns luci-app-hd-idle luci-app-wol luci-app-samba4 autosamba"

# --- FanchmWrt 层 ---
#
# 断言清单与配置清单来自**同一个枚举函数**，这是刻意的：
# 两者要是各写一份，上游加包时可能只更新了一边 —— 配置里编了、断言却不查，
# 或者反过来断言要查、配置却没编。同一个来源就不会有这种漂移。
# kmod-fwx 不在枚举里（内核模块的包名与目录名不同，写死在 config 片段里），
# 但断言必须覆盖它 —— 它恰恰是整层里最关键、最容易编不出来的那个。
FANCHM_PKGS="kmod-fwx $(enumerate_fanchmwrt_pkgs | tr '\n' ' ')"

# --- iStoreOS 层 ---
ISTORE_PKGS="luci-app-quickstart quickstart luci-app-store taskd luci-lib-taskd luci-lib-xterm"

# --- Docker 层 ---
DOCKER_PKGS="luci-app-dockerman dockerd docker docker-compose containerd runc tini docker-defaults"

if [ "$WITH_FANCHMWRT" = "1" ]; then
	MUST_HAVE="$MUST_HAVE $FANCHM_PKGS"
	# 主题互斥：勾了 FanchmWrt 就不该再有 argon。
	MUST_NOT_HAVE="$MUST_NOT_HAVE luci-theme-argon luci-app-argon-config"
else
	MUST_NOT_HAVE="$MUST_NOT_HAVE $FANCHM_PKGS"
fi

if [ "$WITH_ISTOREOS" = "1" ]; then
	MUST_HAVE="$MUST_HAVE $ISTORE_PKGS"
	# 只勾 iStoreOS（没勾 FanchmWrt）时，主题必须是 argon。
	[ "$WITH_FANCHMWRT" = "1" ] || MUST_HAVE="$MUST_HAVE luci-theme-argon"
else
	MUST_NOT_HAVE="$MUST_NOT_HAVE $ISTORE_PKGS luci-theme-argon luci-app-argon-config"
fi

if [ "$ENABLE_DOCKER" = "1" ]; then
	MUST_HAVE="$MUST_HAVE $DOCKER_PKGS"
else
	MUST_NOT_HAVE="$MUST_NOT_HAVE $DOCKER_PKGS"
fi

FAILED=0
for pkg in $MUST_HAVE; do
	if ! assert_pkg_on "$SRC/.config" "$pkg"; then
		warn "该有却没有：$pkg"
		FAILED=1
	fi
done
for pkg in $MUST_NOT_HAVE; do
	if ! assert_pkg_off "$SRC/.config" "$pkg"; then
		warn "不该有却有：$pkg"
		FAILED=1
	fi
done

if [ "$FAILED" = "1" ]; then
	printf '\n' >&2
	die "包清单核对失败，拒绝继续构建。
     一个缺主题或多带 Samba 界面的固件，比一次失败的构建更浪费时间。
     排查方向：
       * 「该有却没有」通常是 feed 没装全，或包名写错（去 openwrt/feeds/ 里找）；
       * 「不该有却有」通常是某个 meta 包把它拖进来了，用
         grep -rn '<包名>' openwrt/feeds/*/*/Makefile 查依赖。"
fi

say "包清单核对通过：$(echo $MUST_HAVE | wc -w) 项必须在位，$(echo $MUST_NOT_HAVE | wc -w) 项确认排除"

# --- 镜像相关配置 -----------------------------------------------------------
for k in "CONFIG_TARGET_ROOTFS_SQUASHFS=y" "CONFIG_TARGET_ROOTFS_EXT4FS=y" \
         "CONFIG_TARGET_IMAGES_GZIP=y" "CONFIG_TARGET_x86_64_DEVICE_generic=y"; do
	grep -qx "$k" "$SRC/.config" || die "目标配置缺失：$k"
done
grep -qx "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE" "$SRC/.config" \
	|| die "固件大小没有生效：期望 CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
# 这四个必须是关的，否则镜像数量和 Release 附件都会失控。
# 末尾的 `|| true` 不能省：它是 for 循环体的最后一句，grep 不匹配时返回 1，
# 在 set -e 下会把「一切正常」误判成失败。
for k in "CONFIG_TARGET_ROOTFS_TARGZ" "CONFIG_TARGET_ROOTFS_INITRAMFS" \
         "CONFIG_TARGET_ROOTFS_CPIOGZ"; do
	grep -qx "CONFIG_$k=y" "$SRC/.config" && die "$k 本应关闭却开着 —— 会多出好几倍的镜像文件" || true
done
say "镜像配置核对通过（4 个镜像：squashfs / ext4 × efi / 非 efi，rootfs ${ROOTFS_PARTSIZE}MB）"

# ---------------------------------------------------------------------------
# 5. 留一份期望清单给 scripts/09-verify.sh
#
# 编译只证明「能编出来」，不证明「编出来的东西对」。产物核验要拿这份清单
# 去比对固件里真实的软件包列表，那才是最终事实。
# ---------------------------------------------------------------------------
{
	echo "WITH_FANCHMWRT=$WITH_FANCHMWRT"
	echo "WITH_ISTOREOS=$WITH_ISTOREOS"
	echo "ENABLE_DOCKER=$ENABLE_DOCKER"
	echo "LAN_IP=$LAN_IP"
	echo "ROOTFS_PARTSIZE=$ROOTFS_PARTSIZE"
	printf 'MUST_HAVE="%s"\n' "$MUST_HAVE"
	printf 'MUST_NOT_HAVE="%s"\n' "$MUST_NOT_HAVE"
	printf 'THEME=%s\n' "${THEME_NAME:-immortalwrt-default}"
} > "$GEN/expectations.env"

say "期望清单已写入 .generated/expectations.env"
