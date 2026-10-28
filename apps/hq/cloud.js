// RKVR HQ ↔ Supabase.
// A small client for Supabase sign-in (Auth) and data (REST), with no outside libraries,
// plus adapters that give the dashboard the same `db` and `user` interface it already uses.
(function () {
  const cfg = window.RKVR_CONFIG;
  if (!cfg || !cfg.supabaseUrl || !cfg.supabaseKey) return;

  const URL_ = cfg.supabaseUrl.replace(/\/$/, '');
  const KEY = cfg.supabaseKey;
  const STORE = 'rkvr-hq-session';
  const POLL_MS = 20000;
  let session = null;
  try { session = JSON.parse(localStorage.getItem(STORE) || 'null'); } catch (_) { session = null; }

  const saveSession = s => {
    session = s;
    try { s ? localStorage.setItem(STORE, JSON.stringify(s)) : localStorage.removeItem(STORE); } catch (_) {}
  };
  const withExpiry = s => Object.assign({}, s, { expires_at: s.expires_at || Math.floor(Date.now() / 1000) + (s.expires_in || 3600) });

  async function authCall(path, body) {
    const res = await fetch(URL_ + '/auth/v1/' + path, {
      method: 'POST',
      headers: { apikey: KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg = data.error_description || data.msg || data.message || 'Sign-in failed';
      const err = new Error(msg); err.status = res.status; throw err;
    }
    return data;
  }

  async function token() {
    if (!session) return null;
    if (session.expires_at - 60 < Date.now() / 1000) {
      try { saveSession(withExpiry(await authCall('token?grant_type=refresh_token', { refresh_token: session.refresh_token }))); }
      catch (e) { saveSession(null); return null; }
    }
    return session.access_token;
  }

  async function rest(path, opts = {}) {
    const t = await token();
    const headers = { apikey: KEY, Authorization: 'Bearer ' + (t || KEY), 'Content-Type': 'application/json' };
    if (opts.prefer) headers.Prefer = opts.prefer;
    const res = await fetch(URL_ + '/rest/v1/' + path, {
      method: opts.method || 'GET', headers, body: opts.body ? JSON.stringify(opts.body) : undefined
    });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      const err = new Error(data.message || ('Request failed: ' + res.status)); err.status = res.status;
      err.code = res.status >= 500 || res.status === 0 ? 'unavailable' : 'denied';
      throw err;
    }
    if (res.status === 204) return null;
    const txt = await res.text();
    return txt ? JSON.parse(txt) : null;
  }

  let profile = null;
  async function loadProfile() {
    if (!session || !session.user) return null;
    const rows = await rest('profiles?select=id,role,full_name,email&id=eq.' + session.user.id);
    profile = rows && rows[0] ? rows[0] : null;
    return profile;
  }

  // Calls `apply` now and then whenever the result changes (checked every 20 seconds)
  function poll(fetcher, apply, onError) {
    let last = null, stopped = false;
    const tick = async () => {
      if (stopped || document.hidden) return;
      try {
        const v = await fetcher();
        const sig = JSON.stringify(v);
        if (sig !== last) { last = sig; apply(v); }
      } catch (e) { if (onError) onError(e); }
    };
    tick();
    const id = setInterval(tick, POLL_MS);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); });
    return () => { stopped = true; clearInterval(id); };
  }

  // Dashboard documents also feed the tables the apps read
  async function mirror(path, data) {
    if (path === 'config/features') {
      const rows = Object.keys(data).map(k => ({ key: k, enabled: !!data[k], updated_by: profile && profile.id }));
      if (rows.length) await rest('feature_flags', { method: 'POST', prefer: 'resolution=merge-duplicates', body: rows });
    } else if (path === 'config/marketing') {
      await rest('settings', { method: 'POST', prefer: 'resolution=merge-duplicates', body: [{ key: 'marketing', value: data, updated_by: profile && profile.id }] });
    } else if (path === 'config/settings') {
      await rest('settings', { method: 'POST', prefer: 'resolution=merge-duplicates', body: [{ key: 'hq', value: data, updated_by: profile && profile.id }] });
    }
  }

  const db = {
    doc(path) {
      return {
        async set(data) {
          await rest('hq_docs', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal',
            body: { path, data, updated_by: profile && profile.id, updated_at: new Date().toISOString() } });
          try { await mirror(path, data); } catch (e) { console.warn('[RKVR] mirror failed', path, e); }
        },
        onSnapshot(cb, onError) {
          return poll(async () => {
            const rows = await rest('hq_docs?select=data&path=eq.' + encodeURIComponent(path));
            return rows && rows[0] ? rows[0].data : null;
          }, d => cb({ exists: d !== null, data: () => d }), onError);
        }
      };
    },
    collection(name) {
      const q = { limit: 50 };
      const api = {
        async add(data) {
          await rest('hq_items', { method: 'POST', prefer: 'return=minimal', body: { collection: name, data, created_by: profile && profile.id } });
        },
        orderBy() { return api; },
        limit(n) { q.limit = n; return api; },
        onSnapshot(cb, onError) {
          return poll(async () => rest('hq_items?select=data&collection=eq.' + encodeURIComponent(name) + '&order=created_at.desc&limit=' + q.limit),
            rows => cb({ docs: (rows || []).map(r => ({ data: () => r.data })) }), onError);
        }
      };
      return api;
    }
  };

  const user = {
    async me() {
      const p = profile || await loadProfile();
      return { id: p.id, name: p.full_name || p.email, avatarUrl: '', canEdit: p.role === 'hq_admin' };
    },
    async canEdit() { return !!(profile && profile.role === 'hq_admin'); },
    async profiles(ids) {
      const out = {};
      if (!ids.length) return out;
      const rows = await rest('profiles?select=id,full_name,email&id=in.(' + ids.map(encodeURIComponent).join(',') + ')');
      (rows || []).forEach(r => { out[r.id] = { name: r.full_name || r.email, isMe: profile && r.id === profile.id }; });
      return out;
    }
  };

  // Links from Supabase emails (password reset, invite) arrive with tokens in the URL hash
  let linkType = null;
  try {
    const h = new URLSearchParams((location.hash || '').replace(/^#/, ''));
    if (h.get('access_token')) {
      linkType = h.get('type') || 'magiclink';
      saveSession(withExpiry({ access_token: h.get('access_token'), refresh_token: h.get('refresh_token'),
        expires_in: +h.get('expires_in') || 3600, user: null }));
      history.replaceState(null, '', location.pathname + location.search);
    } else if (h.get('error_description')) {
      linkType = 'error:' + h.get('error_description');
      history.replaceState(null, '', location.pathname + location.search);
    }
  } catch (_) {}

  async function fillUser() {
    if (session && !session.user) {
      const t = await token();
      const res = await fetch(URL_ + '/auth/v1/user', { headers: { apikey: KEY, Authorization: 'Bearer ' + t } });
      if (res.ok) saveSession(Object.assign({}, session, { user: await res.json() }));
    }
  }

  window.RKVR_CLOUD = {
    db, user,
    get linkType() { return linkType; },
    async updatePassword(password) {
      const t = await token();
      const res = await fetch(URL_ + '/auth/v1/user', { method: 'PUT', headers: { apikey: KEY, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: JSON.stringify({ password }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.msg || data.message || 'Couldn’t set the password');
      linkType = null;
    },
    get profile() { return profile; },
    async ensureSession() {
      if (!session) return null;
      if (!(await token())) return null;
      await fillUser();
      if (!session || !session.user) return null;
      try { return await loadProfile(); } catch (e) { if (e.status === 401) { saveSession(null); return null; } throw e; }
    },
    async signIn(email, password) {
      saveSession(withExpiry(await authCall('token?grant_type=password', { email, password })));
      return loadProfile();
    },
    async resetPassword(email) {
      await authCall('recover', { email, redirect_to: location.origin + location.pathname });
    },
    async signOut() {
      try {
        const t = await token();
        if (t) await fetch(URL_ + '/auth/v1/logout', { method: 'POST', headers: { apikey: KEY, Authorization: 'Bearer ' + t } });
      } catch (_) {}
      saveSession(null); profile = null;
    }
  };
})();
