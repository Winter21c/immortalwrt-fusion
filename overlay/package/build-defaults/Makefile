#
# 构建时选定的默认值（管理地址等）。
#
# 这个包本身没有依赖、也不编译任何东西，只把
# scripts/apply-build-options.sh 生成的文件装进固件：
#
#   /etc/uci-defaults/25_lan_ip   首次启动时套用选定的管理地址
#   /etc/build-options            记录本次构建用了哪些参数
#
# 之所以单独开一个包、而不是塞进 package/istoreos-merge：
# 那个包是 Docker 的附属（DEPENDS 里挂着 luci-app-dockerman），
# 关掉 Docker 时会被一起移除；而管理地址跟 Docker 没有关系，
# 必须在任何组合下都存在。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=build-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_FLAGS:=hold

PKG_LICENSE:=CC0-1.0

include $(INCLUDE_DIR)/package.mk

define Package/build-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Build-time defaults (LAN address etc.)
endef

define Package/build-defaults/description
  scripts/apply-build-options.sh 按构建参数生成的默认值。
  文件是生成物，不存在时本包只装 /etc/build-options。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/build-defaults/install
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	# ./files/ 下的内容是 apply-build-options.sh 生成的，可能只有一部分。
	[ -d ./files/etc ] && $(CP) ./files/etc/. $(1)/etc/ || true
endef

$(eval $(call BuildPackage,build-defaults))
