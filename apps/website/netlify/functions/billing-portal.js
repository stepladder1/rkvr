// Opens Stripe's billing page so a member can update their card or cancel.
const { reply, stripe, caller, allowedReturn } = require('../lib/shared');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const body = JSON.parse(event.body || '{}');
    if (!me.stripe_customer_id) return reply(event, 400, { error: 'There’s no card on file for this account yet.' });
    const s = await stripe('POST', 'billing_portal/sessions', { customer: me.stripe_customer_id, return_url: allowedReturn(body.return_url) ? body.return_url : 'https://rkvr.netlify.app/' });
    return reply(event, 200, { url: s.url });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
