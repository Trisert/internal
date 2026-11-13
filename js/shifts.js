// Lab shifts: two weekly grids (Mon-Fri, 08:30-18:30), half-hour slots, booking of own hours,
// supervisors (admins, not counted), admin management, shift requests.
import { supabase } from './config.js';
import { initProtectedPage, friendlyError } from './auth.js';
import { formatDate, formatTime, formatDateTime, zonedParts, zonedToIso, todayIso } from './format.js';
import { icon } from './icons.js';

/* ---------- constants ---------- */
const DAY_START = 8 * 60 + 30; // 08:30
const DAY_END = 18 * 60 + 30;  // 18:30
const SLOT = 30;               // minutes per slot and per grid row
const SLOT_PX = 24;            // must match --slot in shifts.css
const SLOT_MS = SLOT * 60e3;   // one booking slot
const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
const MAX_CAPACITY = 50;
const HISTORY_DAYS = 30;

/* ---------- utilities ---------- */
const dn = (i) => { const p = i.split('-').map(Number); return Math.round(Date.UTC(p[0], p[1] - 1, p[2]) / 864e5); };
const iso = (n) => new Date(n * 864e5).toISOString().slice(0, 10);
const weekday = (isoDate) => (new Date(dn(isoDate) * 864e5).getUTCDay() + 6) % 7; // 0 = Monday
const mondayOf = (isoDate) => iso(dn(isoDate) - weekday(isoDate));
const hhmm = (min) => `${String(Math.floor(min / 60)).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}`;
const toMin = (t) => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const personName = (p) => p?.full_name ?? p?.email ?? 'Unknown';
// Duration of n milliseconds as "1 h 30 min"
const durationText = (ms) => {
  const min = Math.round(ms / 60e3);
  const h = Math.floor(min / 60), m = min % 60;
  return [h ? `${h} h` : '', m ? `${m} min` : ''].filter(Boolean).join(' ');
};

function toast(message) {
  const t = document.getElementById('toast');
  t.textContent = message;
  t.hidden = false;
  clearTimeout(toast.h);
  toast.h = setTimeout(() => { t.hidden = true; }, 5000);
}

const ERRORS = {
  'Shift full': 'At least one of the selected slots is full.',
  'Overlapping shift': 'The selected hours overlap another booking (yours or of the requester).',
  'Shift already started': 'The selected hours have already started.',
  'Booking already started': 'Your booking has already started: it can no longer be changed.',
  'Shift not found': 'The shift no longer exists.',
  'Half-hour slots only': 'Bookings start and end on :00 or :30.',
  'Outside the shift': 'The selected hours are outside the shift.',
  'Invalid time range': 'The end shall be after the start.',
  'Slot without supervisor': 'At least one of the selected slots has no supervisor yet.',
  'Participants would remain without supervisor': 'Not possible: some participants would remain without supervisor. Add another supervisor for those slots first.',
  'Only admins can be added as supervisors': 'Only admins can be added as supervisors.',
  'Member not found or not active': 'The member is not active.',
  'Capacity lower than current bookings': 'In at least one slot more participants are booked than the new capacity.',
  'Task required': 'Select a task.',
  'Request not found': 'The request no longer exists.',
  'Request not pending': 'The request has already been handled.',
  'Request not found or not pending': 'The request has already been handled.',
  'Requester account not active': 'The requester account is not active.',
  'Supervisor shall be an active admin': 'The supervisor shall be an active admin.',
};
function errorText(error) {
  const m = error?.message ?? String(error);
  if (/row-level security/.test(m) && /shift_requests/.test(m)) return 'The requested start is in the past.';
  if (/half_hours/.test(m)) return 'Shifts start and end on :00 or :30.';
  if (/shifts_check|shift_requests_check/.test(m)) return 'The end shall be after the start.';
  if (/capacity_check/.test(m)) return 'The capacity shall be at least 1.';
  return ERRORS[m] ?? friendlyError(error);
}

/* ---------- state ---------- */
const profile = await initProtectedPage('shifts');
const ADMIN = profile?.role === 'admin';
const ME = profile?.id;
const TODAY = todayIso();
let SHIFTS = [];
let REQUESTS = [];
let TASKS = [];
let ADMINS = [];   // active admins, possible supervisors
const ui = { week: 0, onlyFree: false, onlyMine: false, showRequests: true };

const firstMonday = () => iso(dn(mondayOf(TODAY)) + ui.week * 7);

/* ---------- data ---------- */
// Half-hour slots of a shift with participants and supervisors
function buildSlots(shift, bookings, now) {
  const out = [];
  for (let t = Date.parse(shift.starts_at); t < Date.parse(shift.ends_at); t += SLOT_MS) {
    const inSlot = bookings.filter((b) => Date.parse(b.starts_at) <= t && Date.parse(b.ends_at) > t);
    const participants = inSlot.filter((b) => b.role === 'participant');
    const supervisors = inSlot.filter((b) => b.role === 'supervisor');
    out.push({
      t,
      label: formatTime(new Date(t)),
      participants,
      supervisors,
      free: shift.capacity - participants.length,
      covered: supervisors.length > 0,
      started: t <= now,
    });
  }
  return out;
}

async function load() {
  const from = firstMonday();
  const to = iso(dn(from) + 14);
  const since = new Date(Date.now() - 2 * HISTORY_DAYS * 864e5).toISOString();
  const [s, r, t, a] = await Promise.all([
    supabase.from('shifts')
      .select('*, tasks(code, name), assignments(user_id, role, starts_at, ends_at, created_at, profiles(full_name, email))')
      .gte('starts_at', zonedToIso(from, '00:00'))
      .lt('starts_at', zonedToIso(to, '00:00'))
      .order('starts_at'),
    supabase.from('shift_requests')
      .select('*, requester:profiles!shift_requests_requested_by_fkey(full_name, email), tasks(code, name)')
      .gte('created_at', since)
      .order('starts_at'),
    supabase.from('tasks').select('id, code, name, completed_on, parent_id'),
    supabase.from('profiles').select('id, full_name, email').eq('role', 'admin').eq('status', 'active'),
  ]);
  const error = s.error || r.error || t.error || a.error;
  if (error) throw error;

  const now = Date.now();
  SHIFTS = s.data.map((x) => {
    const start = zonedParts(x.starts_at);
    const end = zonedParts(x.ends_at);
    const bookings = x.assignments
      .map((b) => ({ ...b, name: personName(b.profiles) }))
      .sort((p, q) => (p.starts_at === q.starts_at ? (p.created_at < q.created_at ? -1 : 1) : p.starts_at < q.starts_at ? -1 : 1));
    const slots = buildSlots(x, bookings, now);
    const own = bookings.find((b) => b.user_id === ME) ?? null;
    const future = slots.filter((sl) => !sl.started);
    return {
      ...x,
      date: start.date,
      startMin: start.minutes,
      endMin: end.date === start.date ? end.minutes : DAY_END + 1,
      bookings,
      participants: bookings.filter((b) => b.role === 'participant'),
      supervisors: bookings.filter((b) => b.role === 'supervisor'),
      slots,
      own,
      mine: Boolean(own),
      maxBooked: Math.max(0, ...slots.map((sl) => sl.participants.length)),
      bookable: future.some((sl) => sl.covered && sl.free > 0),
      uncovered: future.some((sl) => !sl.covered),
      started: new Date(x.starts_at) <= new Date(now),
      ended: new Date(x.ends_at) <= new Date(now),
    };
  });
  REQUESTS = r.data.map((x) => {
    const start = zonedParts(x.starts_at);
    const end = zonedParts(x.ends_at);
    return {
      ...x,
      date: start.date,
      startMin: start.minutes,
      endMin: end.date === start.date ? end.minutes : DAY_END + 1,
      own: x.requested_by === ME,
      started: new Date(x.starts_at) <= new Date(now),
      kind: 'request',
    };
  });
  TASKS = t.data.sort((x, y) => x.code.localeCompare(y.code, 'en', { numeric: true }));
  ADMINS = a.data.map((x) => ({ id: x.id, name: personName(x) })).sort((x, y) => x.name.localeCompare(y.name));
}

async function reload(message) {
  try { await load(); } catch (err) { toast(errorText(err)); return; }
  render();
  if (message) toast(message);
}

/* ---------- toolbar ---------- */
function renderTools() {
  const from = firstMonday();
  const to = iso(dn(from) + 11); // Friday of the second week
  document.getElementById('s-tools').innerHTML = `
    <button type="button" class="secondary btn-icon" data-act="prev" aria-label="Previous week" title="Previous week">${icon('chevron-left')}</button>
    <button type="button" class="secondary" data-act="now"${ui.week === 0 ? ' disabled' : ''}>This week</button>
    <button type="button" class="secondary btn-icon" data-act="next" aria-label="Next week" title="Next week">${icon('chevron-right')}</button>
    <span class="range">${formatDate(from)} – ${formatDate(to)}</span>
    <label class="chk"><input type="checkbox" id="f-free"${ui.onlyFree ? ' checked' : ''}> Free seats only</label>
    <label class="chk"><input type="checkbox" id="f-mine"${ui.onlyMine ? ' checked' : ''}> My shifts only</label>
    <label class="chk"><input type="checkbox" id="f-req"${ui.showRequests ? ' checked' : ''}> Show requests</label>
    <button type="button" class="secondary btn-icon" data-act="reload" title="Reload" aria-label="Reload">${icon('rotate-cw')}</button>`;
  document.getElementById('s-actions').innerHTML = ADMIN
    ? `<button type="button" class="btn-with-icon" data-act="new-shift">${icon('calendar-plus')} New shift</button>`
    : `<button type="button" class="btn-with-icon" data-act="new-request">${icon('calendar-plus')} Request a shift</button>`;
}

/* ---------- grid ---------- */
function visible(s) {
  if (ui.onlyFree && !s.bookable) return false;
  if (ui.onlyMine && !s.mine) return false;
  return true;
}

function visibleRequest(r) {
  if (r.status !== 'pending' || !ui.showRequests || ui.onlyFree) return false;
  if (ui.onlyMine && !r.own) return false;
  return true;
}

function requestBlock(r, style = '') {
  const task = r.tasks ? `<span class="c">${esc(r.tasks.code)}</span> ` : '';
  const text = r.description.length > 60 ? `${r.description.slice(0, 60)}…` : r.description;
  return `<button type="button" class="sblock req${r.started ? ' past' : ''}" data-request="${r.id}"${style}
    title="${esc(`Request · ${formatTime(r.starts_at)}–${formatTime(r.ends_at)} · ${personName(r.requester)}`)}">
    <span class="rq">Request</span> <span class="t">${formatTime(r.starts_at)}–${formatTime(r.ends_at)}</span><br>
    <span class="n">${esc(personName(r.requester))}</span><br>${task}${esc(text)}</button>`;
}

function blockClass(s) {
  return `${s.mine ? 'mine' : s.bookable ? 'free' : 'full'}${s.ended ? ' past' : ''}`;
}

// One mark per half-hour slot: free / full / no supervisor / mine
function slotStrip(s) {
  return `<span class="strip">${s.slots.map((sl) => {
    const mineHere = s.own && Date.parse(s.own.starts_at) <= sl.t && Date.parse(s.own.ends_at) > sl.t;
    const cls = mineHere ? 'mine' : !sl.covered ? 'nosup' : sl.free <= 0 ? 'full' : 'free';
    return `<i class="${cls}" title="${esc(`${sl.label} · ${sl.participants.length}/${s.capacity}${sl.covered ? '' : ' · no supervisor'}`)}"></i>`;
  }).join('')}</span>`;
}

function blockText(s) {
  const task = s.tasks ? `<span class="c">${esc(s.tasks.code)}</span> ${esc(s.tasks.name)}` : '';
  return `<span class="seats">${s.maxBooked}/${s.capacity}</span>
    <span class="t">${formatTime(s.starts_at)}–${formatTime(s.ends_at)}</span>${slotStrip(s)}${task}
    ${s.location ? `<br><span class="n">${esc(s.location)}</span>` : ''}
    <br><span class="n${s.uncovered ? ' warn' : ''}">Sup.: ${esc(s.supervisors.map((b) => b.name).join(', ') || 'none')}</span>
    ${s.participants.length ? `<br><span class="n">${esc(s.participants.map((b) => b.name).join(', '))}</span>` : ''}`;
}

// Assigns side-by-side lanes to overlapping items of the same day.
function lanes(items) {
  const sorted = items.slice().sort((a, b) => a.startMin - b.startMin);
  const laneEnds = [];
  sorted.forEach((s) => {
    let lane = laneEnds.findIndex((end) => end <= s.startMin);
    if (lane < 0) { lane = laneEnds.length; laneEnds.push(0); }
    laneEnds[lane] = s.endMin;
    s.lane = lane;
  });
  sorted.forEach((s) => { s.lanes = Math.max(laneEnds.length, 1); });
  return sorted;
}

function itemHtml(s, style = '') {
  if (s.kind === 'request') return requestBlock(s, style);
  return `<button type="button" class="sblock ${blockClass(s)}" data-shift="${s.id}"${style}
    title="${esc(`${formatTime(s.starts_at)}–${formatTime(s.ends_at)} ${s.tasks?.code ?? ''} · up to ${s.maxBooked}/${s.capacity} per slot`)}">${blockText(s)}</button>`;
}

function weekHtml(monday) {
  const days = DAYS.map((label, i) => ({ label, date: iso(dn(monday) + i) }));
  const height = ((DAY_END - DAY_START) / SLOT) * SLOT_PX;
  const outside = [];

  // Labels at 08:30, every full hour, 18:30
  let times = '';
  const marks = [DAY_START];
  for (let m = Math.ceil(DAY_START / 60) * 60; m < DAY_END; m += 60) marks.push(m);
  marks.push(DAY_END);
  marks.forEach((m) => {
    times += `<span style="top:${((m - DAY_START) / SLOT) * SLOT_PX}px">${hhmm(m)}</span>`;
  });

  let heads = '<div class="corner"></div>';
  let bodies = `<div class="times" style="height:${height}px">${times}</div>`;
  let list = '';

  days.forEach((d) => {
    const isToday = d.date === TODAY;
    const isPast = d.date < TODAY;
    heads += `<div class="dhead${isToday ? ' today' : ''}">${d.label} ${formatDate(d.date).slice(0, 5)}</div>`;

    const items = [
      ...SHIFTS.filter((s) => s.date === d.date && visible(s)),
      ...REQUESTS.filter((r) => r.date === d.date && visibleRequest(r)),
    ];
    const inGrid = items.filter((s) => s.endMin > DAY_START && s.startMin < DAY_END);
    items.filter((s) => !inGrid.includes(s)).forEach((s) => outside.push(s));

    const blocks = lanes(inGrid).map((s) => {
      const top = ((Math.max(s.startMin, DAY_START) - DAY_START) / SLOT) * SLOT_PX;
      const bottom = ((Math.min(s.endMin, DAY_END) - DAY_START) / SLOT) * SLOT_PX;
      const w = 100 / s.lanes;
      return itemHtml(s, ` style="top:${top + 1}px;height:${Math.max(bottom - top - 2, 18)}px;left:calc(${s.lane * w}% + 2px);width:calc(${w}% - 4px)"`);
    }).join('');
    bodies += `<div class="dbody${isToday ? ' today' : ''}${isPast ? ' past' : ''}" data-date="${d.date}" style="height:${height}px">${blocks}</div>`;

    list += `<div class="lday${isToday ? ' today' : ''}">${d.label} ${formatDate(d.date)}</div>` +
      (items.length
        ? items.slice().sort((a, b) => a.startMin - b.startMin).map((s) => itemHtml(s)).join('')
        : '<p class="none">No shift.</p>');
  });

  const out = outside.length
    ? `<p class="outside">Outside the 08:30–18:30 grid: ${outside.map((s) =>
      `<a href="#" ${s.kind === 'request' ? `data-request="${s.id}"` : `data-shift="${s.id}"`}>${s.kind === 'request' ? 'Request ' : ''}${formatDateTime(s.starts_at)} ${esc(s.tasks?.code ?? '')}</a>`).join(', ')}</p>`
    : '';

  return `<section class="week"><h2>Week ${formatDate(monday)} – ${formatDate(iso(dn(monday) + 4))}</h2>
    <div class="wscroll"><div class="wgrid">${heads}${bodies}</div></div>
    <div class="wlist">${list}</div>${out}</section>`;
}

/* ---------- requests list ---------- */
function requestsHtml() {
  const from = firstMonday();
  const to = iso(dn(from) + 14);
  const pendingAll = REQUESTS.filter((r) => r.status === 'pending');
  const pending = pendingAll.filter((r) => r.date < from || r.date >= to);
  const sinceHist = new Date(Date.now() - HISTORY_DAYS * 864e5).toISOString();
  const history = REQUESTS.filter((r) => r.status !== 'pending' && (r.decided_at ?? r.created_at) >= sinceHist)
    .sort((a, b) => ((a.decided_at ?? '') < (b.decided_at ?? '') ? 1 : -1));

  const when = (r) => `${formatDate(r.starts_at)}<br><span class="hint">${formatTime(r.starts_at)}–${formatTime(r.ends_at)}</span>`;
  const task = (r) => (r.tasks ? `${esc(r.tasks.code)} ${esc(r.tasks.name)}` : '<span class="hint">—</span>');

  const pendingRows = pending.map((r) => `<tr><td>${esc(personName(r.requester))}</td><td>${when(r)}</td><td>${task(r)}</td>
      <td>${esc(r.description)}</td><td>${esc(r.location ?? '')}</td><td>${formatDate(r.created_at)}</td>
      <td class="actions"><button type="button" class="secondary" data-request="${r.id}">Open</button></td></tr>`).join('');

  const histRows = history.map((r) => `<tr><td><span class="st ${r.status}">${r.status}</span></td>
    <td>${esc(personName(r.requester))}</td><td>${when(r)}</td><td>${task(r)}</td><td>${esc(r.description)}</td>
    <td>${esc(r.admin_note ?? '')}</td><td>${r.decided_at ? formatDate(r.decided_at) : ''}</td></tr>`).join('');

  return `<h2>Shift requests</h2>
    <p class="hint">${pendingAll.length} pending in total. Pending requests in the weeks shown are on the calendar (red, dashed): click one to see it${ADMIN ? ', approve or reject it' : ''}.
    Below: pending requests outside the weeks shown, and the requests handled recently.</p>
    <h2 style="font-size:.9rem">Pending outside the weeks shown (${pending.length})</h2>
    ${pending.length ? `<div class="table-scroll"><table><thead><tr><th>Requested by</th><th>When</th><th>Task</th><th>Work to do</th><th>Location</th><th>Requested on</th><th></th></tr></thead>
      <tbody>${pendingRows}</tbody></table></div>` : '<p class="hint">None.</p>'}
    <details class="hist"><summary>Handled in the last ${HISTORY_DAYS} days (${history.length})</summary>
      ${history.length ? `<div class="table-scroll"><table><thead><tr><th>Outcome</th><th>Requested by</th><th>When</th><th>Task</th><th>Work to do</th><th>Admin note</th><th>Decided on</th></tr></thead>
        <tbody>${histRows}</tbody></table></div>` : '<p class="hint">None.</p>'}
    </details>`;
}

/* ---------- render ---------- */
function render() {
  renderTools();
  const monday = firstMonday();
  document.getElementById('weeks').innerHTML = weekHtml(monday) + weekHtml(iso(dn(monday) + 7));
  document.getElementById('requests').innerHTML = requestsHtml();
}

/* ---------- modal ---------- */
const modal = document.getElementById('modal');
function openModal(html) {
  modal.innerHTML = `<div class="mbox" role="dialog" aria-modal="true">${html}</div>`;
  modal.hidden = false;
  return modal.querySelector('.mbox');
}
function closeModal() { modal.hidden = true; modal.innerHTML = ''; }
modal.addEventListener('click', (e) => { if (e.target === modal) closeModal(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) closeModal(); });

function modalError(box, text) {
  const p = box.querySelector('.message');
  p.textContent = text;
  p.className = 'message error';
  p.hidden = !text;
}

/* ---------- shift details ---------- */
function slotTable(s) {
  return `<div class="table-scroll"><table class="slots"><thead><tr><th>Slot</th><th>Participants</th><th>Supervisors</th></tr></thead><tbody>
    ${s.slots.map((sl) => `<tr class="${sl.started ? 'past' : ''}">
      <td class="mono">${sl.label}–${formatTime(new Date(sl.t + SLOT_MS))}</td>
      <td><span class="${sl.free <= 0 ? 'bad' : ''}">${sl.participants.length}/${s.capacity}</span>
        ${sl.participants.length ? `<span class="hint"> ${esc(sl.participants.map((b) => b.name).join(', '))}</span>` : ''}</td>
      <td>${sl.covered ? esc(sl.supervisors.map((b) => b.name).join(', ')) : '<span class="bad">none</span>'}</td></tr>`).join('')}
    </tbody></table></div>`;
}

function bookingList(s) {
  if (!s.bookings.length) return '<p class="hint">Nobody booked yet.</p>';
  return `<ul class="people">${s.bookings.map((b) => `<li><span>${esc(b.name)}${b.user_id === ME ? ' (you)' : ''}
      <span class="hint">· ${b.role} · ${formatTime(b.starts_at)}–${formatTime(b.ends_at)}</span></span>
      ${ADMIN ? `<button type="button" class="danger btn-icon" data-act="remove" data-user="${b.user_id}" aria-label="Remove booking for ${esc(b.name)}" title="Remove booking for ${esc(b.name)}">${icon('x')}</button>` : ''}</li>`).join('')}</ul>`;
}

function openShift(id) {
  const s = SHIFTS.find((x) => x.id === id);
  if (!s) return;
  const ownFuture = s.own && Date.parse(s.own.starts_at) > Date.now();
  const canBook = !s.own && s.slots.some((sl) => !sl.started && (ADMIN || (sl.covered && sl.free > 0)));
  const box = openModal(`
    <h2>${s.tasks ? `${esc(s.tasks.code)} – ${esc(s.tasks.name)}` : 'Shift'}</h2>
    <p class="meta">${DAYS[weekday(s.date)] ?? ''} ${formatDate(s.starts_at)}, ${formatTime(s.starts_at)}–${formatTime(s.ends_at)}
      · capacity ${s.capacity} participants per half-hour slot (supervisors not counted)${s.ended ? ' · past' : ''}</p>
    <dl>
      ${s.location ? `<dt>Location</dt><dd>${esc(s.location)}</dd>` : ''}
      ${s.description ? `<dt>Work to do</dt><dd>${esc(s.description)}</dd>` : ''}
      ${s.notes ? `<dt>Notes</dt><dd>${esc(s.notes)}</dd>` : ''}
      ${s.own ? `<dt>Your booking</dt><dd>${formatTime(s.own.starts_at)}–${formatTime(s.own.ends_at)} as ${s.own.role}</dd>` : ''}
    </dl>
    ${slotTable(s)}
    <h2 style="font-size:.95rem;margin-top:12px">Bookings</h2>${bookingList(s)}
    <p class="message" role="alert" hidden></p>
    <div class="buttons">
      ${ADMIN ? `<button type="button" class="danger btn-with-icon" data-act="delete-shift">${icon('trash-2')} Delete shift</button>` : ''}
      ${ADMIN ? `<button type="button" class="secondary btn-with-icon" data-act="edit-shift">${icon('pencil')} Edit</button>` : ''}
      ${ADMIN && !s.ended ? '<button type="button" class="secondary" data-act="add-sup">Add supervisor…</button>' : ''}
      ${ownFuture ? '<button type="button" class="danger" data-act="cancel-own">Cancel my booking</button>' : ''}
      ${ownFuture ? '<button type="button" class="secondary" data-act="change-own">Change my hours…</button>' : ''}
      ${canBook ? `<button type="button" data-act="book">${ADMIN ? 'Join as supervisor…' : 'Book…'}</button>` : ''}
      <button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Close</button>
    </div>`);

  box.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const act = b.dataset.act;
    if (act === 'close') { closeModal(); return; }
    if (act === 'edit-shift') { openShiftForm(s); return; }
    if (act === 'book' || act === 'change-own') { openBookingForm(s, ME); return; }
    if (act === 'add-sup') { openBookingForm(s, null); return; }
    b.disabled = true;
    let error = null;
    let message = '';
    if (act === 'cancel-own') {
      const res = await supabase.from('assignments').delete().eq('shift_id', s.id).eq('user_id', ME).select();
      error = res.error;
      if (!error && !res.data.length) error = { message: 'Booking already started' };
      message = 'Booking cancelled.';
    } else if (act === 'remove') {
      const who = s.bookings.find((x) => x.user_id === b.dataset.user);
      if (!window.confirm(`Remove ${who?.name ?? ''} (${who?.role}) from this shift?`)) { b.disabled = false; return; }
      ({ error } = await supabase.from('assignments').delete().eq('shift_id', s.id).eq('user_id', b.dataset.user));
      message = 'Booking removed.';
    } else if (act === 'delete-shift') {
      const warn = s.bookings.length ? `\n\n${s.bookings.length} booking(s) will be deleted.` : '';
      if (!window.confirm(`Delete this shift?${warn}`)) { b.disabled = false; return; }
      ({ error } = await supabase.from('shifts').delete().eq('id', s.id));
      message = 'Shift deleted.';
    }
    if (error) { b.disabled = false; modalError(box, errorText(error)); return; }
    closeModal();
    await reload(message);
  });
}

/* ---------- booking of own hours (or of another admin as supervisor) ---------- */
// userId = ME: own booking; userId = null: admin chooses another admin as supervisor
function openBookingForm(s, userId) {
  const chooseAdmin = userId === null;
  const target = () => (chooseAdmin ? box.querySelector('#b-user').value : ME);
  const role = chooseAdmin || ADMIN ? 'supervisor' : 'participant';
  const existing = (uid) => s.bookings.find((x) => x.user_id === uid) ?? null;
  const future = s.slots.filter((sl) => !sl.started);
  if (!future.length) { toast('The shift has already started.'); return; }

  // Slot usable by the target: not started; for participants also covered and with a free seat
  const usable = (sl, uid) => {
    if (sl.started) return false;
    if (role === 'supervisor') return true;
    const mineHere = sl.participants.some((x) => x.user_id === uid);
    return sl.covered && (sl.free > 0 || mineHere);
  };
  const own = existing(ME);
  const init = own && !chooseAdmin
    ? { from: Date.parse(own.starts_at), to: Date.parse(own.ends_at) }
    : (() => {
      const first = future.find((sl) => usable(sl, ME)) ?? future[0];
      return { from: first.t, to: first.t + SLOT_MS };
    })();

  const fromOpts = future.map((sl) => `<option value="${sl.t}"${sl.t === init.from ? ' selected' : ''}>${sl.label}</option>`).join('');
  const toOpts = future.map((sl) => `<option value="${sl.t + SLOT_MS}"${sl.t + SLOT_MS === init.to ? ' selected' : ''}>${formatTime(new Date(sl.t + SLOT_MS))}</option>`).join('');
  const others = ADMINS.filter((a) => !s.bookings.some((x) => x.user_id === a.id));

  const box = openModal(`
    <h2>${chooseAdmin ? 'Add supervisor' : own ? 'Change my hours' : role === 'supervisor' ? 'Join as supervisor' : 'Book slots'}</h2>
    <p class="meta">${s.tasks ? `${esc(s.tasks.code)} – ${esc(s.tasks.name)} · ` : ''}${DAYS[weekday(s.date)] ?? ''} ${formatDate(s.starts_at)},
      shift ${formatTime(s.starts_at)}–${formatTime(s.ends_at)}</p>
    <form novalidate>
      ${chooseAdmin ? `<label for="b-user">Admin</label><select id="b-user">${others.length
        ? others.map((a) => `<option value="${a.id}">${esc(a.name)}</option>`).join('')
        : '<option value="">No other admin available</option>'}</select>` : ''}
      <div class="row" style="grid-template-columns:1fr 1fr">
        <div><label for="b-from">From</label><select id="b-from">${fromOpts}</select></div>
        <div><label for="b-to">To</label><select id="b-to">${toOpts}</select></div>
      </div>
      <div id="b-hours"></div>
      <p id="b-summary" class="message info"></p>
      <p class="message" role="alert" hidden></p>
      <div class="buttons"><button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Cancel</button>
        <button type="submit" id="b-ok">Confirm</button></div>
    </form>`);

  const fromSel = box.querySelector('#b-from');
  const toSel = box.querySelector('#b-to');
  const summary = box.querySelector('#b-summary');
  const okBtn = box.querySelector('#b-ok');

  const update = () => {
    const uid = target();
    const from = Number(fromSel.value);
    const to = Number(toSel.value);
    const range = future.filter((sl) => sl.t >= from && sl.t < to);
    box.querySelector('#b-hours').innerHTML = `<ul class="hours">${future.map((sl) => {
      const inRange = sl.t >= from && sl.t < to;
      const state = role === 'supervisor' ? (sl.covered ? `supervised by ${sl.supervisors.map((x) => x.name).join(', ')}` : 'no supervisor')
        : !sl.covered ? 'no supervisor' : `${sl.free} free of ${s.capacity}`;
      return `<li class="${inRange ? 'sel' : ''}${usable(sl, uid) ? '' : ' no'}"><span class="mono">${sl.label}</span> ${esc(state)}</li>`;
    }).join('')}</ul>`;
    let problem = '';
    if (chooseAdmin && !uid) problem = 'No other admin available.';
    else if (to <= from) problem = 'The end shall be after the start.';
    else if (range.some((sl) => !usable(sl, uid))) {
      problem = range.some((sl) => !sl.covered) ? 'At least one selected slot has no supervisor yet.' : 'At least one selected slot is full.';
    }
    
    const who = chooseAdmin ? (ADMINS.find((a) => a.id === uid)?.name ?? '') : 'You';
    summary.className = `message ${problem ? 'error' : 'info'}`;
    summary.textContent = problem ||
      `${who} ${chooseAdmin ? 'will be booked' : own ? 'will be booked' : 'book'} ${formatTime(new Date(from))}–${formatTime(new Date(to))} ` +
      `(${durationText(to - from)}) as ${role}, ${DAYS[weekday(s.date)] ?? ''} ${formatDate(s.starts_at)}.`;
    okBtn.disabled = Boolean(problem);
  };
  fromSel.addEventListener('change', () => {
    if (Number(toSel.value) <= Number(fromSel.value)) toSel.value = String(Number(fromSel.value) + SLOT_MS);
    update();
  });
  toSel.addEventListener('change', update);
  box.querySelector('#b-user')?.addEventListener('change', update);
  box.querySelector('[data-act="close"]').addEventListener('click', closeModal);
  update();

  box.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    okBtn.disabled = true;
    const args = {
      p_shift_id: s.id,
      p_starts_at: new Date(Number(fromSel.value)).toISOString(),
      p_ends_at: new Date(Number(toSel.value)).toISOString(),
    };
    if (chooseAdmin) args.p_user_id = target();
    const { error } = await supabase.rpc('book_shift', args);
    if (error) { okBtn.disabled = false; modalError(box, errorText(error)); return; }
    closeModal();
    await reload(own && !chooseAdmin ? 'Booking changed.' : 'Booked.');
  });
}

/* ---------- request details ---------- */
function openRequest(id) {
  const r = REQUESTS.find((x) => x.id === id);
  if (!r) return;
  const box = openModal(`
    <h2>Shift request</h2>
    <p class="meta">${DAYS[weekday(r.date)] ?? ''} ${formatDate(r.starts_at)}, ${formatTime(r.starts_at)}–${formatTime(r.ends_at)}
      · requested by ${esc(personName(r.requester))} on ${formatDate(r.created_at)}</p>
    <dl>
      <dt>Work to do</dt><dd>${esc(r.description)}</dd>
      ${r.tasks ? `<dt>Task</dt><dd>${esc(r.tasks.code)} – ${esc(r.tasks.name)}</dd>` : ''}
      ${r.location ? `<dt>Location</dt><dd>${esc(r.location)}</dd>` : ''}
    </dl>
    ${r.started ? '<p class="hint">The requested start has passed: the request can only be rejected or withdrawn.</p>' : ''}
    <p class="message" role="alert" hidden></p>
    <div class="buttons">
      ${ADMIN && r.status === 'pending' ? '<button type="button" class="danger" data-act="reject">Reject</button>' : ''}
      ${ADMIN && r.status === 'pending' && !r.started ? '<button type="button" data-act="approve">Approve…</button>' : ''}
      ${r.own && r.status === 'pending' ? `<button type="button" class="secondary btn-with-icon" data-act="withdraw">${icon('undo-2')} Withdraw</button>` : ''}
      <button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Close</button>
    </div>`);
  box.addEventListener('click', async (e) => {
    const b = e.target.closest('[data-act]');
    if (!b) return;
    const act = b.dataset.act;
    if (act === 'close') closeModal();
    else if (act === 'approve') openApproveForm(r);
    else if (act === 'reject') openRejectForm(r);
    else if (act === 'withdraw') {
      if (!window.confirm('Withdraw this request?')) return;
      const { error } = await supabase.rpc('withdraw_request', { p_request_id: r.id });
      if (error) { modalError(box, errorText(error)); return; }
      closeModal();
      await reload('Request withdrawn.');
    }
  });
}

/* ---------- forms ---------- */
function supervisorSelect(selected) {
  return `<label for="f-sup">Supervisor (admin, not counted in the capacity; others can join later)</label><select id="f-sup">
    ${ADMINS.map((x) => `<option value="${x.id}"${x.id === selected ? ' selected' : ''}>${esc(x.name)}${x.id === ME ? ' (you)' : ''}</option>`).join('')}</select>`;
}

function taskOptions(selected, optional) {
  return (optional ? '<option value="">— none —</option>' : '<option value="">— select —</option>') +
    TASKS.map((t) => `<option value="${t.id}"${t.id === selected ? ' selected' : ''}>${esc(t.code)} – ${esc(t.name.slice(0, 70))}${t.completed_on ? ' (done)' : ''}</option>`).join('');
}

// Date and half-hour selectors (08:30-18:30)
function slotFields(v) {
  const timeOpts = (first, last, sel) => {
    let o = '';
    for (let m = first; m <= last; m += SLOT) {
      const t = hhmm(m);
      o += `<option value="${t}"${t === sel ? ' selected' : ''}>${t}</option>`;
    }
    return o;
  };
  return `<div class="row">
      <div><label for="f-date">Date</label><input id="f-date" type="date" value="${esc(v.date ?? '')}" required></div>
      <div><label for="f-start">Start</label><select id="f-start">${timeOpts(DAY_START, DAY_END - SLOT, v.start ?? '09:00')}</select></div>
      <div><label for="f-end">End</label><select id="f-end">${timeOpts(DAY_START + SLOT, DAY_END, v.end ?? '11:00')}</select></div>
    </div>`;
}

// Returns an error text, or null if the slot is valid.
function checkSlot(date, start, end) {
  if (!date || !start || !end) return 'Date, start and end are required.';
  if (weekday(date) > 4) return 'Shifts are possible from Monday to Friday only.';
  if (toMin(start) < DAY_START || toMin(end) > DAY_END) return `Shifts are possible between ${hhmm(DAY_START)} and ${hhmm(DAY_END)} only.`;
  if (toMin(start) % SLOT || toMin(end) % SLOT) return 'Shifts start and end on :00 or :30.';
  if (toMin(end) <= toMin(start)) return 'The end shall be after the start.';
  if (zonedToIso(date, start) <= new Date().toISOString()) return 'The start shall be in the future.';
  return null;
}

const val = (box, id) => box.querySelector(`#${id}`).value.trim();
const floorSlot = (min) => hhmm(Math.max(DAY_START, Math.floor(min / SLOT) * SLOT));

// Highest number of participants per slot if the given users are removed
function maxAfterRemoval(s, removed) {
  return Math.max(0, ...s.slots.map((sl) => sl.participants.filter((b) => !removed.includes(b.user_id)).length));
}

// New shift (s undefined) or edit of an existing shift (admin)
function openShiftForm(s, prefill = {}) {
  const v = s
    ? { date: s.date, start: formatTime(s.starts_at), end: formatTime(s.ends_at), task: s.task_id, capacity: s.capacity,
      location: s.location, description: s.description, notes: s.notes }
    : { capacity: 1, ...prefill };
  const box = openModal(`
    <h2>${s ? 'Edit shift' : 'New shift'}</h2>
    <form novalidate>
      ${slotFields(v)}
      ${s ? '<p class="hint">Changing the times keeps the bookings inside the new times; supervisors booked on the whole shift follow the new times.</p>' : ''}
      <label for="f-task">Task</label><select id="f-task" required>${taskOptions(v.task, false)}</select>
      ${s ? '' : supervisorSelect(ME)}
      <label for="f-cap">Capacity (participants per half-hour slot)</label><input id="f-cap" type="number" min="1" max="${MAX_CAPACITY}" value="${esc(v.capacity)}" required>
      <div class="removal" id="f-removal" hidden></div>
      <label for="f-loc">Location</label><input id="f-loc" type="text" maxlength="80" value="${esc(v.location ?? '')}">
      <label for="f-desc">Work to do</label><textarea id="f-desc" maxlength="1000">${esc(v.description ?? '')}</textarea>
      <label for="f-notes">Notes</label><input id="f-notes" type="text" maxlength="300" value="${esc(v.notes ?? '')}">
      <p class="message" role="alert" hidden></p>
      <div class="buttons"><button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Cancel</button><button type="submit" class="btn-with-icon">${icon('check')} Save</button></div>
    </form>`);

  const capInput = box.querySelector('#f-cap');
  const removal = box.querySelector('#f-removal');
  const updateRemoval = () => {
    const cap = Number(capInput.value);
    if (!s || !(cap >= 1) || s.maxBooked <= cap) { removal.hidden = true; removal.innerHTML = ''; return; }
    const checked = new Set([...removal.querySelectorAll('input:checked')].map((i) => i.value));
    removal.hidden = false;
    removal.innerHTML = `<p style="margin:0 0 4px">In some slots more than <strong>${cap}</strong> participants are booked. Select the participants to remove:</p>` +
      s.participants.map((p) => `<label><input type="checkbox" value="${p.user_id}"${checked.has(p.user_id) ? ' checked' : ''}>
        ${esc(p.name)} (${formatTime(p.starts_at)}–${formatTime(p.ends_at)})</label>`).join('');
  };
  capInput.addEventListener('input', updateRemoval);
  box.querySelector('[data-act="close"]').addEventListener('click', closeModal);

  box.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const date = val(box, 'f-date'), start = val(box, 'f-start'), end = val(box, 'f-end');
    const taskId = Number(val(box, 'f-task'));
    const capacity = Math.round(Number(val(box, 'f-cap')));
    const slotChanged = !s || date !== v.date || start !== v.start || end !== v.end;
    const slotError = slotChanged ? checkSlot(date, start, end) : null;
    if (slotError) { modalError(box, slotError); return; }
    if (!taskId) { modalError(box, 'Select a task.'); return; }
    if (!(capacity >= 1 && capacity <= MAX_CAPACITY)) { modalError(box, `The capacity shall be between 1 and ${MAX_CAPACITY}.`); return; }

    const fields = {
      task_id: taskId,
      location: val(box, 'f-loc') || null,
      description: val(box, 'f-desc') || null,
      notes: val(box, 'f-notes') || null,
    };
    const submit = box.querySelector('button[type="submit"]');
    submit.disabled = true;
    let error;
    if (!s) {
      ({ error } = await supabase.rpc('admin_create_shift', {
        p_task_id: taskId, p_starts_at: zonedToIso(date, start), p_ends_at: zonedToIso(date, end), p_capacity: capacity,
        p_location: fields.location, p_description: fields.description, p_notes: fields.notes,
        p_supervisor: val(box, 'f-sup') || null,
      }));
    } else {
      const remove = [...removal.querySelectorAll('input:checked')].map((i) => i.value);
      if (capacity < s.maxBooked && maxAfterRemoval(s, remove) > capacity) {
        submit.disabled = false;
        modalError(box, `Remove participants until at most ${capacity} remain in every slot.`);
        return;
      }
      if (slotChanged) { fields.starts_at = zonedToIso(date, start); fields.ends_at = zonedToIso(date, end); }
      ({ error } = await supabase.from('shifts').update(fields).eq('id', s.id));
      if (!error && capacity !== s.capacity) {
        ({ error } = await supabase.rpc('admin_set_capacity', {
          p_shift_id: s.id, p_capacity: capacity, p_remove_user_ids: remove,
        }));
      }
    }
    if (error) { submit.disabled = false; modalError(box, errorText(error)); return; }
    closeModal();
    await reload(s ? 'Shift updated.' : 'Shift created.');
  });
}

// Shift request (members)
function openRequestForm(prefill = {}) {
  const box = openModal(`
    <h2>Request a shift</h2>
    <p class="meta">Describe the work to do. An administrator will open the shift and you will be booked on it.</p>
    <form novalidate>
      ${slotFields(prefill)}
      <label for="f-task">Task of the Gantt (optional)</label><select id="f-task">${taskOptions(null, true)}</select>
      <label for="f-desc">Work to do (required)</label><textarea id="f-desc" maxlength="1000" required></textarea>
      <label for="f-loc">Location</label><input id="f-loc" type="text" maxlength="80">
      <p class="message" role="alert" hidden></p>
      <div class="buttons"><button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Cancel</button><button type="submit" class="btn-with-icon">${icon('calendar-plus')} Send request</button></div>
    </form>`);
  box.querySelector('[data-act="close"]').addEventListener('click', closeModal);
  box.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const date = val(box, 'f-date'), start = val(box, 'f-start'), end = val(box, 'f-end');
    const slotError = checkSlot(date, start, end);
    if (slotError) { modalError(box, slotError); return; }
    const description = val(box, 'f-desc');
    if (!description) { modalError(box, 'Describe the work to do.'); return; }
    const submit = box.querySelector('button[type="submit"]');
    submit.disabled = true;
    const { error } = await supabase.from('shift_requests').insert({
      starts_at: zonedToIso(date, start), ends_at: zonedToIso(date, end),
      task_id: Number(val(box, 'f-task')) || null, description, location: val(box, 'f-loc') || null,
    });
    if (error) { submit.disabled = false; modalError(box, errorText(error)); return; }
    closeModal();
    await reload('Request sent.');
  });
}

// Approval of a request (admin): creates the shift, books the supervisor and the requester
function openApproveForm(r) {
  const v = {
    date: r.date,
    start: floorSlot(r.startMin),
    end: hhmm(Math.ceil(Math.min(r.endMin, DAY_END) / SLOT) * SLOT),
  };
  const box = openModal(`
    <h2>Approve request</h2>
    <p class="meta">Requested by ${esc(personName(r.requester))} on ${formatDate(r.created_at)}. The shift is created, the supervisor and the requester are booked on it.</p>
    <form novalidate>
      ${slotFields(v)}
      <label for="f-task">Task</label><select id="f-task" required>${taskOptions(r.task_id, false)}</select>
      ${supervisorSelect(ME)}
      <label for="f-cap">Capacity (participants per half-hour slot; 1 = requester only)</label><input id="f-cap" type="number" min="1" max="${MAX_CAPACITY}" value="1">
      <label for="f-loc">Location</label><input id="f-loc" type="text" maxlength="80" value="${esc(r.location ?? '')}">
      <label for="f-desc">Work to do</label><textarea id="f-desc" maxlength="1000">${esc(r.description)}</textarea>
      <label for="f-note">Note to the requester</label><input id="f-note" type="text" maxlength="300">
      <p class="message" role="alert" hidden></p>
      <div class="buttons"><button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Cancel</button><button type="submit" class="btn-with-icon">${icon('check')} Approve and create shift</button></div>
    </form>`);
  box.querySelector('[data-act="close"]').addEventListener('click', closeModal);
  box.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const date = val(box, 'f-date'), start = val(box, 'f-start'), end = val(box, 'f-end');
    const slotError = checkSlot(date, start, end);
    if (slotError) { modalError(box, slotError); return; }
    const taskId = Number(val(box, 'f-task'));
    if (!taskId) { modalError(box, 'Select a task.'); return; }
    const capacity = Math.round(Number(val(box, 'f-cap')));
    if (!(capacity >= 1 && capacity <= MAX_CAPACITY)) { modalError(box, `The capacity shall be between 1 and ${MAX_CAPACITY}.`); return; }
    const submit = box.querySelector('button[type="submit"]');
    submit.disabled = true;
    const { error } = await supabase.rpc('approve_request', {
      p_request_id: r.id,
      p_task_id: taskId,
      p_starts_at: zonedToIso(date, start),
      p_ends_at: zonedToIso(date, end),
      p_capacity: capacity,
      p_location: val(box, 'f-loc') || null,
      p_description: val(box, 'f-desc') || null,
      p_note: val(box, 'f-note') || null,
      p_supervisor: val(box, 'f-sup') || null,
    });
    if (error) { submit.disabled = false; modalError(box, errorText(error)); return; }
    closeModal();
    await reload('Request approved: shift created.');
  });
}

function openRejectForm(r) {
  const box = openModal(`
    <h2>Reject request</h2>
    <p class="meta">${esc(personName(r.requester))} · ${formatDate(r.starts_at)} ${formatTime(r.starts_at)}–${formatTime(r.ends_at)}</p>
    <form novalidate>
      <label for="f-note">Reason (shown to the team)</label><input id="f-note" type="text" maxlength="300">
      <p class="message" role="alert" hidden></p>
      <div class="buttons"><button type="button" class="secondary btn-with-icon" data-act="close">${icon('x')} Cancel</button><button type="submit" class="danger btn-with-icon">${icon('x')} Reject</button></div>
    </form>`);
  box.querySelector('[data-act="close"]').addEventListener('click', closeModal);
  box.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const { error } = await supabase.rpc('reject_request', { p_request_id: r.id, p_note: val(box, 'f-note') || null });
    if (error) { modalError(box, errorText(error)); return; }
    closeModal();
    await reload('Request rejected.');
  });
}

/* ---------- events ---------- */
document.addEventListener('change', (e) => {
  if (e.target.id === 'f-free') { ui.onlyFree = e.target.checked; render(); }
  if (e.target.id === 'f-mine') { ui.onlyMine = e.target.checked; render(); }
  if (e.target.id === 'f-req') { ui.showRequests = e.target.checked; render(); }
});

document.getElementById('app-main').addEventListener('click', async (e) => {
  const reqEl = e.target.closest('[data-request]');
  if (reqEl) { e.preventDefault(); openRequest(Number(reqEl.dataset.request)); return; }
  const shiftEl = e.target.closest('[data-shift]');
  if (shiftEl) { e.preventDefault(); openShift(Number(shiftEl.dataset.shift)); return; }

  const b = e.target.closest('[data-act]');
  if (b) {
    const act = b.dataset.act;
    if (act === 'prev') { ui.week -= 1; await reload(); }
    else if (act === 'next') { ui.week += 1; await reload(); }
    else if (act === 'now') { ui.week = 0; await reload(); }
    else if (act === 'reload') await reload('Data reloaded.');
    else if (act === 'new-shift') openShiftForm();
    else if (act === 'new-request') openRequestForm();
    return;
  }

  // Click on an empty part of a future day: prefilled new shift (admin) or request (members)
  const body = e.target.closest('.dbody');
  if (body && e.target === body && body.dataset.date >= TODAY) {
    const y = e.clientY - body.getBoundingClientRect().top;
    const startMin = Math.min(DAY_START + Math.floor(y / SLOT_PX) * SLOT, DAY_END - SLOT);
    const prefill = { date: body.dataset.date, start: hhmm(startMin), end: hhmm(Math.min(startMin + 120, DAY_END)) };
    if (ADMIN) openShiftForm(undefined, prefill); else openRequestForm(prefill);
  }
});

/* ---------- start ---------- */
if (profile) {
  try {
    await load();
    render();
  } catch (err) {
    document.getElementById('weeks').innerHTML = '';
    toast(errorText(err));
  }
}
