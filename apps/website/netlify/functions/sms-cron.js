// Runs every 2 minutes (netlify.toml). Sends the texts that are due:
//   confirm  – a client's booking is confirmed (booked in the last 6 hours)
//   staff    – the location's operator hears about the new booking
//   reminder – the day before a visit, between 9 AM and 8:59 PM spa time
//   welcome  – a new member (joined in the last 2 days)
// Each row is claimed (marker set) before its text goes out, so a text is never sent twice.
// With texting switched off in HQ, or Twilio not set up, due rows are marked handled and nothing is sent.
const { db } = require('../lib/shared');
const sms = require('../lib/sms');

const APP = 'rkvrclient.netlify.app';
const STOP = ' Reply STOP to opt out.';
const iso = ms => new Date(ms).toISOString();

function when(ts, tz, style) {
  const d = new Date(ts);
  const time = d.toLocaleTimeString('en-US', { timeZone: tz, hour: 'numeric', minute: '2-digit' });
  if (style === 'time') return time;
  return d.toLocaleDateString('en-US', { timeZone: tz, weekday: 'short', month: 'short', day: 'numeric' }) + ' at ' + time;
}
const localDay = (ms, tz) => new Date(ms).toLocaleDateString('en-CA', { timeZone: tz });
const localHour = (ms, tz) => Number(new Date(ms).toLocaleString('en-US', { timeZone: tz, hour: 'numeric', hourCycle: 'h23' }));
function what(b) {
  const items = (b.items || []).slice().sort((x, y) => x.position - y.position).map(i => i.service && i.service.name).filter(Boolean);
  if (!items.length) return 'your visit';
  return items[0] + (items.length > 1 ? ' + ' + (items.length - 1) + ' more' : '');
}
const first = n => String(n || '').trim().split(/\s+/)[0] || '';
const shortName = n => { const p = String(n || '').trim().split(/\s+/); return p.length > 1 ? p[0] + ' ' + p[p.length - 1][0] + '.' : (p[0] || 'A client'); };

// Set the marker only if nobody else has: returns true when this run owns the row
async function claim(table, id, col) {
  const rows = await db(table + '?id=eq.' + id + '&' + col + '=is.null', { method: 'PATCH', prefer: 'return=representation', body: { [col]: new Date().toISOString() } });
  return !!(rows && rows.length);
}

const BOOKING = 'id,starts_at,created_at,spa_id,client_id,client:client_id(full_name,phone,sms_opt_in),spa:spa_id(name,time_zone,address,operator:operator_id(id,phone)),items:booking_items(position,service:service_id(name))';

exports.handler = async () => {
  const now = Date.now();
  const live = sms.configured() && await sms.switchedOn().catch(() => false);
  const done = { confirm: 0, staff: 0, reminder: 0, welcome: 0, live };
  const go = async (kind, args) => { if (live) { await sms.send(Object.assign({ kind }, args)); done[kind]++; } };

  try {
    // 1. Confirmations
    const fresh = await db('bookings?select=' + BOOKING + '&status=eq.booked&confirm_sms_at=is.null&created_at=gte.' + iso(now - 6 * 3600e3) + '&limit=50');
    for (const b of fresh || []) {
      if (!await claim('bookings', b.id, 'confirm_sms_at')) continue;
      const c = b.client || {}, s = b.spa || {}, tz = s.time_zone || 'America/Los_Angeles';
      if (!c.sms_opt_in || !c.phone) continue;
      await go('confirm', { to: c.phone, spa_id: b.spa_id, profile_id: b.client_id, booking_id: b.id,
        body: `RKVR ${s.name}: you're booked for ${what(b)}, ${when(b.starts_at, tz)}. Manage it in the app: ${APP}${STOP}` });
    }

    // 2. Staff alerts (the operator of that location)
    const forStaff = await db('bookings?select=' + BOOKING + '&status=eq.booked&staff_sms_at=is.null&created_at=gte.' + iso(now - 6 * 3600e3) + '&limit=50');
    for (const b of forStaff || []) {
      if (!await claim('bookings', b.id, 'staff_sms_at')) continue;
      const s = b.spa || {}, op = s.operator || {}, tz = s.time_zone || 'America/Los_Angeles';
      if (!op.phone) continue;
      await go('staff', { to: op.phone, spa_id: b.spa_id, profile_id: op.id, booking_id: b.id,
        body: `RKVR ${s.name} new booking: ${shortName(b.client && b.client.full_name)}, ${what(b)}, ${when(b.starts_at, tz)}.` });
    }

    // 3. Day-before reminders: visits 18–26 hours away, sent in daytime hours only.
    //    Bookings made within a day of the visit already got a confirmation, so they're skipped.
    const soon = await db('bookings?select=' + BOOKING + '&status=eq.booked&reminder_sms_at=is.null&starts_at=gte.' + iso(now + 18 * 3600e3) + '&starts_at=lte.' + iso(now + 26 * 3600e3) + '&limit=100');
    for (const b of soon || []) {
      const s = b.spa || {}, c = b.client || {}, tz = s.time_zone || 'America/Los_Angeles';
      const late = Date.parse(b.created_at) > Date.parse(b.starts_at) - 26 * 3600e3;
      const h = localHour(now, tz);
      if (!late && live && (h < 9 || h >= 21)) continue;          // wait for daytime
      if (!await claim('bookings', b.id, 'reminder_sms_at')) continue;
      if (late || !c.sms_opt_in || !c.phone) continue;
      const day = localDay(Date.parse(b.starts_at), tz) === localDay(now + 864e5, tz) ? 'tomorrow at ' + when(b.starts_at, tz, 'time') : when(b.starts_at, tz);
      await go('reminder', { to: c.phone, spa_id: b.spa_id, profile_id: b.client_id, booking_id: b.id,
        body: `RKVR: see you ${day} for ${what(b)} at RKVR ${s.name}${s.address ? ', ' + s.address : ''}. Check in from the app: ${APP}${STOP}` });
    }

    // 4. Membership welcomes
    const members = await db('memberships?select=id,client_id,home_spa_id,client:client_id(full_name,phone,sms_opt_in),spa:home_spa_id(name)&status=eq.active&welcome_sms_at=is.null&created_at=gte.' + iso(now - 48 * 3600e3) + '&limit=50');
    for (const m of members || []) {
      if (!await claim('memberships', m.id, 'welcome_sms_at')) continue;
      const c = m.client || {};
      if (!c.sms_opt_in || !c.phone) continue;
      const hi = first(c.full_name);
      await go('welcome', { to: c.phone, spa_id: m.home_spa_id, profile_id: m.client_id,
        body: `Welcome to RKVR Unlimited${hi ? ', ' + hi : ''}! Book and check in from the app: ${APP}${m.spa && m.spa.name ? ' See you at RKVR ' + m.spa.name + '.' : ''}${STOP}` });
    }
  } catch (e) {
    console.error('[sms-cron]', e.message);
    return { statusCode: 500, body: e.message };
  }
  if (done.confirm + done.staff + done.reminder + done.welcome) console.log('[sms-cron] sent', JSON.stringify(done));
  return { statusCode: 200, body: JSON.stringify(done) };
};
