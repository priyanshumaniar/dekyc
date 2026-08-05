#!/usr/bin/env node
'use strict';

/**
 * DeKYC pinning proxy — reference implementation.
 *
 * WHY THIS EXISTS
 * ---------------
 * Flutter bundles `.env` as an app asset, so on a `flutter build web`
 * deployment every value in it is downloadable by any visitor. A Pinata JWT
 * shipped to the browser is a public credential: anyone can pin arbitrary data
 * to the account until it is rotated. No amount of client-side care fixes that
 * — a client fundamentally cannot hold an API secret.
 *
 * This proxy holds the JWT server-side. The app posts ciphertext here and gets
 * a CID back; the credential never reaches the browser.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 * --------------------------------
 * This is a reference, not a hardened service. It has no authentication, so
 * anyone who can reach it can pin through it — bound it with a size cap and a
 * simple per-IP rate limit, and put real auth (a signed nonce from the user's
 * wallet is the natural fit here) in front of it before exposing it publicly.
 *
 * Zero dependencies — Node 20+ only.
 *
 *   PINATA_JWT=... node proxy/server.js
 *   curl -X POST --data-binary @blob.enc http://localhost:8787/pin
 */

const http = require('node:http');

const PORT = Number(process.env.PORT || 8787);
const JWT = process.env.PINATA_JWT || '';
const MAX_BYTES = Number(process.env.MAX_UPLOAD_BYTES || 10 * 1024 * 1024);
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';

// Naive fixed-window rate limit: enough to stop a trivial pin-flood, not a
// substitute for auth.
const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = Number(process.env.MAX_PINS_PER_MINUTE || 20);
const hits = new Map();

function rateLimited(ip) {
  const now = Date.now();
  const entry = hits.get(ip);
  if (!entry || now - entry.start > WINDOW_MS) {
    hits.set(ip, { start: now, count: 1 });
    return false;
  }
  entry.count += 1;
  return entry.count > MAX_PER_WINDOW;
}

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

function json(res, status, body) {
  cors(res);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

/** Collect the request body, aborting past MAX_BYTES rather than buffering it. */
function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error(`Payload exceeds ${limit} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    cors(res);
    res.writeHead(204);
    return res.end();
  }

  if (req.method === 'GET' && req.url === '/health') {
    return json(res, 200, { ok: true, jwtConfigured: JWT.length > 0 });
  }

  if (req.method !== 'POST' || req.url !== '/pin') {
    return json(res, 404, { error: 'Not found. POST ciphertext to /pin.' });
  }

  if (!JWT) {
    return json(res, 500, {
      error: 'PINATA_JWT is not set on the proxy. See proxy/README.md.',
    });
  }

  const ip = req.socket.remoteAddress || 'unknown';
  if (rateLimited(ip)) {
    return json(res, 429, { error: 'Rate limit exceeded. Try again shortly.' });
  }

  let body;
  try {
    body = await readBody(req, MAX_BYTES);
  } catch (e) {
    return json(res, 413, { error: String(e.message) });
  }
  if (body.length === 0) {
    return json(res, 400, { error: 'Empty body.' });
  }

  try {
    const form = new FormData();
    form.append('file', new Blob([body]), 'dekyc_bundle.enc');
    form.append('pinataOptions', JSON.stringify({ cidVersion: 1 }));

    const upstream = await fetch(
      'https://api.pinata.cloud/pinning/pinFileToIPFS',
      {
        method: 'POST',
        headers: { Authorization: `Bearer ${JWT}` },
        body: form,
      }
    );

    const text = await upstream.text();
    if (!upstream.ok) {
      // Pass through the status but NOT the upstream body verbatim — it can
      // echo details about the credential we are shielding.
      console.error(`[proxy] Pinata ${upstream.status}: ${text}`);
      return json(res, 502, { error: `Pinning failed (${upstream.status}).` });
    }

    const { IpfsHash } = JSON.parse(text);
    if (!IpfsHash) return json(res, 502, { error: 'No CID in response.' });

    console.log(`[proxy] pinned ${body.length} B -> ${IpfsHash}`);
    return json(res, 200, { IpfsHash });
  } catch (e) {
    console.error('[proxy] error:', e);
    return json(res, 500, { error: 'Proxy error.' });
  }
});

server.listen(PORT, () => {
  console.log(`DeKYC pinning proxy on http://localhost:${PORT}`);
  console.log(`  POST /pin      (max ${MAX_BYTES} bytes)`);
  console.log(`  GET  /health`);
  if (!JWT) console.warn('  ⚠️  PINATA_JWT is not set — /pin will fail.');
});
