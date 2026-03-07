# luci-app-parental-privacy-vlan

LuCI wizard and dashboard for a fully isolated Kids Network on OpenWrt.
Automatically detects your hardware and uses the best available isolation method:

- **VLAN mode** — mac80211 drivers (ath9k / ath10k / ath11k / mt76): full VLAN isolation on `br-lan`, no dedicated ports required
- **Bridge mode** — Broadcom brcmfmac and any other hardware lacking mac80211 VLAN support: separate `br-kids` bridge, wired isolation via dedicated LAN ports assigned from the dashboard

The wizard, dashboard, schedule, DNS filtering, DoH blocking, and SafeSearch work identically in both modes.

![Dashboard](docs/screenshot-dashboard.svg)

---

## Features

### Network isolation

**VLAN mode (mac80211 hardware)**

The Kids Network defaults to VLAN ID 28, chosen deliberately to align with the private subnet `172.28.x.x` — giving a router IP of `172.28.28.1` and client addresses in `172.28.28.0/24`. The relationship between VLAN ID and subnet is immediately readable in the router config. VLAN 28 is also essentially unused in consumer networking, where guest networks, IPTV, VoIP, and CCTV typically occupy the lower range (VLAN 10–30).

If VLAN 28 is already in use, the installer works down from the high end (80, 90, 100) before moving into the mid-range (40–70), deliberately leaving the low block free for those common services. Only if all preferred candidates are exhausted does it try 15 and 25. If none of the 11 candidates are free, the install aborts with a clear log message rather than silently claiming a VLAN that may already be in use.

- Detects all physical DSA LAN ports dynamically and tags them — no hardcoded port names
- Creates a `br-lan.<vlan>` subinterface with a dedicated subnet in the `172.28.<vlan>.0/24` range
- Single-NAT: the WAN zone handles masquerade for all traffic; the kids zone never double-NATs, giving consoles NAT Type 2 (Moderate) or better

**Bridge mode (Broadcom / brcmfmac hardware)**

Automatically activated when the installer detects a Broadcom WiFi chip (brcmfmac driver), a missing `br-lan`, or a legacy swconfig switch. A standalone `br-kids` bridge is created instead of a VLAN subinterface. The WiFi VAP attaches directly to it — no VLAN tagging required.

- WiFi isolation is automatic and requires no user action
- Wired isolation is optional: assign physical LAN ports to the kids network from the dashboard or wizard; unassigned ports remain on your main network
- A persistent warning banner appears in the dashboard and wizard when bridge mode is active

**Single-NAT**

The WAN zone handles masquerade for all traffic; the kids zone never double-NATs, ensuring consoles achieve NAT Type 2 (Moderate) or better.

### DNS & Content Filtering
- DNS Interception: Unlike standard setups that rely on DHCP options, this project uses firewall DNAT rules to intercept all DNS queries (TCP/UDP 53) for both IPv4 and IPv6. This forces all requests through a local, filtered dnsmasq instance even if a device has manual DNS settings.
- Local Filtering Instance: Uses a dedicated dnsmasq configuration directory (/etc/dnsmasq.kids.d) to apply local overrides and blocklists before forwarding to family-safe upstreams like Cloudflare Families or OpenDNS.
- SafeSearch Enforcement: Forces SafeSearch on Google, Bing, YouTube (Moderate or Strict), DuckDuckGo, Brave, and Pixabay via local dnsmasq CNAME and address records.
- DoH & DoT Blocking: Prevents browsers and apps from bypassing filters via encrypted DNS-over-HTTPS (Port 443) or DNS-over-TLS (Port 853) using nftables to block known provider IPs.
- App & VPN Blocking: Includes built-in toggles to block undesirable apps like TikTok and Snapchat, as well as common VPN protocols (OpenVPN, WireGuard, IPSec) to ensure the network boundary is respected.


### Wireless

- Creates VAPs on all detected bands: 2.4 GHz (WPA2), 5 GHz (WPA2), and 6 GHz (WPA3/SAE) — all sharing the same SSID and key
- SSID defaults to `<PrimarySSID>_Kids` and is fully customisable
- A strong random password is generated at install time via openssl or `/dev/urandom` and stored in UCI for the dashboard to display
- WiFi is intentionally left broadcasting at all times; internet access is controlled by a firewall rule so devices stay associated and keep their IPs even during blocked hours

### Firewall

- Dedicated `kids` zone with REJECT default for input and forward
- Specific ACCEPT rules for DHCP (UDP 67), DNS (TCP/UDP 53), ICMP, and UPnP (UDP 1900) so miniupnpd can serve consoles
- DNS interception: all DNS queries (TCP/UDP 53) are redirected back to the router via DNAT for both IPv4 and IPv6, preventing bypass
- Internet schedule block: installs a `kids→wan` REJECT rule at cron time rather than toggling radios — no disruptive WiFi restart, wired devices blocked identically to wireless ones

### Time scheduling

- Per-day schedules with up to 4 allowed internet-access windows per day
- Default schedule: Mon–Thu and Sun 06:00–20:00, Fri–Sat 06:00–21:00
- Cron entries are written in UTC with automatic local→UTC conversion, including half-hour timezone offset handling (+05:30, +05:45, etc.)
- 1-hour extend: a one-shot cron entry restores access immediately and re-blocks exactly 60 minutes later, then self-removes from crontab

### Hardware button

- Assigns a physical router button (WPS, Reset, or custom GPIO pin) as an instant internet toggle via an OpenWrt hotplug script
- No reboot required; takes effect on the next button press
- WiFi radios are never toggled — internet access is controlled via the firewall block rule only

### Cross-network broadcast relay

Uses `udp-broadcast-relay-redux` and `umdns` so kids-network devices can discover and use services on the main LAN and vice versa. Narrow per-service firewall rules preserve the REJECT default posture.

Services relayed (both directions unless noted):

| Service | Protocol | Purpose |
|---|---|---|
| mDNS / Bonjour | UDP 5353 multicast | AirPrint, AirPlay, Chromecast, Avahi, HomeKit, Apple TV |
| SSDP / UPnP | UDP 1900 multicast | DLNA, Chromecast, smart TVs |
| WSD | UDP 3702 multicast | Windows printer/scanner discovery |
| NetBIOS-NS | UDP 137 broadcast | Windows LAN name resolution |
| IPP + RAW print | TCP 631 / 9100 | Kids → LAN printer direct |
| Steam | UDP/TCP 27036 | Local Game Transfers and Remote Play Together |
| Minecraft Bedrock | UDP 19132 / TCP 19133 | Console, mobile, and Windows edition LAN discovery |
| Minecraft Java | UDP 4445 / TCP 25565 | Java Edition LAN world discovery and direct connect |

### Setup wizard

- Guided wizard: primary LAN DNS → kids WiFi credentials and DNS → hardware button → LAN port assignment (bridge mode only)
- In bridge mode an extra step appears after the hardware button step, listing available physical LAN ports as clickable cards; port assignments can also be changed any time from the dashboard
- All stages applied sequentially via rpcd without a page reload

### Dashboard

- Single-page view showing live device count, active SSID, current DNS resolver, schedule state, and internet access status
- Persistent bridge-mode warning banner when running on Broadcom hardware, with an interactive port assignment panel
- 30-second live status polling; polling interval is cleanly cancelled when the user navigates away from the page to prevent memory leaks
- Extend (1 hour) and Remove buttons included

### Backup and restore

**Pre-install backup**

Every time the installer runs it creates a timestamped snapshot of your router configuration before making any changes:

```
/etc/parental-privacy/pre-install-backup/<YYYYMMDD-HHMMSS>/
    network.uci       ← full UCI export of network config
    wireless.uci      ← full UCI export of wireless config
    dhcp.uci          ← full UCI export of DHCP config
    firewall.uci      ← full UCI export of firewall config
    crontab.root      ← copy of /etc/crontabs/root
    dnsmasq.d/        ← copy of /etc/dnsmasq.d/
    restore.sh        ← self-contained restore script
```

To roll back to the pre-install state, connect via SSH and run:

```sh
sh /etc/parental-privacy/pre-install-backup/<timestamp>/restore.sh
```

The restore script stops all parental-privacy services, re-imports each UCI config package, restores the crontab and dnsmasq directory, and restarts network/dnsmasq/firewall/wifi. It requires no extra tools beyond the standard OpenWrt shell.

Only the three most recent backups are kept to protect flash storage. Older ones are pruned automatically at install time.

**Schedule backup on remove**

When the Kids Network is removed (via the dashboard Remove button or `opkg remove`), the current schedule is saved to `/etc/parental-privacy/schedule.backup` before the UCI config is wiped. If the package is reinstalled, the installer detects that file, restores the saved schedule on top of the defaults, and then deletes the backup so a second fresh install gets the defaults rather than a stale one. The WiFi password is also preserved through a remove/reinstall cycle.

---

## Screenshots

### Dashboard

![Dashboard](docs/screenshot-dashboard.svg)

![Dashboard in bridge-mode](docs/screenshot-dashboard-bridge.svg)

The main dashboard shows live device count, active SSID, current DNS resolver, and next schedule event — plus collapsible panels for every setting. A bridge-mode banner appears automatically on Broadcom hardware.

### Bedtime Schedule

![Schedule](docs/screenshot-schedule.svg)

Up to 4 allowed time windows per day. Quick presets include School Days, Strict, Split Day, Weekends Relaxed, and Clear All. Changes are written directly to `/etc/crontabs/root`.

### Setup Wizard

![Wizard](docs/screenshot-wizard.svg)

The wizard walks through primary DNS selection, Kids WiFi credentials, and optional hardware button assignment. On Broadcom hardware a fourth step appears for assigning physical LAN ports to the kids network.

---

## Requirements

| Dependency | Purpose |
|---|---|
| `luci-base` | LuCI framework |
| `nftables` | DoH blocking firewall rules (falls back to iptables on 21.02) |
| `rpcd` + `rpcd-mod-rpcsys` | RPC backend for wizard and dashboard |
| `udp-broadcast-relay-redux` | Relays UDP broadcast/multicast between kids network and main LAN |
| `umdns` | OpenWrt mDNS daemon; serves both interfaces so AirPrint, AirPlay, and HomeKit resolve correctly across the network boundary |

OpenWrt 22.03 or later recommended. Works on 21.02 with iptables fallback.

DSA network switch required for VLAN mode. swconfig hardware is automatically detected and falls back to bridge mode.

---

## Installation

### From the packages feed (once merged)

```sh
opkg update
opkg install luci-app-parental-privacy-vlan
```

### Manual install (ipk)

Download the latest release `.ipk` from the [Releases](https://github.com/eddwatts/luci-app-parental-privacy-vlan/releases) page, copy it to your router, and run:

```sh
opkg install luci-app-parental-privacy-vlan_1.3.0_all.ipk
```

### Build from source

Clone this repo into your OpenWrt buildroot packages feed:

```sh
cd /path/to/openwrt
git clone https://github.com/eddwatts/luci-app-parental-privacy-vlan.git package/luci-app-parental-privacy-vlan
make menuconfig   # select LuCI > Applications > luci-app-parental-privacy-vlan
make package/luci-app-parental-privacy-vlan/compile
```

---

## What gets installed

| File | Destination | Purpose |
|---|---|---|
| `99-parental-privacy` | `/etc/uci-defaults/` | Installer: runs once at first boot, creates all network/firewall/wireless config and pre-install backup |
| `30-kids-wifi` | `/etc/hotplug.d/button/` | Hardware button handler |
| `parental-privacy.init` | `/etc/init.d/` | Service init script (applies SafeSearch and DoH rules on boot/reload) |
| `parental-privacy-rpcd` | `/usr/libexec/rpcd/` | rpcd dispatcher for all RPC methods |
| `dashboard.js` | `/usr/share/luci/views/parental_privacy/` | LuCI dashboard view |
| `wizard.js` | `/usr/share/luci/views/parental_privacy/` | LuCI setup wizard view |
| `luci-app-parental-privacy-vlan.json` | `/usr/share/luci/menu.d/` and `/usr/share/rpcd/acl.d/` | LuCI menu entry and ACL |
| `block-doh.sh` | `/usr/share/parental-privacy/` | Manages nftables/iptables DoH blocking rules |
| `broadcast-relay.sh` | `/usr/share/parental-privacy/` | Manages udp-broadcast-relay-redux service |
| `safesearch.sh` | `/usr/share/parental-privacy/` | Writes/removes dnsmasq CNAME records for SafeSearch |
| `schedule-block.sh` | `/usr/share/parental-privacy/` | Installs/removes the firewall schedule block rule |
| `remove.sh` | `/usr/share/parental-privacy/` | Tears down all Kids Network config (backs up schedule first) |
| `rpc-status.sh` | `/usr/share/parental-privacy/` | Returns current status as JSON for the dashboard |
| `rpc-apply.sh` | `/usr/share/parental-privacy/` | Applies all settings changes from wizard and dashboard |
| `rpc-extend.sh` | `/usr/share/parental-privacy/` | Grants a 1-hour internet extension |
| `rpc-remove.sh` | `/usr/share/parental-privacy/` | RPC wrapper for remove.sh |

The `99-parental-privacy` uci-defaults script runs once at first boot. It does not overwrite any existing configuration — every section is guarded by a `uci get ... || uci set ...` check.

---

## First-time setup

After installing, navigate to **Network → Kids Network → Setup Wizard** in the LuCI web interface.

1. **Primary DNS** — optionally upgrade your main network to a protective resolver (Quad9, Cloudflare, AdGuard, or keep your ISP's)
2. **Kids WiFi** — set SSID, password, family DNS provider, SafeSearch, and DoH blocking
3. **Hardware button** — optionally assign a physical button to toggle internet access
4. **LAN Ports** *(bridge mode only, Broadcom hardware)* — select which physical LAN ports should be isolated on the kids network; unselected ports remain on your main network

The dashboard is then available at **Network → Kids Network**.

---

## Hardware button

The hotplug script at `/etc/hotplug.d/button/30-kids-wifi` handles:

- **GL.iNet slider** (`BTN_0`) — slider position maps directly: pressed = internet ON, released = internet OFF
- **WPS button** — single press toggles internet access
- **Reset button** — single press toggles internet access; hold 10 seconds still performs a factory reset as normal
- **Custom GPIO pin** — configurable slider, same logic as BTN_0

Internet access is controlled by a firewall REJECT rule, not by toggling the WiFi radios. Devices stay associated and keep their IPs at all times — the button only affects whether traffic can pass.

To find your router's button name, check the [OpenWrt Hardware Wiki](https://openwrt.org/toh/start) for your model, then set the GPIO pin in the dashboard under **Hardware Kill-Switch**.

---

## Network architecture

### VLAN mode (mac80211 hardware)

```
Internet
    │
  [WAN]
    │
 OpenWrt router
    ├── br-lan        (192.168.1.x)   ← your home devices
    └── br-lan.<vlan> (172.28.<v>.x)  ← isolated kids network
            │
        Firewall zone: kids
            ├── Input:   REJECT  (except DHCP, DNS, ICMP, UPnP)
            ├── Forward: REJECT  → WAN only (blocked by schedule rule during off-hours)
            └── DNS intercepted: all port-53 traffic redirected to dnsmasq
```

### Bridge mode (Broadcom / brcmfmac hardware)

```
Internet
    │
  [WAN]
    │
 OpenWrt router
    ├── br-lan   (192.168.1.x)   ← your home devices + unassigned LAN ports
    └── br-kids  (172.28.<v>.x)  ← isolated kids network
         ├── Kids WiFi VAP  (automatic)
         └── LAN port(s)    (optional, assigned from dashboard)
            │
        Firewall zone: kids
            ├── Input:   REJECT  (except DHCP, DNS, ICMP, UPnP)
            ├── Forward: REJECT  → WAN only (blocked by schedule rule during off-hours)
            └── DNS intercepted: all port-53 traffic redirected to dnsmasq
```

Kids devices receive DNS via DHCP Option 6. A DNAT rule redirects any attempt to use a different DNS server back to the router. DoH blocking prevents browsers from encrypting around the filter entirely.

---

## Restoring after a problem

If the install causes a networking issue, connect via SSH and run the pre-install restore script:

```sh
# List available backups
ls /etc/parental-privacy/pre-install-backup/

# Run the restore (replace the timestamp with your backup directory name)
sh /etc/parental-privacy/pre-install-backup/20240315-143022/restore.sh
```

The script will:
1. Stop and disable the parental-privacy service
2. Re-import the pre-install UCI snapshots for `network`, `wireless`, `dhcp`, and `firewall`
3. Restore `/etc/crontabs/root` and `/etc/dnsmasq.d/`
4. Remove the parental-privacy UCI config
5. Restart network, dnsmasq, firewall, and WiFi

Your router will be returned to exactly the state it was in before the package was installed.

---

## License

GPL-2.0-or-later — see [LICENSE](LICENSE)

## Maintainer

Edward Watts
