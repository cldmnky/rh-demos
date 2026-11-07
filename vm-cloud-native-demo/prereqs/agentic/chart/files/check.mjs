// Read-only connection checks. Never print tokens, keys or full resource objects.
import https from 'node:https';
import fs from 'node:fs';

const config = JSON.parse(fs.readFileSync('/etc/rocket-ramen-agent/opencode.json', 'utf8'));
const ca = fs.readFileSync('/etc/rocket-ramen-agent-ca/service-ca.crt');
const token = fs.readFileSync('/var/run/secrets/kubernetes.io/serviceaccount/token', 'utf8').trim();
const key = fs.readFileSync('/etc/rocket-ramen-agent-key/apikey', 'utf8').trim();
let session;
function request(url, body, credential, headers = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request(url, {
      method: 'POST', ca,
      headers: {'Content-Type': 'application/json', Accept: 'application/json, text/event-stream',
        Authorization: `Bearer ${credential}`, ...headers},
    }, res => {
      let text = '';
      res.on('data', chunk => { text += chunk; });
      res.on('end', () => {
        if (res.statusCode >= 400) return reject(new Error(`HTTP ${res.statusCode} from ${new URL(url).hostname}`));
        const messages = text.startsWith('event:') || text.startsWith('data:')
          ? text.split('\n').filter(line => line.startsWith('data:')).map(line => JSON.parse(line.slice(5)))
          : text ? [JSON.parse(text)] : [];
        resolve({headers: res.headers, data: messages.find(message => message.id !== undefined) || messages[0]});
      });
    });
    req.setTimeout(90000, () => req.destroy(new Error('Connection timed out')));
    req.on('error', reject);
    req.end(data);
  });
}
const mcpURL = config.mcp.openshift.url;
let id = 0;
async function rpc(method, params = {}) {
  const headers = {'MCP-Protocol-Version': '2025-03-26'};
  if (session) headers['Mcp-Session-Id'] = session;
  const response = await request(mcpURL, {jsonrpc: '2.0', id: ++id, method, params}, token, headers);
  session ||= response.headers['mcp-session-id'];
  if (response.data?.error) throw new Error(`MCP ${method} failed: ${response.data.error.message}`);
  return response.data?.result;
}
try {
  await rpc('initialize', {protocolVersion: '2025-03-26', capabilities: {},
    clientInfo: {name: 'rocket-ramen-preflight', version: '1.0'}});
  await request(mcpURL, {jsonrpc: '2.0', method: 'notifications/initialized'}, token,
    session ? {'Mcp-Session-Id': session} : {});
  const tools = await rpc('tools/list');
  if (!tools.tools?.some(tool => tool.name === 'resources_list')) throw new Error('Missing resources_list tool');
  console.log(`MCP TLS, authentication and discovery passed (${tools.tools.length} tools)`);
  const namespace = process.env.NAMESPACE || 'rocket-ramen';
  const resources = await rpc('tools/call', {name: 'resources_list',
    arguments: {apiVersion: 'kubevirt.io/v1', kind: 'VirtualMachine', namespace}});
  if (resources.isError || !JSON.stringify(resources).includes('orders-db')) throw new Error('Demo VM inspection failed');
  console.log(`Live MCP VM inspection passed in ${namespace}`);
  const result = await request(`${config.provider.demo.options.baseURL}/chat/completions`, {
    model: 'demo-model', max_tokens: 100,
    messages: [{role: 'user', content: 'Call list_demo_vms to inspect the demo. Do not change resources.'}],
    tools: [{type: 'function', function: {name: 'list_demo_vms', description: 'Read demo VM names',
      parameters: {type: 'object', properties: {}, additionalProperties: false}}}],
    tool_choice: {type: 'function', function: {name: 'list_demo_vms'}},
  }, key);
  if (result.data?.choices?.[0]?.message?.tool_calls?.[0]?.function?.name !== 'list_demo_vms') {
    throw new Error('LLM tool-calling check failed');
  }
  console.log(`LLM TLS, authentication and tool calling passed (gateway model ${result.data.model})`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
