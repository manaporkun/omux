// Node 22+, installed Codex CLI. Uses only temporary state and a local fake model.
// No OpenAI request, user credentials, or user conversations are involved.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, mkdirSync, realpathSync, writeFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { createServer as createTCPServer, connect as connectTCP } from 'node:net';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const home = mkdtempSync(join(tmpdir(), 'omux-codex-smoke-'));
const sockets = [];
let child;
let calls = 0;
let toolNames = [];
const model = createServer(async (req, res) => {
  if (!req.url.startsWith('/v1/responses')) { res.writeHead(404).end(); return; }
  let data = '';
  for await (const part of req) data += part;
  const body = JSON.parse(data);
  toolNames = (body.tools ?? []).flatMap(t => t.tools?.map(x => x.name) ?? [t.name]);
  calls++;
  const id = `omux-response-${calls}`;
  const item = calls % 2 === 1
    ? { type: 'function_call', id: 'fc_omux', call_id: 'call_omux', name: 'exec_command',
        arguments: JSON.stringify({cmd: 'echo omux-approval-smoke', sandbox_permissions: 'require_escalated', justification: 'Omux local approval integration test'}) }
    : { type: 'message', id: 'msg_omux', role: 'assistant', status: 'completed',
        content: [{type: 'output_text', text: 'Omux local test complete.', annotations: []}] };
  res.writeHead(200, {'content-type': 'text/event-stream'});
  const event = (type, extra) => res.write(`event: ${type}\ndata: ${JSON.stringify({type, ...extra})}\n\n`);
  event('response.created', {response: {id, status: 'in_progress'}});
  event('response.output_item.added', {output_index: 0, item});
  event('response.output_item.done', {output_index: 0, item});
  event('response.completed', {response: {id, status: 'completed', output: [item], usage: {input_tokens: 1, output_tokens: 1, total_tokens: 2}}});
  res.end();
});

const deadline = setTimeout(() => { console.error('Timed out'); child?.kill(); process.exit(1); }, 45000);
async function waitFor(test, description) {
  for (let i = 0; i < 150; i++) { const value = test(); if (value) return value; await delay(100); }
  throw new Error(`Timed out: ${description}`);
}
async function client(endpoint, token, name) {
  const ws = await authenticatedSocket(endpoint, token);
  sockets.push(ws);
  let next = 0;
  const pending = new Map(), events = [];
  ws.onmessage = event => {
    const msg = JSON.parse(event.data);
    if (msg.method == null && pending.has(msg.id)) {
      const call = pending.get(msg.id); pending.delete(msg.id);
      msg.error ? call.reject(new Error(JSON.stringify(msg.error))) : call.resolve(msg.result);
    } else events.push(msg);
  };
  const request = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++next; pending.set(id, {resolve, reject}); ws.send(JSON.stringify({id, method, params}));
  });
  await request('initialize', {clientInfo:{name,version:'0.1.0'}});
  ws.send(JSON.stringify({method:'initialized'}));
  return {request, events, respond:(id, result)=>ws.send(JSON.stringify({id,result}))};
}

// Small RFC 6455 test client so the smoke check needs no npm dependencies. The
// production app uses URLSessionWebSocketTask with the same Authorization header.
function authenticatedSocket(endpoint, token) {
  return new Promise((resolve, reject) => {
    const url = new URL(endpoint);
    const tcp = connectTCP(Number(url.port), url.hostname);
    let buffer = Buffer.alloc(0), upgraded = false;
    const ws = {
      onmessage: null,
      send: text => frame(1, Buffer.from(text)),
      close: () => tcp.destroy()
    };
    function frame(opcode, data) {
      const mask = randomBytes(4);
      const header = Buffer.alloc(data.length < 126 ? 2 : data.length < 65536 ? 4 : 10);
      header[0] = 0x80 | opcode;
      header[1] = 0x80 | (data.length < 126 ? data.length : data.length < 65536 ? 126 : 127);
      if (header.length === 4) header.writeUInt16BE(data.length, 2);
      if (header.length === 10) header.writeBigUInt64BE(BigInt(data.length), 2);
      const body = Buffer.from(data);
      for (let i = 0; i < body.length; i++) body[i] ^= mask[i % 4];
      tcp.write(Buffer.concat([header,mask,body]));
    }
    tcp.on('error',reject);
    tcp.on('connect',()=>tcp.write(`GET / HTTP/1.1\r\nHost: ${url.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer ${token}\r\n\r\n`));
    tcp.on('data',chunk=>{
      buffer=Buffer.concat([buffer,chunk]);
      if(!upgraded) {
        const end=buffer.indexOf('\r\n\r\n');
        if(end<0)return;
        if(!buffer.subarray(0,end).toString().startsWith('HTTP/1.1 101')) {
          tcp.destroy();reject(new Error('Authenticated WebSocket upgrade rejected'));return;
        }
        buffer=buffer.subarray(end+4);upgraded=true;resolve(ws);
      }
      while(buffer.length>=2) {
        const opcode=buffer[0]&15;
        let length=buffer[1]&127,offset=2;
        if(length===126){if(buffer.length<4)return;length=buffer.readUInt16BE(2);offset=4;}
        else if(length===127){if(buffer.length<10)return;length=Number(buffer.readBigUInt64BE(2));offset=10;}
        if(buffer.length<offset+length)return;
        const body=buffer.subarray(offset,offset+length);buffer=buffer.subarray(offset+length);
        if(opcode===1)ws.onmessage?.({data:body.toString()});
        else if(opcode===9)frame(10,body);
      }
    });
  });
}

try {
  await new Promise(resolve => model.listen(0, '127.0.0.1', resolve));
  const fakePort = model.address().port;
  writeFileSync(join(home, 'config.toml'), `model_provider = "omux_local_test"
model = "gpt-6.1-sol"
[model_providers.omux_local_test]
name = "Omux local test"
base_url = "http://127.0.0.1:${fakePort}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
`);
  const tcp = createTCPServer();
  await new Promise(resolve => tcp.listen(0, '127.0.0.1', resolve));
  const port = tcp.address().port;
  await new Promise(resolve => tcp.close(resolve));
  const endpoint = `ws://127.0.0.1:${port}`;
  const token = randomBytes(32).toString('hex');
  const env = {...process.env, CODEX_HOME: home};
  delete env.OPENAI_API_KEY; delete env.CODEX_API_KEY;
  child = spawn('codex', ['app-server', '--listen', endpoint, '--ws-auth', 'capability-token',
    '--ws-token-sha256', createHash('sha256').update(token).digest('hex'), '-c', 'analytics.enabled=false'],
    {env, stdio:['ignore','ignore','pipe']});
  let errors = '';
  child.stderr.on('data', bytes => { errors = (errors + bytes).slice(-4000); });
  await waitFor(() => errors.includes('listening on:'), 'server startup');
  const a = await client(endpoint, token, 'omux_native_smoke');
  const b = await client(endpoint, token, 'omux_tui_protocol_smoke');
  const first = await a.request('thread/start', {cwd:home, approvalPolicy:'on-request', sandbox:'read-only'});
  const id = first.thread.id;
  await a.request('thread/name/set', {threadId:id,name:'Omux local smoke'});
  const resumed = await b.request('thread/resume', {threadId:id,excludeTurns:true});
  assert.equal(resumed.thread.id, id);
  await b.request('turn/start', {threadId:id,input:[{type:'text',text:'Run the local approval test.'}]});
  const approvalA = await waitFor(() => a.events.find(e=>e.method==='item/commandExecution/requestApproval'), `native approval (tools: ${toolNames.join(',')})`);
  const approvalB = await waitFor(() => b.events.find(e=>e.method==='item/commandExecution/requestApproval'), 'TUI approval');
  assert.equal(approvalA.id,approvalB.id);
  assert.equal(approvalA.params.threadId,id);
  a.respond(approvalA.id,{decision:'accept'});
  await waitFor(() => b.events.some(e=>e.method==='serverRequest/resolved' && e.params.requestId===approvalA.id), 'TUI clears native answer');
  const completed = await waitFor(() => a.events.find(e=>e.method==='turn/completed'), 'turn completion');
  assert.equal(completed.params.turn.status,'completed');
  const items = await a.request('thread/items/list',{threadId:id,limit:100,sortDirection:'asc'});
  assert.ok(items.data.some(row=>row.item.type==='commandExecution' && row.item.aggregatedOutput?.includes('omux-approval-smoke')));
  a.events.length=0; b.events.length=0;
  await b.request('turn/start', {threadId:id,input:[{type:'text',text:'Run the second local approval test.'}]});
  const denied = await waitFor(() => a.events.find(e=>e.method==='item/commandExecution/requestApproval'), 'second approval');
  a.respond(denied.id,{decision:'decline'});
  await waitFor(() => a.events.find(e=>e.method==='turn/completed'), 'declined turn completion');
  assert.ok(a.events.some(e=>e.method==='item/completed' && e.params.item?.type==='commandExecution' && e.params.item.status==='declined'));
  a.events.length=0; b.events.length=0;
  const third = await b.request('turn/start', {threadId:id,input:[{type:'text',text:'Run the interrupt test.'}]});
  await waitFor(() => a.events.find(e=>e.method==='item/commandExecution/requestApproval'), 'third approval');
  await a.request('turn/interrupt',{threadId:id,turnId:third.turn.id});
  const interrupted=await waitFor(() => b.events.find(e=>e.method==='turn/completed'), 'interrupted turn');
  assert.equal(interrupted.params.turn.status,'interrupted');
  const tui = spawn('python3',[fileURLToPath(new URL('./codex-tui-smoke.py',import.meta.url)),endpoint,id],
    {env:{...env,OMUX_CODEX_TOKEN:token},stdio:['ignore','pipe','pipe']});
  let tuiOutput='';
  tui.stdout.on('data',b=>{tuiOutput+=b;});
  tui.stderr.on('data',b=>{tuiOutput+=b;});
  const tuiCode=await new Promise(resolve=>tui.once('exit',resolve));
  assert.equal(tuiCode,0,tuiOutput);
  console.log(tuiOutput.trim());
  console.log('PASS: authenticated two-client resume, Allow, Deny, resolved events, interruption, local command, transcript and completion.');
  // A loaded thread cannot change cwd. Restart must reopen the saved identity on a fresh server.
  sockets.forEach(ws=>ws.close());
  const stopped = new Promise(resolve=>child.once('exit',resolve));
  child.kill();
  await stopped;
  errors = '';
  child = spawn('codex', ['app-server', '--listen', endpoint, '--ws-auth', 'capability-token',
    '--ws-token-sha256', createHash('sha256').update(token).digest('hex'), '-c', 'analytics.enabled=false'],
    {env, stdio:['ignore','ignore','pipe']});
  child.stderr.on('data', bytes => { errors = (errors + bytes).slice(-4000); });
  await waitFor(() => errors.includes('listening on:'), 'replacement server startup');
  const recovered = await client(endpoint, token, 'omux_folder_recovery_smoke');
  const chosen = join(home, 'chosen-project');
  mkdirSync(chosen);
  const relocated = await recovered.request('thread/resume', {threadId:id,excludeTurns:true,cwd:chosen});
  assert.equal(relocated.thread.id, id);
  assert.equal(realpathSync(relocated.cwd), realpathSync(chosen));
  console.log('PASS: saved Codex conversation keeps its identity while restarting in the explicitly chosen directory.');
} catch (error) {
  console.error(String(error));
  console.error('Local model tool names:',toolNames.join(', '));
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  sockets.forEach(ws=>ws.close());
  if(child) {
    child.kill();
    await Promise.race([new Promise(r=>child.once('exit',r)),delay(2000)]);
  }
  await new Promise(resolve=>model.close(resolve));
  rmSync(home,{recursive:true,force:true,maxRetries:10,retryDelay:200});
}
