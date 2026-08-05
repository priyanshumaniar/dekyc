# DeKYC pinning proxy

A tiny, dependency-free Node service that holds the Pinata JWT **server-side**
so it never ships to the browser.

## Why

Flutter bundles `.env` as an app asset. On a `flutter build web` deployment,
every value in it — including `PINATA_JWT` — is downloadable by any visitor. A
client cannot keep an API secret; the only real fix is to not give it one.

With this proxy running, the app posts ciphertext to `/pin` and gets a CID back.
The credential stays on the server.

## Run it

```bash
PINATA_JWT=your_jwt_here node proxy/server.js
```

Then point the app at it by adding this to the repo-root `.env`:

```
PINATA_PROXY_URL=http://localhost:8787/pin
```

When `PINATA_PROXY_URL` is set the app uses the proxy and ignores `PINATA_JWT`
entirely. When it is unset the app falls back to pinning directly with the JWT —
fine for local development, not for a public web deployment.

## Configuration

| Variable | Purpose | Default |
|---|---|---|
| `PINATA_JWT` | Pinata API token. **Required.** | — |
| `PORT` | Listen port | `8787` |
| `MAX_UPLOAD_BYTES` | Reject bodies larger than this | `10485760` (10 MB) |
| `MAX_PINS_PER_MINUTE` | Per-IP fixed-window cap | `20` |
| `ALLOWED_ORIGIN` | CORS origin | `*` |

## Endpoints

- `POST /pin` — raw request body is the (already encrypted) blob. Returns
  `{"IpfsHash": "..."}`.
- `GET /health` — returns `{"ok": true, "jwtConfigured": bool}`.

## Before you expose this publicly

This is a **reference implementation**, and it is deliberately minimal. It has
**no authentication** — anyone who can reach it can pin through your Pinata
account. The size cap and rate limit bound the damage; they do not prevent it.

Add real auth before deploying. The natural fit for this app: require a
wallet-signed nonce, recover the address, and only pin for addresses you accept.
Pinata's own scoped, short-lived upload keys are the other half of a production
answer — mint one per request and hand that to the client instead of proxying
the bytes.
