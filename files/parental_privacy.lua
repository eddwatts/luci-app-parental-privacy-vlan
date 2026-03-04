-- /usr/lib/lua/luci/controller/parental_privacy.lua
module("luci.controller.parental_privacy", package.seeall)

function index()
    -- Main Menu Entry
    entry({"admin", "network", "parental_privacy"},
          alias("admin", "network", "parental_privacy", "kids"),
          _("Kids Network"), 60).dependent = false

    -- Sub-entries for Dashboard, Wizard, and API endpoints
    entry({"admin", "network", "parental_privacy", "kids"},   call("action_kids"),   _("Dashboard"), 1)
    entry({"admin", "network", "parental_privacy", "wizard"}, template("parental_privacy/wizard"), _("Setup Wizard"), 2)
    entry({"admin", "network", "parental_privacy", "apply"},  call("action_apply"))
    entry({"admin", "network", "parental_privacy", "status"}, call("action_status"))
    entry({"admin", "network", "parental_privacy", "extend"}, call("action_extend"))
    entry({"admin", "network", "parental_privacy", "remove"}, call("action_remove"))
end

function action_kids()
    luci.template.render("parental_privacy/kids_network", {})
end

-- ──────────────────────────────────────────────────────────────────
-- Status: Fetches active devices and SSID info for the UI
-- ──────────────────────────────────────────────────────────────────
function action_status()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local sys  = require "luci.sys"
    local uci  = require("luci.model.uci").cursor()

    http.prepare_content("application/json")
    local primary_ssid = uci:get("wireless", "@wifi-iface[0]", "ssid") or "OpenWrt"
    local suggested    = primary_ssid .. "_Kids"

    local leases = {}
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            local exp, mac, ip, name = line:match("(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            -- Detect devices on the 172.28.10.x subnet
            if ip and ip:match("^172%.28%.10%.") then
                table.insert(leases, {mac=mac, ip=ip, name=(name~="*" and name or "Unknown")})
            end
        end
        f:close()
    end

    http.write(json.stringify({
        active         = (uci:get("wireless", "kids_wifi", "disabled") ~= "1"),
        ssid           = uci:get("wireless", "kids_wifi", "ssid") or suggested,
        primary_ssid   = primary_ssid,
        suggested_ssid = suggested,
        devices        = leases,
        uptime         = sys.uptime(),
        button_config  = {
            btn0  = (uci:get("parental_privacy", "default", "button_btn0")  == "1"),
            wps   = (uci:get("parental_privacy", "default", "button_wps")   == "1"),
            reset = (uci:get("parental_privacy", "default", "button_reset") == "1")
        }
    }))
end

-- ──────────────────────────────────────────────────────────────────
-- Extension: Forced ON for 1 hour via background timer
-- ──────────────────────────────────────────────────────────────────
function action_extend()
    local sys  = require "luci.sys"
    local uci  = require("luci.model.uci").cursor()
    local json = require "luci.jsonc"

    local function enable_all(state)
        uci:set("wireless", "kids_wifi", "disabled", state)
        if uci:get("wireless", "kids_wifi_5g") then uci:set("wireless", "kids_wifi_5g", "disabled", state) end
        if uci:get("wireless", "kids_wifi_6g") then uci:set("wireless", "kids_wifi_6g", "disabled", state) end
    end

    -- Kill any existing extend timer before starting a new one
    local PIDFILE = "/var/run/kids-extend.pid"
    local pf = io.open(PIDFILE, "r")
    if pf then
        local old_pid = pf:read("*l")
        pf:close()
        if old_pid then sys.call("kill " .. old_pid .. " 2>/dev/null") end
    end

    enable_all("0")
    uci:commit("wireless")
    sys.call("wifi reload")

    -- Temporary background timer with PID tracking
    sys.call(string.format(
        "(sleep 3600 && uci set wireless.kids_wifi.disabled=1 && wifi reload) & echo $! > %s",
        PIDFILE
    ))

    luci.http.prepare_content("application/json")
    luci.http.write(json.stringify({success=true, message="1-hour extension active"}))
end

-- ──────────────────────────────────────────────────────────────────
-- Remove: Tears down all Kids Network UCI config and cleans up
-- ──────────────────────────────────────────────────────────────────
function action_remove()
    local sys  = require "luci.sys"
    local json = require "luci.jsonc"
    local ok, err = pcall(function()
        sys.call("/usr/share/parental-privacy/remove.sh")
    end)
    luci.http.prepare_content("application/json")
    luci.http.write(json.stringify({success=ok, error=err}))
end

-- ──────────────────────────────────────────────────────────────────
-- Apply: Handles Dashboard Saves and Setup Wizard Stages
-- ──────────────────────────────────────────────────────────────────
function action_apply()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local sys  = require "luci.sys"
    local uci  = require("luci.model.uci").cursor()

    http.prepare_content("application/json")
    local data = json.parse(http.content())
    if not data then return end

    local ok, err = pcall(function()
        
        -- Helper: Apply settings across all detected bands
        local function set_wifi(opt, val)
            -- Apply to 2.4G if selected or 'both'/'all'
            if not data.radio or data.radio == "radio0" or data.radio == "both" or data.radio == "all" then
                uci:set("wireless", "kids_wifi", opt, val)
            elseif opt == "disabled" then
                uci:set("wireless", "kids_wifi", "disabled", "1")
            end
            
            -- Apply to 5G
            if uci:get("wireless", "kids_wifi_5g") then
                if not data.radio or data.radio == "radio1" or data.radio == "both" or data.radio == "all" then
                    uci:set("wireless", "kids_wifi_5g", opt, val)
                elseif opt == "disabled" then
                    uci:set("wireless", "kids_wifi_5g", "disabled", "1")
                end
            end

            -- Apply to 6G
            if uci:get("wireless", "kids_wifi_6g") then
                if not data.radio or data.radio == "radio2" or data.radio == "all" then
                    uci:set("wireless", "kids_wifi_6g", opt, val)
                    -- Force SAE (WPA3) for 6GHz band
                    if opt == "encryption" then uci:set("wireless", "kids_wifi_6g", "encryption", "sae") end
                elseif opt == "disabled" then
                    uci:set("wireless", "kids_wifi_6g", "disabled", "1")
                end
            end
        end

        -- 1. STAGE-BASED LOGIC (For Wizard Integration)
        if data.stage == "primary" then
            if data.dns == "isp" then
                uci:delete("dhcp", "@dnsmasq[0]", "server")
                uci:set("dhcp", "@dnsmasq[0]", "noresolv", "0")
            else
                uci:set_list("dhcp", "@dnsmasq[0]", "server", {data.dns})
                uci:set("dhcp", "@dnsmasq[0]", "noresolv", "1")
            end

        elseif data.stage == "kids" then
            set_wifi("ssid", data.ssid)
            set_wifi("key", data.password)
            set_wifi("encryption", "psk2")
            set_wifi("disabled", "0")
            uci:set("dhcp", "kids", "dhcp_option", {"6," .. data.dns})

            -- SafeSearch and DoH — wired up in wizard step 2
            if data.safesearch ~= nil then
                sys.call("/usr/share/parental-privacy/safesearch.sh " ..
                    (data.safesearch and "enable" or "disable"))
            end
            if data.doh ~= nil then
                sys.call("/usr/share/parental-privacy/block-doh.sh " ..
                    (data.doh and "enable" or "disable"))
            end

        elseif data.stage == "gpio" then
            -- Store GPIO pin for hotplug scripts
            uci:set("parental_privacy", "default", "gpio_pin", data.gpio_pin)

        -- 2. FLAT DATA LOGIC (For Dashboard Saves)
        else
            if data.master ~= nil then set_wifi("disabled", data.master and "0" or "1") end
            if data.ssid and data.ssid ~= "" then set_wifi("ssid", data.ssid) end
            if data.password and #data.password >= 8 then
                set_wifi("encryption", "psk2")
                set_wifi("key", data.password)
            end
            if data.isolate ~= nil then set_wifi("isolate", data.isolate and "1" or "0") end

            -- Button assignments
            if data.button_config then
                uci:set("parental_privacy", "default", "button_btn0",  data.button_config.btn0  and "1" or "0")
                uci:set("parental_privacy", "default", "button_wps",   data.button_config.wps   and "1" or "0")
                uci:set("parental_privacy", "default", "button_reset", data.button_config.reset and "1" or "0")
            end

            -- Bandwidth Limiting
            if data.bandwidth then
                sys.call("/usr/share/parental-privacy/bandwidth.sh " .. data.bandwidth)
            end

            -- DNS & DoH Blocking
            if data.dns then uci:set("dhcp", "kids", "dhcp_option", {"6," .. data.dns}) end
            if data.doh ~= nil then
                local doh_state = data.doh and "enable" or "disable"
                sys.call("/usr/share/parental-privacy/block-doh.sh " .. doh_state)
            end

            -- SafeSearch (Google, Bing, YouTube restricted mode)
            if data.safesearch ~= nil then
                local ss_state = data.safesearch and "enable" or "disable"
                sys.call("/usr/share/parental-privacy/safesearch.sh " .. ss_state)
            end

            -- Safe Cron Management
            if data.schedule_data then
                local new_cron = {}
                local f_old = io.open("/etc/crontabs/root", "r")
                if f_old then
                    for line in f_old:lines() do
                        if not line:find("kids_wifi") then table.insert(new_cron, line) end
                    end
                    f_old:close()
                end

                local days_map = {Mon="1", Tue="2", Wed="3", Thu="4", Fri="5", Sat="6", Sun="0"}

                -- Determine the UTC offset in whole hours so cron (which runs in UTC
                -- on most OpenWrt builds) fires at the correct wall-clock time.
                -- `date +%z` returns the POSIX offset e.g. +0530 or -0700, which is
                -- reliable at midnight unlike comparing %H across two calls.
                local tz_offset = 0
                do
                    local z = sys.exec("date +%z 2>/dev/null"):match("([+-]%d%d%d%d)")
                    if z then
                        local sign  = (z:sub(1,1) == "-") and -1 or 1
                        local hours = tonumber(z:sub(2,3)) or 0
                        local mins  = tonumber(z:sub(4,5)) or 0
                        -- Round to nearest whole hour (handles +0530, +0545, etc.)
                        tz_offset = sign * math.floor(hours + mins / 60 + 0.5)
                    end
                end

                for day, hours in pairs(data.schedule_data) do
                    for h = 0, 23 do
                        -- Compare this hour's state against the previous hour to find transitions.
                        -- For h==0 (midnight), wrap back to hour 24 (index 24 = 11pm state).
                        local prev_idx = (h == 0) and 24 or h
                        if hours[h+1] ~= hours[prev_idx] then
                            local state = hours[h+1] and "0" or "1"
                            local cmd = string.format("uci set wireless.kids_wifi.disabled=%s", state)
                            -- Sync all bands to the schedule
                            if uci:get("wireless", "kids_wifi_5g") then cmd = cmd .. " && uci set wireless.kids_wifi_5g.disabled=" .. state end
                            if uci:get("wireless", "kids_wifi_6g") then cmd = cmd .. " && uci set wireless.kids_wifi_6g.disabled=" .. state end
                            cmd = cmd .. " && uci commit wireless && wifi reload"

                            -- Convert the local hour to UTC for the cron expression.
                            -- If the shift crosses midnight the day-of-week must also roll.
                            local utc_h   = (h - tz_offset) % 24
                            local day_num = tonumber(days_map[day]) or 0
                            local day_shift = 0
                            if (h - tz_offset) < 0  then day_shift = -1 end
                            if (h - tz_offset) >= 24 then day_shift =  1 end
                            local utc_dow = (day_num + day_shift) % 7
                            table.insert(new_cron, string.format("0 %d * * %d %s", utc_h, utc_dow, cmd))
                        end
                    end
                end

                local f_new = io.open("/etc/crontabs/root", "w")
                for _, line in ipairs(new_cron) do f_new:write(line .. "\n") end
                f_new:close()
                sys.call("/etc/init.d/cron restart")
            end
        end

        uci:commit("wireless")
        uci:commit("dhcp")
        uci:commit("firewall")
        sys.call("wifi reload & /etc/init.d/dnsmasq restart & /etc/init.d/firewall restart")
    end)

    http.write(json.stringify({success=ok, error=err}))
end
