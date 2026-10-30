'use strict';
// Rocket Ramen web tier: serves the built PatternFly SPA and proxies /api to the
// Go API. The same file runs on the web VM and in the container; /api/webinfo is
// what lets the Mission Control board show which of the two is answering.
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PORT = Number(process.env.PORT || 8080);
const WEB_ROOT = process.env.WEB_ROOT || path.join(__dirname, 'dist');
const API_URL = new URL(process.env.API_URL || 'http://orders-app:8080');
const WEB_RUNTIME = process.env.WEB_RUNTIME || 'VM';

function placement() {
  if (WEB_RUNTIME === 'container') {
    return { runtime: WEB_RUNTIME, name: process.env.POD_NAME || '', namespace: process.env.POD_NAMESPACE || '',
      node: process.env.NODE_NAME || '', serial: '', reported_by: 'Downward API' };
  }
  let info = {};
  try { info = JSON.parse(fs.readFileSync('/etc/rocket-ramen/placement.json', 'utf8')); } catch (_) { /* optional outside a VM */ }
  let serial = info.serial || '';
  let reportedBy = (info.name || info.namespace || info.serial) ? 'Provisioning metadata' : 'Unavailable';
  try {
    const guestSerial = fs.readFileSync('/sys/class/dmi/id/product_serial', 'utf8').trim();
    if (guestSerial) { serial = guestSerial; reportedBy = 'KubeVirt SMBIOS + provisioning metadata'; }
  } catch (_) { /* serial may be unavailable to the process */ }
  return { runtime: 'VM', name: info.name || os.hostname(), namespace: info.namespace || '', node: '', serial, reported_by: reportedBy };
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
};

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
  });
  res.end(payload);
}

function serveStatic(req, res) {
  const requested = decodeURIComponent((req.url || '/').split('?')[0]);
  const candidate = path.normalize(path.join(WEB_ROOT, requested));
  const insideRoot = candidate === WEB_ROOT || candidate.startsWith(WEB_ROOT + path.sep);

  let file = insideRoot ? candidate : WEB_ROOT;
  if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    // SPA fallback: any unknown path renders the app shell.
    file = path.join(WEB_ROOT, 'index.html');
  }
  if (!fs.existsSync(file)) {
    res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('web bundle missing: expected ' + WEB_ROOT);
    return;
  }

  const body = fs.readFileSync(file);
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
    'Content-Length': body.length,
    // Deterministic asset names, so never let a browser cache a stale tier.
    'Cache-Control': 'no-cache',
  });
  res.end(req.method === 'HEAD' ? undefined : body);
}

function proxy(req, res) {
  const upstream = http.request(
    {
      protocol: API_URL.protocol,
      hostname: API_URL.hostname,
      port: API_URL.port || 80,
      method: req.method,
      path: req.url,
      headers: Object.assign({}, req.headers, { host: API_URL.host }),
    },
    (reply) => {
      // Stream straight through: /api/stream is SSE and must not be buffered.
      res.writeHead(reply.statusCode || 502, reply.headers);
      reply.pipe(res);
    },
  );
  upstream.on('error', () => {
    if (!res.headersSent) {
      sendJson(res, 502, { error: 'api_unavailable', message: 'the galley API is not answering' });
    } else {
      res.end();
    }
  });
  req.pipe(upstream);
}

const server = http.createServer((req, res) => {
  if (req.url === '/api/webinfo') {
    sendJson(res, 200, { ...placement(), node_version: process.version, host: os.hostname() });
    return;
  }
  if ((req.url || '').startsWith('/api/')) {
    proxy(req, res);
    return;
  }
  serveStatic(req, res);
});

// Long-lived SSE must survive Node's default request timeout.
server.requestTimeout = 0;
server.timeout = 0;
server.headersTimeout = 20000;

server.listen(PORT, '0.0.0.0', () => {
  console.log('Rocket Ramen web tier on :' + PORT + ' (runtime=' + WEB_RUNTIME + ', api=' + API_URL.origin + ')');
});
