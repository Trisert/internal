// Stats (admin): booked hours of ended lab shifts, by person, by task, person x task.
import { supabase } from './config.js';
import { initProtectedPage, friendlyError } from './auth.js';
import { formatDate, todayIso } from './format.js';
import { icon } from './icons.js';

const TEAMS = ['SYS', 'ELE', 'SFW', 'AOCS', 'THM', 'TTC', 'OUT', 'MGT'];
const VIEWS = [['people', 'By person'], ['tasks', 'By task'], ['matrix', 'Person × task']];

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const h1 = (n) => (Math.round(n * 10) / 10).toFixed(1);
const addDays = (d, n) => new Date(Date.parse(`${d}T00:00:00Z`) + n * 864e5).toISOString().slice(0, 10);

const me = await initProtectedPage('stats', { adminOnly: true });
const TODAY = todayIso();
const ui = { view: 'people', from: addDays(TODAY, -29), to: TODAY, team: 'All' };
let ROWS = [];        // { user_id, person, task_id, role: participant|supervisor, hours, shifts }
let TASKS = new Map(); // id -> task

async function load() {
  const [h, t] = await Promise.all([
    supabase.rpc('admin_hours', { p_from: ui.from, p_to: ui.to }),
    supabase.from('tasks').select('id, code, name, parent_id, teams, department'),
  ]);
  if (h.error || t.error) throw (h.error || t.error);
  ROWS = h.data.map((r) => ({ ...r, hours: Number(r.hours) }));
  TASKS = new Map(t.data.map((x) => [x.id, x]));
}

function rows() {
  if (ui.team === 'All') return ROWS;
  return ROWS.filter((r) => {
    const t = TASKS.get(r.task_id);
    return t && (t.department === ui.team || t.teams.includes(ui.team));
  });
}

function renderTools() {
  document.getElementById('tools').innerHTML = `
    <div><label for="from">From</label><input id="from" type="date" value="${ui.from}"></div>
    <div><label for="to">To</label><input id="to" type="date" value="${ui.to}"></div>
    <div><label for="team">Department</label><select id="team">${['All', ...TEAMS].map((k) =>
      `<option${k === ui.team ? ' selected' : ''}>${k}</option>`).join('')}</select></div>
    <button type="button" class="secondary" data-range="30">Last 30 days</button>
    <button type="button" class="secondary" data-range="month">This month</button>
    <button type="button" class="secondary" data-range="all">All</button>
    <button type="button" class="secondary btn-icon" data-act="csv" title="Export CSV" aria-label="Export CSV">${icon('download')}</button>`;
  document.getElementById('nav').innerHTML = VIEWS.map(([k, l]) =>
    `<a href="#${k}"${k === ui.view ? ' aria-current="page"' : ''}>${l}</a>`).join('');
}

function taskLabel(id) {
  const t = TASKS.get(id);
  return t ? `<span class="code">${esc(t.code)}</span> ${esc(t.name)}` : '<span class="hint">no task</span>';
}

function byPerson(list) {
  const map = new Map();
  list.forEach((r) => {
    const p = map.get(r.user_id) ?? { name: r.person, hours: 0, sup: 0, shifts: 0, tasks: new Map() };
    p.hours += r.hours;
    if (r.role === 'supervisor') p.sup += r.hours;
    p.shifts += r.shifts;
    p.tasks.set(r.task_id, (p.tasks.get(r.task_id) ?? 0) + r.hours);
    map.set(r.user_id, p);
  });
  return [...map.values()].sort((a, b) => b.hours - a.hours);
}

function viewPeople(list) {
  const people = byPerson(list);
  if (!people.length) return '<p class="hint">No hours in this period.</p>';
  const max = people[0].hours || 1;
  const total = people.reduce((s, p) => s + p.hours, 0);
  return `<div class="table-scroll card cards"><table><thead><tr><th>Person</th><th class="num">Hours</th><th class="num">of which supervising</th><th class="num">Shifts</th><th>Main tasks</th></tr></thead><tbody>
    ${people.map((p) => `<tr><td data-label="Person">${esc(p.name)}</td>
      <td class="num" data-label="Hours"><span class="bar" style="width:${Math.round((p.hours / max) * 80)}px"></span>${h1(p.hours)}</td>
      <td class="num" data-label="of which supervising">${p.sup ? h1(p.sup) : ''}</td>
      <td class="num" data-label="Shifts">${p.shifts}</td>
      <td data-label="Main tasks">${[...p.tasks.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3)
        .map(([id, hrs]) => `${taskLabel(id)} (${h1(hrs)} h)`).join('<br>')}</td></tr>`).join('')}
    <tr class="total"><td data-label="Person">Total</td><td class="num" data-label="Hours">${h1(total)}</td><td class="num" data-label="of which supervising">${h1(people.reduce((s, p) => s + p.sup, 0))}</td><td class="num" data-label="Shifts">${people.reduce((s, p) => s + p.shifts, 0)}</td><td></td></tr>
    </tbody></table></div>`;
}

function viewTasks(list) {
  // Own hours per task, then roll-up of subtasks into parents
  const own = new Map();
  const people = new Map();
  list.forEach((r) => {
    own.set(r.task_id, (own.get(r.task_id) ?? 0) + r.hours);
    if (!people.has(r.task_id)) people.set(r.task_id, new Set());
    people.get(r.task_id).add(r.user_id);
  });
  if (!own.size) return '<p class="hint">No hours in this period.</p>';
  const parentOf = (id) => TASKS.get(id)?.parent_id ?? null;
  const top = new Map(); // top-level id -> { total, ownHours, children: [] }
  own.forEach((hrs, id) => {
    const pid = parentOf(id);
    const key = pid ?? id;
    const entry = top.get(key) ?? { total: 0, ownHours: 0, children: [], people: new Set() };
    entry.total += hrs;
    if (pid) entry.children.push(id); else entry.ownHours += hrs;
    people.get(id).forEach((u) => entry.people.add(u));
    top.set(key, entry);
  });
  const sorted = [...top.entries()].sort((a, b) => b[1].total - a[1].total);
  const total = sorted.reduce((s, [, e]) => s + e.total, 0);
  return `<div class="table-scroll card cards"><table><thead><tr><th>Task</th><th class="num">Hours (incl. subtasks)</th><th class="num">Own hours</th><th class="num">People</th></tr></thead><tbody>
    ${sorted.map(([id, e]) => `<tr><td data-label="Task">${taskLabel(id)}</td><td class="num" data-label="Hours (incl. subtasks)">${h1(e.total)}</td><td class="num" data-label="Own hours">${h1(e.ownHours)}</td><td class="num" data-label="People">${e.people.size}</td></tr>` +
      e.children.sort((a, b) => own.get(b) - own.get(a)).map((c) => `<tr class="sub"><td data-label="Task">${taskLabel(c)}</td><td class="num" data-label="Hours (incl. subtasks)"></td>
        <td class="num" data-label="Own hours">${h1(own.get(c))}</td><td class="num" data-label="People">${people.get(c).size}</td></tr>`).join('')).join('')}
    <tr class="total"><td data-label="Task">Total</td><td class="num" data-label="Hours (incl. subtasks)">${h1(total)}</td><td></td><td></td></tr>
    </tbody></table></div>`;
}

function viewMatrix(list) {
  const people = byPerson(list);
  if (!people.length) return '<p class="hint">No hours in this period.</p>';
  const taskTotals = new Map();
  list.forEach((r) => taskTotals.set(r.task_id, (taskTotals.get(r.task_id) ?? 0) + r.hours));
  const cols = [...taskTotals.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id);
  const code = (id) => esc(TASKS.get(id)?.code ?? '?');
  return `<div class="table-scroll card matrix-scroll"><table class="matrix"><thead><tr><th>Person</th>
      ${cols.map((id) => `<th class="num" title="${esc(TASKS.get(id)?.name ?? '')}">${code(id)}</th>`).join('')}<th class="num">Total</th></tr></thead><tbody>
    ${people.map((p) => `<tr><td>${esc(p.name)}</td>${cols.map((id) =>
      `<td class="num">${p.tasks.has(id) ? h1(p.tasks.get(id)) : ''}</td>`).join('')}<td class="num"><b>${h1(p.hours)}</b></td></tr>`).join('')}
    <tr class="total"><td>Total</td>${cols.map((id) => `<td class="num">${h1(taskTotals.get(id))}</td>`).join('')}
      <td class="num">${h1(people.reduce((s, p) => s + p.hours, 0))}</td></tr>
    </tbody></table></div><p class="hint">Columns: task codes (hover for the name), by decreasing hours.</p>`;
}

function render() {
  renderTools();
  const list = rows();
  const total = list.reduce((s, r) => s + r.hours, 0);
  const people = new Set(list.map((r) => r.user_id)).size;
  const tasks = new Set(list.map((r) => r.task_id)).size;
  document.getElementById('kpi').innerHTML = `<li>Period<b>${formatDate(ui.from)} – ${formatDate(ui.to)}</b></li>
    <li>Total hours<b>${h1(total)}</b></li><li>People<b>${people}</b></li><li>Tasks<b>${tasks}</b></li>`;
  document.getElementById('view').innerHTML = ui.view === 'tasks' ? viewTasks(list)
    : ui.view === 'matrix' ? viewMatrix(list) : viewPeople(list);
}

function exportCsv() {
  const out = [['Person', 'Role', 'Task code', 'Task', 'Parent task', 'Hours', 'Shifts']];
  rows().forEach((r) => {
    const t = TASKS.get(r.task_id);
    const parent = t?.parent_id ? TASKS.get(t.parent_id)?.code ?? '' : '';
    out.push([r.person, r.role, t?.code ?? '', t?.name ?? '', parent, h1(r.hours), r.shifts]);
  });
  const csv = out.map((r) => r.map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')).join('\r\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([`﻿${csv}`], { type: 'text/csv;charset=utf-8' }));
  a.download = `lab_hours_${ui.from}_${ui.to}.csv`;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 500);
}

async function refresh() {
  try { await load(); render(); }
  catch (err) { document.getElementById('view').innerHTML = `<p class="message error">${esc(friendlyError(err))}</p>`; }
}

document.addEventListener('change', async (e) => {
  if (e.target.id === 'from' || e.target.id === 'to') {
    if (!e.target.value) return;
    ui[e.target.id] = e.target.value;
    if (ui.from > ui.to) [ui.from, ui.to] = [ui.to, ui.from];
    await refresh();
  } else if (e.target.id === 'team') { ui.team = e.target.value; render(); }
});

document.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-range],[data-act]');
  if (!b) return;
  if (b.dataset.act === 'csv') { exportCsv(); return; }
  const r = b.dataset.range;
  ui.to = TODAY;
  ui.from = r === '30' ? addDays(TODAY, -29) : r === 'month' ? `${TODAY.slice(0, 8)}01` : '2020-01-01';
  await refresh();
});

window.addEventListener('hashchange', () => {
  const h = location.hash.slice(1);
  ui.view = VIEWS.some(([k]) => k === h) ? h : 'people';
  render();
});

if (me) {
  const h = location.hash.slice(1);
  ui.view = VIEWS.some(([k]) => k === h) ? h : 'people';
  await refresh();
}
