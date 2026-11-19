// HQ → Controls → Text messages (Super Admins only).
//   { status: true }         is Twilio set up, and which account/number
//   { test: '+1619…' }       send a test text (works even while texting is switched off)
const { reply, caller } = require('../lib/shared');
const sms = require('../lib/sms');

exports.handler = async event => {
  if (event.httpMethod === 'OPTIONS') return reply(event, 204, {});
  if (event.httpMethod !== 'POST') return reply(event, 405, { error: 'Use POST' });
  try {
    const me = await caller(event);
    if (me.role !== 'super_admin') return reply(event, 403, { error: 'Only RKVR Super Admins can do this.' });
    if (!sms.configured()) return reply(event, 200, { configured: false });
    const body = JSON.parse(event.body || '{}');
    if (body.test) {
      if (!sms.e164(body.test)) return reply(event, 400, { error: 'Enter a 10-digit US mobile number.' });
      const r = await sms.send({ to: body.test, kind: 'test', profile_id: me.id, body: 'RKVR test text: texts from RKVR are working. Join. Book. Recover.' });
      return r.ok ? reply(event, 200, { sent: true }) : reply(event, 502, { error: 'Twilio didn’t send it: ' + r.error });
    }
    const a = await sms.twilio('GET', '.json');
    return reply(event, 200, {
      configured: true, account: a.friendly_name || null, accountStatus: a.status || null, trial: a.type === 'Trial',
      sender: process.env.TWILIO_MESSAGING_SERVICE_SID ? 'Messaging Service' : (process.env.TWILIO_FROM || '').trim()
    });
  } catch (e) {
    return reply(event, e.status || 500, { error: e.message });
  }
};
