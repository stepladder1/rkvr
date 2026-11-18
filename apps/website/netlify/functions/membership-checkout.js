// Starts RKVR Unlimited sign-up: returns a Stripe Checkout link.
//  • A signed-in client joins for themselves (website, client app).
//  • Spa staff (front-desk iPad, RKVR Pro) can sign someone up: body.for = { name, email, phone, spa_id, visit_id }.
//    Their RKVR account is made if they don't have one yet.
// Founding rate if they join by the plan's cutoff date (locked in for as long as they stay).
const { reply, stripe, db, caller, allowedReturn, isStaffFor, findOrCreateClient, customerFor, withParam, withSession } = require('../lib/shared');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const body = JSON.parse(event.body || '{}');
    const back = allowedReturn(body.return_url) ? body.return_url : 'https://rkvr.netlify.app/';

    let who = me;
    if (body.for) {
      const f = body.for;
      if (!f.spa_id || !(await isStaffFor(me, f.spa_id))) return reply(event, 403, { error: 'Only staff at this spa can sign someone up.' });
      who = await findOrCreateClient({ email: f.email, name: f.name, phone: f.phone, spaId: f.spa_id });
      if (!who.home_spa_id) { await db('profiles?id=eq.' + who.id, { method: 'PATCH', body: { home_spa_id: f.spa_id } }); who.home_spa_id = f.spa_id; }
      if (f.visit_id) await db('visits?id=eq.' + f.visit_id + '&spa_id=eq.' + f.spa_id + '&client_id=is.null', { method: 'PATCH', body: { client_id: who.id } });
    }

    const live = await db('memberships?select=id,status&client_id=eq.' + who.id + '&status=in.(pending,active,past_due,paused)');
    if (live && live.some(m => m.status !== 'pending')) return reply(event, 409, { error: (body.for ? 'They’re' : 'You’re') + ' already a member.', code: 'already_member' });

    const plans = await db('membership_plans?select=*&id=eq.rkvr');
    const plan = plans && plans[0];
    if (!plan || !plan.active) return reply(event, 400, { error: 'Membership isn’t available right now.' });
    const today = new Date().toISOString().slice(0, 10);
    const founding = !!(plan.founding_price_cents && plan.founding_cutoff && today <= plan.founding_cutoff);
    const rate = founding ? plan.founding_price_cents : plan.price_cents;

    const customer = await customerFor(who);
    // Uses the Stripe prices saved on the plan if there are any; otherwise describes the price here.
    const savedPrice = founding ? plan.stripe_founding_price_id : plan.stripe_price_id;
    const lineItem = savedPrice ? { price: savedPrice, quantity: 1 } : {
      quantity: 1,
      price_data: { currency: 'usd', unit_amount: rate, recurring: { interval: 'month' }, product_data: { name: plan.name + (founding ? ' · founding rate' : '') } }
    };
    const meta = { rkvr_client_id: who.id, rkvr_plan: 'rkvr', rkvr_rate_cents: String(rate), rkvr_founding: founding ? '1' : '0', rkvr_home_spa: who.home_spa_id || '', rkvr_signed_up_by: body.for ? me.id : '' };
    const session = await stripe('POST', 'checkout/sessions', {
      mode: 'subscription',
      customer,
      client_reference_id: who.id,
      line_items: { 0: lineItem },
      subscription_data: { metadata: meta },
      metadata: meta,
      allow_promotion_codes: 'true',
      success_url: withSession(withParam(back, 'joined', '1')),
      cancel_url: back
    });
    return reply(event, 200, { url: session.url });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
