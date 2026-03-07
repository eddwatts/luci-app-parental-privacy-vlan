'use strict';
// /usr/share/luci/views/parental_privacy/wizard.js

'require view';
'require rpc';
'require dom';

// ── RPC declarations ──────────────────────────────────────────────────────────
const callStatus = rpc.declare({
    object: 'parental-privacy',
    method: 'status',
    expect: {}
});

const callApply = rpc.declare({
    object: 'parental-privacy',
    method: 'apply',
    params: ['data'],
    expect: {}
});

// ── State ─────────────────────────────────────────────────────────────────────
let primaryDNS  = 'isp';
let kidsDNS     = '1.1.1.3';
let bridgeMode  = false;
let availPorts  = [];
let selectedPorts = [];

// ── Helpers ───────────────────────────────────────────────────────────────────
function $(id) { return document.getElementById(id); }

function goStep(n) {
    // Steps 1-3 always exist; step 4 (port picker) only shown in bridge mode
    const maxStep = bridgeMode ? 4 : 3;
    const steps = bridgeMode ? [1,2,3,4] : [1,2,3];
    steps.forEach(i => {
        const s = $('step' + i); if (s) s.classList.remove('active');
        const t = $('tab'  + i); if (!t) return;
        t.classList.remove('active');
        if (i < n) t.classList.add('done');
        else t.classList.remove('done');
    });
    const target = $('step' + n);
    if (target) target.classList.add('active');
    const tab = $('tab' + n);
    if (tab) tab.classList.add('active');
    window.scrollTo(0, 0);
}

function pickDNS(el, val) {
    document.querySelectorAll('#step1 .pp-card')
        .forEach(c => c.classList.remove('selected'));
    el.classList.add('selected');
    primaryDNS = val;
}

function pickKidsDNS(el, val) {
    document.querySelectorAll('#step2 .pp-card')
        .forEach(c => c.classList.remove('selected'));
    el.classList.add('selected');
    kidsDNS = val;
}

function togglePort(port, el) {
    const idx = selectedPorts.indexOf(port);
    if (idx >= 0) {
        selectedPorts.splice(idx, 1);
        el.classList.remove('selected');
    } else {
        selectedPorts.push(port);
        el.classList.add('selected');
    }
}

function toggleGPIO(cb) {
    $('gpio_fields').style.display = cb.checked ? 'block' : 'none';
}

function clearError(id) {
    $(id).style.display = 'none';
}

function showResult(ok, msg) {
    const el = $('pp-result');
    el.style.display = 'block';
    el.className = 'alert ' + (ok ? 'alert-success' : 'alert-danger');
    el.textContent = (ok ? '✔ ' : '✖ ') + msg;
}

// ── Show/hide YouTube mode + block-search when SafeSearch is toggled ──────────
function toggleSafeSearchOptions(cb) {
    const opts = $('wiz_safesearch_opts');
    if (opts) opts.style.display = cb.checked ? 'flex' : 'none';
}

// ── Validate step 2 ───────────────────────────────────────────────────────────
function validateAndNext() {
    const ssid = $('kids_ssid').value.trim();
    const pwd  = $('kids_pwd').value;
    let ok = true;

    if (ssid.length < 1) {
        $('ssid-error').style.display = 'block';
        ok = false;
    }
    if (pwd.length < 8) {
        $('pwd-error').style.display = 'block';
        ok = false;
    }
    if (ok) goStep(3);
}

// ── Apply all stages sequentially ────────────────────────────────────────────
async function applyAll() {
    const btn = $('apply-btn');
    btn.disabled    = true;
    btn.textContent = '⏳ ' + _('Applying…');

    const stages = [
        { stage: 'primary', dns: primaryDNS },
        {
            stage:        'kids',
            ssid:         $('kids_ssid').value.trim(),
            password:     $('kids_pwd').value,
            dns:          kidsDNS,
            safesearch:   $('wiz_safesearch').checked,
            youtube_mode: $('wiz_ytmode') ? $('wiz_ytmode').value : 'moderate',
            block_search: $('wiz_blocksearch') ? $('wiz_blocksearch').checked : false,
            doh:          $('wiz_doh').checked,
            dot:          $('wiz_dot').checked,
			vpn_block:    $('wiz_vpn_block').checked,
			undesirable:  $('wiz_undesirable').checked
        }
    ];

    if ($('gpio_enable').checked) {
        stages.push({
            stage:    'gpio',
            gpio_pin: $('gpio_pin').value
        });
    }

    // Bridge mode: assign chosen ports
    if (bridgeMode && selectedPorts.length > 0) {
        stages.push({ ports: selectedPorts });
    }

    for (const stage of stages) {
        try {
            const data = await callApply(stage);
            if (!data || !data.success) {
                showResult(false, data ? data.error : _('Unknown error'));
                btn.disabled    = false;
                btn.textContent = '✔ ' + _('Apply Configuration');
                return;
            }
        } catch(e) {
            showResult(false, e.toString());
            btn.disabled    = false;
            btn.textContent = '✔ ' + _('Apply Configuration');
            return;
        }
    }

    showResult(true, _('All settings applied successfully! Taking you to the dashboard…'));
    btn.disabled    = false;
    btn.textContent = '✔ ' + _('Apply Configuration');

    setTimeout(() => {
        window.location = L.url('admin/network/parental_privacy/kids');
    }, 2500);
}

// ── View ──────────────────────────────────────────────────────────────────────
return view.extend({

    load() {
        return callStatus().catch(() => ({}));
    },

    render(status) {
        const existingSSID = status && status.ssid ? status.ssid : '';
        bridgeMode  = !!(status && status.bridge_mode);
        availPorts  = (status && status.available_ports) || [];
        selectedPorts = [];

        // Build port picker cards for bridge mode
        const portCards = availPorts.length
            ? availPorts.map(p =>
                `<div class="pp-card pp-port-card" id="port-${p}" onclick="togglePort('${p}',this)">
                   <h4>&#127760; ${p}</h4>
                   <small>${_('Click to assign this LAN port to the kids network')}</small>
                 </div>`
              ).join('')
            : `<p class="alert alert-warning">${_('No free LAN ports detected. You can assign ports later from the dashboard.')}</p>`;

        const bridgeNotice = bridgeMode ? `
  <div class="alert alert-warning" style="margin-bottom:1rem">
    &#9888; <strong>${_('Bridge mode active')}</strong> —
    ${_('Broadcom WiFi detected. VLAN tagging is not supported on this hardware. The kids network uses a dedicated bridge instead. WiFi isolation is automatic. For wired isolation, assign dedicated LAN ports in the next step.')}
  </div>` : '';

        const step4Tab  = bridgeMode ? `<div class="pp-tab" id="tab4">${_('4. LAN Ports')}</div>` : '';
        const step4Html = bridgeMode ? `
  <!-- STEP 4 — LAN Port assignment (bridge mode only) -->
  <div class="pp-step" id="step4">
    <h3>${_('Assign LAN Ports (Optional)')}</h3>
    <div class="alert alert-info">
      ${_('Your router uses a Broadcom WiFi chip that does not support VLAN tagging. WiFi devices are already isolated on the kids network. To isolate wired devices too, select which physical LAN ports should belong to the kids network. Unselected ports remain on your main network.')}
    </div>
    <div id="port-picker">
      ${portCards}
    </div>
    <p><small>${_('You can change port assignments any time from the dashboard.')}</small></p>
    <div style="margin-top:20px; display:flex; gap:8px; justify-content:flex-end">
      <button class="cbi-button" onclick="goStep(3)">← ${_('Back')}</button>
      <button class="cbi-button cbi-button-action" id="apply-btn" onclick="applyAll()">
        ✔ ${_('Apply Configuration')}
      </button>
    </div>
  </div>` : '';

        // Step 3 forward button routes to step 4 in bridge mode, else applies
        const step3Next = bridgeMode
            ? `<button class="cbi-button cbi-button-action" onclick="goStep(4)">${_('Next: LAN Ports')} →</button>`
            : `<button class="cbi-button cbi-button-action" id="apply-btn" onclick="applyAll()">✔ ${_('Apply Configuration')}</button>`;

        const css = `
<style>
  .pp-wizard { max-width:720px; }
  .pp-step { display:none; }
  .pp-step.active { display:block; }
  .pp-card {
    border:1px solid #ddd; border-radius:4px;
    padding:12px 14px; margin:6px 0; cursor:pointer;
    transition:border-color .15s;
  }
  .pp-card:hover, .pp-card.selected { border-color:#337ab7; background:#f0f8ff; }
  .pp-card h4 { margin:0 0 3px; }
  .pp-steps-bar {
    display:flex; margin-bottom:1rem; border-bottom:2px solid #ddd;
    overflow-x:auto; white-space:nowrap;
    -ms-overflow-style:none; scrollbar-width:none;
  }
  .pp-steps-bar::-webkit-scrollbar { display:none; }
  .pp-tab {
    flex:1 0 auto; text-align:center;
    padding:9px 16px; cursor:pointer; color:#888;
    border-bottom:2px solid transparent; margin-bottom:-2px;
  }
  .pp-tab.active { color:#337ab7; border-bottom-color:#337ab7; font-weight:600; }
  .pp-tab.done { color:#5cb85c; }
  .field-row { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
  @media(max-width:500px) { .field-row { grid-template-columns:1fr; } }
  .pp-toggle-row {
    display:flex; align-items:flex-start; gap:10px;
    padding:9px 0; border-bottom:1px solid #eee;
  }
  .pp-toggle-row:last-child { border-bottom:none; }
  .pp-toggle-row input[type=checkbox] { margin-top:3px; width:16px; height:16px; flex-shrink:0; }
  .pp-toggles-box { border:1px solid #ddd; border-radius:4px; padding:4px 14px; margin-top:12px; }
  .field-error { color:#d9534f; font-size:.85em; margin-top:4px; display:none; }
  .pp-port-card.selected { border-color:#5cb85c; background:#f0fff4; }
</style>`;

        const html = `
${css}

<h2 class="section-title">${_('Parental Privacy Wizard')}</h2>

<div class="pp-wizard">

  ${bridgeNotice}

  <!-- Already-configured warning -->
  <div id="pp-already-warn" class="alert alert-warning"
       style="display:${existingSSID ? 'block' : 'none'}">
    ⚠ ${_('Kids network already configured (SSID:')}
    <strong id="pp-existing-ssid">${existingSSID}</strong>).
    ${_('Completing this wizard will overwrite your existing settings.')}
    <a href="${L.url('admin/network/parental_privacy/kids')}"
       style="margin-left:8px">${_('Go to dashboard instead')} →</a>
  </div>

  <!-- Step tabs -->
  <div class="pp-steps-bar">
    <div class="pp-tab active" id="tab1">${_('1. Primary DNS')}</div>
    <div class="pp-tab" id="tab2">${_('2. Kids WiFi')}</div>
    <div class="pp-tab" id="tab3">${_('3. Hardware Button')}</div>
    ${step4Tab}
  </div>

  <!-- STEP 1 — Primary DNS -->
  <div class="pp-step active" id="step1">
    <h3>${_('Secure Your Main Network')}</h3>
    <div class="alert alert-info">
      ${_('Every time a device visits a website it asks a DNS server for directions. Choosing a protective DNS like Quad9 blocks known malware and scam sites before they load — with zero performance overhead.')}
    </div>

    <div class="pp-card selected" onclick="pickDNS(this,'isp')">
      <h4>${_('ISP Default')}</h4>
      <small>${_('Uses your internet provider\'s DNS. May satisfy 12-month data retention mandates.')}</small>
    </div>
    <div class="pp-card" onclick="pickDNS(this,'9.9.9.9')">
      <h4>${_('Quad9 — Malware Shield')} <code>9.9.9.9</code></h4>
      <small>${_('Blocks known malware and phishing. No logging. Non-profit, Switzerland-based.')}</small>
    </div>
    <div class="pp-card" onclick="pickDNS(this,'1.1.1.2')">
      <h4>${_('Cloudflare — Privacy and Malware Protection')} <code>1.1.1.2</code></h4>
      <small>${_('Fastest public DNS resolver. Privacy-focused, protection from malware, minimal data retention.')}</small>
    </div>
    <div class="pp-card" onclick="pickDNS(this,'1.1.1.1')">
      <h4>${_('Cloudflare — Privacy')} <code>1.1.1.1</code></h4>
      <small>${_('Fastest public DNS resolver. Privacy-focused, minimal data retention.')}</small>
    </div>
    <div class="pp-card" onclick="pickDNS(this,'94.140.14.14')">
      <h4>${_('AdGuard DNS — Ad Blocking')} <code>94.140.14.14</code></h4>
      <small>${_('Blocks ads and trackers for every device on your network. No setup required.')}</small>
    </div>

    <div style="margin-top:16px; text-align:right">
      <button class="cbi-button cbi-button-action" onclick="goStep(2)">
        ${_('Next: Kids WiFi')} →
      </button>
    </div>
  </div>

  <!-- STEP 2 — Kids WiFi -->
  <div class="pp-step" id="step2">
    <h3>${_('Kids WiFi Fortress')}</h3>
    <div class="alert alert-info">
      ${_('This creates a separate WiFi on its own subnet. DHCP Option 6 forces every connected device to use a family-safe DNS — and a firewall rule blocks any attempt to bypass it. No accounts or ID checks ever required.')}
    </div>

    <div class="field-row">
      <div>
        <label>${_('Network Name (SSID)')}</label><br>
        <input type="text" id="kids_ssid" value="_Kids_WiFi" style="width:100%"
               oninput="clearError('ssid-error')">
        <div class="field-error" id="ssid-error">${_('Please enter a network name.')}</div>
      </div>
      <div>
        <label>${_('Password (min. 8 characters)')}</label><br>
        <input type="password" id="kids_pwd" value="" placeholder="${_('min. 8 chars')}"
               style="width:100%" oninput="clearError('pwd-error')">
        <div class="field-error" id="pwd-error">${_('Password must be at least 8 characters.')}</div>
      </div>
    </div>

    <h4 style="margin-top:16px">${_('Choose Family DNS')}</h4>
    <div class="pp-card selected" onclick="pickKidsDNS(this,'1.1.1.3')">
      <h4>${_('Cloudflare for Families')} <code>1.1.1.3</code></h4>
      <small>${_('Blocks malware and adult content. No account needed.')}</small>
    </div>
    <div class="pp-card" onclick="pickKidsDNS(this,'185.228.168.9')">
      <h4>${_('CleanBrowsing')} <code>185.228.168.9</code></h4>
      <small>${_('Strict family filter — blocks adult content, proxies, and VPN sites.')}</small>
    </div>
    <div class="pp-card" onclick="pickKidsDNS(this,'208.67.222.123')">
      <h4>${_('OpenDNS FamilyShield')} <code>208.67.222.123</code></h4>
      <small>${_('Cisco-backed. Blocks adult content automatically, no account required.')}</small>
    </div>

    <div class="pp-toggles-box">
      <div class="pp-toggle-row">
        <input type="checkbox" id="wiz_safesearch" checked onchange="toggleSafeSearchOptions(this)">
        <div>
          <strong>${_('Force SafeSearch')}</strong><br>
          <small>${_('Enforces safe results on Google, Bing, YouTube, DuckDuckGo, Brave and Pixabay at DNS level — no device cooperation needed.')}</small>
        </div>
      </div>
      <div id="wiz_safesearch_opts" style="margin-left:1.75rem; margin-top:.5rem; display:flex; flex-direction:column; gap:.5rem;">
        <div>
          <label style="font-size:.85rem; font-weight:600">${_('YouTube restriction level')}</label><br>
          <small style="color:#666">${_('Moderate blocks most adult content. Strict enables supervised mode — very locked down, may block legitimate videos.')}</small><br>
          <select id="wiz_ytmode" style="margin-top:.3rem; max-width:160px">
            <option value="moderate" selected>${_('Moderate')}</option>
            <option value="strict">${_('Strict')}</option>
          </select>
        </div>
        <div class="pp-toggle-row" style="margin-top:.25rem">
          <input type="checkbox" id="wiz_blocksearch">
          <div>
            <strong>${_('Block uncontrolled search engines')}</strong><br>
            <small>${_('Blocks search engines that cannot enforce SafeSearch at DNS level (e.g. Yandex, Baidu, Startpage, Ecosia). Prevents bypassing SafeSearch by switching to an unsupported engine.')}</small>
          </div>
        </div>
      </div>
      <div class="pp-toggle-row">
        <input type="checkbox" id="wiz_doh" checked>
        <div>
          <strong>${_('Block DNS-over-HTTPS bypass')}</strong><br>
          <small>${_('Prevents browsers silently bypassing the DNS filter using encrypted DNS. Recommended.')}</small>
        </div>
      </div>
      <div class="pp-toggle-row">
        <input type="checkbox" id="wiz_dot" checked>
        <div>
          <strong>${_('Block DNS-over-TLS bypass')}</strong><br>
          <small>${_('Blocks port 853 so devices cannot use encrypted DNS-over-TLS to bypass the filter. Recommended.')}</small>
        </div>
      </div>

	  <div class="pp-toggle-row">
	    <input type="checkbox" id="wiz_vpn_block" checked>
		<div>
		  <strong>${_('Block VPN & Bypass Tools')}</strong><br>
		  <small>${_('Blocks common VPN ports (OpenVPN, WireGuard) to prevent kids from bypassing the DNS filters.')}</small>
		</div>
	  </div>

	  <div class="pp-toggle-row">
		<input type="checkbox" id="wiz_undesirable" checked>
		<div>
		  <strong>${_('Block Undesirable Apps')}</strong><br>
		  <small>${_('Automatically blocks TikTok and Snapchat domains at the DNS level.')}</small>
		</div>
	  </div>

    </div>

    <div style="margin-top:16px; display:flex; gap:8px; justify-content:flex-end">
      <button class="cbi-button" onclick="goStep(1)">← ${_('Back')}</button>
      <button class="cbi-button cbi-button-action" onclick="validateAndNext()">
        ${_('Next: Hardware Button')} →
      </button>
    </div>
  </div>

  <!-- STEP 3 — Hardware Button -->
  <div class="pp-step" id="step3">
    <h3>${_('Hardware Kill-Switch (Optional)')}</h3>
    <div class="alert alert-info">
      ${_('Assign a physical button on your router (e.g. the WPS button) to instantly toggle the Kids WiFi on or off. The wizard writes a hotplug script — no reboot needed, takes effect immediately on press.')}
    </div>

    <label>
      <input type="checkbox" id="gpio_enable" checked onchange="toggleGPIO(this)">
      ${_('Enable hardware button toggle')}
    </label>

    <div id="gpio_fields" style="margin-top:12px">
      <label>${_('GPIO Pin / Button ID')}</label><br>
      <input type="number" id="gpio_pin" value="0" min="0" max="255" style="width:120px">
      <p><small>${_('Common values: 0 = WPS button, 11 = Reset. Check your router\'s hardware page on the OpenWrt wiki for the correct pin number.')}</small></p>
    </div>

    <div style="margin-top:20px; display:flex; gap:8px; justify-content:flex-end">
      <button class="cbi-button" onclick="goStep(2)">← ${_('Back')}</button>
      ${step3Next}
    </div>
  </div>

  ${step4Html}

  <!-- Result -->
  <div id="pp-result" style="display:none; margin-top:16px"></div>

</div>`;

        return dom.parse(html);
    },

    // Suppress default LuCI save/reset footer buttons
    handleSaveApply: null,
    handleSave: null,
    handleReset: null,

    addFooter() {
        // Expose functions needed by inline onclick handlers
        Object.assign(window, {
            goStep, pickDNS, pickKidsDNS, toggleGPIO,
            clearError, validateAndNext, applyAll, togglePort,
            toggleSafeSearchOptions
        });
    }
});
