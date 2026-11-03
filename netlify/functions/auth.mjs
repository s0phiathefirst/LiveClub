// Logs people in with their ID (아이디) instead of their email, so nobody's email ever reaches the browser.
// Needs three environment variables in Netlify (Project configuration > Environment variables):
//   SUPABASE_URL              https://xxxx.supabase.co
//   SUPABASE_PUBLISHABLE_KEY  the publishable (anon) key
//   SUPABASE_SECRET_KEY       the secret (service_role) key  <- server only, never in config.js
// No npm packages: plain fetch against the Supabase REST and Auth endpoints.

const URL_ = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
const PUB = process.env.SUPABASE_PUBLISHABLE_KEY || '';
const SECRET = process.env.SUPABASE_SECRET_KEY || '';

// new-style keys (sb_...) go only in the apikey header; legacy JWT keys also go in Authorization
const headers = (key, extra = {}) =>
  Object.assign(key.startsWith('sb_') ? { apikey: key } : { apikey: key, Authorization: 'Bearer ' + key }, extra);
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

// small per-instance brake on password guessing: 10 tries per ID per 10 minutes
const tries = new Map();
function limited(login) {
  const now = Date.now(), t = (tries.get(login) || []).filter((x) => now - x < 600000);
  t.push(now); tries.set(login, t);
  return t.length > 10;
}

async function emailFor(login) {
  const r = await fetch(`${URL_}/rest/v1/accounts?select=email&login_lower=eq.${encodeURIComponent(login)}&limit=1`, { headers: headers(SECRET) });
  if (!r.ok) throw new Error('lookup ' + r.status);
  const rows = await r.json();
  return rows.length ? rows[0].email : null;
}
const mask = (email) => {
  const [u, d] = email.split('@');
  return (u.slice(0, 2) + '***@' + (d || '').replace(/^[^.]+/, (m) => m[0] + '***'));
};
const session = (j) => ({ access_token: j.access_token, refresh_token: j.refresh_token });

export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'method' }, 405);
  if (!URL_ || !PUB || !SECRET) return json({ error: 'not_configured' }, 500);
  let body;
  try { body = await req.json(); } catch { return json({ error: 'bad_request' }, 400); }
  const action = String(body.action || '');
  const login = String(body.login || '').trim().toLowerCase();
  if (!/^[a-z0-9._]{4,16}$/.test(login)) return json({ error: 'invalid' }, 401);

  try {
    if (limited(login)) return json({ error: 'rate' }, 429);
    const email = await emailFor(login);
    if (!email) return json({ error: 'invalid' }, 401);

    if (action === 'login') {
      const r = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
        method: 'POST', headers: headers(PUB, { 'Content-Type': 'application/json' }),
        body: JSON.stringify({ email, password: String(body.password || '') }),
      });
      const j = await r.json().catch(() => ({}));
      if (r.ok) return json(session(j));
      const msg = (j.error_code || '') + ' ' + (j.msg || j.error_description || j.message || '');
      // email confirmation is turned off for this site, so no mail is sent here
      if (/not.?confirmed/i.test(msg)) return json({ error: 'unconfirmed' }, 401);
      return json({ error: r.status === 429 ? 'rate' : 'invalid' }, r.status === 429 ? 429 : 401);
    }

    if (action === 'verify') {
      const token = String(body.token || '');
      if (!/^\d{6}$/.test(token)) return json({ error: 'invalid' }, 400);
      const r = await fetch(`${URL_}/auth/v1/verify`, {
        method: 'POST', headers: headers(PUB, { 'Content-Type': 'application/json' }),
        body: JSON.stringify({ type: 'signup', email, token }),
      });
      const j = await r.json().catch(() => ({}));
      return r.ok && j.access_token ? json(session(j)) : json({ error: 'invalid' }, 401);
    }

    if (action === 'resend') {
      const r = await fetch(`${URL_}/auth/v1/resend`, { method: 'POST', headers: headers(PUB, { 'Content-Type': 'application/json' }), body: JSON.stringify({ type: 'signup', email }) });
      return r.ok ? json({ sent: true }) : json({ error: 'rate' }, 429);
    }

    return json({ error: 'bad_request' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: 'server' }, 500);
  }
};

export const config = { path: '/api/auth' };
