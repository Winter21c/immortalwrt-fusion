#
# docker-defaults —— 让 Docker 在 x86 的 squashfs / ext4 镜像上都能正常起来。
#
# ===========================================================================
# 这里**故意没有**做什么，以及为什么
# ===========================================================================
#
# 原本计划照搬 iStoreOS 对 dockerd 的定制补丁（关掉 docker 自带的 iptables、
# 改由 fw4 统一管、补一条 172.16.0.0/12 的出网 NAT）。实际核对 ImmortalWrt
# 自带的 dockerd 之后**放弃了这个方案**，原因有三条：
#
#   1. 两边的做法是相反的。ImmortalWrt 的 dockerd.init 自带 uciadd/ucidel，
#      会创建 docker firewall zone、把接口加进去，并且 postinst 里自动调用
#      （feeds/packages/utils/dockerd/files/dockerd.init 第 85-100 行）。
#      它默认 iptables='1'，也就是让 docker 自己管 NAT。iStoreOS 那套是
#      把 docker 的 iptables 关掉、全部搬到 fw4 —— 硬套上去等于把一套能用的
#      机制拆掉换成另一套，收益不明而风险很实在。
#
#   2. 版本对不上。ImmortalWrt 的 dockerd 是 29.6.1，iStoreOS 的定制是针对
#      27.3.1 的，补丁涉及的文件树都不一样，patch 直接打不上。
#
#   3. 定制补丁只动 files/ 下的 7 个文件，其中有 4 个（fstab.d、hotplug、
#      两个 uci-defaults）是为 iStoreOS 自己的镜像布局服务的，
#      对 ImmortalWrt 的镜像布局没有意义。
#
# 结论：**能跟随底座的就跟随底座**。这个包只做两件与 dockerd 版本无关、
# 纯粹由「x86 + squashfs 镜像布局」决定的事。
#
# ===========================================================================
# 包含的文件
# ===========================================================================
#
#   files/etc/uci-defaults/20_docker_data_root
#       squashfs 镜像上把 docker 数据目录指到 /overlay/upper，
#       否则 overlay2 存储驱动会拒绝启动。
#
#   files/etc/uci-defaults/30_docker_log_limit
#       给容器日志封顶，否则一个话多的容器能把盘写满。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=docker-defaults
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_FLAGS:=hold

PKG_LICENSE:=CC0-1.0

include $(INCLUDE_DIR)/package.mk

define Package/docker-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Docker defaults for x86 disk images
  DEPENDS:=+dockerd
endef

define Package/docker-defaults/description
 x86 镜像布局决定的 docker 默认值：squashfs 上的数据目录落点、容器日志封顶。
 不包含任何对 dockerd 本身的改动 —— 那些交给 ImmortalWrt 自带的实现。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/docker-defaults/install
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,docker-defaults))
