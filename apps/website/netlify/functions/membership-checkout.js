// Starts RKVR Unlimited sign-up: returns a Stripe Checkout link for the signed-in person.
// Founding rate if they join by the plan's cutoff date (locked in for as long as they stay).
const { reply, stripe, db, caller, allowedReturn } = require('../lib/shared');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const body = JSON.parse(event.body || '{}');
    const back = allowedReturn(body.return_url) ? body.return_url : 'https://rkvr.netlify.app/';

    const live = await db('memberships?select=id,status&client_id=eq.' + me.id + '&status=in.(pending,active,past_due,paused)');
    if (live && live.some(m => m.status !== 'pending')) return reply(event, 409, { error: 'You’re already a member.', code: 'already_member' });

    const plans = await db('membership_plans?select=*&id=eq.rkvr');
    const plan = plans && plans[0];
    if (!plan || !plan.active) return reply(event, 400, { error: 'Membership isn’t available right now.' });
    const today = new Date().toISOString().slice(0, 10);
    const founding = !!(plan.founding_price_cents && plan.founding_cutoff && today <= plan.founding_cutoff);
    const rate = founding ? plan.founding_price_cents : plan.price_cents;

    let customer = me.stripe_customer_id;
    if (!customer) {
      const c = await stripe('POST', 'customers', { email: me.email, name: me.full_name || undefined, phone: me.phone || undefined, metadata: { rkvr_client_id: me.id } });
      customer = c.id;
      await db('profiles?id=eq.' + me.id, { method: 'PATCH', body: { stripe_customer_id: customer } });
    }

    // Uses the Stripe prices saved on the plan if there are any; otherwise describes the price here.
    const savedPrice = founding ? plan.stripe_founding_price_id : plan.stripe_price_id;
    const lineItem = savedPrice ? { price: savedPrice, quantity: 1 } : {
      quantity: 1,
      price_data: { currency: 'usd', unit_amount: rate, recurring: { interval: 'month' }, product_data: { name: plan.name + (founding ? ' · founding rate' : '') } }
    };
    const meta = { rkvr_client_id: me.id, rkvr_plan: 'rkvr', rkvr_rate_cents: String(rate), rkvr_founding: founding ? '1' : '0', rkvr_home_spa: me.home_spa_id || '' };
    const [base, hash] = back.split('#'), sep = base.includes('?') ? '&' : '?';
    const session = await stripe('POST', 'checkout/sessions', {
      mode: 'subscription',
      customer,
      client_reference_id: me.id,
      line_items: { 0: lineItem },
      subscription_data: { metadata: meta },
      metadata: meta,
      allow_promotion_codes: 'true',
      success_url: base + sep + 'joined=1' + (hash ? '#' + hash : ''),
      cancel_url: back
    });
    return reply(event, 200, { url: session.url });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
