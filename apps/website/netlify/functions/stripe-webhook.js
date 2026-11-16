// Stripe tells RKVR when a membership starts, renews, fails to renew or is cancelled.
// Keeps the memberships table in step. Stripe → Developers → Webhooks points here.
const { stripe, db, verifyStripe, need, RKVR_ACCOUNT } = require('../lib/shared');

const STATUS = { active: 'active', trialing: 'active', past_due: 'past_due', unpaid: 'past_due', paused: 'paused', canceled: 'canceled', incomplete_expired: 'canceled', incomplete: 'pending' };
const day = ts => ts ? new Date(ts * 1000).toISOString().slice(0, 10) : null;

async function syncSubscription(sub) {
  const m = sub.metadata || {};
  if (!m.rkvr_client_id) return 'not an RKVR membership';
  const item = sub.items && sub.items.data && sub.items.data[0];
  const start = sub.current_period_start || (item && item.current_period_start);
  const end = sub.current_period_end || (item && item.current_period_end);
  const status = STATUS[sub.status] || 'pending';
  const row = {
    client_id: m.rkvr_client_id, plan_id: m.rkvr_plan || 'rkvr', home_spa_id: m.rkvr_home_spa || null,
    rate_cents: Number(m.rkvr_rate_cents) || (item && item.price && item.price.unit_amount) || 0,
    is_founding: m.rkvr_founding === '1', status,
    current_period_start: day(start), current_period_end: day(end),
    stripe_subscription_id: sub.id,
    started_at: sub.start_date ? new Date(sub.start_date * 1000).toISOString() : null,
    canceled_at: status === 'canceled' ? new Date((sub.canceled_at || sub.ended_at || Date.now() / 1000) * 1000).toISOString() : null
  };
  await db('memberships?on_conflict=stripe_subscription_id', { method: 'POST', prefer: 'resolution=merge-duplicates,return=minimal', body: row });
  return 'membership ' + status;
}

exports.handler = async event => {
  if (event.httpMethod !== 'POST') return { statusCode: 405, body: 'Use POST' };
  const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
  const sig = event.headers['stripe-signature'] || event.headers['Stripe-Signature'];
  let secret;
  try { secret = need('STRIPE_WEBHOOK_SECRET'); } catch (e) { return { statusCode: 500, body: e.message }; }
  if (!verifyStripe(raw, sig, secret)) return { statusCode: 400, body: 'Bad signature' };
  const evt = JSON.parse(raw);
  // With RKVR as a connected account, events arrive tagged with that account. Ignore anyone else's.
  const acct = evt.account || null;
  if (RKVR_ACCOUNT() && acct && acct !== RKVR_ACCOUNT()) return { statusCode: 200, body: JSON.stringify({ received: true, note: 'other account' }) };
  const as = acct || RKVR_ACCOUNT();
  try {
    let note = 'ignored';
    const o = evt.data && evt.data.object;
    if (evt.type === 'checkout.session.completed' && o.mode === 'subscription' && o.subscription) {
      note = await syncSubscription(await stripe('GET', 'subscriptions/' + o.subscription, null, as));
    } else if (/^customer\.subscription\.(created|updated|deleted|paused|resumed)$/.test(evt.type)) {
      note = await syncSubscription(o);
    } else if (evt.type === 'invoice.payment_failed' || evt.type === 'invoice.paid') {
      const subId = o.subscription || (o.parent && o.parent.subscription_details && o.parent.subscription_details.subscription);
      if (subId) note = await syncSubscription(await stripe('GET', 'subscriptions/' + subId, null, as));
    }
    return { statusCode: 200, body: JSON.stringify({ received: true, note }) };
  } catch (e) {
    return { statusCode: 500, body: e.message };   // Stripe retries on errors
  }
};
