// HQ only: a fresh Stripe sign-up link for RKVR's connected account (business details, bank account).
// Stripe's links expire within minutes and work once, so HQ asks for a new one each time.
const { reply, stripe, caller, RKVR_ACCOUNT } = require('../lib/shared');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    if (me.role !== 'hq_admin') return reply(event, 403, { error: 'Only RKVR HQ can do this.' });
    const acct = RKVR_ACCOUNT();
    if (!acct) return reply(event, 400, { error: 'STRIPE_ACCOUNT_ID isn’t set in Netlify yet.' });
    const back = 'https://rkvr-dashboard.netlify.app/?stripe=done';
    const body = JSON.parse(event.body || '{}');
    if (body.status) {
      const a = await stripe('GET', 'accounts/' + acct, null, null);
      const due = (a.requirements && (a.requirements.currently_due || []).concat(a.requirements.past_due || [])) || [];
      return reply(event, 200, { charges: !!a.charges_enabled, payouts: !!a.payouts_enabled, details: !!a.details_submitted, due: Array.from(new Set(due)), name: (a.business_profile && a.business_profile.name) || a.settings && a.settings.dashboard && a.settings.dashboard.display_name || null });
    }
    const link = await stripe('POST', 'account_links', { account: acct, type: 'account_onboarding', collect: 'currently_due', refresh_url: 'https://rkvr-dashboard.netlify.app/?stripe=retry', return_url: back }, null);
    return reply(event, 200, { url: link.url });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
