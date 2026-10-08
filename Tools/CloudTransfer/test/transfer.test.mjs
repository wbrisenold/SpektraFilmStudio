import test from 'node:test';
import assert from 'node:assert/strict';
import { handleRequest } from '../worker.mjs';
const id='0123456789abcdef0123456789abcdef';
function mockBucket(){
  const map=new Map();
  const metadata=new Map();
  return {
    async head(key){const o=map.get(key);return o?{size:o.byteLength,httpEtag:'"example-etag"',customMetadata:metadata.get(key)}:null;},
    async put(key,stream,options={}){
      const data=new Uint8Array(await new Response(stream).arrayBuffer());
      map.set(key,data);metadata.set(key,options.customMetadata);
      return {size:data.byteLength};
    },
    async get(key){const o=map.get(key);return o?{
      size:o.byteLength,customMetadata:metadata.get(key),body:new ReadableStream({start(c){c.enqueue(o);c.close();}})}:null;}
  };
}
const env=()=>({TRANSFER_TOKEN:'abc'.repeat(12),ADOBE_CLIENT_ID:'adobe-app-id',ORIGINALS:mockBucket()});
function req(url, body,headers={}){return new Request('https://worker.example'+url,{
  method:'POST',headers:{authorization:'Bearer '+ 'abc'.repeat(12),
  'x-adobe-access-token':'example-oauth-token-more-than-15',
  'content-type':'application/json',...headers},body:JSON.stringify(body)});}
test('no auth -> 401', async()=>{
  const response=await handleRequest(new Request('https://worker.example/v1/status/'+id),env());
  assert.equal(response.status,401);
});
test('reject SSRF sources, redirects and invalid identifiers', async()=>{
  const e=env();
  const fetcher=()=>{throw Error('unexpected upstream call');};
  const common={assetId:id,originalUrl:'https://127.0.0.1/secret'};
  assert.equal((await handleRequest(req('/v1/transfer',common),e,fetcher)).status,400);
  assert.equal((await handleRequest(req('/v1/transfer',{...common,assetId:'../../bad',originalUrl:'https://lr.adobe.io/v2'}),e,fetcher)).status,400);
  const response=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:'https://lr.adobe.io/path'}),e,async()=>new Response(null,{status:302,headers:{location:'https://evil.test'}}));
  assert.equal(response.status,424);
});
test('cloud stream transfers once, verifies object and serves authorized on-demand download',async()=>{
  const e=env();let hits=0;
  const fetched=async (_url,opt)=>{
    hits++;assert.equal(opt.redirect,'manual');
    assert.match(opt.headers.get('Authorization'),/^Bearer example/);
    return new Response(new Uint8Array([1,2,3,4]),{headers:{'content-length':'4','content-type':'application/octet-stream'}});
  };
  const source='https://lr.adobe.io/v2/assets/original';
  const a=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:source}),e,fetched);
  assert.equal(a.status,200);assert.equal((await a.json()).bytes,4);
  const again=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:source}),e,fetched);
  assert.equal((await again.json()).state,'already-transferred');assert.equal(hits,1);
  const read=await handleRequest(new Request('https://worker.example/v1/original/'+id,{headers:{authorization:'Bearer '+'abc'.repeat(12)}}),e);
  assert.deepEqual(Array.from(new Uint8Array(await read.arrayBuffer())),[1,2,3,4]);
});
test('reject large originals before put',async()=>{
  const a=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:'https://lr.adobe.io/v2/x'}),env(),async()=>new Response('a',{headers:{'content-length':String(150*1024*1024)}}));
  assert.equal(a.status,413);
});

test('reject truncated and oversized streams without marking them complete', async()=>{
  for (const bytes of [new Uint8Array([1,2]),new Uint8Array([1,2,3,4,5])]) {
    const e=env();
    const result=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:'https://lr.adobe.io/x'}),e,
      async()=>new Response(bytes,{headers:{'content-length':'4'}}));
    assert.equal(result.status,502);
    assert.equal(await e.ORIGINALS.head('lightroom-originals/'+id),null);
  }
});
test('refuse legacy unverified objects instead of claiming successful transfer',async()=>{
  const e=env();await e.ORIGINALS.put('lightroom-originals/'+id,new Uint8Array([1,2,3,4]));
  const result=await handleRequest(req('/v1/transfer',{assetId:id,originalUrl:'https://lr.adobe.io/x'}),e,
    ()=>{throw Error('must not overwrite');});
  assert.equal(result.status,409);
});
