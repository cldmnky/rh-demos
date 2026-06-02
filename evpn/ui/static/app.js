// EVPN UI — Main Application

const API = '/api';
let currentTopology = null;

function init() {
  fetch(API + '/topology')
    .then(r => r.json())
    .then(render)
    .catch(err => console.warn('initial fetch failed:', err));

  listenSSE();
}

function listenSSE() {
  const evt = new EventSource(API + '/events');
  evt.addEventListener('topology', e => {
    try {
      currentTopology = JSON.parse(e.data);
      render(currentTopology);
      setStatus('connected');
    } catch (err) {
      console.warn('parse error:', err);
    }
  });
  evt.onerror = () => setStatus('disconnected');
}

function setStatus(state) {
  const el = document.getElementById('status');
  el.className = 'status-' + state;
  el.textContent = state === 'connected' ? 'live' : 'connecting';
}

function render(topo) {
  renderWorkloads(topo.workloads || []);
  renderBGP(topo.bgp || []);
  renderEVPN(topo.evpn);
  drawTopology(topo);
}

function renderWorkloads(workloads) {
  const list = document.getElementById('workload-list');
  const count = document.getElementById('workload-count');
  count.textContent = workloads.length;

  if (workloads.length === 0) {
    list.innerHTML = '<div class="empty">No workloads deployed</div>';
    return;
  }

  list.innerHTML = workloads.map(w => `
    <div class="row">
      <span class="cluster-badge ${w.cluster}">${w.cluster}</span>
      <span class="pod-name">${w.name}</span>
      <span class="pod-ip">${w.cudn_ip || '...'}</span>
      <span class="pod-mac">${w.mac || ''}</span>
      <span class="pod-node">${w.node || ''}</span>
      <span class="pod-state ${w.state}">${w.state}</span>
    </div>
  `).join('');
}

function renderBGP(sessions) {
  const list = document.getElementById('bgp-list');
  const count = document.getElementById('bgp-count');
  const up = sessions.filter(s => s.state === 'Up' || s.state === 'Established');
  count.textContent = up.length + ' up';

  if (sessions.length === 0) {
    list.innerHTML = '<div class="empty">No BGP data</div>';
    return;
  }

  list.innerHTML = sessions.map(s => `
    <div class="bgp-row">
      <span class="bgp-peer">${s.local} ↔ ${s.remote}</span>
      <span class="bgp-state ${s.state}">${s.state}</span>
      <span class="bgp-uptime">${s.uptime || ''}</span>
      <span class="bgp-pfx">${s.pfx_rcd || '0'}p</span>
    </div>
  `).join('');
}

function renderEVPN(evpn) {
  const list = document.getElementById('evpn-list');
  const routes = document.getElementById('evpn-routes');

  if (!evpn) {
    list.innerHTML = '<div class="empty">No EVPN data</div>';
    routes.textContent = '0 routes';
    return;
  }

  const total = (evpn.type2_count || 0) + (evpn.type3_count || 0);
  routes.textContent = total + ' routes';

  const vnis = evpn.vnis || [];
  if (vnis.length === 0) {
    list.innerHTML = '<div class="empty">No VNIs</div>';
    return;
  }

  list.innerHTML = vnis.map(v => `
    <div class="evpn-row">
      <span class="evpn-vni">VNI ${v.vni}</span>
      <span class="evpn-rd">RD ${v.rd || ''}</span>
      <span class="evpn-vteps">${(v.remote_vteps || []).length} remote VTEPs</span>
    </div>
  `).join('');
}

document.addEventListener('DOMContentLoaded', init);
