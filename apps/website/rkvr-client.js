// RKVR ↔ Supabase for the public website and the client app.
// Email-link sign-in (Supabase Auth) and data (Supabase REST), with no outside libraries.
// Exposes window.RKVR_CLOUD. Requires window.RKVR_CONFIG (config.js) to be loaded first.
(function () {
  const cfg = window.RKVR_CONFIG;
  if (!cfg || !cfg.supabaseUrl || !cfg.supabaseKey) return;

  const URL_ = cfg.supabaseUrl.replace(/\/$/, '');
  const KEY = cfg.supabaseKey;
  const STORE = cfg.sessionKey || 'rkvr-session';
  let session = null;
  try { session = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (_) { session = null; }

  const saveSession = s => {
    session = s;
    try { s ? localStorage.setItem(STORE, JSON.stringify(s)) : localStorage.removeItem(STORE); } catch (_) {}
  };
  const withExpiry = s => Object.assign({}, s, { expires_at: s.expires_at || Math.floor(Date.now() / 1000) + (s.expires_in || 3600) });

  async function auth(path, body, method) {
    const t = method === 'GET' || method === 'PUT' ? await token() : null;
    const res = await fetch(URL_ + '/auth/v1/' + path, {
      method: method || 'POST',
      headers: Object.assign({ apikey: KEY, 'Content-Type': 'application/json' }, t ? { Authorization: 'Bearer ' + t } : {}),
      body: body ? JSON.stringify(body) : undefined
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(data.error_description || data.msg || data.message || 'Something went wrong');
      err.status = res.status; err.code = data.error_code || data.code; throw err;
    }
    return data;
  }

  async function token() {
    if (!session) return null;
    if (session.expires_at - 60 < Date.now() / 1000) {
      try {
        const res = await fetch(URL_ + '/auth/v1/token?grant_type=refresh_token', {
          method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' },
          body: JSON.stringify({ refresh_token: session.refresh_token })
        });
        if (!res.ok) throw new Error('refresh failed');
        saveSession(withExpiry(await res.json()));
      } catch (e) { saveSession(null); return null; }
    }
    return session.access_token;
  }

  async function rest(path, opts = {}) {
    const t = await token();
    const headers = { apikey: KEY, Authorization: 'Bearer ' + (t || KEY), 'Content-Type': 'application/json' };
    if (opts.prefer) headers.Prefer = opts.prefer;
    const res = await fetch(URL_ + '/rest/v1/' + path, {
      method: opts.method || 'GET', headers, body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      const err = new Error(data.message || ('Request failed (' + res.status + ')')); err.status = res.status; throw err;
    }
    if (res.status === 204) return null;
    const txt = await res.text();
    return txt ? JSON.parse(txt) : null;
  }
  const rpc = (fn, args) => rest('rpc/' + fn, { method: 'POST', body: args || {} });

  // Email links come back with the session in the URL hash
  let linkType = null, linkError = null;
  try {
    const h = new URLSearchParams((location.hash || '').replace(/^#/, ''));
    if (h.get('access_token')) {
      linkType = h.get('type') || 'magiclink';
      saveSession(withExpiry({ access_token: h.get('access_token'), refresh_token: h.get('refresh_token'),
        expires_in: +h.get('expires_in') || 3600, user: null }));
      history.replaceState(null, '', location.pathname + location.search);
    } else if (h.get('error_description') || h.get('error')) {
      linkError = (h.get('error_description') || h.get('error') || '').replace(/\+/g, ' ');
      history.replaceState(null, '', location.pathname + location.search);
    }
  } catch (_) {}

  let profile = null;
  async function loadProfile() {
    if (!session) return null;
    if (!session.user) {
      try { saveSession(Object.assign({}, session, { user: await auth('user', null, 'GET') })); }
      catch (e) { if (e.status === 401 || e.status === 403) saveSession(null); return null; }
    }
    if (!session) return null;
    const rows = await rest('profiles?select=id,role,full_name,email,phone,sms_opt_in,home_spa_id,created_at&id=eq.' + session.user.id);
    profile = rows && rows[0] ? rows[0] : null;
    return profile;
  }

  window.RKVR_CLOUD = {
    rest, rpc,
    get linkType() { return linkType; },
    get linkError() { return linkError; },
    get profile() { return profile; },
    get signedIn() { return !!session; },
    loadProfile,
    // Sends a sign-in link. New emails get an account; `data` fills in their profile.
    async sendLink(email, data, returnTo) {
      const redirect = location.origin + location.pathname;
      try { localStorage.setItem(STORE + ':return', returnTo || ''); } catch (_) {}
      await auth('otp?redirect_to=' + encodeURIComponent(redirect), { email, create_user: true, data: data || {} });
    },
    takeReturn() {
      let v = '';
      try { v = localStorage.getItem(STORE + ':return') || ''; localStorage.removeItem(STORE + ':return'); } catch (_) {}
      return v;
    },
    async updateProfile(fields) {
      if (!profile) return null;
      const rows = await rest('profiles?id=eq.' + profile.id, { method: 'PATCH', prefer: 'return=representation', body: fields });
      profile = rows && rows[0] ? rows[0] : profile;
      return profile;
    },
    async signOut() {
      try { const t = await token(); if (t) await fetch(URL_ + '/auth/v1/logout', { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + t } }); } catch (_) {}
      saveSession(null); profile = null;
    }
  };
})();
