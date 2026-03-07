include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-parental-privacy-vlan
PKG_VERSION:=1.2.0
PKG_RELEASE:=1
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/eddwatts/luci-app-parental-privacy-vlan.git
PKG_SOURCE_VERSION:=main
PKG_MIRROR_HASH:=<fill-in-after-first-build>
PKG_MAINTAINER:=Edward Watts <edd@eddtech.co.uk>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-parental-privacy-vlan
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Parental Privacy Wizard (VLAN edition)
  DEPENDS:=+luci-base +nftables +rpcd +rpcd-mod-rpcsys +udp-broadcast-relay-redux +umdns
  PKGARCH:=all
endef

define Package/luci-app-parental-privacy-vlan/description
  LuCI wizard and dashboard for a fully isolated Kids Network using a
  dedicated VLAN on the main br-lan bridge (DSA/OpenWrt 22.03+ required).
  mac80211 WiFi driver required (ath9k/ath10k/ath11k/mt76).
  Broadcom brcmfmac is NOT supported — use the bridge edition instead.

  NETWORK ISOLATION (VLAN)
  - The Kids Network defaults to VLAN ID 28, which was chosen deliberately to
    align with the private subnet range 172.28.x.x — resulting in a router IP
	of 172.28.28.1 and client addresses in the 172.28.28.0/24 block. This
	makes the relationship between the VLAN ID and the subnet immediately
	obvious to anyone reading the router config. The VLAN ID 28 is also
	essentially unused in consumer networking, where common VLANs for guest
	networks, IPTV, VoIP, and CCTV typically occupy the lower range (VLAN 10–30).
	If VLAN 28 is already taken, the installer works down from the high end
	(80, 90, 100) before moving into the mid-range (40–70), deliberately
	staying away from the low block where those common services live and
	leaving those IDs free for their intended use. Only if all preferred
	candidates are exhausted does the installer try 15 and 25 — non-round
	numbers unlikely to be in use on any network. If none of the 11
	candidates are available, the install aborts with a clear error rather
	than silently claiming a VLAN that may already be in use, protecting the
	integrity of your existing network configuration.
  - Detects all physical DSA LAN ports dynamically and tags them — no
    hardcoded port names.
  - Creates a br-lan.<vlan> subinterface with a dedicated subnet in the
    172.28.<vlan>.0/24 range (e.g. VLAN 10 → 172.28.10.0/24).
  - Aborts cleanly with a log message if DSA is absent or swconfig is
    detected, allowing the bridge edition to be used instead.
  - Single-NAT: the WAN zone handles masquerade for all traffic; the kids
    zone never double-NATs, giving consoles NAT Type 2 (Moderate) or better.

  WIRELESS
  - Creates VAPs on all detected bands: 2.4 GHz (WPA2), 5 GHz (WPA2), and
    6 GHz (WPA3/SAE) — all sharing the same SSID and key.
  - SSID defaults to <PrimarySSID>_Kids and is fully customisable.
  - A strong random password is generated at install time via openssl or
    /dev/urandom and stored in UCI for the dashboard to display.
  - WiFi is intentionally left broadcasting at all times; internet access
    is controlled by a firewall rule so devices stay associated and keep
    their IPs even when the schedule blocks them.

  FIREWALL
  - Dedicated 'kids' zone with REJECT default for input and forward.
  - Specific ACCEPT rules for DHCP (UDP 67), DNS (TCP/UDP 53), ICMP, and
    UPnP (UDP 1900) so miniupnpd can serve consoles.
  - DNS interception: all DNS queries (TCP/UDP port 53) are redirected back
    to the router via DNAT for both IPv4 and IPv6, preventing bypass.
  - Internet schedule block: installs a kids→wan REJECT rule at cron time
    rather than toggling radios — no disruptive wifi restart, wired VLAN
    devices blocked identically to wireless ones.

  DNS FILTERING
  - DHCP Option 6 pushes a family-safe DNS (default: Cloudflare 1.1.1.3 /
    1.0.0.3 for Families) to every kids device.
  - Configurable from the wizard; choices include Cloudflare Families,
    CleanBrowsing Family, and OpenDNS FamilyShield.
  - Primary LAN DNS is also configurable (Quad9, Cloudflare, AdGuard, ISP).

  SAFESEARCH ENFORCEMENT
  - Forces SafeSearch on Google (all regional domains), Bing, YouTube
    (Restricted Mode), and DuckDuckGo via dnsmasq CNAME records.
  - Works at DNS level — no DPI, no SSL inspection, no accounts needed.

  DNS-OVER-HTTPS (DoH) BLOCKING
  - Prevents browsers from silently bypassing the DNS filter using
    encrypted DNS (DoH) on port 443.
  - Blocks known DoH provider IPs (Cloudflare, Google, Quad9, AdGuard,
    OpenDNS, CleanBrowsing) for both TCP and UDP (HTTP/3).
  - Uses nftables sets on OpenWrt 22.03+ with an iptables fallback for
    older kernels. IPv4 and IPv6 providers are both covered.

  TIME SCHEDULING
  - Per-day schedules with up to 4 allowed internet-access windows per day.
  - Default schedule: Mon–Thu and Sun 06:00–20:00, Fri–Sat 06:00–21:00.
  - Cron entries are written in UTC with automatic local→UTC conversion,
    including half-hour timezone offset handling (+05:30, +05:45, etc.).
  - 1-hour extend: a one-shot cron entry restores access immediately and
    re-blocks exactly 60 minutes later, then self-removes from crontab.

  HARDWARE BUTTON
  - Assigns a physical router button (WPS, Reset, or custom GPIO pin) as
    an instant kids WiFi / internet toggle via an OpenWrt hotplug script.
  - No reboot required; takes effect on the next button press.

  CROSS-VLAN BROADCAST RELAY
  - Uses udp-broadcast-relay-redux and umdns so kids-VLAN devices can
    discover and use services on the main LAN and vice versa.
  - Narrow per-service firewall rules preserve the REJECT default posture.
  - Services relayed (both directions unless noted):
      mDNS / Bonjour   (UDP 5353 multicast) — AirPrint, AirPlay,
                        Chromecast, Avahi, HomeKit, Apple TV
      SSDP / UPnP      (UDP 1900 multicast) — DLNA, Chromecast, smart TVs
      WSD              (UDP 3702 multicast) — Windows printer/scanner
                        discovery (Web Services for Devices)
      NetBIOS-NS       (UDP 137 broadcast)  — Windows LAN name resolution
      IPP + RAW print  (TCP 631 / 9100)     — kids → LAN printer direct
      Steam            (UDP/TCP 27036)      — Local Game Transfers and
                        Remote Play Together
      Minecraft Bedrock (UDP 19132 / TCP 19133) — console, mobile, and
                        Windows 10 edition LAN world discovery
      Minecraft Java    (UDP 4445 / TCP 25565) — Java Edition LAN world
                        discovery and direct connect

  SETUP WIZARD
  - Three-step guided wizard: primary LAN DNS, kids WiFi + DNS, hardware
    button. All applied sequentially via rpcd without a page reload.

  DASHBOARD
  - Single-page view showing: live device list (from DHCP leases), current
    internet status, SSID/password, schedule, SafeSearch, DoH, and relay
    toggles. Extend and Remove buttons included.

  REQUIREMENTS
    OpenWrt 22.03 or later (fw4/nftables)
    DSA network switch (swconfig hardware NOT supported)
    mac80211 WiFi driver (ath9k, ath10k, ath11k, mt76)
    Packages: luci-base, rpcd, rpcd-mod-file, nftables,
              udp-broadcast-relay-redux, umdns
endef

define Build/Compile
	$(foreach po,$(wildcard $(PKG_BUILD_DIR)/po/*/*.po), \
		$(STAGING_DIR_HOST)/bin/po2lmo \
			$(po) \
			$(PKG_BUILD_DIR)/po/$(notdir $(po:.po=.lmo)); \
	)
endef

define Package/luci-app-parental-privacy-vlan/install
	# ── Directories ───────────────────────────────────────────────────────────
	$(INSTALL_DIR) $(1)/usr/share/luci/views/parental_privacy
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/parental-privacy
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/hotplug.d/button
	$(INSTALL_DIR) $(1)/etc/init.d

	# ── Init script ───────────────────────────────────────────────────────────
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/parental-privacy.init \
		$(1)/etc/init.d/parental-privacy

	# ── Shell scripts ─────────────────────────────────────────────────────────
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/block-doh.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/broadcast-relay.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/safesearch.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/schedule-block.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/remove.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-status.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-apply.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-extend.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-remove.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-blocklist.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/rpc-get-logs.sh \
		$(1)/usr/share/parental-privacy/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/update-blocklists.sh \
		$(1)/usr/share/parental-privacy/

	# ── rpcd dispatcher ───────────────────────────────────────────────────────
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/parental-privacy-rpcd \
		$(1)/usr/libexec/rpcd/parental-privacy

	# ── UCI defaults + hotplug ────────────────────────────────────────────────
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/99-parental-privacy \
		$(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/files/30-kids-wifi \
		$(1)/etc/hotplug.d/button/

	# ── LuCI JS views ─────────────────────────────────────────────────────────
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/dashboard.js \
		$(1)/usr/share/luci/views/parental_privacy/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/wizard.js \
		$(1)/usr/share/luci/views/parental_privacy/

	# ── LuCI menu descriptors ─────────────────────────────────────────────────
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/luci-app-parental-privacy-vlan.json \
		$(1)/usr/share/luci/menu.d/
	# ── ACL ───────────────────────────────────────────────────────────────────
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/luci-app-parental-privacy-vlan.json \
		$(1)/usr/share/rpcd/acl.d/
	# ── DNS blocklists catalog ────────────────────────────────────────────────────
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/files/blocklists.json \
		$(1)/usr/share/parental-privacy/

	# ── Translations ──────────────────────────────────────────────────────────
	$(if $(wildcard $(PKG_BUILD_DIR)/po/*.lmo), \
		$(INSTALL_DIR) $(1)/usr/share/luci/i18n; \
		$(INSTALL_DATA) $(PKG_BUILD_DIR)/po/*.lmo \
			$(1)/usr/share/luci/i18n/, \
	)
endef

$(eval $(call BuildPackage,luci-app-parental-privacy-vlan))
