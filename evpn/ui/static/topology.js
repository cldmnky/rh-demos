// EVPN UI — Topology Graph (vis-network) with Pods, Groups, and Route Animations

let network = null;
let topologyData = {nodes: new vis.DataSet(), edges: new vis.DataSet()};
let initialized = false;
let animatedEdges = new Set();

const POSITIONS = {
  'evpn-cluster1-control-plane': {x: -350, y: -100},
  'evpn-cluster1-worker':        {x: -210, y: -100},
  'evpn-cluster2-control-plane': {x: 210, y: -100},
  'evpn-cluster2-worker':        {x: 350, y: -100},
  'evpn-edge1':                  {x: -280, y: 100},
  'evpn-edge2':                  {x: 280, y: 100},
};

const COLORS = {
  c1: '#1f6feb',
  c2: '#7c3aed',
  edge: '#d29922',
};

function drawTopology(topo) {
  if (!initialized) {
    initNetwork();
    initialized = true;
  }
  updateGraph(topo);
}

function initNetwork() {
  const container = document.getElementById('topology');
  const options = {
    physics: false,
    interaction: { hover: true, zoomView: true, dragView: true },
    nodes: {
      shape: 'box',
      margin: { top: 10, bottom: 10, left: 16, right: 16 },
      font: { color: '#c9d1d9', size: 13, face: 'monospace' },
      borderWidth: 2,
      shadow: { enabled: true, color: 'rgba(0,0,0,0.4)', size: 5 },
    },
    edges: {
      arrows: { to: { enabled: false } },
      color: { color: '#58a6ff55', highlight: '#58a6ff' },
      width: 2,
      smooth: { type: 'curvedCW', roundness: 0.15 },
    },
  };

  network = new vis.Network(container, topologyData, options);

  // Background Group Backdrops
  network.on("beforeDrawing", function (ctx) {
    drawGroupBackdrop(ctx, -410, -270, 260, 235, "Cluster 1 (East)", COLORS.c1);
    drawGroupBackdrop(ctx, 150, -270, 260, 235, "Cluster 2 (West)", COLORS.c2);
    drawGroupBackdrop(ctx, -340, 40, 680, 120, "Provider Edge Core (BGP EVPN)", COLORS.edge);
    // Transit backdrop only drawn when visible (checked in drawTransitBackdrop)
    drawTransitBackdrop(ctx);
  });

  // Drill Down Click Listener
  network.on("click", function (params) {
    if (params.nodes.length > 0) {
      const nodeId = params.nodes[0];
      if (nodeId === "evpn-transit") {
        showTransitDetails();
      } else if (nodeId.startsWith("evpn-edge")) {
        showEdgeDetails(nodeId);
      } else if (nodeId.startsWith("vm-")) {
        showWorkloadDetails(nodeId);
      } else {
        showNodeDetails(nodeId);
      }
    } else {
      toggleDrawer(false);
    }
  });

  resizeObserver(container);
}

function drawGroupBackdrop(ctx, x, y, width, height, label, color) {
  ctx.save();
  ctx.fillStyle = color + '0a';
  ctx.strokeStyle = color + '22';
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);

  const r = 8;
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + width - r, y);
  ctx.quadraticCurveTo(x + width, y, x + width, y + r);
  ctx.lineTo(x + width, y + height - r);
  ctx.quadraticCurveTo(x + width, y + height, x + width - r, y + height);
  ctx.lineTo(x + r, y + height);
  ctx.quadraticCurveTo(x, y + height, x, y + height - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();

  ctx.setLineDash([]);
  ctx.fillStyle = color + 'aa';
  ctx.font = 'bold 11px monospace';
  ctx.fillText(label.toUpperCase(), x + 12, y + 20);
  ctx.restore();
}

function drawTransitBackdrop(ctx) {
  const topo = currentTopology;
  if (!topo || !topo.transit_subnet) return;
  ctx.save();
  ctx.fillStyle = '#d299220a';
  ctx.strokeStyle = '#d2992233';
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);
  const r = 8;
  const x = -200, y = 170, width = 400, height = 70;
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + width - r, y);
  ctx.quadraticCurveTo(x + width, y, x + width, y + r);
  ctx.lineTo(x + width, y + height - r);
  ctx.quadraticCurveTo(x + width, y + height, x + width - r, y + height);
  ctx.lineTo(x + r, y + height);
  ctx.quadraticCurveTo(x, y + height, x, y + height - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = '#d29922aa';
  ctx.font = 'bold 10px monospace';
  ctx.fillText(('TRANSIT ' + topo.transit_subnet).toUpperCase(), x + 12, y + 22);
  ctx.restore();
}

function buildIPMap(topo) {
  const m = {};
  (topo.clusters || []).forEach(c => {
    (c.nodes || []).forEach(n => {
      m[n.kind_ip] = n.name;
      if (n.ip) m[n.ip] = n.name;
    });
  });
  (topo.edges || []).forEach(e => {
    m[e.ip] = e.name;
    if (e.transit_ip) m[e.transit_ip] = e.name;
  });
  return m;
}

function addPodsToGraph(topo, nodes, edges) {
  const ipMap = buildIPMap(topo);

  // Group workloads by cluster
  const c1Workloads = (topo.workloads || []).filter(w => w.cluster === 'c1' && w.state === 'Running');
  const c2Workloads = (topo.workloads || []).filter(w => w.cluster === 'c2' && w.state === 'Running');

  // Helper to add pod nodes for a cluster
  function addClusterPods(workloads, workerNode, clusterColor) {
    const baseX = POSITIONS[workerNode] ? POSITIONS[workerNode].x : 0;
    const baseY = (POSITIONS[workerNode] ? POSITIONS[workerNode].y : -100) - 120; // Increased distance to prevent overlaps
    const total = workloads.length;

    workloads.forEach((w, idx) => {
      const xOffset = total === 1 ? 0 : (idx - (total - 1) / 2) * 70; // Increased horizontal spacing for readable labels
      const x = baseX + xOffset;

      nodes.push({
        id: w.name,
        label: w.name + '\n' + (w.cudn_ip || ''),
        x: x,
        y: baseY,
        shape: 'dot',
        size: 18,
        color: { background: clusterColor, border: '#ffffff66' },
        font: { size: 9, color: '#8b949e', face: 'monospace' },
        borderWidth: 1.5,
        title: `${w.name}\nIP: ${w.cudn_ip}\nMAC: ${w.mac}\nNode: ${w.node}\nState: ${w.state}`,
        group: 'pod',
      });

      // Thin dotted line connecting pod to its worker
      const edgeId = workerNode + '-' + w.name;
      edges.push({
        id: edgeId,
        from: workerNode,
        to: w.name,
        color: { color: clusterColor + '44', opacity: 0.4 },
        width: 1,
        dashes: [3, 3],
        title: `L2 CUDN: ${w.cudn_ip || ''}`,
      });
    });
  }

  addClusterPods(c1Workloads, 'evpn-cluster1-worker', COLORS.c1);
  addClusterPods(c2Workloads, 'evpn-cluster2-worker', COLORS.c2);

  // L2 stretch line between the first pod in each cluster
  if (c1Workloads.length > 0 && c2Workloads.length > 0) {
    const a = c1Workloads[0];
    const b = c2Workloads[0];
    const edgeId = 'l2-stretch-' + a.name + '-' + b.name;
    edges.push({
      id: edgeId,
      from: a.name,
      to: b.name,
      color: { color: '#58a6ff88', opacity: 0.5 },
      width: 1,
      dashes: [6, 4],
      title: 'L2 Stretched Subnet 192.170.1.0/24 (VNI 110)',
    });
  }
}

function updateGraph(topo) {
  const nodes = [];
  const edges = [];

  // Build IP → node name map for BGP edge resolution
  const ipMap = buildIPMap(topo);

  (topo.clusters || []).forEach(cluster => {
    const k8sColor = cluster.name === 'evpn-cluster1' ? COLORS.c1 : COLORS.c2;

    (cluster.nodes || []).forEach(node => {
      const pos = POSITIONS[node.name] || {};
      const label = node.name.replace(cluster.name + '-', '').replace('-', '\n');
      nodes.push({
        id: node.name,
        label: label,
        x: pos.x,
        y: pos.y,
        color: { background: '#161b22', border: k8sColor },
        title: `${node.name}\nIP: ${node.kind_ip}\nRole: ${node.role}`,
        shapeProperties: { borderRadius: 6 },
      });
    });
  });

  (topo.edges || []).forEach(edge => {
    const color = edge.state === 'running' ? COLORS.edge : '#484f58';
    const roleShort = edge.name.replace('evpn-', '');
    const label = roleShort + '\n' + edge.ip;
    nodes.push({
      id: edge.name,
      label: label,
      shape: 'diamond',
      x: POSITIONS[edge.name] ? POSITIONS[edge.name].x : 0,
      y: POSITIONS[edge.name] ? POSITIONS[edge.name].y : 0,
      color: { background: '#1a1a1a', border: color },
      size: 30,
      font: { size: 11 },
      title: `${edge.name}\nIP: ${edge.ip}\nAS: ${edge.as}\nState: ${edge.state}`,
    });
  });

  // Transit network (v2 demo): cloud node + transit links between edges
  if (topo.transit_subnet && topo.edges && topo.edges.length >= 2) {
    const e1 = topo.edges[0];
    const e2 = topo.edges[1];
    nodes.push({
      id: 'evpn-transit',
      label: topo.transit_subnet,
      x: 0,
      y: 210,
      shape: 'box',
      color: { background: '#1a1a1a', border: '#d29922' },
      font: { size: 10, color: '#d29922', face: 'monospace' },
      title: 'eBGP Transit Network ' + topo.transit_subnet,
      shapeProperties: { borderRadius: 8 },
      margin: { top: 8, bottom: 8, left: 12, right: 12 },
    });
    edges.push({
      id: 'edge1-transit',
      from: 'evpn-edge1',
      to: 'evpn-transit',
      color: { color: '#d2992266', opacity: 0.4 },
      width: 1,
      dashes: [4, 4],
      label: e1.transit_ip || '',
      font: { size: 9, color: '#d29922', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
      smooth: false,
      title: 'eBGP: edge1 → transit (' + (e1.transit_ip || '') + ')',
    });
    edges.push({
      id: 'edge2-transit',
      from: 'evpn-edge2',
      to: 'evpn-transit',
      color: { color: '#d2992266', opacity: 0.4 },
      width: 1,
      dashes: [4, 4],
      label: e2.transit_ip || '',
      font: { size: 9, color: '#d29922', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
      smooth: false,
      title: 'eBGP: edge2 → transit (' + (e2.transit_ip || '') + ')',
    });
  }

  // Add workload pods to graph
  addPodsToGraph(topo, nodes, edges);

  (topo.bgp || []).forEach(session => {
    const localNode = session.local;
    // Resolve remote IP to node name using IP map preferentially, then FRR hostname
    const remoteName = ipMap[session.remote] || session.remote_name || session.remote;
    if (!localNode || !remoteName) return;

    const edgeId = localNode + '-' + remoteName;

    // Skip edges currently under route animation
    if (animatedEdges.has(edgeId)) return;

    const color = session.state === 'Up' || session.state === 'Established'
      ? '#3fb950' : (session.state === 'Active' ? '#d29922' : '#f85149');
    const dashes = session.state !== 'Up' && session.state !== 'Established';

    edges.push({
      id: edgeId,
      from: localNode,
      to: remoteName,
      color: { color: color, opacity: 0.6 },
      dashes: dashes,
      title: `${localNode} ↔ ${remoteName}\n${session.state} | uptime: ${session.uptime}\nprefixes: ${session.pfx_rcd}`,
    });
  });

  topologyData.nodes.update(nodes);
  topologyData.edges.update(edges);

  if (!initialized) {
    network.fit({ animation: { duration: 500 } });
  }
}

// --- Route Propagation Animation ---

function processRouteEvents(routeEvents) {
  if (!network || !routeEvents || routeEvents.length === 0) return;
  routeEvents.forEach(ev => animateRoutePath(ev));
}

function animateRoutePath(event) {
  if (!network || !event.path || event.path.length < 2) return;
  const edges = network.body.data.edges;
  const edgeIds = [];

  // Find edge IDs for each hop in the path
  for (let i = 0; i < event.path.length - 1; i++) {
    const a = event.path[i];
    const b = event.path[i + 1];
    const id1 = a + '-' + b;
    const id2 = b + '-' + a;
    if (edges.get(id1)) edgeIds.push(id1);
    else if (edges.get(id2)) edgeIds.push(id2);
  }

  if (edgeIds.length === 0) return;

  // Mark edges as animated (topology updates skip them)
  edgeIds.forEach(id => animatedEdges.add(id));

  const label = event.type === 'type2' ? ' NEW ROUTE ' : ' IMET ';

  // Set animated style: pulsing orange dashed
  edgeIds.forEach(id => {
    edges.update({
      id: id,
      color: { color: '#d29922', opacity: 1.0 },
      width: 3,
      dashes: [6, 4],
      label: label,
      font: { size: 8, color: '#d29922', strokeWidth: 0, face: 'monospace' },
    });
  });

  // Pulse animation: toggle opacity every 350ms
  let pulseOn = true;
  const pulseInterval = setInterval(() => {
    pulseOn = !pulseOn;
    const opacity = pulseOn ? 1.0 : 0.25;
    edgeIds.forEach(id => {
      edges.update({ id: id, color: { color: '#d29922', opacity: opacity } });
    });
  }, 350);

  // After 4 seconds, remove animation markers and let next topology update restore styling
  setTimeout(() => {
    clearInterval(pulseInterval);
    edgeIds.forEach(id => {
      animatedEdges.delete(id);
      edges.update({
        id: id,
        label: '',
        color: { color: '#3fb950', opacity: 0.6 },
        width: 2,
        dashes: false,
      });
    });
  }, 4000);
}

function resizeObserver(el) {
  new ResizeObserver(() => {
    if (network) {
      network.redraw();
      network.fit({ animation: false });
    }
  }).observe(el);
}
