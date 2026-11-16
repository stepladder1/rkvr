// Shared helpers for RKVR's Netlify Functions. Runs on Netlify's servers, never in the browser.
// Secrets come from Netlify → Project configuration → Environment variables:
//   STRIPE_SECRET_KEY      sk_test_… (test) or sk_live_… (live)
//   STRIPE_WEBHOOK_SECRET  whsec_…  (from the Stripe webhook endpoint)
//   SUPABASE_SECRET_KEY    Supabase secret key (sb_secret_…) or legacy service_role key
const crypto = require('crypto');

const SUPABASE_URL = 'https://inoyndkciffwqquhvsid.supabase.co';
const PUBLISHABLE = 'sb_publishable_HMFhcC_cEnGT2yeh1bfU6Q_YWZDLsoD';
const ORIGINS = ['https://rkvr.netlify.app', 'https://rkvrclient.netlify.app', 'https://rkvr-wellness.com', 'https://www.rkvr-wellness.com'];

function cors(event) {
  const o = (event.headers && (event.headers.origin || event.headers.Origin)) || '';
  return {
    'Access-Control-Allow-Origin': ORIGINS.includes(o) ? o : ORIGINS[0],
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin'
  };
}
const reply = (event, status, body) => ({ statusCode: status, headers: Object.assign({ 'Content-Type': 'application/json' }, cors(event)), body: JSON.stringify(body) });

function need(name) {
  const v = process.env[name];
  if (!v) { const e = new Error('Server setting ' + name + ' is missing'); e.status = 500; throw e; }
  return v;
}

// Stripe's API takes form-encoded bodies with bracketed keys: a[b][0][c]=1
function form(obj, prefix, out) {
  out = out || [];
  Object.keys(obj).forEach(k => {
    const v = obj[k], key = prefix ? prefix + '[' + k + ']' : k;
    if (v === undefined || v === null) return;
    if (typeof v === 'object') form(v, key, out);
    else out.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(v)));
  });
  return out.join('&');
}
async function stripe(method, path, params) {
  const res = await fetch('https://api.stripe.com/v1/' + path + (method === 'GET' && params ? '?' + form(params) : ''), {
    method,
    headers: { Authorization: 'Bearer ' + need('STRIPE_SECRET_KEY'), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: method === 'GET' ? undefined : form(params || {})
  });
  const data = await res.json();
  if (!res.ok) { const e = new Error((data.error && data.error.message) || 'Stripe error'); e.status = 502; throw e; }
  return data;
}

// Supabase with the secret key (bypasses row level security: server use only)
async function db(path, opts) {
  opts = opts || {};
  const key = need('SUPABASE_SECRET_KEY');
  const headers = { apikey: key, 'Content-Type': 'application/json' };
  if (key.startsWith('eyJ')) headers.Authorization = 'Bearer ' + key;   // legacy service_role JWT
  if (opts.prefer) headers.Prefer = opts.prefer;
  const res = await fetch(SUPABASE_URL + '/rest/v1/' + path, { method: opts.method || 'GET', headers, body: opts.body ? JSON.stringify(opts.body) : undefined });
  if (!res.ok) { const t = await res.text(); const e = new Error('Database error: ' + t.slice(0, 300)); e.status = 500; throw e; }
  if (res.status === 204) return null;
  const t = await res.text();
  return t ? JSON.parse(t) : null;
}

// Who is calling? Checks their RKVR sign-in token with Supabase.
async function caller(event) {
  const h = (event.headers && (event.headers.authorization || event.headers.Authorization)) || '';
  const token = h.replace(/^Bearer\s+/i, '');
  if (!token) { const e = new Error('Please sign in first.'); e.status = 401; throw e; }
  const res = await fetch(SUPABASE_URL + '/auth/v1/user', { headers: { apikey: PUBLISHABLE, Authorization: 'Bearer ' + token } });
  if (!res.ok) { const e = new Error('Your sign-in has expired. Please sign in again.'); e.status = 401; throw e; }
  const u = await res.json();
  const rows = await db('profiles?select=id,email,full_name,phone,home_spa_id,stripe_customer_id&id=eq.' + u.id);
  if (!rows || !rows[0]) { const e = new Error('We couldn’t find your RKVR account.'); e.status = 404; throw e; }
  return rows[0];
}

// Stripe webhook signatures: header "t=…,v1=…", HMAC-SHA256 of "t.body" with the endpoint secret
function verifyStripe(rawBody, header, secret) {
  const parts = {}; String(header || '').split(',').forEach(p => { const i = p.indexOf('='); if (i > 0) (parts[p.slice(0, i)] = parts[p.slice(0, i)] || []).push(p.slice(i + 1)); });
  const t = parts.t && parts.t[0];
  if (!t || !parts.v1) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 600) return false;
  const expected = crypto.createHmac('sha256', secret).update(t + '.' + rawBody, 'utf8').digest('hex');
  return parts.v1.some(sig => sig.length === expected.length && crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected)));
}

function allowedReturn(url) {
  try { const u = new URL(url); return ORIGINS.includes(u.origin) || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(u.origin); } catch (_) { return false; }
}

module.exports = { reply, stripe, db, caller, verifyStripe, need, allowedReturn, ORIGINS };
