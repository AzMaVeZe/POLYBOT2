// Minimal mock of the Supabase endpoints PadelZit uses (GoTrue + PostgREST).
const http = require('http');

const users = {};   // email -> {id, password}
const rows = {};    // id -> {id, user_id, data}
const tokens = {};  // access_token -> user_id
const codes = {};   // auth_code -> user_id  (PKCE)
const profiles = {}; // user_id -> {user_id, email, name, nickname, roster}
let counter = 0;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, authorization, content-type, prefer',
  'Access-Control-Allow-Methods': 'GET,POST,DELETE,PATCH,OPTIONS',
};

function json(res, code, body) {
  res.writeHead(code, Object.assign({ 'Content-Type': 'application/json' }, CORS));
  res.end(JSON.stringify(body));
}

function makeSession(user) {
  const at = 'at_' + (++counter) + '_' + user.id;
  tokens[at] = user.id;
  return {
    access_token: at,
    refresh_token: 'rt_' + user.id,
    expires_in: 3600,
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    user: { id: user.id, email: user.email },
  };
}

function authedUser(req) {
  const h = req.headers['authorization'] || '';
  const at = h.replace(/^Bearer /, '');
  return tokens[at] || null;
}

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const path = url.pathname;
    let data = null;
    try { data = body ? JSON.parse(body) : null; } catch (e) {}

    if (req.method === 'OPTIONS') { res.writeHead(204, CORS); res.end(); return; }

    if (path === '/auth/v1/signup' && req.method === 'POST') {
      if (!data || !/@/.test(data.email || '')) return json(res, 400, { error_code: 'validation_failed', msg: 'invalid email' });
      if ((data.password || '').length < 6) return json(res, 422, { error_code: 'weak_password', msg: 'Password should be at least 6 characters' });
      if (users[data.email]) return json(res, 422, { error_code: 'user_already_exists', msg: 'User already registered' });
      const user = { id: 'u_' + (++counter), email: data.email, password: data.password };
      users[data.email] = user;
      return json(res, 200, makeSession(user));
    }

    // Provider round-trip (PKCE): pretend the user authenticated, redirect back with ?code=
    if (path === '/auth/v1/authorize' && req.method === 'GET') {
      const provider = url.searchParams.get('provider') || 'google';
      const redirectTo = url.searchParams.get('redirect_to') || '/';
      const email = provider + '.user@example.com';
      let user = users[email];
      if (!user) { user = { id: 'u_' + (++counter), email: email, password: null, provider: provider }; users[email] = user; }
      const code = 'code_' + (++counter);
      codes[code] = user.id;
      const sep = redirectTo.indexOf('?') === -1 ? '?' : '&';
      res.writeHead(302, Object.assign({ Location: redirectTo + sep + 'code=' + code }, CORS));
      res.end();
      return;
    }

    if (path === '/auth/v1/token' && req.method === 'POST') {
      const grant = url.searchParams.get('grant_type');
      if (grant === 'pkce') {
        const uid = codes[(data || {}).auth_code];
        delete codes[(data || {}).auth_code];
        const u = Object.values(users).find(x => x.id === uid);
        if (!u || !(data || {}).code_verifier) return json(res, 400, { error_code: 'invalid_grant' });
        return json(res, 200, makeSession(u));
      }
      if (grant === 'password') {
        const u = users[(data || {}).email];
        if (!u || u.password !== data.password) return json(res, 400, { error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
        return json(res, 200, makeSession(u));
      }
      if (grant === 'refresh_token') {
        const uid = ((data || {}).refresh_token || '').replace('rt_', '');
        const u = Object.values(users).find(x => x.id === uid);
        if (!u) return json(res, 400, { error_code: 'invalid_grant' });
        return json(res, 200, makeSession(u));
      }
      return json(res, 400, { error_code: 'unsupported_grant_type' });
    }

    if (path === '/auth/v1/user' && req.method === 'GET') {
      const uid = authedUser(req);
      if (!uid) return json(res, 401, { message: 'JWT required' });
      const u = Object.values(users).find(x => x.id === uid);
      return json(res, 200, { id: uid, email: u ? u.email : null });
    }

    if (path === '/rest/v1/rpc/delete_account' && req.method === 'POST') {
      const uid = authedUser(req);
      if (!uid) return json(res, 401, { message: 'JWT required' });
      Object.values(rows).filter(r => r.user_id === uid).forEach(r => delete rows[r.id]);
      const u = Object.values(users).find(x => x.id === uid);
      if (u) delete users[u.email];
      res.writeHead(204, CORS); res.end(); return;
    }

    if (path === '/rest/v1/tournaments') {
      const uid = authedUser(req);
      const idFilter = url.searchParams.get('id') || '';
      const id = idFilter ? decodeURIComponent(idFilter.replace(/^eq\./, '')) : null;

      if (req.method === 'GET') {
        // Anon (no JWT): NO direct row access at all — the public share path is
        // the get_public_tournament RPC only (mirrors the fixed RLS setup).
        if (!uid) return json(res, 200, []);
        // Authenticated: RLS visibility is own rows + (historically) public rows.
        // Mirror the WORST-CASE production policy so tests catch pulls that
        // forget to filter by user_id: visible = own OR is_public.
        let visible = Object.values(rows).filter(r => r.user_id === uid || r.is_public);
        // Honor PostgREST-style filters the way the real API does.
        const uidFilter = url.searchParams.get('user_id') || '';
        if (uidFilter) {
          const want = decodeURIComponent(uidFilter.replace(/^eq\./, ''));
          visible = visible.filter(r => r.user_id === want);
        }
        if (id) visible = visible.filter(r => r.id === id);
        return json(res, 200, visible.map(r => ({ id: r.id, data: r.data, is_public: !!r.is_public })));
      }
      if (!uid) return json(res, 401, { message: 'JWT required' });
      if (req.method === 'POST') {
        const arr = Array.isArray(data) ? data : [data];
        arr.forEach(r => {
          const existing = rows[r.id];
          rows[r.id] = { id: r.id, user_id: uid, data: r.data, is_public: existing ? existing.is_public : false };
        });
        res.writeHead(201, CORS); res.end(); return;
      }
      if (req.method === 'PATCH') {
        if (rows[id] && rows[id].user_id === uid && data && typeof data.is_public === 'boolean') {
          rows[id].is_public = data.is_public;
        }
        res.writeHead(204, CORS); res.end(); return;
      }
      if (req.method === 'DELETE') {
        if (rows[id] && rows[id].user_id === uid) delete rows[id];
        res.writeHead(204, CORS); res.end(); return;
      }
    }

    // Player profiles: own-row read/write + exact-match directory lookup.
    if (path === '/rest/v1/profiles') {
      const uid = authedUser(req);
      if (!uid) return json(res, 401, { message: 'JWT required' });
      if (req.method === 'GET') {
        const p = profiles[uid];
        return json(res, 200, p ? [p] : []);
      }
      if (req.method === 'POST') {
        const row = Array.isArray(data) ? data[0] : data;
        profiles[uid] = { user_id: uid, email: row.email, name: row.name || null, nickname: row.nickname || null, roster: row.roster || [] };
        res.writeHead(201, CORS); res.end(); return;
      }
    }
    if (path === '/rest/v1/rpc/find_player' && req.method === 'POST') {
      const uid = authedUser(req);
      if (!uid) return json(res, 401, { message: 'JWT required' });
      const q = String((data || {}).q || '').trim().toLowerCase();
      const hit = Object.values(profiles).find(p =>
        (p.email && p.email.toLowerCase() === q) ||
        (p.nickname && p.nickname.toLowerCase() === q));
      return json(res, 200, hit ? { uid: hit.user_id, name: hit.name, nickname: hit.nickname } : null);
    }

    // Account-free live publish: create/update an ownerless row keyed by
    // the device's write token (mirrors publish_live's ON CONFLICT ... WHERE:
    // wrong token = silent no-op, same as production).
    if (path === '/rest/v1/rpc/publish_live' && req.method === 'POST') {
      const { tid, token, tdata } = data || {};
      if (!tid || !token || String(token).length < 16 || !tdata) return json(res, 400, { message: 'bad request' });
      const r = rows[tid];
      if (!r) rows[tid] = { id: tid, user_id: null, data: tdata, is_public: true, write_token: token };
      else if (r.user_id === null && r.write_token === token) { r.data = tdata; r.is_public = true; }
      res.writeHead(204, CORS); res.end(); return;
    }
    if (path === '/rest/v1/rpc/stop_live' && req.method === 'POST') {
      const { tid, token } = data || {};
      const r = rows[tid];
      if (r && r.user_id === null && r.write_token === token) r.is_public = false;
      res.writeHead(204, CORS); res.end(); return;
    }

    // Public share read: fetch-by-exact-id, scrubbed of account-linked fields.
    if (path === '/rest/v1/rpc/get_public_tournament' && req.method === 'POST') {
      const tid = (data || {}).tid;
      const r = tid && rows[tid];
      if (!(r && r.is_public)) return json(res, 200, null);
      const scrubbed = Object.assign({}, r.data);
      delete scrubbed.claims; delete scrubbed.meIndex;
      return json(res, 200, scrubbed);
    }

    // debug endpoint for tests
    if (path === '/__state') return json(res, 200, { users: Object.keys(users), rows: Object.values(rows).map(r => ({ id: r.id, user_id: r.user_id, is_public: !!r.is_public })) });

    json(res, 404, { message: 'not found: ' + req.method + ' ' + path });
  });
});

server.listen(9021, () => console.log('mock supabase on :9021'));
