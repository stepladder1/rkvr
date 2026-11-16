// Pay for an à la carte visit by card. Returns a Stripe Checkout link.
//  • body.booking_id: a booked visit, paid ahead by the client (website, app) or by staff.
//  • body.visit_id: a visit at the desk (walk-in or checked in), paid on the iPad. Staff only, or the visit's client.
// The amount always comes from the database, never from the browser. Membership-covered services are free.
const { reply, stripe, db, caller, allowedReturn, isStaffFor, customerFor, withParam } = require('../lib/shared');

async function activeMember(clientId) {
  if (!clientId) return false;
  const m = await db('memberships?select=id&client_id=eq.' + clientId + '&status=in.(active,past_due)');
  return !!(m && m.length);
}

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    const body = JSON.parse(event.body || '{}');
    const back = allowedReturn(body.return_url) ? body.return_url : 'https://rkvr.netlify.app/';
    let kind, id, spaId, clientId, lines = [], amount = 0;

    if (body.booking_id) {
      const rows = await db('bookings?select=id,spa_id,client_id,repeat,status,paid_at,pay_method,booking_items(position,service_id,price_cents,services(name,member_included))&id=eq.' + body.booking_id);
      const b = rows && rows[0];
      if (!b) return reply(event, 404, { error: 'Booking not found.' });
      if (b.client_id !== me.id && !(await isStaffFor(me, b.spa_id))) return reply(event, 403, { error: 'That isn’t your booking.' });
      if (b.paid_at) return reply(event, 409, { error: 'This visit is already paid.', code: 'paid' });
      if (b.repeat !== 'once') return reply(event, 400, { error: 'Repeating visits are paid at each visit.' });
      if (!['booked', 'checked_in', 'pending_payment'].includes(b.status)) return reply(event, 400, { error: 'This visit can’t be paid for now.' });
      const mem = await activeMember(b.client_id);
      (b.booking_items || []).sort((x, y) => x.position - y.position).forEach(i => {
        const covered = mem && i.services && i.services.member_included;
        if (!covered && i.price_cents > 0) lines.push({ name: (i.services && i.services.name) || 'RKVR service', cents: i.price_cents });
      });
      kind = 'booking'; id = b.id; spaId = b.spa_id; clientId = b.client_id;
    } else if (body.visit_id) {
      const rows = await db('visits?select=id,spa_id,client_id,booking_id,service_ids,pay,amount_cents,paid_at,status&id=eq.' + body.visit_id);
      const v = rows && rows[0];
      if (!v) return reply(event, 404, { error: 'Visit not found.' });
      if (v.client_id !== me.id && !(await isStaffFor(me, v.spa_id))) return reply(event, 403, { error: 'Only staff at this spa can take this payment.' });
      if (v.paid_at) return reply(event, 409, { error: 'This visit is already paid.', code: 'paid' });
      const ids = v.booking_id
        ? ((await db('booking_items?select=service_id,price_cents,position&booking_id=eq.' + v.booking_id + '&order=position')) || []).map(i => i.service_id)
        : (v.service_ids || []);
      const svcs = ids.length ? await db('services?select=id,name,price_cents,member_included&id=in.(' + ids.join(',') + ')') : [];
      const covers = v.pay === 'member' || v.pay === 'join';
      ids.forEach(sid => { const s = (svcs || []).find(x => x.id === sid); if (s && !(covers && s.member_included) && s.price_cents > 0) lines.push({ name: s.name, cents: s.price_cents }); });
      kind = 'visit'; id = v.id; spaId = v.spa_id; clientId = v.client_id;
    } else {
      return reply(event, 400, { error: 'Nothing to pay for.' });
    }

    amount = lines.reduce((a, l) => a + l.cents, 0);
    if (!amount) return reply(event, 400, { error: 'Nothing is due for this visit.', code: 'nothing_due' });

    let customer;
    if (clientId) {
      const p = await db('profiles?select=id,email,full_name,phone,stripe_customer_id&id=eq.' + clientId);
      if (p && p[0] && p[0].email) customer = await customerFor(p[0]);
    }
    const meta = { rkvr_kind: kind, rkvr_id: id, rkvr_spa: spaId, rkvr_client_id: clientId || '' };
    const items = {};
    lines.forEach((l, i) => { items[i] = { quantity: 1, price_data: { currency: 'usd', unit_amount: l.cents, product_data: { name: l.name } } }; });
    const session = await stripe('POST', 'checkout/sessions', {
      mode: 'payment',
      customer,
      line_items: items,
      metadata: meta,
      payment_intent_data: { metadata: meta, description: 'RKVR visit' },
      success_url: withParam(back, 'paid', id),
      cancel_url: back
    });
    return reply(event, 200, { url: session.url, amount_cents: amount });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
