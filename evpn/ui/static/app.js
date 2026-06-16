// EVPN UI — Main Application with Interactivity (Phase 2 & 3)

const API = '/api';
let currentTopology = null;
let activeView = 'topo';
let activeDiagCluster = 'c1';
let currentDrawerID = null;
let activeDrawerTab = 1;
let pingEventSource = null;

function init() {
  fetch(API + '/topology')
    .then(r => r.json())
    .then(render)
    .catch(err => console.warn('initial fetch failed:', err));

  listenSSE();
  setupFormSubmit();
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
  evt.addEventListener('route_event', e => {
    try {
      const routeEvent = JSON.parse(e.data);
      processRouteEvents([routeEvent]);
      showToast(`New ${routeEvent.type === 'type2' ? 'MAC/IP' : 'IMET'} route propagated!`, 'info');
    } catch (err) {
      console.warn('route_event parse error:', err);
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
  populatePingSelects(topo.workloads || []);
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
      <button class="btn-delete" onclick="deletePod(event, '${w.cluster}', '${w.name}')" title="Delete pod">×</button>
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

  list.innerHTML = vnis.map(v => {
    const vteps = (v.remote_vteps || []).join(', ');
    const type2 = evpn.type2_count || 0;
    const type3 = evpn.type3_count || 0;
    return `
      <div class="evpn-row" onclick="showEVPNRoutes()" style="cursor:pointer">
        <span class="evpn-vni">VNI ${v.vni}</span>
        <span class="evpn-rd">RD ${v.rd || ''}</span>
        <span class="evpn-vteps">${(v.remote_vteps || []).length} remote VTEPs</span>
        <div class="evpn-detail">
          <span class="evpn-rt">RT ${v.rt || ''}</span>
          <span class="evpn-type-count">Type-2: ${type2}  Type-3: ${type3}</span>
          ${vteps ? `<span class="evpn-vtep-list">VTEPs: ${vteps}</span>` : ''}
        </div>
      </div>
    `;
  }).join('');
}

/* Tab Navigation */
function switchView(view) {
  activeView = view;
  const topoView = document.getElementById('topo-view');
  const diagView = document.getElementById('diag-view');
  const topoBtn = document.getElementById('nav-btn-topo');
  const diagBtn = document.getElementById('nav-btn-diag');

  if (view === 'topo') {
    topoView.style.display = 'flex';
    diagView.style.display = 'none';
    topoBtn.classList.add('active');
    diagBtn.classList.remove('active');
  } else {
    topoView.style.display = 'none';
    diagView.style.display = 'flex';
    topoBtn.classList.remove('active');
    diagBtn.classList.add('active');
    refreshDiag();
  }
}

/* Theme Toggle */
function toggleTheme() {
  const body = document.body;
  if (body.classList.contains('dark-theme')) {
    body.classList.remove('dark-theme');
    body.classList.add('light-theme');
  } else {
    body.classList.remove('light-theme');
    body.classList.add('dark-theme');
  }
}

/* Modals */
function toggleModal(id, show) {
  const el = document.getElementById(id);
  el.style.display = show ? 'block' : 'none';
  if (show) {
    document.getElementById('pod-name').value = '';
    document.getElementById('pod-ip').value = '';
    document.getElementById('pod-name').focus();
  }
}

function submitCreatePod(event) {
  event.preventDefault();
  const name = document.getElementById('pod-name').value.trim().toLowerCase();
  const cluster = document.querySelector('input[name="pod-cluster"]:checked').value;
  const ip = document.getElementById('pod-ip').value.trim();

  const submitBtn = document.getElementById('btn-submit-pod');
  submitBtn.disabled = true;
  submitBtn.textContent = 'Deploying...';

  fetch(API + '/workloads', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ cluster, name, cudn_ip: ip })
  })
  .then(async r => {
    submitBtn.disabled = false;
    submitBtn.textContent = 'Deploy Pod';
    if (!r.ok) {
      const err = await r.text();
      throw new Error(err);
    }
    return r.json();
  })
  .then(() => {
    toggleModal('create-modal', false);
    showToast(`Pod ${name} deployment triggered successfully!`, 'success');
  })
  .catch(err => {
    console.error(err);
    showToast(`Error: ${err.message}`, 'error');
  });
}

function setupFormSubmit() {
  // handled via index.html attributes
}

/* Delete Workload */
function deletePod(event, cluster, name) {
  event.stopPropagation();
  const bypass = new URLSearchParams(window.location.search).get('bypass-confirm') === 'true';
  if (!bypass && !confirm(`Are you sure you want to delete pod "${name}" on cluster "${cluster}"?`)) {
    return;
  }

  showToast(`Deleting pod ${name}...`, 'info');

  fetch(`${API}/workloads/${cluster}/${name}`, {
    method: 'DELETE'
  })
  .then(async r => {
    if (!r.ok) {
      const err = await r.text();
      throw new Error(err);
    }
    return r.json();
  })
  .then(() => {
    showToast(`Pod ${name} successfully deleted.`, 'success');
  })
  .catch(err => {
    console.error(err);
    showToast(`Delete failed: ${err.message}`, 'error');
  });
}

function showWorkloadDetails(podName) {
  currentDrawerID = podName;
  toggleDrawer(true, `Workload: ${podName}`);

  const tabs = document.querySelector('.drawer-tabs');
  if (tabs) {
    tabs.style.display = 'none';
  }
  switchDrawerTab(1);

  const wl = currentTopology && currentTopology.workloads
    ? currentTopology.workloads.find(w => w.name === podName)
    : null;

  document.getElementById('drawer-info').innerHTML = wl ? `
    <p><strong>Pod:</strong> ${wl.name}</p>
    <p><strong>Cluster:</strong> ${wl.cluster}</p>
    <p><strong>Node:</strong> ${wl.node || '—'}</p>
    <p><strong>CUDN IP:</strong> ${wl.cudn_ip || '—'}</p>
    <p><strong>MAC:</strong> ${wl.mac || '—'}</p>
    <p><strong>State:</strong> ${wl.state}</p>
    <p><strong>Age:</strong> ${wl.age || '—'}</p>
  ` : `
    <p><strong>Pod:</strong> ${podName}</p>
    <p><em>No detailed workload info available.</em></p>
  `;

  document.getElementById('drawer-fdb').textContent = 'Workload detail: no FDB or neighbor data.';
}

/* Side Drawer (Drill Down) */
function toggleDrawer(show, title = 'Details') {
  const dr = document.getElementById('side-drawer');
  if (show) {
    document.getElementById('drawer-title').textContent = title;
    dr.classList.add('open');
  } else {
    dr.classList.remove('open');
    currentDrawerID = null;
  }
}

function showNodeDetails(nodeName) {
  currentDrawerID = nodeName;
  toggleDrawer(true, `${nodeName} Diagnostics`);
  
  // Show tabs, hide second/third tab contents, activate tab 1
  const tabs = document.querySelector('.drawer-tabs');
  if (tabs) {
    tabs.style.display = 'flex';
  }
  switchDrawerTab(1);

  document.getElementById('drawer-info').innerHTML = `
    <p><strong>Hostname:</strong> ${nodeName}</p>
    <p><strong>CUDN Core Interface:</strong> ovn-udn1 (192.170.1.0/24)</p>
    <p><strong>SVD VTEP Devices:</strong> evbr-evpn-vtep, evx4-evpn-vtep, svl2.1</p>
  `;

  // Fetch FDB
  fetch(`${API}/nodes/${nodeName}/fdb`)
    .then(r => r.text())
    .then(t => document.getElementById('drawer-fdb').textContent = t || 'No FDB entries found.')
    .catch(e => document.getElementById('drawer-fdb').textContent = 'Error: ' + e.message);

  // Fetch Neighbors
  fetch(`${API}/nodes/${nodeName}/neigh`)
    .then(r => r.text())
    .then(t => document.getElementById('drawer-neigh').textContent = t || 'No neighbor entries resolved.')
    .catch(e => document.getElementById('drawer-neigh').textContent = 'Error: ' + e.message);

  // Fetch Interfaces
  fetch(`${API}/nodes/${nodeName}/devices`)
    .then(r => r.text())
    .then(t => document.getElementById('drawer-devices').textContent = t || 'No links.')
    .catch(e => document.getElementById('drawer-devices').textContent = 'Error: ' + e.message);
}

function showEVPNRoutes() {
  currentDrawerID = 'evpn-routes';
  toggleDrawer(true, 'EVPN Route Table');

  const tabs = document.querySelector('.drawer-tabs');
  if (tabs) { tabs.style.display = 'none'; }
  switchDrawerTab(1);

  const evpn = currentTopology && currentTopology.evpn;
  const routes = (evpn && evpn.routes) || [];
  const total = (evpn && ((evpn.type2_count || 0) + (evpn.type3_count || 0))) || 0;

  document.getElementById('drawer-info').innerHTML = `
    <p><strong>Total Routes:</strong> ${total}</p>
    <p><strong>Type-2 (MAC/IP):</strong> ${(evpn && evpn.type2_count) || 0}</p>
    <p><strong>Type-3 (IMET):</strong> ${(evpn && evpn.type3_count) || 0}</p>
  `;

  if (routes.length === 0) {
    document.getElementById('drawer-fdb').textContent = 'No EVPN route details available.';
    return;
  }

  const ipMap = typeof buildIPMap === 'function' && currentTopology ? buildIPMap(currentTopology) : {};

  let html = '';
  let type2Count = 0;
  let type3Count = 0;
  routes.forEach(r => {
    const peerName = ipMap[r.peer_id] || r.peer_id;
    const remote = r.remote_vtep ? ` (remote VTEP: ${r.remote_vtep})` : '';
    if (r.type === 2) {
      type2Count++;
      const ipPart = r.ip ? `/${r.ip_len || 32}` : '';
      html += `<div class="evpn-route type2">
        <span class="route-type">Type-2</span>
        <span class="route-mac">${r.mac || ''}</span>
        <span class="route-arrow">→</span>
        <span class="route-ip">${r.ip || ''}${ipPart}</span>
        <span class="route-via">via ${peerName}${remote}</span>
      </div>`;
    } else {
      type3Count++;
      const ipStr = r.ip ? ` (${r.ip})` : '';
      html += `<div class="evpn-route type3">
        <span class="route-type">Type-3</span>
        <span class="route-desc">IMET${ipStr}</span>
        <span class="route-via">via ${peerName}${remote}</span>
      </div>`;
    }
  });
  document.getElementById('drawer-fdb').innerHTML = html || 'No EVPN route details.';
  document.getElementById('drawer-neigh').textContent = '';
  document.getElementById('drawer-devices').textContent = '';
}

function showTransitDetails() {
  currentDrawerID = 'evpn-transit';
  toggleDrawer(true, 'eBGP Transit Network');

  const tabs = document.querySelector('.drawer-tabs');
  if (tabs) { tabs.style.display = 'none'; }
  switchDrawerTab(1);

  const edges = (currentTopology && currentTopology.edges) || [];
  const e1 = edges.find(e => e.name === 'evpn-edge1');
  const e2 = edges.find(e => e.name === 'evpn-edge2');
  const bgp = (currentTopology && currentTopology.bgp) || [];
  const transitSessions = bgp.filter(s =>
    (s.local === 'evpn-edge1' && s.remote === (e2 && e2.transit_ip)) ||
    (s.local === 'evpn-edge2' && s.remote === (e1 && e1.transit_ip)) ||
    (s.remote === (e1 && e1.transit_ip)) ||
    (s.remote === (e2 && e2.transit_ip))
  );

  document.getElementById('drawer-info').innerHTML = `
    <p><strong>Network:</strong> evpn-transit</p>
    <p><strong>Subnet:</strong> ${(currentTopology && currentTopology.transit_subnet) || '10.250.0.0/24'}</p>
    <p><strong>edge1 IP:</strong> ${(e1 && e1.transit_ip) || '—'}</p>
    <p><strong>edge2 IP:</strong> ${(e2 && e2.transit_ip) || '—'}</p>
    <p><strong>Protocol:</strong> eBGP (AS 65001 ↔ AS 65002)</p>
    <p><strong>Peers:</strong> 2</p>
  `;

  const ipMap = typeof buildIPMap === 'function' && currentTopology ? buildIPMap(currentTopology) : {};
  let html = transitSessions.map(s => {
    const remoteName = ipMap[s.remote] || s.remote_name || s.remote;
    const color = s.state === 'Up' || s.state === 'Established' ? '#3fb950' : '#f85149';
    return `<div class="bgp-row" style="font-size:12px">
      <span class="bgp-peer">${s.local} ↔ ${remoteName}</span>
      <span class="bgp-state ${s.state}" style="color:${color}">${s.state}</span>
      <span class="bgp-uptime">${s.uptime || ''}</span>
    </div>`;
  }).join('');

  document.getElementById('drawer-fdb').innerHTML = html ||
    '<div class="empty">No transit BGP session data available.</div>';
  document.getElementById('drawer-neigh').textContent = '';
  document.getElementById('drawer-devices').textContent = '';
}

function showEdgeDetails(edgeName) {
  currentDrawerID = edgeName;
  toggleDrawer(true, `${edgeName} Routing Table`);

  // Edges don't have SVD or local interfaces, so hide node-tabs 2 and 3
  const tabs = document.querySelector('.drawer-tabs');
  if (tabs) {
    tabs.style.display = 'none';
  }
  switchDrawerTab(1);

  document.getElementById('drawer-info').innerHTML = `
    <p><strong>Reflector Name:</strong> ${edgeName}</p>
    <p><strong>BGP AS:</strong> 64512</p>
    <p><strong>Role:</strong> iBGP EVPN Route Reflector</p>
  `;

  // Fetch EVPN routes
  fetch(`${API}/edges/${edgeName}/routes`)
    .then(r => r.text())
    .then(t => document.getElementById('drawer-fdb').textContent = t || 'No EVPN routes installed.')
    .catch(e => document.getElementById('drawer-fdb').textContent = 'Error: ' + e.message);
}

function switchDrawerTab(tabIndex) {
  activeDrawerTab = tabIndex;
  for (let i = 1; i <= 3; i++) {
    const btn = document.getElementById('tab-btn-' + i);
    const content = document.getElementById('drawer-tab-content-' + i);
    if (i === tabIndex) {
      btn.classList.add('active');
      content.classList.add('active');
    } else {
      btn.classList.remove('active');
      content.classList.remove('active');
    }
  }
}

/* Ping Panel Runner */
function togglePingPanel() {
  const panel = document.getElementById('ping-panel');
  const icon = document.getElementById('ping-toggle-icon');
  if (panel.classList.contains('collapsed')) {
    panel.classList.remove('collapsed');
    panel.classList.add('expanded');
    icon.textContent = '▼';
  } else {
    panel.classList.remove('expanded');
    panel.classList.add('collapsed');
    icon.textContent = '▲';
  }
}

function populatePingSelects(workloads) {
  const fromSelect = document.getElementById('ping-from');
  const toSelect = document.getElementById('ping-to');

  const currentFrom = fromSelect.value;
  const currentTo = toSelect.value;

  fromSelect.innerHTML = '';
  toSelect.innerHTML = '';

  const c1Pods = workloads.filter(w => w.cluster === 'c1');
  const c2Pods = workloads.filter(w => w.cluster === 'c2');

  if (c1Pods.length === 0) {
    fromSelect.innerHTML = '<option value="">No cluster-1 pods</option>';
  } else {
    c1Pods.forEach(p => {
      const opt = document.createElement('option');
      opt.value = `c1/${p.name}`;
      opt.textContent = `${p.name} (c1 - ${p.cudn_ip})`;
      fromSelect.appendChild(opt);
    });
  }

  if (c2Pods.length === 0) {
    toSelect.innerHTML = '<option value="">No cluster-2 pods</option>';
  } else {
    c2Pods.forEach(p => {
      const opt = document.createElement('option');
      opt.value = p.cudn_ip;
      opt.textContent = `${p.name} (c2 - ${p.cudn_ip})`;
      toSelect.appendChild(opt);
    });
  }

  if (currentFrom) fromSelect.value = currentFrom;
  if (currentTo) toSelect.value = currentTo;
}

function runPing() {
  const fromVal = document.getElementById('ping-from').value;
  const toIP = document.getElementById('ping-to').value;
  const terminal = document.getElementById('ping-terminal');

  if (!fromVal || !toIP) {
    showToast('Please select valid source and target pods first.', 'error');
    return;
  }

  const parts = fromVal.split('/');
  const fromCluster = parts[0];
  const fromPod = parts[1];

  terminal.textContent = `>>> Executing ping from ${fromPod} (${fromCluster}) to ${toIP} over EVPN fabric...\n`;

  document.querySelector('.btn-ping').disabled = true;
  const stopBtn = document.querySelector('.btn-ping-stop');
  stopBtn.disabled = false;

  const url = `${API}/ping?from_cluster=${fromCluster}&from_pod=${fromPod}&to_ip=${toIP}`;
  pingEventSource = new EventSource(url);

  pingEventSource.onmessage = function(e) {
    terminal.textContent += e.data + '\n';
    terminal.scrollTop = terminal.scrollHeight; // Auto scroll
  };

  pingEventSource.onerror = function() {
    terminal.textContent += '\n>>> Ping execution completed or stream ended.\n';
    stopPing();
  };
}

function stopPing() {
  if (pingEventSource) {
    pingEventSource.close();
    pingEventSource = null;
  }
  document.querySelector('.btn-ping').disabled = false;
  document.querySelector('.btn-ping-stop').disabled = true;
}

/* Diagnostics View Functions */
function switchDiagCluster(cluster) {
  activeDiagCluster = cluster;
  document.getElementById('diag-btn-c1').classList.toggle('active', cluster === 'c1');
  document.getElementById('diag-btn-c2').classList.toggle('active', cluster === 'c2');
  refreshDiag();
}

function refreshDiag() {
  const out = document.getElementById('diag-output');
  out.textContent = `Querying cluster resources for ${activeDiagCluster === 'c1' ? 'Cluster 1 (evpn-cluster1)' : 'Cluster 2 (evpn-cluster2)'}...`;

  fetch(`${API}/cluster-resources/${activeDiagCluster}`)
    .then(r => r.text())
    .then(t => {
      out.textContent = t || 'No resources found.';
    })
    .catch(e => {
      out.textContent = 'Failed to fetch diagnostics: ' + e.message;
    });
}

/* Toast Notice Helper */
function showToast(message, type = 'info') {
  const toast = document.getElementById('toast');
  toast.textContent = message;
  toast.className = 'toast show';
  if (type === 'error') {
    toast.style.borderColor = '#f85149';
  } else if (type === 'success') {
    toast.style.borderColor = '#3fb950';
  } else {
    toast.style.borderColor = 'var(--text-title)';
  }
  setTimeout(() => {
    toast.className = 'toast';
  }, 3000);
}

document.addEventListener('DOMContentLoaded', init);
