#!/usr/bin/env node
'use strict';
/*
 * xPerion app server - hosts several demo apps on the xPerion Azure VM
 * Zero dependencies (Node 20.3+). Runs behind Caddy, which handles HTTPS.
 *
 *  - Serves each app at its own path (/foresightstudio/, /careai/, ...)
 *  - For apps that use AI, relays calls to Anthropic or Claude in Microsoft
 *    Foundry and adds the API key on the server, so it never reaches the browser
 *  - Optionally pins the model (Foundry: your deployment name)
 *  - Per-IP rate limit, optional login
 *  - Mirrors each app from its GitHub repo (only changed files are downloaded;
 *    change checks don't use GitHub's limited REST API)
 *
 * Usage:  node server.js                 start the server
 *         node server.js --check         validate config and key, then exit
 *         node server.js --hash-password read a password on stdin, print {salt,hash}
 * Config: config.json next to this file, or the path in FS_CONFIG.
 */
const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');

const VERSION = '2.1.0';
const KEY_RE = /^[A-Za-z0-9._~+\/=-]{20,}$/;      // Anthropic (sk-ant-...) or Azure Foundry key
const KEY_SCAN_RE = /sk-ant-[A-Za-z0-9_-]{20,}/;   // what a leaked Anthropic key looks like
const TEXT_EXT = new Set(['.html', '.htm', '.js', '.mjs', '.css', '.json', '.txt', '.md', '.csv', '.tsv', '.xml', '.svg', '.yml', '.yaml']);
const DEFAULT_EXCLUDE = ['deploy/', 'README.md', 'MIGRATION.md', 'LICENSE'];
const SEC_HEADERS = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin' };
const MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.webp': 'image/webp', '.ico': 'image/x-icon', '.pdf': 'application/pdf', '.csv': 'text/csv; charset=utf-8',
  '.tsv': 'text/tab-separated-values; charset=utf-8', '.txt': 'text/plain; charset=utf-8', '.xml': 'application/xml',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.mp4': 'video/mp4', '.webm': 'video/webm', '.wasm': 'application/wasm'
};

let cfg = null;

// ---------------------------------------------------------------- config & log
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }

function loadConfig() {
  const file = process.env.FS_CONFIG || path.join(__dirname, 'config.json');
  const c = readJson(file);
  const out = Object.assign({
    host: '127.0.0.1', port: 8790, logFile: null, rootRedirect: null,
    upstream: 'https://api.anthropic.com', upstreamTimeoutMs: 120000, model: null,
    maxBodyBytes: 5 * 1024 * 1024, trustProxy: true, auth: null
  }, c);
  out.rateLimit = Object.assign({ perMinute: 60, burst: 30 }, c.rateLimit || {});
  out.github = Object.assign({ apiBase: 'https://api.github.com', webBase: 'https://github.com', rawBase: 'https://raw.githubusercontent.com', tokenFile: null, intervalSeconds: 120 }, c.github || {});
  if (!out.keyFile) throw new Error('config.keyFile is required');
  if (!Array.isArray(c.apps) || !c.apps.length) throw new Error('config.apps must list at least one app');
  const seen = new Set();
  out.apps = c.apps.map((a, i) => {
    const app = Object.assign({ branch: 'main', proxyVar: null, repo: null, model: null, exclude: DEFAULT_EXCLUDE }, a);
    if (!/^[a-z0-9][a-z0-9-]*$/.test(app.name || '')) throw new Error(`apps[${i}].name must be lowercase letters, digits and dashes`);
    app.aliases = [].concat(app.aliases || []).map(String);   // old paths that forward here
    for (const n of [app.name, ...app.aliases]) {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(n)) throw new Error(`apps[${i}]: invalid name or alias '${n}'`);
      if (seen.has(n.toLowerCase())) throw new Error(`apps: '${n}' is used twice`);
      seen.add(n.toLowerCase());
    }
    app.basePath = app.basePath || '/' + app.name;
    if (!/^\/[A-Za-z0-9._-]+$/.test(app.basePath)) throw new Error(`apps[${i}].basePath must look like /name`);
    if (!app.appDir) throw new Error(`apps[${i}].appDir is required`);
    app.appDir = path.resolve(app.appDir);
    if (app.proxyVar && !/^[A-Za-z_$][\w$]*$/.test(app.proxyVar)) throw new Error(`apps[${i}].proxyVar must be a JavaScript name`);
    if (app.repo && !/^[\w.-]+\/[\w.-]+$/.test(app.repo)) throw new Error(`apps[${i}].repo must look like owner/name`);
    app.configJs = app.proxyVar
      ? `// Served by the xPerion app server. No API key here: the server adds it.\nwindow.${app.proxyVar} = "api/v1/messages";\n`
      : null;
    return app;
  });
  if (!out.rootRedirect) out.rootRedirect = out.apps[0].basePath + '/';
  return out;
}

function log(...parts) {
  const line = `${new Date().toISOString()} ${parts.join(' ')}`;
  console.log(line);
  if (!cfg || !cfg.logFile) return;
  try {
    try { if (fs.statSync(cfg.logFile).size > 5 * 1024 * 1024) fs.renameSync(cfg.logFile, cfg.logFile + '.1'); } catch { /* new file */ }
    fs.appendFileSync(cfg.logFile, line + '\n');
  } catch { /* logging must never break serving */ }
}

// ---------------------------------------------------------------- key, ip, limits, auth
let keyCache = { mtimeMs: -1, value: '' };
function getKey() {           // re-read when the file changes, so key rotation needs no restart
  try {
    const st = fs.statSync(cfg.keyFile);
    if (st.mtimeMs !== keyCache.mtimeMs) {
      const v = fs.readFileSync(cfg.keyFile, 'utf8').replace(/^\uFEFF/, '').trim();
      keyCache = { mtimeMs: st.mtimeMs, value: KEY_RE.test(v) ? v : '' };
    }
    return keyCache.value;
  } catch { return ''; }
}

function clientIp(req) {
  const ra = String(req.socket.remoteAddress || '').replace(/^::ffff:/, '');
  if (cfg.trustProxy && (ra === '127.0.0.1' || ra === '::1')) {
    const parts = String(req.headers['x-forwarded-for'] || '').split(',').map(s => s.trim()).filter(Boolean);
    if (parts.length) return parts[parts.length - 1];   // the hop added by Caddy
  }
  return ra || 'unknown';
}

const buckets = new Map();     // token bucket per client IP
function allow(ip) {
  const { perMinute, burst } = cfg.rateLimit;
  if (!perMinute) return { ok: true };
  const rate = perMinute / 60000, cap = Math.max(1, burst), now = Date.now();
  let b = buckets.get(ip);
  if (!b) { b = { tokens: cap, ts: now }; buckets.set(ip, b); }
  b.tokens = Math.min(cap, b.tokens + (now - b.ts) * rate); b.ts = now;
  if (b.tokens >= 1) { b.tokens -= 1; return { ok: true }; }
  return { ok: false, retryAfter: Math.max(1, Math.ceil((1 - b.tokens) / rate / 1000)) };
}
setInterval(() => { const now = Date.now(); for (const [ip, b] of buckets) if (now - b.ts > 600000) buckets.delete(ip); }, 60000).unref();

const goodAuth = new Set();
function checkAuth(req) {
  if (!cfg.auth) return true;
  const h = String(req.headers.authorization || '');
  if (goodAuth.has(h)) return true;
  const m = /^Basic\s+([A-Za-z0-9+/=]+)$/i.exec(h);
  if (!m) return false;
  const dec = Buffer.from(m[1], 'base64').toString('utf8');
  const i = dec.indexOf(':');
  if (i < 0) return false;
  const sha = s => crypto.createHash('sha256').update(s).digest();
  const expected = Buffer.from(cfg.auth.hash, 'hex');
  const got = crypto.scryptSync(dec.slice(i + 1), Buffer.from(cfg.auth.salt, 'hex'), expected.length);
  const ok = crypto.timingSafeEqual(sha(dec.slice(0, i)), sha(cfg.auth.user)) && crypto.timingSafeEqual(got, expected);
  if (ok) { if (goodAuth.size > 100) goodAuth.clear(); goodAuth.add(h); }
  return ok;
}

// ---------------------------------------------------------------- responses
function send(res, status, body, headers = {}) {
  if (res.headersSent) { res.end(); return; }
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(String(body));
  res.writeHead(status, Object.assign({ 'Content-Length': buf.length }, SEC_HEADERS, headers));
  res.end(res.req.method === 'HEAD' ? undefined : buf);
}
const notFound = res => send(res, 404, 'Not found', { 'Content-Type': 'text/plain; charset=utf-8' });
function apiError(res, status, type, message, headers) {
  send(res, status, JSON.stringify({ type: 'error', error: { type, message } }),
    Object.assign({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }, headers));
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    if (Number(req.headers['content-length'] || 0) > limit) { req.resume(); return reject(Object.assign(new Error('too large'), { code: 413 })); }
    const chunks = []; let size = 0, over = false;
    req.on('data', c => { if (over) return; size += c.length; if (size > limit) { over = true; reject(Object.assign(new Error('too large'), { code: 413 })); } else chunks.push(c); });
    req.on('end', () => { if (!over) resolve(Buffer.concat(chunks)); });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------- AI proxy
async function handleApi(req, res, ip, app) {
  if (req.method !== 'POST') return apiError(res, 405, 'invalid_request_error', 'Use POST.', { Allow: 'POST' });
  const rl = allow(ip);
  if (!rl.ok) { log('api', app.name, ip, 429, 'rate-limited'); return apiError(res, 429, 'rate_limit_error', 'Too many requests from this network. Wait a minute and try again.', { 'Retry-After': String(rl.retryAfter) }); }
  const key = getKey();
  if (!key) { log('api', app.name, ip, 500, 'no valid key in', cfg.keyFile); return apiError(res, 500, 'api_error', 'The server has no valid API key configured.'); }

  let body, parsed;
  try { body = await readBody(req, cfg.maxBodyBytes); }
  catch (e) { return e.code === 413 ? apiError(res, 413, 'request_too_large', 'Request is too large.', { Connection: 'close' }) : apiError(res, 400, 'invalid_request_error', 'Could not read the request.'); }
  try { parsed = JSON.parse(body.toString('utf8')); } catch { return apiError(res, 400, 'invalid_request_error', 'Body must be JSON.'); }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return apiError(res, 400, 'invalid_request_error', 'Body must be a JSON object.');
  const pin = app.model || cfg.model;
  if (pin && parsed.model !== pin) { parsed.model = pin; body = Buffer.from(JSON.stringify(parsed)); }

  // A fresh header set: the AI service never sees the visitor's cookies, login or origin.
  const headers = { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': String(req.headers['anthropic-version'] || '2023-06-01') };
  if (req.headers['anthropic-beta']) headers['anthropic-beta'] = String(req.headers['anthropic-beta']);

  const clientGone = new AbortController();
  res.on('close', () => { if (!res.writableEnded) clientGone.abort(); });
  const t0 = Date.now();
  let up;
  try {
    up = await fetch(cfg.upstream.replace(/\/+$/, '') + '/v1/messages', {
      method: 'POST', headers, body,
      signal: AbortSignal.any([clientGone.signal, AbortSignal.timeout(cfg.upstreamTimeoutMs)])
    });
  } catch (e) {
    if (clientGone.signal.aborted) { log('api', app.name, ip, 'client-closed', `${Date.now() - t0}ms`); return; }
    const timedOut = e && e.name === 'TimeoutError';
    log('api', app.name, ip, timedOut ? 504 : 502, `${Date.now() - t0}ms`, `model=${parsed.model}`, (e && e.cause && e.cause.code) || (e && e.message));
    return timedOut
      ? apiError(res, 504, 'api_error', 'The AI Engine took too long to respond. Try again.')
      : apiError(res, 502, 'api_error', 'The server could not reach the AI Engine. Try again shortly.');
  }
  const out = { 'Content-Type': up.headers.get('content-type') || 'application/json', 'Cache-Control': 'no-store' };
  for (const h of ['request-id', 'retry-after']) { const v = up.headers.get(h); if (v) out[h] = v; }
  res.writeHead(up.status, Object.assign({}, SEC_HEADERS, out));
  try { if (up.body) await pipeline(Readable.fromWeb(up.body), res); else res.end(); }
  catch { if (!res.writableEnded) res.destroy(); }
  log('api', app.name, ip, up.status, `${Date.now() - t0}ms`, `model=${parsed.model}`, `max_tokens=${parsed.max_tokens}`);
}

// ---------------------------------------------------------------- static files
async function handleStatic(req, res, app, rel) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', { Allow: 'GET, HEAD', 'Content-Type': 'text/plain' });
  if (rel === '' || rel.endsWith('/')) rel += 'index.html';
  if (app.configJs && rel === 'config.js') return send(res, 200, app.configJs, { 'Content-Type': MIME['.js'], 'Cache-Control': 'no-cache' });
  const segs = rel.split('/');
  // No dotfiles, empty segments, backslashes, NULs, drive letters or Windows streams.
  if (segs.some(s => !s || s.startsWith('.') || /[\\\0:*?"<>|]/.test(s))) return notFound(res);
  const file = path.join(app.appDir, ...segs);
  if (!file.startsWith(app.appDir + path.sep)) return notFound(res);
  let st;
  try { st = await fsp.stat(file); } catch { return notFound(res); }
  if (st.isDirectory()) return send(res, 301, '', { Location: app.basePath + '/' + rel + '/' });
  const etag = `W/"${st.size}-${Math.trunc(st.mtimeMs)}"`;
  const common = { ETag: etag, 'Cache-Control': 'no-cache', 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' };
  if (req.headers['if-none-match'] === etag) { res.writeHead(304, Object.assign({}, SEC_HEADERS, common)); return res.end(); }
  if (st.size <= 256 * 1024) {
    let data;
    try { data = await fsp.readFile(file); } catch { return notFound(res); }
    return send(res, 200, data, common);
  }
  // Large files (datasets) are streamed rather than loaded into memory.
  res.writeHead(200, Object.assign({ 'Content-Length': st.size }, SEC_HEADERS, common));
  if (req.method === 'HEAD') return res.end();
  try { await pipeline(fs.createReadStream(file), res); } catch { if (!res.writableEnded) res.destroy(); }
}

// ---------------------------------------------------------------- router & server
function findApp(pathname) {
  for (const app of cfg.apps) if (pathname === app.basePath || pathname.startsWith(app.basePath + '/')) return app;
  return null;
}

async function route(req, res) {
  let url;
  try { url = new URL(req.url, 'http://localhost'); } catch { return send(res, 400, 'Bad request'); }
  const pathname = url.pathname;
  const ip = clientIp(req);
  if (pathname === '/healthz') {
    const apps = cfg.apps.map(a => ({ name: a.name, path: a.basePath + '/', synced: (syncState[a.name] && syncState[a.name].commit) || null, error: (syncState[a.name] && syncState[a.name].error) || null }));
    return send(res, 200, JSON.stringify({ ok: true, version: VERSION, keyConfigured: !!getKey(), apps }),
      { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  }
  if (!checkAuth(req)) {
    const rl = allow(ip);   // failed logins count against the same per-IP limit
    if (!rl.ok) return send(res, 429, 'Too many attempts', { 'Retry-After': String(rl.retryAfter), 'Content-Type': 'text/plain' });
    return send(res, 401, 'Login required', { 'WWW-Authenticate': 'Basic realm="xPerion demos", charset="UTF-8"', 'Content-Type': 'text/plain' });
  }
  if (pathname === '/') return send(res, 302, '', { Location: cfg.rootRedirect });
  const app = findApp(pathname);
  if (!app) {
    // Old links: other capitalisation (/CareAI/ -> /careai/) or a previous name (alias)
    const lower = pathname.toLowerCase();
    for (const a of cfg.apps) {
      for (const b of [a.basePath.toLowerCase(), ...a.aliases.map(x => '/' + x.toLowerCase())]) {
        if (lower === b || lower.startsWith(b + '/')) return send(res, 301, '', { Location: a.basePath + pathname.slice(b.length) + url.search });
      }
    }
    return notFound(res);
  }
  if (pathname === app.basePath) return send(res, 301, '', { Location: app.basePath + '/' + url.search });
  if (app.proxyVar && pathname === app.basePath + '/api/v1/messages') return handleApi(req, res, ip, app);
  let rel;
  try { rel = decodeURIComponent(pathname.slice(app.basePath.length + 1)); } catch { return send(res, 400, 'Bad request'); }
  return handleStatic(req, res, app, rel);
}

function start() {
  const server = http.createServer((req, res) => {
    route(req, res).catch(e => { log('error', (e && e.stack) || e); if (!res.headersSent) send(res, 500, 'Internal error'); else res.destroy(); });
  });
  server.keepAliveTimeout = 130000;   // longer than Caddy's idle keep-alive, avoids reset races
  server.headersTimeout = 131000;
  server.on('error', e => { log('fatal', e.code || '', e.message); process.exit(1); });
  server.listen(cfg.port, cfg.host, () => {
    log('start', `v${VERSION}`, `http://${cfg.host}:${cfg.port}/`, `key=${getKey() ? 'ok' : 'MISSING'}`,
      `upstream=${new URL(cfg.upstream).host}`, `model=${cfg.model || 'from app'}`, `auth=${cfg.auth ? 'on' : 'off'}`,
      `apps=${cfg.apps.map(a => a.basePath + (a.proxyVar ? '(ai)' : '')).join(',')}`);
  });
  startSync();
}

// ---------------------------------------------------------------- GitHub mirror
// Each app mirrors a branch of its repo. Change checks use git's own protocol
// (the same request "git fetch" makes), which isn't subject to the REST API's
// 60-requests-per-hour limit. The REST API is used once per new commit, to list
// files; files are downloaded from GitHub's raw file server by commit, and only
// when their content changed.
const syncState = {};      // name -> { commit, files: {path: blobSha}, rejected, error, at }
let apiPausedUntil = 0;

const stateFile = app => path.join(app.appDir, '.deploy-state.json');
function loadSyncState(app) {
  try { syncState[app.name] = Object.assign({ files: {} }, readJson(stateFile(app)), { error: null }); }
  catch { syncState[app.name] = { commit: null, files: {}, rejected: null, error: null, at: null }; }
}
function saveSyncState(app) {
  const s = syncState[app.name];
  try { fs.writeFileSync(stateFile(app), JSON.stringify({ commit: s.commit, files: s.files, rejected: s.rejected, at: s.at })); }
  catch (e) { log('deploy', app.name, 'could not save state:', e.message); }
}

function ghToken() {
  if (!cfg.github.tokenFile) return '';
  try { return fs.readFileSync(cfg.github.tokenFile, 'utf8').replace(/^\uFEFF/, '').trim(); } catch { return ''; }
}
const escRe = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const encPath = p => p.split('/').map(encodeURIComponent).join('/');

async function remoteHead(app) {
  const h = { 'User-Agent': 'git/2.45.0 (xperion-app-server)' };
  const tok = ghToken();
  if (tok) h.Authorization = 'Basic ' + Buffer.from('x-access-token:' + tok).toString('base64');
  const r = await fetch(`${cfg.github.webBase.replace(/\/+$/, '')}/${app.repo}.git/info/refs?service=git-upload-pack`,
    { headers: h, signal: AbortSignal.timeout(20000) });
  if (r.status === 401 || r.status === 404) throw new Error(`can't read ${app.repo}: private or doesn't exist (re-run setup to add a GitHub token)`);
  if (!r.ok) throw new Error(`GitHub returned ${r.status} for ${app.repo}`);
  const m = (await r.text()).match(new RegExp(`([0-9a-f]{40}) refs/heads/${escRe(app.branch)}[\\0\\n]`));
  if (!m) throw new Error(`branch '${app.branch}' not found in ${app.repo}`);
  return m[1];
}

async function apiGet(url) {
  if (Date.now() < apiPausedUntil) throw new Error(`waiting for GitHub's API limit to reset (${new Date(apiPausedUntil).toISOString()})`);
  const h = { Accept: 'application/vnd.github+json', 'User-Agent': 'xperion-app-server', 'X-GitHub-Api-Version': '2022-11-28' };
  const tok = ghToken();
  if (tok) h.Authorization = 'Bearer ' + tok;
  const r = await fetch(url, { headers: h, signal: AbortSignal.timeout(30000) });
  if ((r.status === 403 || r.status === 429) && r.headers.get('x-ratelimit-remaining') === '0') {
    const reset = Number(r.headers.get('x-ratelimit-reset')) * 1000;
    apiPausedUntil = reset > Date.now() ? reset : Date.now() + 15 * 60000;
    throw new Error(`GitHub API limit reached; retrying after ${new Date(apiPausedUntil).toISOString()}`);
  }
  return r;
}

async function rawGet(app, commit, p) {
  const h = { 'User-Agent': 'xperion-app-server' };
  const tok = ghToken();
  if (tok) h.Authorization = 'token ' + tok;
  return fetch(`${cfg.github.rawBase.replace(/\/+$/, '')}/${app.repo}/${commit}/${encPath(p)}`,
    { headers: h, signal: AbortSignal.timeout(180000) });
}

function excluded(p, patterns) {
  if (p.split('/').some(s => s.startsWith('.'))) return true;
  return patterns.some(x => (x.endsWith('/') ? p.startsWith(x) : p === x));
}
function safeRelPath(p) {
  const segs = p.split('/');
  return !segs.some(s => !s || s === '..' || s.startsWith('.') || /[\\\0:*?"<>|]/.test(s));
}
const gitBlobSha = buf => crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex');

function validateApp(app, files) {
  const idx = files.get('index.html');
  if (!idx) return 'no index.html in the repo';
  const html = idx.toString('utf8');
  if (!/<\/html>\s*$/i.test(html)) return 'index.html is not a complete HTML file';
  if (app.proxyVar && !html.includes(app.proxyVar)) return `index.html lacks server-proxy support (${app.proxyVar})`;
  for (const [p, buf] of files) {
    if (TEXT_EXT.has(path.extname(p).toLowerCase()) && KEY_SCAN_RE.test(buf.toString('utf8'))) return `${p} contains an API key`;
  }
  return null;
}

async function atomicWrite(file, buf) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const tmp = path.join(path.dirname(file), '.' + path.basename(file) + '.tmp');
  await fsp.writeFile(tmp, buf);
  for (let i = 0; ; i++) {
    try { await fsp.rename(tmp, file); return; }
    catch (e) {
      if (i >= 10 || !['EPERM', 'EBUSY', 'EACCES'].includes(e.code)) { await fsp.rm(tmp, { force: true }); throw e; }
      await new Promise(r => setTimeout(r, 200));   // Windows: file briefly open by a reader
    }
  }
}

async function syncApp(app) {
  const st = syncState[app.name];
  const head = await remoteHead(app);
  if (head === st.commit) { if (st.rejected) { st.rejected = null; st.error = null; saveSyncState(app); } return; }
  if (head === st.rejected) return;

  const r = await apiGet(`${cfg.github.apiBase.replace(/\/+$/, '')}/repos/${app.repo}/git/trees/${head}?recursive=1`);
  if (!r.ok) throw new Error(`GitHub returned ${r.status} listing files of ${app.repo}`);
  const tree = await r.json();
  if (tree.truncated) throw new Error(`${app.repo} has too many files to mirror`);

  const wanted = (tree.tree || []).filter(e => e.type === 'blob' && e.mode !== '120000' && !excluded(e.path, app.exclude));
  for (const e of wanted) if (!safeRelPath(e.path)) throw new Error(`unsafe path in repo: ${e.path}`);
  const tooBig = wanted.filter(e => e.size > 100 * 1024 * 1024);
  if (tooBig.length) throw new Error(`files over 100 MB can't be mirrored: ${tooBig.map(e => e.path).join(', ')}`);

  // Download only what changed, verifying each file against its git hash.
  const files = new Map(), changedPaths = new Set();
  for (const e of wanted) {
    const local = path.join(app.appDir, ...e.path.split('/'));
    if (st.files[e.path] === e.sha && fs.existsSync(local)) {
      if (TEXT_EXT.has(path.extname(e.path).toLowerCase())) files.set(e.path, await fsp.readFile(local));   // for validation
      continue;
    }
    if (fs.existsSync(local)) {   // already on disk with the same content (e.g. after an upgrade): no download
      const cur = await fsp.readFile(local);
      if (gitBlobSha(cur) === e.sha) { files.set(e.path, cur); continue; }
    }
    const b = await rawGet(app, head, e.path);
    if (!b.ok) throw new Error(`GitHub returned ${b.status} for ${e.path}`);
    const buf = Buffer.from(await b.arrayBuffer());
    if (gitBlobSha(buf) !== e.sha) throw new Error(`download of ${e.path} was corrupted`);
    files.set(e.path, buf);
    changedPaths.add(e.path);
  }
  const bad = validateApp(app, files);
  if (bad) {
    Object.assign(st, { rejected: head, error: `refused ${head.slice(0, 7)}: ${bad}` });
    saveSyncState(app);
    log('deploy', app.name, 'skipped', head.slice(0, 7), '-', bad);
    return;
  }

  // Write changed files, index.html last so the page never references files that aren't there yet.
  const changed = [...files.entries()].filter(([p]) => changedPaths.has(p)).sort(([a], [b]) => (a === 'index.html') - (b === 'index.html'));
  for (const [p, buf] of changed) await atomicWrite(path.join(app.appDir, ...p.split('/')), buf);
  const keep = new Set(wanted.map(e => e.path));
  const removed = Object.keys(st.files).filter(p => !keep.has(p));
  for (const p of removed) await fsp.rm(path.join(app.appDir, ...p.split('/')), { force: true });

  st.files = Object.fromEntries(wanted.map(e => [e.path, e.sha]));
  Object.assign(st, { commit: head, rejected: null, error: null, at: new Date().toISOString() });
  saveSyncState(app);
  log('deploy', app.name, changed.length || removed.length
    ? `updated to ${head.slice(0, 7)} (${changed.length} file(s) written${removed.length ? `, ${removed.length} removed` : ''})`
    : `in sync at ${head.slice(0, 7)}`);
}

function startSync() {
  const apps = cfg.apps.filter(a => a.repo);
  for (const a of cfg.apps) loadSyncState(a);
  if (!apps.length) return;
  const lastErr = {};
  const every = Math.max(5, Number(cfg.github.intervalSeconds) || 120) * 1000;
  const run = async () => {
    for (const app of apps) {
      try { await syncApp(app); lastErr[app.name] = ''; if (!syncState[app.name].rejected) syncState[app.name].error = null; }
      catch (e) {
        const m = (e && e.message) || String(e);
        syncState[app.name].error = m;
        if (m !== lastErr[app.name]) log('deploy', app.name, 'check failed:', m);
        lastErr[app.name] = m;
      }
    }
    setTimeout(run, every);
  };
  setTimeout(run, 2000);
}

// ---------------------------------------------------------------- CLI
function selfCheck() {
  const problems = [];
  if (cfg.apps.some(a => a.proxyVar) && !getKey()) problems.push(`no valid API key in ${cfg.keyFile}`);
  if (cfg.auth && !(cfg.auth.user && cfg.auth.salt && cfg.auth.hash)) problems.push('auth settings incomplete');
  for (const a of cfg.apps) {
    if (!a.repo && !fs.existsSync(path.join(a.appDir, 'index.html'))) problems.push(`${a.name}: no repo and no index.html in ${a.appDir}`);
  }
  if (problems.length) { problems.forEach(p => console.error('FAIL ' + p)); process.exit(1); }
  console.log(`OK config and key look good (${cfg.apps.length} app(s): ${cfg.apps.map(a => a.basePath + '/').join(' ')})`);
}

function hashPassword() {
  let input = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', d => { input += d; });
  process.stdin.on('end', () => {
    const pass = input.replace(/^\uFEFF/, '').replace(/\r?\n$/, '');
    if (pass.length < 8) { console.error('Password must be at least 8 characters.'); process.exit(1); }
    const salt = crypto.randomBytes(16);
    console.log(JSON.stringify({ salt: salt.toString('hex'), hash: crypto.scryptSync(pass, salt, 32).toString('hex') }));
  });
}

process.on('uncaughtException', e => { log('fatal', 'uncaught', (e && e.stack) || e); process.exit(1); });
process.on('unhandledRejection', e => { log('error', 'unhandledRejection', (e && e.stack) || e); });

const arg = process.argv[2];
if (arg === '--hash-password') hashPassword();
else {
  try { cfg = loadConfig(); } catch (e) { console.error('Config error: ' + e.message); process.exit(1); }
  if (arg === '--check') selfCheck(); else start();
}
