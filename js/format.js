// Date and time formatting in the laboratory time zone.
export const TIME_ZONE = 'Europe/Rome';

function parts(value, options) {
  const date = value instanceof Date ? value : new Date(value);
  const out = {};
  new Intl.DateTimeFormat('en-GB', { timeZone: TIME_ZONE, ...options })
    .formatToParts(date)
    .forEach((p) => { out[p.type] = p.value; });
  return out;
}

// DD.MM.YYYY (accepts a timestamp or a YYYY-MM-DD date)
export function formatDate(value) {
  if (!value) return '';
  if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const [y, m, d] = value.split('-');
    return `${d}.${m}.${y}`;
  }
  const p = parts(value, { day: '2-digit', month: '2-digit', year: 'numeric' });
  return `${p.day}.${p.month}.${p.year}`;
}

// HH:MM (24 h)
export function formatTime(value) {
  if (!value) return '';
  const p = parts(value, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
  return `${p.hour}:${p.minute}`;
}

// DD.MM.YYYY HH:MM
export function formatDateTime(value) {
  if (!value) return '';
  return `${formatDate(value)} ${formatTime(value)}`;
}

// Calendar parts of an instant in the laboratory time zone.
export function zonedParts(value) {
  const p = parts(value, {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  });
  return {
    year: Number(p.year), month: Number(p.month), day: Number(p.day),
    hour: Number(p.hour), minute: Number(p.minute),
    date: `${p.year}-${p.month}-${p.day}`,
    minutes: Number(p.hour) * 60 + Number(p.minute),
  };
}

// Today as YYYY-MM-DD in the laboratory time zone.
export function todayIso() {
  return zonedParts(new Date()).date;
}

// Local date (YYYY-MM-DD) and time (HH:MM) in the laboratory time zone -> ISO instant (UTC).
export function zonedToIso(dateStr, timeStr) {
  const [y, mo, d] = dateStr.split('-').map(Number);
  const [h, mi] = timeStr.split(':').map(Number);
  const target = Date.UTC(y, mo - 1, d, h, mi);
  let t = target;
  for (let i = 0; i < 2; i += 1) {
    const p = zonedParts(new Date(t));
    t += target - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
  }
  return new Date(t).toISOString();
}
