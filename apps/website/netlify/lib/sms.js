// Text messages through Twilio (RKVR's subaccount under SalonHQ). Server only.
// Netlify → rkvr → Project configuration → Environment variables:
//   TWILIO_ACCOUNT_SID             AC… of RKVR's Twilio subaccount
//   TWILIO_AUTH_TOKEN              that subaccount's auth token (secret)
//   TWILIO_MESSAGING_SERVICE_SID   MG… (preferred), or
//   TWILIO_FROM                    +1… the RKVR phone number
const crypto = require('crypto');
const { db } = require('./shared');

const env = k => (process.env[k] || '').trim();
const configured = () => !!(env('TWILIO_ACCOUNT_SID') && env('TWILIO_AUTH_TOKEN') && (env('TWILIO_MESSAGING_SERVICE_SID') || env('TWILIO_FROM')));

// US numbers only for now: (619) 555-0142 → +16195550142
function e164(p) {
  const d = String(p || '').replace(/\D/g, '');
  if (d.length === 10) return '+1' + d;
  if (d.length === 11 && d[0] === '1') return '+' + d;
  return null;
}

async function twilio(method, path, params) {
  const sid = env('TWILIO_ACCOUNT_SID');
  const res = await fetch('https://api.twilio.com/2010-04-01/Accounts/' + sid + path, {
    method,
    headers: { Authorization: 'Basic ' + Buffer.from(sid + ':' + env('TWILIO_AUTH_TOKEN')).toString('base64'), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: params ? new URLSearchParams(params).toString() : undefined
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(data.message || 'Twilio error ' + res.status); e.code = data.code; throw e; }
  return data;
}

// Send one text and record it in sms_log. Never throws: returns { ok, sid, error }.
async function send({ to, body, kind, spa_id, profile_id, booking_id }) {
  const num = e164(to);
  const log = (status, extra) => db('sms_log', { method: 'POST', prefer: 'return=minimal', body: Object.assign({ kind, spa_id: spa_id || null, profile_id: profile_id || null, booking_id: booking_id || null, to_phone: num || to || null, body, status }, extra || {}) }).catch(e => console.error('[sms] log', e.message));
  if (!num) { await log('skipped', { error: 'No valid US mobile number' }); return { ok: false, error: 'No valid US mobile number' }; }
  try {
    const params = { To: num, Body: body };
    if (env('TWILIO_MESSAGING_SERVICE_SID')) params.MessagingServiceSid = env('TWILIO_MESSAGING_SERVICE_SID'); else params.From = env('TWILIO_FROM');
    const m = await twilio('POST', '/Messages.json', params);
    await log('sent', { twilio_sid: m.sid });
    return { ok: true, sid: m.sid };
  } catch (e) {
    console.error('[sms]', kind, e.code, e.message);
    // 21610: the person replied STOP to this number. Respect it everywhere.
    if (e.code === 21610) await db('rpc/sms_set_opt_in', { method: 'POST', body: { p_phone: num, p_on: false } }).catch(() => {});
    await log('failed', { error: (e.code ? e.code + ': ' : '') + e.message });
    return { ok: false, error: e.message };
  }
}

// Twilio signs each webhook: base64(HMAC-SHA1(auth token, url + sorted key/value pairs))
function validSignature(url, params, header) {
  const token = env('TWILIO_AUTH_TOKEN');
  if (!token || !header) return false;
  const data = url + Object.keys(params).sort().map(k => k + params[k]).join('');
  const want = crypto.createHmac('sha1', token).update(Buffer.from(data, 'utf8')).digest('base64');
  const a = Buffer.from(want), b = Buffer.from(String(header));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Is texting switched on in HQ → Controls?
async function switchedOn() {
  const rows = await db('hq_docs?select=data&path=eq.config/sms');
  return !!(rows && rows[0] && rows[0].data && rows[0].data.on === true);
}

module.exports = { configured, e164, twilio, send, validSignature, switchedOn };
