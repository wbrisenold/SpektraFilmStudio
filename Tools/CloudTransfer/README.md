# SpektraFilm: Cloudflare Workers → R2 transfer bridge (prototype)

This is an **API-based server-side transfer component**, not a standalone Lightroom OAuth client. RAW bytes stream from an authorized Adobe-hosted binary URL to R2; they do not pass through the photographer's Mac. No transfer is initiated until it is deployed and supplied with an authorized source URL.

**Critical:** Adobe Lightroom Partner API access requires an entitled integration and customer OAuth consent with `lr_partner_apis`. A generic Adobe native-app client ID does *not* necessarily have this entitlement. The Lightroom response may expose only renditions, and a `master_create` link means *upload*, NOT download. This worker intentionally does not invent an originals-download endpoint. It accepts a user-authorized, Adobe-hosted direct original URL, if one is available. It rejects redirects to unreviewed CDN hosts.

## Free tier (October 2026)

- Cloudflare Workers Free: 100,000 requests/day, 10 milliseconds CPU per invocation (streaming minimizes CPU use).
- Cloudflare R2 Standard: 10 GB-month of storage, 1 million Class A operations, 10 million Class B operations, free egress.
- This prototype conservatively caps a RAW to 100 MiB; it does **not** support multipart large-RAW transfers. Large photography catalogs will exceed the free 10 GB allowance. R2 is NOT iCloud Drive.

Prices/limits: https://developers.cloudflare.com/workers/platform/pricing/ and https://developers.cloudflare.com/r2/pricing/

## Deploy (requires your own Cloudflare account)

```sh
npx wrangler login
npx wrangler r2 bucket create spektrafilm-originals
npx wrangler secret put TRANSFER_TOKEN
npx wrangler secret put ADOBE_CLIENT_ID
npx wrangler deploy
```

Use a unique random `TRANSFER_TOKEN` at least 24 characters, generated on your machine, not included in a GitHub commit. Protect it as a password. Do not paste an Adobe access/refresh token into an issue or repository. Configure a budget alert / spend cap where supported.

## API

`GET /health` is public. All other endpoints require `Authorization: Bearer <TRANSFER_TOKEN>`.

`POST /v1/transfer` body:

```json
{"assetId":"0123456789abcdef0123456789abcdef", "originalUrl":"https://lr.adobe.io/v2/authorized-original-download-endpoint"}
```

Provide `X-Adobe-Access-Token: <OAUTH_ACCESS_TOKEN>` for an **entitled** Adobe integration. The URL above is an illustrative placeholder, **not** a confirmed original download endpoint; do not use it as-is. The worker does not save the token and never logs credentials. Only Adobe-hosted HTTPS URLs are allowed, and upstream redirects are rejected pending review. Transfers stream without materializing an original on the local machine. After upload, the worker compares R2 object size to the remote Content-Length; cryptographic SHA-256 verification is not yet implemented.

`GET /v1/status/<assetId>` reports if an original exists and its size. `GET /v1/original/<assetId>` streams the original for an external-drive scratch downloader. Both require the transfer bearer token; do not expose this token in photo-sharing links.

## Storage architecture and limitations

- Lightroom Cloud → Cloudflare Worker → private R2 originals.
- SpektraFilm would use only thumbnails/metadata for Library and Cull.
- The user-selected external-drive scratch is the correct download target for Edit/Export; the current Swift app is not yet wired to this worker's on-demand download endpoint.
- No ordinary iCloud Drive upload API exists for this worker to call. To preserve iCloud Drive as the final destination, a logged-in remote Mac bridge would be needed; that's **not** implemented here.
- Upgrade path: an entitled Lightroom OAuth integration, a reviewed direct-original download endpoint, resumable/multipart R2 uploads with SHA-256 verification, and a Swift external-drive streaming downloader.

## Tests

```sh
node --test test/*.test.mjs
```

These tests use fake Adobe responses and in-memory R2; they do not exercise real Adobe/Cloudflare accounts or prove Lightroom entitlement.
