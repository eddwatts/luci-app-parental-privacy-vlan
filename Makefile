include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-parental-privacy-vlan
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_SOURCE_VERSION:=main
PKG_MAINTAINER:=Edward Watts
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/eddwatts/luci-app-parental-privacy-vlan.git
PKG_MIRROR_HASH:=skip
PKG_MAINTAINER:=Edward Watts <edd@eddtech.co.uk>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-parental-privacy-vlan
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Parental Privacy Wizard (VLAN edition)
  DEPENDS:=+luci-base +tc-full +kmod-sched-core +nftables @(TARGET_x86||TARGET_ath79||TARGET_ramips||TARGET_mediatek)
  PKGARCH:=all
endef

define Package/luci-app-parental-privacy-vlan/description
  Isolated Kids WiFi with DNS filtering, schedules, and bandwidth limiting.
  VLAN edition — requires DSA hardware (OpenWrt 21.02+) and mac80211 WiFi
  driver (ath9k/ath10k/ath11k/mt76). Provides single-NAT isolation suitable
  for games consoles. For older hardware use luci-app-parental-privacy instead.
endef

define Build/Compile
endef

define Package/luci-app-parental-privacy-vlan/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/parental_privacy
	$(INSTALL_DIR) $(1)/usr/share/parental-privacy
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/hotplug.d/button

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/bandwidth.sh $(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/block-doh.sh $(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/safesearch.sh $(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/99-parental-privacy $(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/30-kids-wifi $(1)/etc/hotplug.d/button/

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/parental_privacy.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/kids_network.htm $(1)/usr/lib/lua/luci/view/parental_privacy/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/wizard.htm $(1)/usr/lib/lua/luci/view/parental_privacy/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/luci-app-parental-privacy.json $(1)/usr/share/rpcd/acl.d/
endef


$(eval $(call BuildPackage,luci-app-parental-privacy-vlan))




