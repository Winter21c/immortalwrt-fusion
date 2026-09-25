include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI app for fwx user record
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+fwxd +luci-compat +luci-lib-jsonc +luci-app-fwx-resources

PKG_NAME:=luci-app-fwx-user-record
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature