// Twilio → this function when someone texts RKVR's number (set as the number's or Messaging
// Service's incoming-message webhook). STOP turns texts off for that phone; START turns them back on.
// Twilio itself sends the "you're unsubscribed" reply, so we answer with empty TwiML.
const { db } = require('../lib/shared');
const sms = require('../lib/sms');

const OFF = ['STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT'];
const ON = ['START', 'UNSTOP', 'YES'];
const twiml = { statusCode: 200, headers: { 'Content-Type': 'text/xml' }, body: '<?xml version="1.0" encoding="UTF-8"?><Response></Response>' };

exports.handler = async event => {
  if (event.httpMethod !== 'POST') return { statusCode: 405, body: 'Use POST' };
  const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
  const params = Object.fromEntries(new URLSearchParams(raw));
  const url = event.rawUrl || ('https://' + event.headers.host + event.path);
  const sig = event.headers['x-twilio-signature'] || event.headers['X-Twilio-Signature'];
  if (!sms.validSignature(url, params, sig)) { console.warn('[sms-inbound] bad signature'); return { statusCode: 403, body: 'Bad signature' }; }

  const word = String(params.Body || '').trim().toUpperCase().replace(/[^A-Z]/g, '');
  const on = ON.includes(word) ? true : OFF.includes(word) ? false : null;
  try {
    if (on !== null) {
      const n = await db('rpc/sms_set_opt_in', { method: 'POST', body: { p_phone: params.From, p_on: on } });
      await db('sms_log', { method: 'POST', prefer: 'return=minimal', body: { kind: 'inbound', to_phone: params.From, body: word, status: on ? 'start' : 'stop', twilio_sid: params.MessageSid || null, error: n ? null : 'No RKVR client with this number' } });
    } else {
      await db('sms_log', { method: 'POST', prefer: 'return=minimal', body: { kind: 'inbound', to_phone: params.From, body: String(params.Body || '').slice(0, 500), status: 'received', twilio_sid: params.MessageSid || null } });
    }
  } catch (e) { console.error('[sms-inbound]', e.message); }
  return twiml;
};
