/*
 * SpektraFilm direct Lightroom-provider-download -> R2 stream bridge.
 * Raw bytes never transit the photographer's computer. No disk buffering.
 * Strict, authenticated endpoints; explicit source URL allowlist.
 * This is a transport component, not a Lightroom OAuth implementation.
 */
const MAX_BYTES = 100 * 1024 * 1024; // Conservative one-object bound for a free transfer trial.
const ID_PATTERN = /^[a-f0-9]{32}$/i;
const ALLOWED_HOST = /(^|\.)((adobe\.io)|(adobe\.com)|(adobesc\.com))$/i;

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }
  });
}
function authorized(request, env) {
  const expected = env.TRANSFER_TOKEN;
  const supplied = request.headers.get('authorization');
  // Worker must not run with blank secret; only HTTPS via Workers runtime.
  return typeof expected === 'string' && expected.length >= 24 &&
    supplied === `Bearer ${expected}`;
}
function adobeSource(urlText) {
  if (typeof urlText !== 'string' || urlText.length > 4096) return null;
  try {
    const url = new URL(urlText);
    if (url.protocol !== 'https:' || url.port || url.username || url.password ||
        !ALLOWED_HOST.test(url.hostname)) return null;
    return url;
  } catch { return null; }
}
function assetKey(assetId) { return `lightroom-originals/${assetId.toLowerCase()}`; }

export async function handleRequest(request, env, fetchImpl = fetch) {
  const route = new URL(request.url);
  if (route.pathname === '/health' && request.method === 'GET')
    return json({ status: 'ok', storage: 'r2', version: 1 });
  if (!authorized(request, env)) return json({ error: 'unauthorized' }, 401);
  if (!env.ORIGINALS || typeof env.ORIGINALS.put !== 'function')
    return json({ error: 'R2 bucket binding missing' }, 503);

  const match = /^\/v1\/(status|original)\/([a-f0-9]{32})$/i.exec(route.pathname);
  if (match && request.method === 'GET') {
    const [, action, id] = match;
    const key = assetKey(id);
    if (action === 'status') {
      const obj = await env.ORIGINALS.head(key);
      return json({ exists: Boolean(obj), assetId: id.toLowerCase(),
        size: obj?.size ?? null, etag: obj?.httpEtag ?? null });
    }
    const obj = await env.ORIGINALS.get(key);
    if (!obj?.body) return json({ error: 'not found' }, 404);
    return new Response(obj.body, {
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(obj.size),
        'cache-control': 'private, no-store',
        'content-disposition': 'attachment',
      }
    });
  }
  if (route.pathname !== '/v1/transfer' || request.method !== 'POST')
    return json({ error: 'not found' }, 404);

  // Never accept arbitrary destination keys or URLs (SSRF and path traversal).
  let body;
  try { body = await request.json(); }
  catch { return json({ error: 'invalid JSON' }, 400); }
  const id = body?.assetId;
  if (typeof id !== 'string' || !ID_PATTERN.test(id))
    return json({ error: 'assetId must be 32 hexadecimal characters' }, 400);
  const adobeURL = adobeSource(body?.originalUrl);
  if (!adobeURL) return json({ error: 'source must be Adobe-hosted HTTPS URL' }, 400);
  const token = request.headers.get('x-adobe-access-token');
  if (!token || token.length < 15 || token.length > 8192)
    return json({ error: 'Adobe OAuth access token required' }, 401);
  const key = assetKey(id);
  const existing = await env.ORIGINALS.head(key);
  if (existing) return json({ state: 'already-transferred', assetId: id.toLowerCase(),
    bytes: existing.size, etag: existing.httpEtag });

  const headers = new Headers({
    'Authorization': `Bearer ${token}`,
    'X-API-Key': env.ADOBE_CLIENT_ID || '',
    'Accept': 'application/octet-stream'
  });
  // Do not automatically follow redirects to untrusted download providers.
  const upstream = await fetchImpl(adobeURL.href, { headers, redirect: 'manual' });
  if (upstream.status >= 300 && upstream.status < 400) {
    return json({ error: 'Adobe returned redirect; requires reviewed allowlist/CDN adapter' }, 424);
  }
  if (!upstream.ok) return json({ error: 'Adobe download unavailable', status: upstream.status }, 424);
  if (!upstream.body) return json({ error: 'Adobe returned empty stream' }, 502);
  const length = Number(upstream.headers.get('content-length'));
  const mediaType = (upstream.headers.get('content-type') || '').toLowerCase();
  if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_BYTES)
    return json({ error: 'Unknown or oversized original; use multipart transfer backend',
      maxBytes: MAX_BYTES }, 413);
  if (/text\/html|application\/json/.test(mediaType))
    return json({ error: 'Original endpoint returned a document, not binary image data' }, 502);

  // The body is streamed directly from Adobe to R2, with no arrayBuffer() or temp files.
  const saved = await env.ORIGINALS.put(key, upstream.body, {
    httpMetadata: { contentType: 'application/octet-stream' },
    customMetadata: { adobeAssetId: id.toLowerCase(), importedFrom: 'Lightroom Cloud' }
  });
  if (!saved) return json({ error: 'R2 write rejected' }, 502);
  const head = await env.ORIGINALS.head(key);
  if (!head || head.size !== length) return json({
    error: 'Transfer not verified; stored size differs from source',
    expectedSize: length, actualSize: head?.size ?? null
  }, 502);
  return json({ state: 'transferred', assetId: id.toLowerCase(), bytes: head.size,
    etag: head.httpEtag });
}

export default { fetch: (request, env) => handleRequest(request, env) };
