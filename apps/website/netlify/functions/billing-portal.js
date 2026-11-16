// Opens Stripe's billing page so a member can update their card or cancel.
const { reply, stripe, caller, allowedReturn } = require('../lib/shared');

// Uses RKVR's saved portal settings; creates them the first time if there are none
let cached = null;
async function portalConfig() {
  if (cached) return cached;
  const list = await stripe('GET', 'billing_portal/configurations', { is_default: 'true', active: 'true', limit: 1 });
  if (list.data && list.data[0]) return (cached = list.data[0].id);
  const c = await stripe('POST', 'billing_portal/configurations', {
    business_profile: { headline: 'Manage your RKVR membership' },
    features: {
      payment_method_update: { enabled: 'true' },
      invoice_history: { enabled: 'true' },
      customer_update: { enabled: 'true', allowed_updates: { 0: 'email', 1: 'phone' } },
      subscription_cancel: { enabled: 'true', mode: 'at_period_end', cancellation_reason: { enabled: 'true', options: { 0: 'too_expensive', 1: 'unused', 2: 'switched_service', 3: 'other' } } }
    }
  });
  return (cached = c.id);
}

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const body = JSON.parse(event.body || '{}');
    if (!me.stripe_customer_id) return reply(event, 400, { error: 'There’s no card on file for this account yet.' });
    const configuration = await portalConfig();
    const s = await stripe('POST', 'billing_portal/sessions', { customer: me.stripe_customer_id, configuration, return_url: allowedReturn(body.return_url) ? body.return_url : 'https://rkvr.netlify.app/' });
    return reply(event, 200, { url: s.url });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
