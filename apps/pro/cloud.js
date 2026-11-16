// RKVR Pro ↔ Supabase: staff sign-in, the desk functions and the spa's data. No outside libraries.
(function () {
  const cfg = window.RKVR_CONFIG;
  if (!cfg || !cfg.supabaseUrl || !cfg.supabaseKey) return;
  const URL_ = cfg.supabaseUrl.replace(/\/$/, '');
  const KEY = cfg.supabaseKey;
  const STORE = 'rkvr-pro-session';
  let session = null, profile = null;
  try { session = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (_) {}
  const save = s => { session = s; try { s ? localStorage.setItem(STORE, JSON.stringify(s)) : localStorage.removeItem(STORE); } catch (_) {} };
  const withExpiry = s => Object.assign({}, s, { expires_at: s.expires_at || Math.floor(Date.now() / 1000) + (s.expires_in || 3600) });

  async function authCall(path, body) {
    const res = await fetch(URL_ + '/auth/v1/' + path, { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { const e = new Error(data.error_description || data.msg || data.message || 'Sign-in failed'); e.status = res.status; throw e; }
    return data;
  }
  async function token() {
    if (!session) return null;
    if (session.expires_at - 60 < Date.now() / 1000) {
      try { save(withExpiry(await authCall('token?grant_type=refresh_token', { refresh_token: session.refresh_token }))); }
      catch (e) { if (e.status >= 400 && e.status < 500) save(null); return null; }
    }
    return session.access_token;
  }
  async function rest(path, opts = {}) {
    const t = await token();
    const headers = { apikey: KEY, Authorization: 'Bearer ' + (t || KEY), 'Content-Type': 'application/json' };
    if (opts.prefer) headers.Prefer = opts.prefer;
    const res = await fetch(URL_ + '/rest/v1/' + path, { method: opts.method || 'GET', headers, body: opts.body ? JSON.stringify(opts.body) : undefined });
    if (!res.ok) {
      const d = await res.json().catch(() => ({}));
      const e = new Error(d.message || ('Request failed: ' + res.status)); e.status = res.status; throw e;
    }
    if (res.status === 204) return null;
    const txt = await res.text();
    return txt ? JSON.parse(txt) : null;
  }
  const rpc = (fn, args) => rest('rpc/' + fn, { method: 'POST', body: args || {} });

  // Email links: ?token_hash=…&type=… (used up only when the person taps Continue)
  let pendingLink = null, linkType = null;
  try {
    const q = new URLSearchParams(location.search);
    if (q.get('token_hash')) {
      pendingLink = { token_hash: q.get('token_hash'), type: q.get('type') || 'magiclink' };
      history.replaceState(null, '', location.pathname + location.hash);
    }
    const h = new URLSearchParams((location.hash || '').replace(/^#/, ''));
    if (h.get('access_token')) {
      linkType = h.get('type') || 'magiclink';
      save(withExpiry({ access_token: h.get('access_token'), refresh_token: h.get('refresh_token'), expires_in: +h.get('expires_in') || 3600 }));
      history.replaceState(null, '', location.pathname + location.search);
    }
  } catch (_) {}

  async function loadProfile() {
    if (!session) return null;
    const t = await token(); if (!t) return null;
    if (!session.user) {
      const res = await fetch(URL_ + '/auth/v1/user', { headers: { apikey: KEY, Authorization: 'Bearer ' + t } });
      if (!res.ok) { if (res.status === 401 || res.status === 403) save(null); return null; }
      save(Object.assign({}, session, { user: await res.json() }));
    }
    const rows = await rest('profiles?select=id,role,full_name,email&id=eq.' + session.user.id);
    profile = rows && rows[0] ? rows[0] : null;
    return profile;
  }

  window.RKVR_CLOUD = {
    rest, rpc, loadProfile,
    get profile() { return profile; },
    get pendingLink() { return pendingLink; },
    get linkType() { return linkType; },
    async verifyLink() {
      const l = pendingLink; pendingLink = null; if (!l) return;
      try { save(withExpiry(await authCall('verify', { type: l.type === 'email' ? 'magiclink' : l.type, token_hash: l.token_hash }))); linkType = l.type; }
      catch (e) { if (session && await token()) return; throw new Error('That link has already been used or has expired. Enter your email for a new one.'); }
    },
    // RKVR's server functions (Stripe checkout) on the website, called as the signed-in staff member
    async callFn(name, body) {
      const t = await token();
      if (!t) { const e = new Error('Please sign in again.'); e.status = 401; throw e; }
      const res = await fetch((cfg.functionsUrl || 'https://rkvr.netlify.app/.netlify/functions').replace(/\/$/, '') + '/' + name, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + t }, body: JSON.stringify(body || {}) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { const e = new Error(data.error || 'Something went wrong. Try again.'); e.status = res.status; e.code = data.code; throw e; }
      return data;
    },
    async signIn(email, password) { save(withExpiry(await authCall('token?grant_type=password', { email, password }))); return loadProfile(); },
    async sendLink(email) { await authCall('otp?redirect_to=' + encodeURIComponent(location.origin + location.pathname), { email, create_user: false }); },
    async signOut() {
      try { const t = await token(); if (t) await fetch(URL_ + '/auth/v1/logout', { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + t } }); } catch (_) {}
      save(null); profile = null;
    }
  };
})();
