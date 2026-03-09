'use strict';
// /usr/share/luci/views/parental_privacy/dashboard.js

'require view';
'require rpc';
'require ui';
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

const callExtend = rpc.declare({
    object: 'parental-privacy',
    method: 'extend',
    expect: {}
});

const callRemove = rpc.declare({
    object: 'parental-privacy',
    method: 'remove',
    expect: {}
});

const callBlocklistApply = rpc.declare({
    object: 'parental-privacy',
    method: 'blocklist_apply',
    params: ['data'],
    expect: {}
});

const callBlocklistUpdate = rpc.declare({
    object: 'parental-privacy',
    method: 'blocklist_update',
    expect: {}
});

const callPauseDevice = rpc.declare({
    object: 'parental-privacy',
    method: 'pause_device',
    params: ['data'],
    expect: {}
});

const callListPaused = rpc.declare({
    object: 'parental-privacy',
    method: 'list_paused',
    expect: {}
});

const callGetLogs = rpc.declare({
    object: 'parental-privacy',
    method: 'get_logs',
    expect: {}
});

// clear_logs is a dedicated rpcd method — the backend injects {"action":"clear"}
// itself so no params envelope is needed here and no unwrapping is required in
// the shell script.  Using a separate method (rather than a magic parameter on
// get_logs) makes the ACL surface explicit and keeps each endpoint single-purpose.
const callClearLogs = rpc.declare({
    object: 'parental-privacy',
    method: 'clear_logs',
    expect: {}
});

// ── Constants ─────────────────────────────────────────────────────────────────
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const MAX_RANGES_PER_DAY = 4;

// ── State ─────────────────────────────────────────────────────────────────────
// schedule: { Mon: ["06:00-20:00", ...], ... }  up to 4 ranges per day
let schedule     = {};
let selectedDNS  = '1.1.1.3';
let primarySSID  = '';
let suggestedSSID = '';
let statusTimer  = null;
let toastTimer   = null;
let logsTimer    = null;

// Initialise schedule with empty arrays
DAYS.forEach(d => { schedule[d] = []; });

// ── Blocklist state ───────────────────────────────────────────────────────────
// The blocklist catalog is maintained by update-blocklists.sh, which fetches
// blocklists.json from GitHub at each run and syncs it into UCI.
// The dashboard reads catalog + enabled state from the status RPC — no direct
// GitHub fetch is needed here.
let blCatalog       = [];   // populated from status RPC (blocklists array)
let blEnabled       = {};   // { id: true/false } — loaded from UCI via status
let blCustomEntries = [];   // user-added custom URLs


// ── Helpers ───────────────────────────────────────────────────────────────────
function $(id) { return document.getElementById(id); }

function showToast(type, msg) {
    const t = $('kn-toast');
    $('kn-toast-msg').textContent = msg;
    t.className = 'kn-toast show ' + type;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = 'kn-toast'; }, 3200);
}

function addLog(type, msg) {
    const box = $('log-box');
    if (!box) return;
    const now = new Date();
    const ts  = [now.getHours(), now.getMinutes(), now.getSeconds()]
                    .map(n => String(n).padStart(2, '0')).join(':');
    const div = document.createElement('div');
    div.innerHTML = `<span class="log-ts">${ts}</span><span class="log-${type}">${msg}</span>`;
    box.appendChild(div);
    box.scrollTop = box.scrollHeight;
}

function markUnsaved() {
    $('unsaved-badge').style.display = 'inline-flex';
    const ssid = $('wifi-ssid');
    if (ssid) $('stat-ssid').textContent = ssid.value || '_Kids_WiFi';
}

// ── Time range utilities ──────────────────────────────────────────────────────
function timeToMins(t) {
    const [h, m] = t.split(':').map(Number);
    return h * 60 + m;
}

function minsToTime(m) {
    return String(Math.floor(m / 60)).padStart(2, '0') + ':' +
           String(m % 60).padStart(2, '0');
}

function rangesOverlap(ranges) {
    const sorted = [...ranges].sort((a, b) =>
        timeToMins(a.split('-')[0]) - timeToMins(b.split('-')[0]));
    for (let i = 1; i < sorted.length; i++) {
        const prevEnd   = timeToMins(sorted[i - 1].split('-')[1]);
        const currStart = timeToMins(sorted[i].split('-')[0]);
        if (currStart < prevEnd) return true;
    }
    return false;
}

function validateRange(range) {
    return /^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$/.test(range);
}

// ── Schedule panel ────────────────────────────────────────────────────────────
function buildSchedulePanel() {
    const container = $('schedule-ranges');
    if (!container) return;
    container.innerHTML = '';

    DAYS.forEach(day => {
        const dayDiv = document.createElement('div');
        dayDiv.className = 'kn-sched-day';
        dayDiv.dataset.day = day;

        const header = document.createElement('div');
        header.className = 'kn-sched-day-header';

        const dayLabel = document.createElement('strong');
        dayLabel.textContent = day;
        dayLabel.style.minWidth = '36px';

        const addBtn = document.createElement('button');
        addBtn.className = 'cbi-button cbi-button-add kn-sched-add';
        addBtn.textContent = '+ Add';
        addBtn.disabled = schedule[day].length >= MAX_RANGES_PER_DAY;
        addBtn.onclick = () => addRange(day);

        const noSched = document.createElement('span');
        noSched.className = 'kn-sched-unrestricted';
        noSched.textContent = schedule[day].length === 0 ? ' (unrestricted)' : '';
        noSched.id = `unrestricted-${day}`;

        header.appendChild(dayLabel);
        header.appendChild(noSched);
        header.appendChild(addBtn);
        dayDiv.appendChild(header);

        const rangesDiv = document.createElement('div');
        rangesDiv.className = 'kn-sched-ranges';
        rangesDiv.id = `ranges-${day}`;

        schedule[day].forEach((range, idx) => {
            rangesDiv.appendChild(buildRangeRow(day, idx, range));
        });

        dayDiv.appendChild(rangesDiv);
        container.appendChild(dayDiv);
    });

    updateScheduleStat();
}

function buildRangeRow(day, idx, range) {
    const [start, end] = range.split('-');
    const row = document.createElement('div');
    row.className = 'kn-range-row';
    row.dataset.idx = idx;

    const startInput = document.createElement('input');
    startInput.type = 'time';
    startInput.className = 'cbi-input-text kn-time-input';
    startInput.value = start;
    startInput.onchange = () => updateRange(day, idx);

    const sep = document.createElement('span');
    sep.textContent = '→';
    sep.style.margin = '0 .4rem';

    const endInput = document.createElement('input');
    endInput.type = 'time';
    endInput.className = 'cbi-input-text kn-time-input';
    endInput.value = end;
    endInput.onchange = () => updateRange(day, idx);

    const delBtn = document.createElement('button');
    delBtn.className = 'cbi-button cbi-button-remove';
    delBtn.textContent = '✕';
    delBtn.style.marginLeft = '.5rem';
    delBtn.onclick = () => removeRange(day, idx);

    row.appendChild(startInput);
    row.appendChild(sep);
    row.appendChild(endInput);
    row.appendChild(delBtn);
    return row;
}

function addRange(day) {
    if (schedule[day].length >= MAX_RANGES_PER_DAY) return;

    // Default: start after the last range, or 08:00-18:00 if empty
    let defaultStart = '08:00';
    let defaultEnd   = '18:00';

    if (schedule[day].length > 0) {
        const lastEnd = schedule[day][schedule[day].length - 1].split('-')[1];
        const lastEndMins = timeToMins(lastEnd);
        defaultStart = lastEnd;
        defaultEnd   = minsToTime(Math.min(lastEndMins + 120, 23 * 60 + 59));
    }

    schedule[day].push(`${defaultStart}-${defaultEnd}`);
    buildSchedulePanel();
    markUnsaved();
}

function removeRange(day, idx) {
    schedule[day].splice(idx, 1);
    buildSchedulePanel();
    markUnsaved();
}

function updateRange(day, idx) {
    const rangesDiv  = $(`ranges-${day}`);
    const rows       = rangesDiv.querySelectorAll('.kn-range-row');
    const row        = rows[idx];
    const inputs     = row.querySelectorAll('input[type=time]');
    const start      = inputs[0].value;
    const end        = inputs[1].value;

    if (!start || !end) return;

    const newRange = `${start}-${end}`;

    if (timeToMins(end) <= timeToMins(start)) {
        showToast('err', `${day}: end time must be after start time`);
        return;
    }

    schedule[day][idx] = newRange;

    if (rangesOverlap(schedule[day])) {
        showToast('err', `${day}: time ranges must not overlap`);
        // Revert
        buildSchedulePanel();
        return;
    }

    // Keep ranges sorted by start time
    schedule[day].sort((a, b) =>
        timeToMins(a.split('-')[0]) - timeToMins(b.split('-')[0]));

    updateScheduleStat();
    markUnsaved();
}

function applyPreset(val) {
    if (!val) return;
    DAYS.forEach(d => {
        const isWeekendNight = (d === 'Fri' || d === 'Sat');
        switch (val) {
            case 'school':
                schedule[d] = isWeekendNight ? ['06:00-21:00'] : ['06:00-20:00'];
                break;
            case 'strict':
                schedule[d] = ['09:00-19:00'];
                break;
            case 'splitday':
                // Morning + evening — typical school day split
                schedule[d] = isWeekendNight
                    ? ['08:00-12:00', '15:00-21:00']
                    : ['07:00-08:00', '15:30-20:00'];
                break;
            case 'weekend':
                // Weekdays restricted; weekends relaxed
                if (d === 'Sat') {
                    schedule[d] = ['08:00-21:00'];
                } else if (d === 'Sun') {
                    schedule[d] = ['08:00-20:00'];
                } else if (d === 'Fri') {
                    schedule[d] = ['15:00-21:00'];
                } else {
                    schedule[d] = ['07:00-08:00', '15:30-19:00'];
                }
                break;
            case 'allday':
                schedule[d] = ['00:00-23:59'];
                break;
            case 'clear':
                schedule[d] = [];
                break;
        }
    });
    buildSchedulePanel();
    markUnsaved();
    $('schedule-preset').value = '';
}

function updateScheduleStat() {
    const el = $('stat-schedule');
    if (!el) return;
    const dn    = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    const now   = new Date();
    const today = dn[now.getDay()];
    const nowM  = now.getHours() * 60 + now.getMinutes();

    const todayRanges = schedule[today] || [];
    let activeUntil = -1;
    let nextStart   = -1;

    for (const range of todayRanges) {
        const [s, e] = range.split('-').map(timeToMins);
        if (nowM >= s && nowM < e) { activeUntil = e; break; }
        if (s > nowM && nextStart === -1) nextStart = s;
    }

    if (activeUntil >= 0) {
        el.textContent = `ON until ${minsToTime(activeUntil)}`;
    } else if (nextStart >= 0) {
        el.textContent = `OFF — ON at ${minsToTime(nextStart)}`;
    } else {
        el.textContent = todayRanges.length === 0 ? 'Unrestricted' : 'OFF today';
    }
}

// ── Access status banner & stat card ─────────────────────────────────────────
// Reads internet_blocked from the last status poll and updates both the
// top-bar stat card and the banner inside the Schedule section.
function updateAccessStat(internetBlocked) {
    // ── Top-bar stat card ─────────────────────────────────────────────────────
    const card  = $('stat-card-access');
    const val   = $('stat-access');
    if (card && val) {
        if (internetBlocked) {
            card.className = 'kn-stat-card kn-red';
            val.className  = 'kn-stat-val kn-red';
            val.textContent = _('Blocked');
        } else {
            card.className = 'kn-stat-card kn-green';
            val.className  = 'kn-stat-val kn-green';
            val.textContent = _('Allowed');
        }
    }

    // ── Schedule section banner ───────────────────────────────────────────────
    const banner = $('access-banner');
    const icon   = $('access-banner-icon');
    const title  = $('access-banner-title');
    const detail = $('access-banner-detail');
    if (!banner) return;

    if (internetBlocked) {
        banner.className     = 'kn-access-banner blocked';
        icon.textContent     = '✖';
        title.textContent    = _('Internet access blocked');
        detail.textContent   = _('A firewall rule is active. Devices are connected to WiFi and can resolve DNS, but all internet traffic is dropped.');
    } else {
        banner.className     = 'kn-access-banner allowed';
        icon.textContent     = '✔';
        title.textContent    = _('Internet access allowed');
        detail.textContent   = _('No schedule block is active. Traffic flows normally through the kids VLAN.');
    }
}


// ── DNS Activity Log ─────────────────────────────────────────────────────────
// Polls rpc get_logs every 20 seconds and renders a table of the last 50
// DNS queries made by kids-network devices.  The log file lives entirely in
// RAM (/tmp/dnsmasq-kids.log) and is never written to flash.

async function updateActivityLog() {
    const box = document.getElementById('dns-log-tbody');
    if (!box) return;

    let data;
    try { data = await callGetLogs(); }
    catch(e) { return; }

    if (!data || !Array.isArray(data.logs)) return;

    if (data.logs.length === 0) {
        box.innerHTML = '<tr><td colspan="3" style="text-align:center;color:#aaa;font-style:italic;padding:.5rem 0">' +
            _('No queries recorded yet.') + '</td></tr>';
        return;
    }

    // Build rows newest-first (tail -n returns oldest first)
    const rows = data.logs.slice().reverse().map(entry => {
        // Resolve client IP to friendly name using device list cached on window
        const name = (window._kidsDeviceMap && window._kidsDeviceMap[entry.client])
            ? window._kidsDeviceMap[entry.client]
            : entry.client;
        const typeClass = entry.type && entry.type.includes('AAAA') ? 'log-ipv6' : 'log-ipv4';
        return `<tr>
            <td style="white-space:nowrap;font-size:.8rem;color:#888">${entry.time || ''}</td>
            <td style="font-size:.82rem">${name}</td>
            <td style="font-size:.82rem;word-break:break-all">${entry.domain || ''}</td>
        </tr>`;
    }).join('');

    box.innerHTML = rows;
}

async function clearActivityLog() {
    const btn = document.getElementById('dns-log-clear-btn');
    if (btn) { btn.disabled = true; btn.textContent = _('Clearing…'); }
    try {
        await callClearLogs();
        const box = document.getElementById('dns-log-tbody');
        if (box) box.innerHTML = '<tr><td colspan="3" style="text-align:center;color:#aaa;font-style:italic;padding:.5rem 0">' +
            _('Log cleared.') + '</td></tr>';
        showToast(_('DNS activity log cleared.'));
    } catch(e) {
        showToast(_('Failed to clear log.'));
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = '🗑 ' + _('Clear Log'); }
    }
}


async function updateStatus() {
    let data;
    try { data = await callStatus(); }
    catch(e) { return; }

    if (!data) return;

    primarySSID   = data.primary_ssid  || '';
    suggestedSSID = data.suggested_ssid || '';

    const suggWrap = document.getElementById('ssid-suggestion-wrap');
    const suggText = document.getElementById('ssid-suggestion-text');
    if (suggText) suggText.textContent = suggestedSSID;
    if (suggWrap) suggWrap.style.display = suggestedSSID ? '' : 'none';

    // Only update fields if no unsaved changes pending
    if ($('unsaved-badge').style.display === 'none') {
        if ($('wifi-ssid'))  $('wifi-ssid').value  = data.ssid || '';
        if ($('wifi-pwd'))   $('wifi-pwd').value   = data.wifi_password || '';
        $('stat-ssid').textContent = data.ssid || '';

        // Sync master switch
        const ms = $('master-switch');
        if (ms) {
            ms.classList.toggle('on', !!data.active);
            $('master-label').textContent = data.active
                ? _('Kids WiFi Active') : _('Kids WiFi Off');
        }

        // Sync safesearch, doh + relay toggles
        const ss = $('sw-safesearch');
        if (ss) {
            ss.classList.toggle('on', !!data.safesearch);
            const ssOn = !!data.safesearch;
            const ytRow = $('row-youtube-mode');
            const bsRow = $('row-block-search');
            if (ytRow) ytRow.style.display = ssOn ? '' : 'none';
            if (bsRow) bsRow.style.display = ssOn ? '' : 'none';
        }
        const ytSel = $('yt-mode-select');
        if (ytSel && data.youtube_mode) ytSel.value = data.youtube_mode;
        const bsSw = $('sw-block-search');
        if (bsSw) bsSw.classList.toggle('on', !!data.block_search);
        const doh = $('BlockDoH');
        if (doh) doh.classList.toggle('on', !!data.doh_block);
        const dot = $('BlockDoT');
        if (dot) dot.classList.toggle('on', !!data.dot_block);
        const vpnSw = $('sw-vpn-block');
        if (vpnSw) vpnSw.classList.toggle('on', !!data.vpn_block);
        const undSw = $('sw-undesirable');
        if (undSw) undSw.classList.toggle('on', !!data.undesirable);
        const relay = $('sw-relay');
        if (relay) relay.classList.toggle('on', !!data.broadcast_relay);

        // Load schedule from status (convert range arrays to our format)
        let hasSchedule = false;
        if (data.schedule) {
            DAYS.forEach(d => {
                const ranges = data.schedule[d];
                if (Array.isArray(ranges) && ranges.length > 0) {
                    schedule[d] = ranges.filter(validateRange);
                    hasSchedule = true;
                } else {
                    schedule[d] = [];
                }
            });
            if (hasSchedule) buildSchedulePanel();
        }
    }

    updateDeviceList(data.devices || []);

    // Cache IP → hostname map for the DNS activity log renderer
    window._kidsDeviceMap = {};
    (data.devices || []).forEach(d => {
        if (d.ip && d.name && d.name !== 'Unknown') {
            window._kidsDeviceMap[d.ip] = d.name;
        }
    });

    updateScheduleStat();
    updateAccessStat(!!data.internet_blocked);
    loadBlocklistState(data);
}
// ── Device list ───────────────────────────────────────────────────────────────
// paused: tracks MAC → true/false for optimistic UI updates before RPC confirms
const paused = {};
const blocked = {};

function updateDeviceList(devices) {
    const list = $('device-list');
    if (!list) return;
    list.innerHTML = '';
    let count = 0;

    devices.forEach((dev, i) => {
        count++;
        const now     = Math.floor(Date.now() / 1000);
        const expSecs = dev.expires - now;
        const timeStr = expSecs > 0
            ? `exp ${Math.round(expSecs / 60)}m`
            : 'expired';

        // Use server-side paused state on first render; optimistic local state
        // takes over after the user clicks Pause/Resume in this session.
        if (typeof paused[dev.mac] === 'undefined') {
            paused[dev.mac] = !!dev.paused;
        }

        const isPaused = !!paused[dev.mac];

        const row = document.createElement('div');
        row.className = 'kn-device-row' + (isPaused ? ' kn-device-paused' : '');
        row.id = `device-row-${dev.mac.replace(/:/g, '')}`;

        row.innerHTML =
            `<div class="kn-device-dot ${isPaused ? 'paused' : 'online'}"></div>` +
            `<div style="flex:1">` +
              `<div><strong>${dev.name}</strong>` +
              (isPaused ? ` <span class="kn-paused-badge">${_('Paused')}</span>` : '') +
              `</div>` +
              `<div class="kn-device-mac">${dev.mac}</div>` +
            `</div>` +
            `<div class="kn-device-ip">${dev.ip}</div>` +
            `<div class="kn-device-time">${timeStr}</div>` +
            `<button class="cbi-button kn-pause-btn${isPaused ? ' kn-btn-resume' : ' kn-btn-pause'}"
                id="pause-btn-${dev.mac.replace(/:/g, '')}"
                onclick="togglePause(${JSON.stringify(dev.mac)}, ${JSON.stringify(dev.name)}, this)">` +
            (isPaused ? `&#9654; ${_('Resume')}` : `&#9646;&#9646; ${_('Pause')}`) +
            `</button>` +
            `<button class="cbi-button${blocked[dev.mac] ? ' cbi-button-remove' : ''}"
                onclick="toggleBlock(${i},this,${JSON.stringify(dev)})">` +
            (blocked[dev.mac] ? _('Unblock') : _('Block')) + `</button>`;

        list.appendChild(row);
    });

    $('stat-devices').textContent   = count;
    $('devices-count').textContent  = count + ' online';
}

async function togglePause(mac, name, btn) {
    const isPaused = !!paused[mac];
    const action   = isPaused ? 'del' : 'add';
    const macId    = mac.replace(/:/g, '');
    const row      = $(`device-row-${macId}`);

    // Optimistic UI update — flip immediately, revert on error
    paused[mac] = !isPaused;
    _applyPauseUI(mac, macId, row, btn, paused[mac]);

    try {
        await callPauseDevice({ action, mac });
        const verb = paused[mac] ? 'Paused' : 'Resumed';
        addLog(paused[mac] ? 'warn' : 'ok', `${verb}: ${name} (${mac})`);
        showToast(paused[mac] ? 'warn' : 'ok',
                  paused[mac]
                    ? `⏸ ${name} paused — internet cut immediately`
                    : `▶ ${name} resumed`);
    } catch(e) {
        // Revert on failure
        paused[mac] = isPaused;
        _applyPauseUI(mac, macId, row, btn, paused[mac]);
        showToast('err', `Failed to ${action === 'add' ? 'pause' : 'resume'} ${name}`);
        addLog('err', `RPC error toggling pause for ${mac}: ${e}`);
    }
}

function _applyPauseUI(mac, macId, row, btn, nowPaused) {
    if (!row || !btn) return;
    row.className = 'kn-device-row' + (nowPaused ? ' kn-device-paused' : '');

    const dot = row.querySelector('.kn-device-dot');
    if (dot) dot.className = 'kn-device-dot ' + (nowPaused ? 'paused' : 'online');

    // Update or remove the "Paused" badge
    const nameDiv = row.querySelector('div > strong')?.parentElement;
    if (nameDiv) {
        const badge = nameDiv.querySelector('.kn-paused-badge');
        if (nowPaused && !badge) {
            const b = document.createElement('span');
            b.className = 'kn-paused-badge';
            b.textContent = _('Paused');
            nameDiv.appendChild(b);
        } else if (!nowPaused && badge) {
            badge.remove();
        }
    }

    btn.className = 'cbi-button kn-pause-btn ' + (nowPaused ? 'kn-btn-resume' : 'kn-btn-pause');
    btn.innerHTML = nowPaused
        ? `&#9654; ${_('Resume')}`
        : `&#9646;&#9646; ${_('Pause')}`;
}

function toggleBlock(i, btn, dev) {
    blocked[dev.mac] = !blocked[dev.mac];
    btn.className    = 'cbi-button' + (blocked[dev.mac] ? ' cbi-button-remove' : '');
    btn.textContent  = blocked[dev.mac] ? _('Unblock') : _('Block');
    addLog(blocked[dev.mac] ? 'warn' : 'ok',
           (blocked[dev.mac] ? 'Blocked: ' : 'Unblocked: ') + dev.name);
    markUnsaved();
}

// ── UI toggle helpers ─────────────────────────────────────────────────────────
function toggleMaster() {
    const sw = $('master-switch');
    sw.classList.toggle('on');
    $('master-label').textContent = sw.classList.contains('on')
        ? _('Kids WiFi Active') : _('Kids WiFi Off');
    addLog(sw.classList.contains('on') ? 'ok' : 'warn',
           'Kids WiFi ' + (sw.classList.contains('on') ? 'ENABLED' : 'DISABLED') + ' manually');
    markUnsaved();
}

function pickRadio(el, val) {
    document.querySelectorAll('.kn-radio-card').forEach(c => c.classList.remove('selected'));
    el.classList.add('selected');
    el.querySelector('input').checked = true;
    markUnsaved();
}

function pickDNS(el, val) {
    document.querySelectorAll('.kn-dns-opt').forEach(c => c.classList.remove('selected'));
    el.classList.add('selected');
    selectedDNS = val;
    $('custom-dns-field').style.display = (val === 'custom') ? 'block' : 'none';
    if (val !== 'custom') $('stat-dns').textContent = val;
    markUnsaved();
}

function updateCustomPreview() {
    const v = $('custom-dns-ip').value || '—';
    $('custom-dns-preview').textContent = v;
    $('stat-dns').textContent = v;
    markUnsaved();
}

function useSuggestedSSID() {
    // suggestedSSID is populated by rpc-status.sh which now uses the smart
    // pick_primary_ssid() logic — so this always reflects the true home network.
    if (!suggestedSSID) {
        showToast('error', _('Suggested name not available yet — try again in a moment'));
        return;
    }
    $('wifi-ssid').value = suggestedSSID;
    markUnsaved();
    showToast('ok', _('Switched to suggested SSID'));
}

function togglePanel(switchEl, panelId) {
    switchEl.classList.toggle('on');
    $(panelId).style.display = switchEl.classList.contains('on') ? 'block' : 'none';
    markUnsaved();
}

// ── 1h extension ──────────────────────────────────────────────────────────────
async function grantExtension() {
    const btn = $('ext-btn');
    btn.disabled = true;
    try {
        const data = await callExtend();
        if (data && data.success) {
            showToast('ok', _('WiFi is forced ON for the next hour.'));
            addLog('ok', _('Parent granted 60-minute manual extension.'));
            setTimeout(() => { btn.disabled = false; }, 5000);
        } else {
            showToast('err', 'Extension failed');
            btn.disabled = false;
        }
    } catch(e) {
        btn.disabled = false;
        showToast('err', _('Connection failed'));
    }
}

// ── Save ──────────────────────────────────────────────────────────────────────
async function saveAll() {
    const btn = $('save-btn');
    btn.disabled    = true;
    btn.textContent = _('Applying…');

    // Validate schedule before sending
    for (const day of DAYS) {
        for (const range of schedule[day]) {
            if (!validateRange(range)) {
                showToast('err', `Invalid range format for ${day}: ${range}`);
                btn.disabled    = false;
                btn.textContent = _('Save & Apply All');
                return;
            }
        }
        if (rangesOverlap(schedule[day])) {
            showToast('err', `Overlapping ranges on ${day}`);
            btn.disabled    = false;
            btn.textContent = _('Save & Apply All');
            return;
        }
        if (schedule[day].length > MAX_RANGES_PER_DAY) {
            showToast('err', `Max ${MAX_RANGES_PER_DAY} ranges per day (${day})`);
            btn.disabled    = false;
            btn.textContent = _('Save & Apply All');
            return;
        }
    }

    const payload = {
        master:        $('master-switch').classList.contains('on'),
        ssid:          $('wifi-ssid').value,
        password:      $('wifi-pwd').value,
        radio:         document.querySelector('.kn-radio-card.selected input').value,
        dns:           selectedDNS === 'custom'
                           ? $('custom-dns-ip').value
                           : selectedDNS,
        doh:           $('BlockDoH').classList.contains('on'),
        dot:           $('BlockDoT').classList.contains('on'),
        safesearch:    $('sw-safesearch').classList.contains('on'),
        youtube_mode:  $('yt-mode-select') ? $('yt-mode-select').value : 'moderate',
        block_search:  $('sw-block-search') ? $('sw-block-search').classList.contains('on') : false,
		vpn_block:   $('sw-vpn-block').classList.contains('on'),
		undesirable: $('sw-undesirable').classList.contains('on'),
        broadcast_relay: $('sw-relay').classList.contains('on'),
        schedule:      schedule,
        button_config: {
            btn0:      $('sw-btn0').classList.contains('on'),
            wps:       $('sw-btnwps').classList.contains('on'),
            reset:     $('sw-btnreset').classList.contains('on'),
            gpio_pin:  $('gpio-pin-input') ? $('gpio-pin-input').value : ''
        }
    };

    try {
        const data = await callApply(payload);
        btn.disabled    = false;
        btn.textContent = _('Save & Apply All');

        if (data && data.success) {
            $('unsaved-badge').style.display = 'none';
            showToast('ok', _('Settings applied successfully!'));
            addLog('ok', 'Applied settings to ' + payload.radio);
            // Refresh status after a short delay to show new state
            setTimeout(updateStatus, 2000);
        } else {
            showToast('err', 'Error: ' + (data ? data.error : 'unknown'));
            addLog('error', data ? data.error : 'Apply failed');
        }
    } catch(e) {
        btn.disabled    = false;
        btn.textContent = _('Save & Apply All');
        showToast('err', _('Connection failed'));
    }
}


// ── DNS Blocklists ────────────────────────────────────────────────────────────
// The catalog is fetched from GitHub by update-blocklists.sh (runs at 03:00
// and on manual "Update Now").  The dashboard reads it back via the status RPC
// which returns the full blocklist array from UCI.  No direct GitHub fetch here.

// loadBlocklistCatalog is called from addFooter and the "Reload Catalog" button.
// Since the catalog lives in UCI (populated by the shell script), we just
// re-poll the status RPC to pick up any changes since page load.
async function loadBlocklistCatalog() {
    const panel   = $('bl-catalog-panel');
    const spinner = $('bl-spinner');
    if (spinner) spinner.style.display = 'inline';

    try {
        const data = await callStatus();
        if (data) loadBlocklistState(data);
    } catch(e) {
        if (panel) panel.innerHTML =
            `<div class="alert alert-warning">${_('Could not load blocklist catalog. The list is refreshed from GitHub automatically at 3 AM, or click Update Now to refresh immediately.')}</div>`;
    } finally {
        if (spinner) spinner.style.display = 'none';
    }
}

function renderBlocklistCatalog() {
    const panel = $('bl-catalog-panel');
    if (!panel || !blCatalog.length) return;

    // Group by provider
    const byProvider = {};
    blCatalog.forEach(entry => {
        if (!byProvider[entry.provider]) byProvider[entry.provider] = [];
        byProvider[entry.provider].push(entry);
    });

    let html = '';
    Object.keys(byProvider).sort().forEach(provider => {
        html += `<div class="bl-provider-group">
            <div class="bl-provider-label">${provider}</div>`;
        byProvider[provider].forEach(entry => {
            const checked = blEnabled[entry.id] ? 'checked' : '';
            const sizeTag = entry.size_hint === 'large'
                ? `<span class="bl-size-tag bl-size-large">${_('Large — needs 32 MB+ RAM')}</span>`
                : `<span class="bl-size-tag bl-size-small">${_('Small')}</span>`;
            html += `<label class="bl-entry ${checked ? 'bl-entry-active' : ''}">
                <input type="checkbox" class="bl-check" data-id="${entry.id}"
                    ${checked} onchange="toggleBlocklist(this,'${entry.id}')">
                <div class="bl-entry-info">
                    <strong>${entry.name}</strong>${sizeTag}
                    <div class="bl-entry-desc">${entry.description}</div>
                    <div class="bl-entry-url">${entry.url}</div>
                </div>
            </label>`;
        });
        html += `</div>`;
    });

    panel.innerHTML = html;
}

function toggleBlocklist(el, id) {
    blEnabled[id] = el.checked;
    const label = el.closest('label');
    if (label) label.classList.toggle('bl-entry-active', el.checked);
    saveBlocklistSelections();
    markUnsaved();
}

// Persist enabled list IDs to UCI via the blocklist_apply RPC
async function saveBlocklistSelections() {
    const custom = blCustomEntries.filter(e => e.url.trim());
    try {
        await callBlocklistApply({
            enabled: blEnabled,
            custom: custom
        });
    } catch(e) {
        // Non-fatal — will be saved on next full Save & Apply
    }
}

// Add a custom blocklist URL
function addCustomBlocklist() {
    const nameEl = $('bl-custom-name');
    const urlEl  = $('bl-custom-url');
    const name = nameEl ? nameEl.value.trim() : '';
    const url  = urlEl  ? urlEl.value.trim()  : '';

    if (!url) { showToast('err', _('Please enter a URL for the custom list.')); return; }
    if (!url.startsWith('http')) { showToast('err', _('URL must start with http:// or https://')); return; }

    const id = 'custom_' + Date.now();
    blCustomEntries.push({ id, name: name || url, url });
    blEnabled[id] = true;

    if (nameEl) nameEl.value = '';
    if (urlEl)  urlEl.value  = '';

    renderCustomEntries();
    saveBlocklistSelections();
    markUnsaved();
    showToast('ok', _('Custom list added.'));
}

function removeCustomBlocklist(id) {
    blCustomEntries = blCustomEntries.filter(e => e.id !== id);
    delete blEnabled[id];
    renderCustomEntries();
    saveBlocklistSelections();
    markUnsaved();
}

function renderCustomEntries() {
    const list = $('bl-custom-list');
    if (!list) return;
    list.innerHTML = '';
    blCustomEntries.forEach(entry => {
        const row = document.createElement('div');
        row.className = 'bl-custom-row';
        row.innerHTML =
            `<div class="bl-custom-info">` +
            `<strong>${entry.name}</strong>` +
            `<div class="bl-entry-url">${entry.url}</div></div>` +
            `<button class="cbi-button cbi-button-remove" onclick="removeCustomBlocklist('${entry.id}')">${_('Remove')}</button>`;
        list.appendChild(row);
    });
    $('bl-custom-empty').style.display = blCustomEntries.length ? 'none' : 'block';
}

// Trigger an immediate blocklist update (runs the shell script via RPC)
async function triggerBlocklistUpdate() {
    const btn = $('bl-update-btn');
    if (btn) { btn.disabled = true; btn.textContent = _('Updating…'); }
    addLog('ok', _('Manual blocklist update triggered…'));
    try {
        const data = await callBlocklistUpdate();
        if (data && data.success) {
            showToast('ok', _('Blocklist update started in background.'));
            addLog('ok', _('Blocklist update running — check status in a minute.'));
        } else {
            showToast('err', _('Update failed: ') + (data ? data.error : 'unknown'));
        }
    } catch(e) {
        showToast('err', _('Connection failed'));
    }
    if (btn) { btn.disabled = false; btn.textContent = _('Update Now'); }
}

// Populate blEnabled (and blCatalog) from the status RPC response.
// statusData.blocklists is an array of objects with:
//   { id, name, url, size_hint, description, enabled, custom? }
function loadBlocklistState(statusData) {
    if (!statusData || !statusData.blocklists) return;

    blEnabled = {};
    blCustomEntries = [];
    const lists = statusData.blocklists;

    if (Array.isArray(lists)) {
        // Rebuild catalog from UCI-sourced data (excludes custom entries)
        blCatalog = lists
            .filter(item => !item.custom)
            .map(item => ({
                id:          item.id,
                name:        item.name        || item.id,
                provider:    item.provider    || 'Other',
                url:         item.url         || '',
                size_hint:   item.size_hint   || 'small',
                description: item.description || ''
            }));

        lists.forEach(item => {
            blEnabled[item.id] = !!item.enabled;
            if (item.custom && item.url) {
                blCustomEntries.push({ id: item.id, name: item.name || item.url, url: item.url });
            }
        });
    }

    renderBlocklistCatalog();
    renderCustomEntries();

    // Update stats display
    if (statusData.dns_stats) {
        const s  = statusData.dns_stats;
        const el = $('bl-stat-text');
        if (el && s.last_update && s.last_update !== 'Never') {
            let txt = _('Last update: ') + s.last_update +
                ' — ' + s.post_dupe + _(' entries') +
                (s.saved > 0 ? ' (' + s.saved + _(' dupes removed') + ')' : '') +
                (s.skip_count > 0 ? ' · ' + s.skip_count + _(' lists skipped (low RAM)') : '');
            if (s.catalog_updated) {
                txt += ' · ' + _('catalog refreshed from GitHub');
            }
            el.textContent = txt;
        }
    }
}

// ── Remove ────────────────────────────────────────────────────────────────────
async function removeNetwork() {
    if (!confirm(_('Remove Kids Network? This will delete all Kids WiFi configuration.\n\nYour schedule will be saved to /etc/parental-privacy/schedule.backup and restored automatically if you reinstall.')))
        return;
    try {
        const data = await callRemove();
        if (data && data.success) {
            showToast('ok', _('Kids Network removed. Schedule backed up for reinstall.'));
            addLog('warn', 'Kids Network removed — schedule saved to schedule.backup');
        } else {
            showToast('err', 'Remove failed: ' + (data ? data.error : 'unknown'));
        }
    } catch(e) {
        showToast('err', _('Connection failed'));
    }
}

// ── View entry point ──────────────────────────────────────────────────────────
return view.extend({

    // Fetch initial status before rendering so the page loads with real data
    load() {
        return callStatus().catch(() => ({}));
    },

    render(status) {
        // Populate initial state from status
        if (status) {
            primarySSID   = status.primary_ssid   || '';
            suggestedSSID = status.suggested_ssid  || '';

            if (status.schedule) {
                DAYS.forEach(d => {
                    const r = status.schedule[d];
                    schedule[d] = (Array.isArray(r) && r.length) ? r.filter(validateRange) : [];
                });
            }
        }

        // ── Inline styles ─────────────────────────────────────────────────────
        const css = `
<style>
/* Status summary cards */
.kn-stat-bar { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:.5rem; margin-bottom:1rem; }
.kn-stat-card { border:1px solid #ddd; border-radius:4px; padding:.7rem 1rem; border-top:3px solid #ddd; }
.kn-stat-card.kn-green  { border-top-color:#5cb85c; }
.kn-stat-card.kn-blue   { border-top-color:#337ab7; }
.kn-stat-card.kn-orange { border-top-color:#f0ad4e; }
.kn-stat-card.kn-red    { border-top-color:#d9534f; }
.kn-stat-val.kn-red    { color:#d9534f; }
/* Schedule block status banner */
.kn-access-banner { display:flex; align-items:flex-start; gap:.65rem; border-radius:4px; padding:.7rem 1rem; margin-bottom:.85rem; border:1px solid; font-size:.88rem; }
.kn-access-banner.allowed  { background:#f0fff4; border-color:#5cb85c; color:#2d6a2d; }
.kn-access-banner.blocked  { background:#fff5f5; border-color:#d9534f; color:#7a1f1f; }
.kn-access-banner-icon { font-size:1.2rem; flex-shrink:0; margin-top:.05rem; }
.kn-access-banner strong { display:block; margin-bottom:.15rem; }
.kn-stat-val { font-size:1.4rem; font-weight:600; }
.kn-stat-val.kn-green  { color:#5cb85c; }
.kn-stat-val.kn-blue   { color:#337ab7; }
.kn-stat-val.kn-orange { color:#f0ad4e; }
.kn-stat-val.kn-purple { color:#9b59b6; }
.kn-stat-key { font-size:.72rem; color:#888; text-transform:uppercase; letter-spacing:.4px; margin-top:.1rem; }
/* Master pill */
.kn-pill { display:inline-flex; align-items:center; gap:.5rem; cursor:pointer; vertical-align:middle; }
.kn-pill-track { width:44px; height:24px; border-radius:12px; background:#ccc; position:relative; transition:background .2s; flex-shrink:0; }
.kn-pill-track.on { background:#5cb85c; }
.kn-pill-track::after { content:''; position:absolute; top:3px; left:3px; width:18px; height:18px; background:#fff; border-radius:50%; transition:transform .2s; box-shadow:0 1px 3px rgba(0,0,0,.3); }
.kn-pill-track.on::after { transform:translateX(20px); }
/* Toggle rows */
.kn-toggle-row { display:flex; align-items:center; justify-content:space-between; gap:1rem; padding:.5rem 0; border-bottom:1px solid #f0f0f0; }
.kn-toggle-row:last-child { border-bottom:none; }
.kn-toggle-row .kn-tinfo strong { display:block; }
.kn-toggle-row .kn-tinfo small { color:#888; }
.kn-switch { width:36px; height:20px; border-radius:10px; background:#ccc; position:relative; transition:background .2s; flex-shrink:0; cursor:pointer; }
.kn-switch.on { background:#5cb85c; }
.kn-switch::after { content:''; position:absolute; top:2px; left:2px; width:16px; height:16px; background:#fff; border-radius:50%; transition:transform .2s; }
.kn-switch.on::after { transform:translateX(16px); }
/* DNS */
.kn-dns-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr)); gap:.5rem; }
.kn-dns-opt { border:2px solid #ddd; border-radius:4px; padding:.75rem; cursor:pointer; transition:border-color .15s; }
.kn-dns-opt.selected { border-color:#337ab7; background:#f0f8ff; }
.kn-dns-ip { font-family:monospace; font-size:.8rem; color:#337ab7; margin:.15rem 0; }
.kn-dns-desc { font-size:.78rem; color:#666; }
.kn-dns-badge { display:inline-block; font-size:.65rem; padding:.1rem .35rem; border-radius:3px; margin-bottom:.25rem; text-transform:uppercase; border:1px solid currentColor; }
.kn-badge-family  { color:#5cb85c; }
.kn-badge-malware { color:#337ab7; }
.kn-badge-strict  { color:#f0ad4e; }
.kn-badge-custom  { color:#9b59b6; }
/* Radio */
.kn-radio-row { display:grid; grid-template-columns:repeat(auto-fit,minmax(120px,1fr)); gap:.5rem; }
.kn-radio-card { border:2px solid #ddd; border-radius:4px; padding:.75rem; cursor:pointer; text-align:center; transition:border-color .15s; }
.kn-radio-card.selected { border-color:#337ab7; background:#f0f8ff; }
.kn-radio-card input { display:none; }
.kn-radio-freq { font-family:monospace; font-size:.75rem; color:#337ab7; margin:.2rem 0; }
.kn-radio-desc { font-size:.72rem; color:#666; }
/* Schedule — range based */
.kn-sched-day { margin-bottom:.75rem; border:1px solid #eee; border-radius:4px; padding:.5rem .75rem; }
.kn-sched-day-header { display:flex; align-items:center; gap:.5rem; margin-bottom:.4rem; }
.kn-sched-unrestricted { font-size:.75rem; color:#aaa; flex:1; }
.kn-sched-add { padding:.1rem .5rem; font-size:.78rem; }
.kn-sched-ranges { display:flex; flex-direction:column; gap:.35rem; }
.kn-range-row { display:flex; align-items:center; flex-wrap:wrap; gap:.25rem; }
.kn-time-input { width:110px; font-family:monospace; }
/* Devices */
.kn-device-row { display:flex; align-items:center; gap:.6rem; padding:.5rem .75rem; border:1px solid #eee; border-radius:4px; margin-bottom:.35rem; transition:background .2s, border-color .2s; }
.kn-device-paused { background:#fff8f0; border-color:#f0ad4e !important; }
.kn-device-dot { width:8px; height:8px; border-radius:50%; flex-shrink:0; }
.kn-device-dot.online { background:#5cb85c; }
.kn-device-dot.offline { background:#ccc; }
.kn-device-dot.paused { background:#f0ad4e; box-shadow:0 0 4px #f0ad4e; }
.kn-device-mac { font-family:monospace; font-size:.75rem; color:#888; }
.kn-device-ip { font-family:monospace; font-size:.75rem; color:#337ab7; margin-left:auto; }
.kn-device-time { font-size:.75rem; color:#888; white-space:nowrap; }
.kn-paused-badge { display:inline-block; background:#f0ad4e; color:#fff; font-size:.68rem; font-weight:600; padding:.05rem .35rem; border-radius:3px; margin-left:.4rem; vertical-align:middle; letter-spacing:.03em; }
.kn-pause-btn { font-size:.78rem; padding:.2rem .55rem; white-space:nowrap; }
.kn-btn-pause { background:#f0f0f0; border-color:#bbb; color:#555; }
.kn-btn-pause:hover { background:#e8e8e8; border-color:#999; }
.kn-btn-resume { background:#fff3cd; border-color:#f0ad4e; color:#8a6d3b; }
.kn-btn-resume:hover { background:#ffe8a0; border-color:#d9930a; }
/* Unsaved */
.kn-unsaved { display:inline-flex; align-items:center; gap:.3rem; background:#ffc; border:1px solid #e6b800; color:#7a6000; border-radius:3px; padding:.1rem .45rem; font-size:.75rem; }
/* Log */
.kn-log { background:#f8f8f8; border:1px solid #ddd; border-radius:4px; padding:.6rem .8rem; font-family:monospace; font-size:.78rem; line-height:1.7; max-height:130px; overflow-y:auto; }
.kn-log .log-ts { color:#aaa; margin-right:.4rem; }
.kn-log .log-ok { color:#5cb85c; }
.kn-log .log-warn { color:#f0ad4e; }
.kn-log .log-error { color:#d9534f; }

/* Blocklists */
.bl-provider-group { margin-bottom:.85rem; }
.bl-provider-label { font-size:.72rem; font-weight:700; text-transform:uppercase; letter-spacing:.5px; color:#888; margin-bottom:.35rem; }
.bl-entry { display:flex; align-items:flex-start; gap:.65rem; padding:.55rem .65rem; border:1px solid #eee; border-radius:4px; margin-bottom:.3rem; cursor:pointer; transition:background .12s,border-color .12s; }
.bl-entry-active { background:#f0f8ff; border-color:#337ab7; }
.bl-entry input[type=checkbox] { margin-top:.2rem; flex-shrink:0; }
.bl-entry-info { flex:1; }
.bl-entry-info strong { font-size:.88rem; }
.bl-entry-desc { font-size:.78rem; color:#666; margin:.1rem 0; }
.bl-entry-url { font-family:monospace; font-size:.72rem; color:#999; word-break:break-all; }
.bl-size-tag { display:inline-block; font-size:.65rem; padding:.05rem .3rem; border-radius:3px; margin-left:.4rem; border:1px solid; vertical-align:middle; }
.bl-size-large { color:#f0ad4e; border-color:#f0ad4e; }
.bl-size-small { color:#5cb85c; border-color:#5cb85c; }
.bl-custom-row { display:flex; align-items:flex-start; gap:.6rem; padding:.5rem .65rem; border:1px solid #eee; border-radius:4px; margin-bottom:.3rem; }
.bl-custom-info { flex:1; }
.bl-stat-bar-bl { background:#f8f8f8; border:1px solid #ddd; border-radius:4px; padding:.5rem .85rem; font-size:.8rem; color:#555; margin-bottom:.75rem; }
/* Toast */
.kn-toast { position:fixed; bottom:1.25rem; right:1.25rem; background:#fff; border:1px solid #ddd; border-radius:4px; padding:.65rem 1rem; display:flex; align-items:center; gap:.6rem; box-shadow:0 4px 12px rgba(0,0,0,.15); transform:translateY(60px); opacity:0; transition:all .3s; z-index:9999; max-width:300px; font-size:.88rem; }
.kn-toast.show { transform:none; opacity:1; }
.kn-toast.ok  { border-color:#5cb85c; }
.kn-toast.err { border-color:#d9534f; }
</style>`;

        const active   = status && status.active;
        const ssid     = (status && status.ssid)     || '';
        const passwd   = (status && status.wifi_password) || '';
        const ss       = status  ? status.safesearch    : true;
        const doh      = status  ? status.doh_block     : true;
        const dot      = status  ? status.dot_block     : true;
        const vpnSw      = status  ? status.vpn_block     : true;
        const undSw      = status  ? status.undesirable     : true;
        const relayOn  = status  ? status.broadcast_relay : true;
        const ytMode   = (status && status.youtube_mode) || 'moderate';
        const blkSrch  = status  ? status.block_search   : false;

        // ── HTML ──────────────────────────────────────────────────────────────
        const html = `
${css}

<h2 class="section-title">
  ${_('Kids Network')}
  <span id="unsaved-badge" class="kn-unsaved" style="display:none; font-size:.72rem; margin-left:.75rem;">&#9679; ${_('unsaved changes')}</span>
</h2>

<div class="cbi-section">
  <div style="display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:.5rem; margin-bottom:1rem;">
    <p class="cbi-section-descr">${_('All settings for your children\'s WiFi — managed in one place.')}</p>
    <label class="kn-pill" onclick="toggleMaster()">
      <div class="kn-pill-track ${active ? 'on' : ''}" id="master-switch"></div>
      <span id="master-label">${active ? _('Kids WiFi Active') : _('Kids WiFi Off')}</span>
    </label>
  </div>
  <div class="kn-stat-bar">
    <div class="kn-stat-card kn-green">
      <div class="kn-stat-val kn-green" id="stat-devices">0</div>
      <div class="kn-stat-key">${_('Devices Online')}</div>
    </div>
    <div class="kn-stat-card kn-blue">
      <div class="kn-stat-val kn-blue" id="stat-ssid" style="font-size:1rem">${ssid}</div>
      <div class="kn-stat-key">${_('Active SSID')}</div>
    </div>
    <div class="kn-stat-card kn-orange">
      <div class="kn-stat-val kn-orange" id="stat-dns" style="font-size:.95rem">1.1.1.3</div>
      <div class="kn-stat-key">${_('DNS Resolver')}</div>
    </div>
    <div class="kn-stat-card kn-purple">
      <div class="kn-stat-val kn-purple" id="stat-schedule" style="font-size:.95rem">—</div>
      <div class="kn-stat-key">${_('Schedule')}</div>
    </div>
    <div class="kn-stat-card" id="stat-card-access">
      <div class="kn-stat-val" id="stat-access" style="font-size:.95rem">—</div>
      <div class="kn-stat-key">${_('Internet Access')}</div>
    </div>
  </div>
</div>

<!-- WiFi Settings -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('WiFi Settings')}
    <span class="cbi-section-descr">${_('SSID, password, band')}</span>
  </h3>
  <div class="cbi-section-node">
    <div class="row">
      <div class="col-sm-6">
        <div class="cbi-value">
          <label class="cbi-value-title">${_('SSID — Network Name')}</label>
          <div class="cbi-value-field">
            <input type="text" class="cbi-input-text" id="wifi-ssid" value="${ssid}" oninput="markUnsaved()">
            <div class="cbi-value-description">
              <span id="ssid-suggestion-wrap" style="${suggestedSSID ? '' : 'display:none'}">
                <a href="#" onclick="useSuggestedSSID(); return false;">&#8634; ${_('Use suggested name:')} <span id="ssid-suggestion-text">${suggestedSSID}</span></a>
              </span>
            </div>
          </div>
        </div>
      </div>
      <div class="col-sm-6">
        <div class="cbi-value">
          <label class="cbi-value-title">${_('Password')}</label>
          <div class="cbi-value-field">
            <input type="password" class="cbi-input-text" id="wifi-pwd" value="${passwd}" oninput="markUnsaved()" placeholder="${_('min. 8 characters')}">
            <div class="cbi-value-description">${_('Minimum 8 characters for WPA2-PSK encryption.')}</div>
          </div>
        </div>
      </div>
    </div>
    <div class="cbi-value">
      <label class="cbi-value-title">${_('Frequency Band')}</label>
      <div class="cbi-value-field">
        <div class="kn-radio-row">
          <div class="kn-radio-card selected" onclick="pickRadio(this,'radio0')">
            <input type="radio" name="radio" value="radio0" checked>
            <div><strong>${_('2.4 GHz')}</strong></div>
            <div class="kn-radio-freq">radio0</div>
            <div class="kn-radio-desc">${_('Better range through walls.')}</div>
          </div>
          <div class="kn-radio-card" onclick="pickRadio(this,'radio1')">
            <input type="radio" name="radio" value="radio1">
            <div><strong>${_('5 GHz')}</strong></div>
            <div class="kn-radio-freq">radio1</div>
            <div class="kn-radio-desc">${_('Faster speeds, shorter range.')}</div>
          </div>
          <div class="kn-radio-card" onclick="pickRadio(this,'radio2')">
            <input type="radio" name="radio" value="radio2">
            <div><strong>${_('6 GHz')}</strong></div>
            <div class="kn-radio-freq">radio2</div>
            <div class="kn-radio-desc">${_('Ultra-fast Wi-Fi 6E/7. Requires WPA3.')}</div>
          </div>
          <div class="kn-radio-card" onclick="pickRadio(this,'both')">
            <input type="radio" name="radio" value="both">
            <div><strong>${_('All Bands')}</strong></div>
            <div class="kn-radio-freq">Sync All</div>
            <div class="kn-radio-desc">${_('Unified SSID across all radios.')}</div>
          </div>
        </div>
      </div>
    </div>

  </div>
</div>

<!-- DNS & Content Filtering -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('DNS & Content Filtering')}
    <span class="cbi-section-descr">${_('DHCP Option 6 — zero overhead')}</span>
  </h3>
  <div class="cbi-section-node">
    <div class="cbi-value">
      <label class="cbi-value-title">${_('DNS Provider')}</label>
      <div class="cbi-value-field">
        <div class="kn-dns-grid">
          <div class="kn-dns-opt selected" onclick="pickDNS(this,'1.1.1.3')">
            <input type="radio" name="dns" value="1.1.1.3" checked>
            <span class="kn-dns-badge kn-badge-family">${_('Family Safe')}</span>
            <div><strong>${_('Cloudflare Family')}</strong></div>
            <div class="kn-dns-ip">1.1.1.3 / 1.0.0.3</div>
            <div class="kn-dns-desc">${_('Blocks malware + adult content.')}</div>
          </div>
          <div class="kn-dns-opt" onclick="pickDNS(this,'185.228.168.9')">
            <input type="radio" name="dns" value="185.228.168.9">
            <span class="kn-dns-badge kn-badge-strict">${_('Strict')}</span>
            <div><strong>${_('CleanBrowsing')}</strong></div>
            <div class="kn-dns-ip">185.228.168.9</div>
            <div class="kn-dns-desc">${_('Blocks adult content, proxies & VPN bypass sites.')}</div>
          </div>
          <div class="kn-dns-opt" onclick="pickDNS(this,'208.67.222.123')">
            <input type="radio" name="dns" value="208.67.222.123">
            <span class="kn-dns-badge kn-badge-family">${_('Family Safe')}</span>
            <div><strong>${_('OpenDNS Family')}</strong></div>
            <div class="kn-dns-ip">208.67.222.123</div>
            <div class="kn-dns-desc">${_('Cisco-backed. Blocks adult content.')}</div>
          </div>
          <div class="kn-dns-opt" onclick="pickDNS(this,'9.9.9.11')">
            <input type="radio" name="dns" value="9.9.9.11">
            <span class="kn-dns-badge kn-badge-malware">${_('Malware Only')}</span>
            <div><strong>${_('Quad9 Secure')}</strong></div>
            <div class="kn-dns-ip">9.9.9.11</div>
            <div class="kn-dns-desc">${_('Blocks malware/phishing only.')}</div>
          </div>
          <div class="kn-dns-opt" onclick="pickDNS(this,'94.140.14.15')">
            <input type="radio" name="dns" value="94.140.14.15">
            <span class="kn-dns-badge kn-badge-family">${_('Family Safe')}</span>
            <div><strong>${_('AdGuard Family')}</strong></div>
            <div class="kn-dns-ip">94.140.14.15</div>
            <div class="kn-dns-desc">${_('Blocks ads, trackers & adult content.')}</div>
          </div>
          <div class="kn-dns-opt" onclick="pickDNS(this,'custom')">
            <input type="radio" name="dns" value="custom">
            <span class="kn-dns-badge kn-badge-custom">${_('Custom')}</span>
            <div><strong>${_('Custom DNS')}</strong></div>
            <div class="kn-dns-ip" id="custom-dns-preview">&mdash;</div>
            <div class="kn-dns-desc">${_('Enter any DNS resolver IP manually.')}</div>
          </div>
        </div>
        <div id="custom-dns-field" style="display:none; margin-top:.75rem">
          <input type="text" class="cbi-input-text" id="custom-dns-ip" placeholder="e.g. 176.103.130.132" oninput="updateCustomPreview()" style="max-width:260px">
        </div>
      </div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Block DNS-over-HTTPS (DoH) bypass')}</strong>
        <small>${_('Blocks known DoH providers so browsers cannot silently bypass the DNS filter')}</small>
      </div>
      <div class="kn-switch ${doh ? 'on' : ''}" id="BlockDoH" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Block DNS-over-TLS (DoT) bypass')}</strong>
        <small>${_('Blocks port 853 so devices cannot use encrypted DNS-over-TLS to bypass the DNS filter')}</small>
      </div>
      <div class="kn-switch ${dot ? 'on' : ''}" id="BlockDoT" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('SafeSearch enforcement')}</strong>
        <small>${_('Forces SafeSearch on Google, Bing, YouTube, DuckDuckGo, Brave and Pixabay via DNS CNAME')}</small>
      </div>
      <div class="kn-switch ${ss ? 'on' : ''}" id="sw-safesearch" onclick="
        this.classList.toggle('on');
        const on = this.classList.contains('on');
        document.getElementById('row-youtube-mode').style.display = on ? '' : 'none';
        document.getElementById('row-block-search').style.display = on ? '' : 'none';
        markUnsaved()
      "></div>
    </div>
    <div class="kn-toggle-row" id="row-youtube-mode" style="${ss ? '' : 'display:none'}">
      <div class="kn-tinfo">
        <strong>${_('YouTube restriction level')}</strong>
        <small>${_('Moderate blocks most adult content. Strict enables supervised mode — very locked down, may block legitimate videos.')}</small>
      </div>
      <select class="cbi-input-select" id="yt-mode-select" onchange="markUnsaved()" style="min-width:120px">
        <option value="moderate" ${ytMode === 'moderate' ? 'selected' : ''}>${_('Moderate')}</option>
        <option value="strict"   ${ytMode === 'strict'   ? 'selected' : ''}>${_('Strict')}</option>
      </select>
    </div>
    <div class="kn-toggle-row" id="row-block-search" style="${ss ? '' : 'display:none'}">
      <div class="kn-tinfo">
        <strong>${_('Block uncontrolled search engines')}</strong>
        <small>${_('Blocks search engines that cannot enforce SafeSearch at DNS level (e.g. Yandex, Baidu, Startpage, Ecosia). Prevents bypassing SafeSearch by switching to an unsupported engine.')}</small>
      </div>
      <div class="kn-switch ${blkSrch ? 'on' : ''}" id="sw-block-search" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
	<div class="kn-toggle-row">
	  <div class="kn-tinfo">
		<strong>${_('Block VPN & Bypass Tools')}</strong>
		<small>${_('Blocks common VPN ports (OpenVPN, WireGuard, IPSec) to prevent filter bypassing.')}</small>
	  </div>
	<div class="kn-switch ${status.vpn_block ? 'on' : ''}" id="sw-vpn-block" onclick="this.classList.toggle('on');markUnsaved()"></div>
	</div>
	<div class="kn-toggle-row">
	  <div class="kn-tinfo">
		<strong>${_('Block Undesirable Apps')}</strong>
		<small>${_('Prevents access to TikTok and Snapchat domains.')}</small>
	  </div>
	<div class="kn-switch ${status.undesirable ? 'on' : ''}" id="sw-undesirable" onclick="this.classList.toggle('on');markUnsaved()"></div>
	</div>
  </div>
</div>

<!-- Schedule -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Bedtime Schedule')}
    <span class="cbi-section-descr">${_('Up to 4 allowed time ranges per day')}</span>
  </h3>
  <div class="cbi-section-node">

    <!-- Live access status banner — updated by updateAccessStat() -->
    <div class="kn-access-banner allowed" id="access-banner">
      <div class="kn-access-banner-icon" id="access-banner-icon">✔</div>
      <div>
        <strong id="access-banner-title">${_('Internet access allowed')}</strong>
        <span id="access-banner-detail"></span>
      </div>
    </div>

    <!-- How the schedule works -->
    <div class="alert alert-info" style="font-size:.85rem; margin-bottom:.85rem;">
      <strong>${_('How this schedule works')}</strong><br>
      ${_('During blocked hours the WiFi remains on — devices stay connected and keep their IP address. A firewall rule silently drops all internet traffic from the kids network. DNS still resolves and pings still work, so devices show as connected but cannot load pages or apps. Wired devices on the kids VLAN are affected in exactly the same way.')}<br><br>
      ${_('Outside the allowed windows the block rule is installed automatically via cron. The \'Grant extension\' button removes it immediately for one hour, then reinstates it — no WiFi restart required at any point.')}
    </div>

    <div style="display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:.5rem; margin-bottom:.75rem;">
      <span class="cbi-value-description">${_('Leave a day empty for unrestricted access. Ranges must not overlap.')}</span>
      <select class="cbi-input-select" id="schedule-preset" onchange="applyPreset(this.value)" style="max-width:200px">
        <option value="">${_('Apply preset…')}</option>
        <option value="school">${_('School days')}</option>
        <option value="strict">${_('Strict (9am–7pm)')}</option>
        <option value="splitday">${_('Split day (before/after school)')}</option>
        <option value="weekend">${_('Weekdays limited, weekends relaxed')}</option>
        <option value="allday">${_('All day (no restriction)')}</option>
        <option value="clear">${_('Clear all')}</option>
      </select>
    </div>
    <div id="schedule-ranges"></div>
  </div>
</div>

<!-- Connected Devices -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Connected Devices')}
    <span class="cbi-section-descr" id="devices-count">0 online</span>
  </h3>
  <div class="cbi-section-node">
    <div id="device-list"><em>${_('Loading…')}</em></div>
    <button class="cbi-button" id="ext-btn" onclick="grantExtension()" style="margin-top:.75rem">
      &#9201; ${_('Grant 1-hour extension')}
    </button>
  </div>
</div>

<!-- Hardware Buttons -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Hardware Buttons')}
    <span class="cbi-section-descr">${_('Physical controls')}</span>
  </h3>
  <div class="cbi-section-node">
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('BTN_0 / slider (GL.iNet)')}</strong>
        <small>${_('Pressed = ON, Released = OFF')}</small>
      </div>
      <div class="kn-switch" id="sw-btn0" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('WPS button (toggle)')}</strong>
        <small>${_('Press to toggle Kids WiFi on/off')}</small>
      </div>
      <div class="kn-switch" id="sw-btnwps" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Reset button (toggle)')}</strong>
        <small>${_('Press to toggle — hold 10s still factory resets')}</small>
      </div>
      <div class="kn-switch" id="sw-btnreset" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Custom GPIO pin')}</strong>
        <small>${_('GPIO pin number for a hardware slider (leave blank to disable)')}</small>
      </div>
      <input type="text" class="cbi-input-text" id="gpio-pin-input" placeholder="e.g. 4" style="max-width:80px" oninput="markUnsaved()">
    </div>
  </div>
</div>

<!-- Cross-Network Discovery (Broadcast Relay) -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Cross-Network Discovery')}
    <span class="cbi-section-descr">${_('mDNS, SSDP, Steam, Minecraft, printing')}</span>
  </h3>
  <div class="cbi-section-node">
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Enable broadcast relay')}</strong>
        <small>${_('Allows kids-network devices to discover and use services on your main network — printers, Chromecast, AirPlay, game servers (Steam, Minecraft) and more. Requires udp-broadcast-relay-redux to be installed.')}</small>
      </div>
      <div class="kn-switch ${relayOn ? 'on' : ''}" id="sw-relay" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
  </div>
</div>

<!-- Additional Protection — DNS Blocklists -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Additional Protection — DNS Blocklists')}
    <span class="cbi-section-descr">${_('Blocks are applied at DNS level on the kids dnsmasq instance only. Updated nightly at 3 AM.')}</span>
  </h3>
  <div class="cbi-section-node">

    <div class="bl-stat-bar-bl" id="bl-stat-text">${_('Loading update statistics…')}</div>

    <div class="alert alert-info" style="font-size:.83rem; margin-bottom:.85rem;">
      <strong>${_('How this works')}</strong><br>
      ${_('Checked lists are downloaded and merged into a single deduplicated file at /etc/dnsmasq.kids.d/dns_blocklist.conf, which the kids dnsmasq instance picks up automatically via its confdir setting. Large HaGeZi lists are automatically substituted with the Light version when router RAM is below 32 MB free. Updates run at 3 AM to avoid peak usage. Each update is syntax-checked before going live; if it fails, the previous list is restored automatically.')}
    </div>

    <!-- Catalog — synced from GitHub nightly by update-blocklists.sh, served from UCI -->
    <div style="display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:.5rem; margin-bottom:.65rem;">
      <strong>${_('Pre-configured Lists')}</strong>
      <span id="bl-spinner" style="display:none; font-size:.8rem; color:#888;">${_('Loading catalog…')}</span>
      <button class="cbi-button" onclick="loadBlocklistCatalog()" style="font-size:.8rem; padding:.25rem .75rem;">&#8635; ${_('Reload Catalog')}</button>
    </div>
    <div id="bl-catalog-panel">
      <em style="color:#aaa; font-size:.85rem;">${_('Loading…')}</em>
    </div>

    <!-- Manual / custom lists -->
    <div style="margin-top:1.1rem;">
      <strong>${_('Custom Lists')}</strong>
      <p class="cbi-value-description">${_('Add any dnsmasq-format blocklist URL (address= or server= lines).')}</p>
      <div id="bl-custom-list"></div>
      <div id="bl-custom-empty" style="font-size:.82rem; color:#aaa; margin:.3rem 0;">${_('No custom lists added yet.')}</div>

      <div style="display:flex; gap:.5rem; flex-wrap:wrap; margin-top:.6rem;">
        <input type="text" class="cbi-input-text" id="bl-custom-name"
               placeholder="${_('Label (optional)')}" style="max-width:180px; font-size:.85rem;">
        <input type="text" class="cbi-input-text" id="bl-custom-url"
               placeholder="${_('https://example.com/blocklist.txt')}" style="flex:1; min-width:200px; font-size:.85rem;">
        <button class="cbi-button cbi-button-add" onclick="addCustomBlocklist()">+ ${_('Add')}</button>
      </div>
    </div>

    <!-- Manual update trigger -->
    <div style="margin-top:1.1rem; padding-top:.75rem; border-top:1px solid #eee; display:flex; align-items:center; gap:1rem; flex-wrap:wrap;">
      <button class="cbi-button" id="bl-update-btn" onclick="triggerBlocklistUpdate()">
        &#9654; ${_('Update Now')}
      </button>
      <span class="cbi-value-description" style="margin:0;">${_('Runs the download &amp; dedup immediately rather than waiting for 3 AM.')}</span>
    </div>

  </div>
</div>


<!-- Recent DNS Activity -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Recent DNS Activity')}
    <span class="cbi-section-descr">${_('Last 50 queries · RAM only · auto-cleared on reboot')}</span>
  </h3>
  <div class="cbi-section-node">
    <div class="alert alert-info" style="font-size:.82rem;margin-bottom:.75rem;">
      ${_('Queries are logged to /tmp/dnsmasq-kids.log (RAM only). The log never touches flash storage and is wiped automatically on reboot or service stop.')}
    </div>
    <div style="overflow-x:auto;">
      <table style="width:100%;border-collapse:collapse;font-size:.85rem;" id="dns-log-table">
        <thead>
          <tr style="border-bottom:2px solid #ddd;">
            <th style="text-align:left;padding:.3rem .5rem;white-space:nowrap">${_('Time')}</th>
            <th style="text-align:left;padding:.3rem .5rem">${_('Device')}</th>
            <th style="text-align:left;padding:.3rem .5rem">${_('Domain')}</th>
          </tr>
        </thead>
        <tbody id="dns-log-tbody">
          <tr><td colspan="3" style="text-align:center;color:#aaa;font-style:italic;padding:.5rem 0">${_('Loading…')}</td></tr>
        </tbody>
      </table>
    </div>
    <div style="margin-top:.6rem;display:flex;gap:.75rem;align-items:center;flex-wrap:wrap;">
      <button class="cbi-button" id="dns-log-refresh-btn" onclick="updateActivityLog()" style="font-size:.82rem;padding:.25rem .75rem;">
        &#8635; ${_('Refresh')}
      </button>
      <button class="cbi-button cbi-button-remove" id="dns-log-clear-btn" onclick="clearActivityLog()" style="font-size:.82rem;padding:.25rem .75rem;">
        🗑 ${_('Clear Log')}
      </button>
      <span style="font-size:.78rem;color:#888">${_('Auto-refreshes every 20 seconds.')}</span>
    </div>
  </div>
</div>

<!-- Activity Log -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Activity Log')}</h3>
  <div class="cbi-section-node">
    <div class="kn-log" id="log-box"></div>
  </div>
</div>

<!-- Save / Remove -->
<div class="cbi-section">
  <div style="display:flex; gap:.5rem; flex-wrap:wrap; align-items:center;">
    <button class="cbi-button cbi-button-apply" id="save-btn" onclick="saveAll()">
      ${_('Save & Apply All')}
    </button>
    <button class="cbi-button cbi-button-remove" onclick="removeNetwork()">
      ${_('Remove Kids Network')}
    </button>
  </div>
</div>

<div class="kn-toast" id="kn-toast">
  <span id="kn-toast-msg"></span>
</div>`;

        const node = dom.parse(html);

        // ── Post-render setup ─────────────────────────────────────────────────
        node.addEventListener('DOMContentLoaded', () => {}, { once: true });

        // We return the node and then wire up after it's in the DOM
        return node;
    },

    // Called after render() node is inserted into the DOM
    handleSaveApply: null,
    handleSave: null,
    handleReset: null,

    // Called by LuCI when the user navigates away from this view.
    // Clears the polling interval so it doesn't run against a detached DOM.
    close() {
        if (statusTimer) { clearInterval(statusTimer); statusTimer = null; }
        if (toastTimer)  { clearTimeout(toastTimer);   toastTimer  = null; }
        if (logsTimer)   { clearInterval(logsTimer);   logsTimer   = null; }
    },

    // Use addFooter to run post-DOM setup instead
    addFooter() {
        // Build schedule panel with initial data
        buildSchedulePanel();
        updateScheduleStat();

        // Start status polling
        updateStatus();
        statusTimer = setInterval(updateStatus, 30000);

        // Start DNS activity log polling (every 20 s)
        updateActivityLog();
        logsTimer = setInterval(updateActivityLog, 20000);

        // Expose functions to inline onclick handlers
        Object.assign(window, {
            toggleMaster, pickRadio, pickDNS, updateCustomPreview,
            useSuggestedSSID, togglePanel, applyPreset, addRange,
            removeRange, updateRange, grantExtension, saveAll,
            removeNetwork, markUnsaved, toggleBlock, togglePause,
            updateAccessStat, toggleBlocklist, addCustomBlocklist,
            removeCustomBlocklist, loadBlocklistCatalog, triggerBlocklistUpdate,
            updateActivityLog, clearActivityLog
        });

        // Load blocklist catalog (reads UCI state via status RPC) after DOM is ready
        loadBlocklistCatalog();
    }
});
