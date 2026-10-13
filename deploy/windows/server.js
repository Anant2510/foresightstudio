#!/usr/bin/env node
'use strict';
/*
 * Foresight Studio — app server for the xPerion Azure VM
 * Zero dependencies (Node 20.3+). Runs behind Caddy, which handles HTTPS.
 *
 *  - Serves the app at <basePath>/ (index.html from appDir)
 *  - Relays AI calls to Anthropic and adds the API key on the server,
 *    so the key never reaches the browser
 *  - Per-IP rate limit, optional login, auto-deploys index.html from GitHub
 *
 * Usage:  node server.js                 start the server
 *         node server.js --check         validate config, key and app, then exit
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

const VERSION = '1.0.0';
const KEY_RE = /^sk-ant-[A-Za-z0-9_-]{20,}$/;
const KEY_SCAN_RE = /sk-ant-[A-Za-z0-9_-]{20,}/;
const CONFIG_JS = '// Served by the Foresight Studio server. No API key here: the server adds it.\n' +
                  'window.FORESIGHT_PROXY = "api/v1/messages";\n';
const SEC_HEADERS = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'strict-origin-when-cross-origin' };
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon', '.pdf': 'application/pdf',
  '.csv': 'text/csv; charset=utf-8', '.txt': 'text/plain; charset=utf-8', '.woff2': 'font/woff2'
};

let cfg = null;

// ---------------------------------------------------------------- config & log
function readJson(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); }

function loadConfig() {
  const file = process.env.FS_CONFIG || path.join(__dirname, 'config.json');
  const c = readJson(file);
  const out = Object.assign({
    host: '127.0.0.1', port: 8790, basePath: '/foresightstudio', logFile: null,
    upstream: 'https://api.anthropic.com', upstreamTimeoutMs: 120000,
    maxBodyBytes: 5 * 1024 * 1024, trustProxy: true, auth: null
  }, c);
  out.rateLimit = Object.assign({ perMinute: 60, burst: 30 }, c.rateLimit || {});
  out.autoUpdate = Object.assign({
    enabled: false, repo: '', branch: 'main', path: 'index.html',
    intervalSeconds: 120, tokenFile: null, apiBase: 'https://api.github.com'
  }, c.autoUpdate || {});
  if (!/^\/[A-Za-z0-9._-]+(\/[A-Za-z0-9._-]+)*$/.test(out.basePath)) throw new Error('basePath must look like /foresightstudio');
  for (const k of ['appDir', 'keyFile']) if (!out[k]) throw new Error(`config.${k} is required`);
  if (out.autoUpdate.enabled && !/^[\w.-]+\/[\w.-]+$/.test(out.autoUpdate.repo)) throw new Error('autoUpdate.repo must look like owner/name');
  out.appDir = path.resolve(out.appDir);
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
async function handleApi(req, res, ip) {
  if (req.method !== 'POST') return apiError(res, 405, 'invalid_request_error', 'Use POST.', { Allow: 'POST' });
  const rl = allow(ip);
  if (!rl.ok) { log('api', ip, 429, 'rate-limited'); return apiError(res, 429, 'rate_limit_error', 'Too many requests from this network. Wait a minute and try again.', { 'Retry-After': String(rl.retryAfter) }); }
  const key = getKey();
  if (!key) { log('api', ip, 500, 'no valid key in', cfg.keyFile); return apiError(res, 500, 'api_error', 'The server has no valid API key configured.'); }

  let body, parsed;
  try { body = await readBody(req, cfg.maxBodyBytes); }
  catch (e) { return e.code === 413 ? apiError(res, 413, 'request_too_large', 'Request is too large.', { Connection: 'close' }) : apiError(res, 400, 'invalid_request_error', 'Could not read the request.'); }
  try { parsed = JSON.parse(body.toString('utf8')); } catch { return apiError(res, 400, 'invalid_request_error', 'Body must be JSON.'); }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return apiError(res, 400, 'invalid_request_error', 'Body must be a JSON object.');

  // A fresh header set: Anthropic never sees the visitor's cookies, login or origin.
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
    if (clientGone.signal.aborted) { log('api', ip, 'client-closed', `${Date.now() - t0}ms`); return; }
    const timedOut = e && e.name === 'TimeoutError';
    log('api', ip, timedOut ? 504 : 502, `${Date.now() - t0}ms`, `model=${parsed.model}`, (e && e.cause && e.cause.code) || (e && e.message));
    return timedOut
      ? apiError(res, 504, 'api_error', 'The AI Engine took too long to respond. Try again.')
      : apiError(res, 502, 'api_error', 'The server could not reach the AI Engine. Try again shortly.');
  }
  const out = { 'Content-Type': up.headers.get('content-type') || 'application/json', 'Cache-Control': 'no-store' };
  for (const h of ['request-id', 'retry-after']) { const v = up.headers.get(h); if (v) out[h] = v; }
  res.writeHead(up.status, Object.assign({}, SEC_HEADERS, out));
  try { if (up.body) await pipeline(Readable.fromWeb(up.body), res); else res.end(); }
  catch { if (!res.writableEnded) res.destroy(); }
  log('api', ip, up.status, `${Date.now() - t0}ms`, `model=${parsed.model}`, `max_tokens=${parsed.max_tokens}`);
}

// ---------------------------------------------------------------- static app
async function handleStatic(req, res, rel) {
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed', { Allow: 'GET, HEAD', 'Content-Type': 'text/plain' });
  if (rel === '' || rel.endsWith('/')) rel += 'index.html';
  if (rel === 'config.js') return send(res, 200, CONFIG_JS, { 'Content-Type': MIME['.js'], 'Cache-Control': 'no-cache' });
  const segs = rel.split('/');
  // No dotfiles, empty segments, backslashes, NULs, drive letters or Windows streams.
  if (segs.some(s => !s || s.startsWith('.') || /[\\\0:*?"<>|]/.test(s))) return notFound(res);
  const file = path.join(cfg.appDir, ...segs);
  if (!file.startsWith(cfg.appDir + path.sep)) return notFound(res);
  let st;
  try { st = await fsp.stat(file); } catch { return notFound(res); }
  if (st.isDirectory()) return send(res, 301, '', { Location: cfg.basePath + '/' + rel + '/' });
  const etag = `W/"${st.size}-${Math.trunc(st.mtimeMs)}"`;
  const common = { ETag: etag, 'Cache-Control': 'no-cache', 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' };
  if (req.headers['if-none-match'] === etag) { res.writeHead(304, Object.assign({}, SEC_HEADERS, common)); return res.end(); }
  let data;
  try { data = await fsp.readFile(file); } catch { return notFound(res); }
  send(res, 200, data, common);
}

// ---------------------------------------------------------------- router & server
async function route(req, res) {
  let pathname;
  try { pathname = new URL(req.url, 'http://localhost').pathname; } catch { return send(res, 400, 'Bad request'); }
  const ip = clientIp(req);
  if (pathname === '/healthz') {
    return send(res, 200, JSON.stringify({ ok: true, version: VERSION, keyConfigured: !!getKey(), app: deployState.sha }),
      { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  }
  if (!checkAuth(req)) {
    const rl = allow(ip);   // failed logins count against the same per-IP limit
    if (!rl.ok) return send(res, 429, 'Too many attempts', { 'Retry-After': String(rl.retryAfter), 'Content-Type': 'text/plain' });
    return send(res, 401, 'Login required', { 'WWW-Authenticate': 'Basic realm="Foresight Studio", charset="UTF-8"', 'Content-Type': 'text/plain' });
  }
  const base = cfg.basePath;
  if (pathname === '/') return send(res, 302, '', { Location: base + '/' });
  if (pathname === base) return send(res, 301, '', { Location: base + '/' });
  if (pathname === base + '/api/v1/messages') return handleApi(req, res, ip);
  if (pathname.startsWith(base + '/')) {
    let rel;
    try { rel = decodeURIComponent(pathname.slice(base.length + 1)); } catch { return send(res, 400, 'Bad request'); }
    return handleStatic(req, res, rel);
  }
  return notFound(res);
}

function start() {
  const server = http.createServer((req, res) => {
    route(req, res).catch(e => { log('error', (e && e.stack) || e); if (!res.headersSent) send(res, 500, 'Internal error'); else res.destroy(); });
  });
  server.keepAliveTimeout = 130000;   // longer than Caddy's idle keep-alive, avoids reset races
  server.headersTimeout = 131000;
  server.on('error', e => { log('fatal', e.code || '', e.message); process.exit(1); });
  server.listen(cfg.port, cfg.host, () => {
    log('start', `v${VERSION}`, `http://${cfg.host}:${cfg.port}${cfg.basePath}/`, `key=${getKey() ? 'ok' : 'MISSING'}`,
      `auth=${cfg.auth ? 'on' : 'off'}`, `autoUpdate=${cfg.autoUpdate.enabled ? cfg.autoUpdate.repo + '@' + cfg.autoUpdate.branch : 'off'}`);
  });
  if (cfg.autoUpdate.enabled) startUpdater();
}

// ---------------------------------------------------------------- auto-deploy from GitHub
const deployState = { sha: null, rejected: null, at: null };
const stateFile = () => path.join(cfg.appDir, '.deploy-state.json');
function saveState() { try { fs.writeFileSync(stateFile(), JSON.stringify(deployState)); } catch (e) { log('deploy', 'could not save state:', e.message); } }

function validateApp(text) {
  if (text.length < 1000) return 'file too small';
  if (!/<\/html>\s*$/i.test(text)) return 'not a complete HTML file';
  if (!text.includes('FORESIGHT_PROXY')) return 'missing server-proxy support (FORESIGHT_PROXY)';
  if (KEY_SCAN_RE.test(text)) return 'contains an API key';
  return null;
}

function ghHeaders(accept) {
  const h = { Accept: accept, 'User-Agent': 'foresight-studio-updater', 'X-GitHub-Api-Version': '2022-11-28' };
  if (cfg.autoUpdate.tokenFile) {
    try { const t = fs.readFileSync(cfg.autoUpdate.tokenFile, 'utf8').replace(/^\uFEFF/, '').trim(); if (t) h.Authorization = 'Bearer ' + t; } catch { /* no token */ }
  }
  return h;
}

async function atomicWrite(file, text) {
  const tmp = path.join(path.dirname(file), '.' + path.basename(file) + '.tmp');
  await fsp.writeFile(tmp, text, 'utf8');
  for (let i = 0; ; i++) {
    try { await fsp.rename(tmp, file); return; }
    catch (e) {
      if (i >= 10 || !['EPERM', 'EBUSY', 'EACCES'].includes(e.code)) { await fsp.rm(tmp, { force: true }); throw e; }
      await new Promise(r => setTimeout(r, 200));   // Windows: file briefly open by a reader
    }
  }
}

async function checkForUpdate() {
  const u = cfg.autoUpdate, api = u.apiBase.replace(/\/+$/, '');
  const r = await fetch(`${api}/repos/${u.repo}/commits/${encodeURIComponent(u.branch)}`,
    { headers: ghHeaders('application/vnd.github+json'), signal: AbortSignal.timeout(20000) });
  if (!r.ok) {
    const hint = r.status === 404 ? ' (private repo? add a token)' : (r.status === 403 || r.status === 429) ? ' (GitHub rate limit)' : '';
    throw new Error(`GitHub returned ${r.status}${hint}`);
  }
  const sha = (await r.json()).sha;
  if (!sha || sha === deployState.sha || sha === deployState.rejected) return;
  const filePath = u.path.split('/').map(encodeURIComponent).join('/');
  const f = await fetch(`${api}/repos/${u.repo}/contents/${filePath}?ref=${sha}`,
    { headers: ghHeaders('application/vnd.github.raw'), signal: AbortSignal.timeout(30000) });
  if (!f.ok) throw new Error(`GitHub returned ${f.status} for ${u.path}`);
  const text = await f.text();
  const bad = validateApp(text);
  if (bad) { deployState.rejected = sha; saveState(); log('deploy', 'skipped', sha.slice(0, 7), '-', bad); return; }
  const target = path.join(cfg.appDir, 'index.html');
  let current = '';
  try { current = await fsp.readFile(target, 'utf8'); } catch { /* first deploy */ }
  if (current !== text) { await atomicWrite(target, text); log('deploy', 'updated index.html to', sha.slice(0, 7)); }
  else log('deploy', 'in sync at', sha.slice(0, 7));
  Object.assign(deployState, { sha, rejected: null, at: new Date().toISOString() });
  saveState();
}

function startUpdater() {
  try { Object.assign(deployState, readJson(stateFile())); } catch { /* first run */ }
  let lastErr = '';
  const every = Math.max(5, Number(cfg.autoUpdate.intervalSeconds) || 120) * 1000;
  const run = async () => {
    try { await checkForUpdate(); lastErr = ''; }
    catch (e) { const m = (e && e.message) || String(e); if (m !== lastErr) log('deploy', 'check failed:', m); lastErr = m; }
    finally { setTimeout(run, every); }
  };
  setTimeout(run, 3000);
}

// ---------------------------------------------------------------- CLI
function selfCheck() {
  const problems = [];
  const idx = path.join(cfg.appDir, 'index.html');
  if (!fs.existsSync(idx)) problems.push(`index.html not found in ${cfg.appDir}`);
  else { const bad = validateApp(fs.readFileSync(idx, 'utf8')); if (bad) problems.push(`index.html: ${bad}`); }
  if (!getKey()) problems.push(`no valid API key in ${cfg.keyFile}`);
  if (cfg.auth && !(cfg.auth.user && cfg.auth.salt && cfg.auth.hash)) problems.push('auth settings incomplete');
  if (problems.length) { problems.forEach(p => console.error('FAIL ' + p)); process.exit(1); }
  console.log(`OK config, key and app look good (port ${cfg.port}, path ${cfg.basePath}/)`);
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
