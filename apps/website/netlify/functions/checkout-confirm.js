// Called by the apps when someone comes back from Stripe Checkout. Looks the session up with Stripe and
// records the membership or payment right away, so nothing depends only on the webhook arriving.
// Safe to call more than once; the webhook does the same thing.
const { reply, stripe, caller, isStaffFor } = require('../lib/shared');
const { syncSubscription, markPaid } = require('./stripe-webhook');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const { session_id } = JSON.parse(event.body || '{}');
    if (!/^cs_[A-Za-z0-9_]+$/.test(session_id || '')) return reply(event, 400, { error: 'Missing checkout session.' });
    const s = await stripe('GET', 'checkout/sessions/' + session_id);
    const m = s.metadata || {};
    const mine = m.rkvr_client_id && m.rkvr_client_id === me.id;
    const staff = (m.rkvr_spa || m.rkvr_home_spa) ? await isStaffFor(me, m.rkvr_spa || m.rkvr_home_spa) : me.role === 'super_admin';
    if (!mine && !staff && !(m.rkvr_signed_up_by && m.rkvr_signed_up_by === me.id)) return reply(event, 403, { error: 'Not your checkout.' });
    let note = 'nothing to do';
    if (s.mode === 'subscription' && s.subscription) note = await syncSubscription(await stripe('GET', 'subscriptions/' + s.subscription));
    else if (s.mode === 'payment') note = await markPaid(s);
    return reply(event, 200, { ok: true, status: s.status, payment_status: s.payment_status, note });
  } catch (e) {
    console.error('[checkout-confirm]', e.message);
    return reply(event, e.status || 500, { error: e.message });
  }
};
