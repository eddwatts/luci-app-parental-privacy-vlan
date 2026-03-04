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

// Initialise schedule with empty arrays
DAYS.forEach(d => { schedule[d] = []; });

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

// ── Status polling ────────────────────────────────────────────────────────────
async function updateStatus() {
    let data;
    try { data = await callStatus(); }
    catch(e) { return; }

    if (!data) return;

    primarySSID   = data.primary_ssid  || '';
    suggestedSSID = data.suggested_ssid || '';

    $('ssid-suggestion-text').textContent = suggestedSSID;

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

        // Sync safesearch + doh toggles
        const ss = $('sw-safesearch');
        if (ss) ss.classList.toggle('on', !!data.safesearch);
        const doh = $('BlockDoH');
        if (doh) doh.classList.toggle('on', !!data.doh_block);

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
    updateScheduleStat();
}

// ── Device list ───────────────────────────────────────────────────────────────
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

        const row = document.createElement('div');
        row.className = 'kn-device-row';
        row.innerHTML =
            `<div class="kn-device-dot online"></div>` +
            `<div style="flex:1"><div><strong>${dev.name}</strong></div>` +
            `<div class="kn-device-mac">${dev.mac}</div></div>` +
            `<div class="kn-device-ip">${dev.ip}</div>` +
            `<div class="kn-device-time">${timeStr}</div>` +
            `<button class="cbi-button${blocked[dev.mac] ? ' cbi-button-remove' : ''}"
                onclick="toggleBlock(${i},this,${JSON.stringify(dev)})">` +
            (blocked[dev.mac] ? _('Unblock') : _('Block')) + `</button>`;
        list.appendChild(row);
    });

    $('stat-devices').textContent   = count;
    $('devices-count').textContent  = count + ' online';
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
        isolate:       $('sw-isolate').classList.contains('on'),
        dns:           selectedDNS === 'custom'
                           ? $('custom-dns-ip').value
                           : selectedDNS,
        doh:           $('BlockDoH').classList.contains('on'),
        safesearch:    $('sw-safesearch').classList.contains('on'),
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

// ── Remove ────────────────────────────────────────────────────────────────────
async function removeNetwork() {
    if (!confirm(_('Remove Kids Network? This will delete all Kids WiFi configuration.')))
        return;
    try {
        const data = await callRemove();
        if (data && data.success) {
            showToast('ok', _('Kids Network removed.'));
            addLog('warn', 'Kids Network removed');
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
.kn-stat-card.kn-purple { border-top-color:#9b59b6; }
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
.kn-device-row { display:flex; align-items:center; gap:.6rem; padding:.5rem .75rem; border:1px solid #eee; border-radius:4px; margin-bottom:.35rem; }
.kn-device-dot { width:8px; height:8px; border-radius:50%; flex-shrink:0; }
.kn-device-dot.online { background:#5cb85c; }
.kn-device-dot.offline { background:#ccc; }
.kn-device-mac { font-family:monospace; font-size:.75rem; color:#888; }
.kn-device-ip { font-family:monospace; font-size:.75rem; color:#337ab7; margin-left:auto; }
.kn-device-time { font-size:.75rem; color:#888; white-space:nowrap; }
/* Unsaved */
.kn-unsaved { display:inline-flex; align-items:center; gap:.3rem; background:#ffc; border:1px solid #e6b800; color:#7a6000; border-radius:3px; padding:.1rem .45rem; font-size:.75rem; }
/* Log */
.kn-log { background:#f8f8f8; border:1px solid #ddd; border-radius:4px; padding:.6rem .8rem; font-family:monospace; font-size:.78rem; line-height:1.7; max-height:130px; overflow-y:auto; }
.kn-log .log-ts { color:#aaa; margin-right:.4rem; }
.kn-log .log-ok { color:#5cb85c; }
.kn-log .log-warn { color:#f0ad4e; }
.kn-log .log-error { color:#d9534f; }
/* Toast */
.kn-toast { position:fixed; bottom:1.25rem; right:1.25rem; background:#fff; border:1px solid #ddd; border-radius:4px; padding:.65rem 1rem; display:flex; align-items:center; gap:.6rem; box-shadow:0 4px 12px rgba(0,0,0,.15); transform:translateY(60px); opacity:0; transition:all .3s; z-index:9999; max-width:300px; font-size:.88rem; }
.kn-toast.show { transform:none; opacity:1; }
.kn-toast.ok  { border-color:#5cb85c; }
.kn-toast.err { border-color:#d9534f; }
</style>`;

        const active   = status && status.active;
        const ssid     = (status && status.ssid)     || '';
        const passwd   = (status && status.wifi_password) || '';
        const ss       = status  ? status.safesearch  : true;
        const doh      = status  ? status.doh_block   : true;

        // ── HTML ──────────────────────────────────────────────────────────────
        const html = `
${css}

<h2 class="section-title">
  ${_('Kids Network')}
  <span id="unsaved-badge" class="kn-unsaved" style="display:none; font-size:.72rem; margin-left:.75rem;">&#9679; ${_('unsaved changes')}</span>
</h2>

<div class="cbi-section">
  <div style="display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:.5rem; margin-bottom:1rem;">
    <p class="cbi-section-descr">${_('All settings for your isolated children\'s WiFi — managed in one place.')}</p>
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
              <a href="#" onclick="useSuggestedSSID(); return false;">&#8634; ${_('Use suggested name:')} <span id="ssid-suggestion-text">${suggestedSSID}</span></a>
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
    <div class="kn-toggle-row">
      <div class="kn-tinfo">
        <strong>${_('Isolate clients from each other')}</strong>
        <small>${_('Prevents devices on this network from talking to each other')}</small>
      </div>
      <div class="kn-switch on" id="sw-isolate" onclick="this.classList.toggle('on');markUnsaved()"></div>
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
        <strong>${_('SafeSearch enforcement')}</strong>
        <small>${_('Forces SafeSearch on Google, Bing, YouTube and DuckDuckGo via DNS CNAME')}</small>
      </div>
      <div class="kn-switch ${ss ? 'on' : ''}" id="sw-safesearch" onclick="this.classList.toggle('on');markUnsaved()"></div>
    </div>
  </div>
</div>

<!-- Schedule -->
<div class="cbi-section">
  <h3 class="cbi-section-title">${_('Bedtime Schedule')}
    <span class="cbi-section-descr">${_('Up to 4 allowed time ranges per day')}</span>
  </h3>
  <div class="cbi-section-node">
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

    // Use addFooter to run post-DOM setup instead
    addFooter() {
        // Build schedule panel with initial data
        buildSchedulePanel();
        updateScheduleStat();

        // Start status polling
        updateStatus();
        statusTimer = setInterval(updateStatus, 30000);

        // Expose functions to inline onclick handlers
        Object.assign(window, {
            toggleMaster, pickRadio, pickDNS, updateCustomPreview,
            useSuggestedSSID, togglePanel, applyPreset, addRange,
            removeRange, updateRange, grantExtension, saveAll,
            removeNetwork, markUnsaved, toggleBlock
        });
    }
});
