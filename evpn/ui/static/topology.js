// EVPN UI — Topology Graph (vis-network) with Namespaces, UDNs, Pods, MetalLB & Route Animations

let network = null;
let topologyData = { nodes: new vis.DataSet(), edges: new vis.DataSet() };
let initialized = false;
let animatedEdges = new Set();
let currentNamespaceLayouts = { c1: {}, c2: {} };

const POSITIONS = {
  'evpn-cluster1-control-plane': { x: -370, y: -35 },
  'evpn-cluster1-worker':        { x: -190, y: -35 },
  'evpn-cluster2-control-plane': { x: 190, y: -35 },
  'evpn-cluster2-worker':        { x: 370, y: -35 },
  'evpn-edge1':                  { x: -280, y: 130 },
  'evpn-edge2':                  { x: 280, y: 130 },
  'evpn-transit':                { x: 0, y: 260 },
};

const COLORS = {
  c1: '#1f6feb',
  c2: '#7c3aed',
  edge: '#d29922',
};

const NS_THEMES = {
  'tenant-a':     { color: '#388bfd', label: 'TENANT-A', desc: 'Isolated Layer3 Tenant UDN' },
  'udn-bgp':      { color: '#2ea043', label: 'UDN-BGP', desc: 'Layer2 CUDN • BGP Advertised (no EVPN)' },
  'vm-workloads': { color: '#a371f7', label: 'VM-WORKLOADS', desc: 'Stretched L2 CUDN • BGP EVPN (VNI 110)' },
  'l3-services':  { color: '#d29922', label: 'L3-SERVICES', desc: 'MetalLB LoadBalancer (eBGP Transit VIP)' },
  'default':      { color: '#8b949e', label: 'DEFAULT', desc: 'Cluster Default Network' },
};

function getNSTheme(nsName) {
  return NS_THEMES[nsName] || { color: '#8b949e', label: nsName.toUpperCase(), desc: 'Namespace' };
}

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
      margin: { top: 8, bottom: 8, left: 12, right: 12 },
      font: { color: '#c9d1d9', size: 12, face: 'monospace' },
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
    // 1. Cluster 1 (East) outer bounding box
    drawGroupBackdrop(ctx, -485, -310, 390, 335, "Cluster 1 (East)", COLORS.c1);

    // 2. Cluster 2 (West) outer bounding box
    drawGroupBackdrop(ctx, 95, -310, 390, 335, "Cluster 2 (West)", COLORS.c2);

    // 3. Draw active Namespace & UDN sub-containers inside each cluster
    drawNamespaceBackdrops(ctx);

    // 4. Provider Edge Core backdrop
    drawGroupBackdrop(ctx, -380, 75, 760, 115, "Provider Edge Core (BGP EVPN)", COLORS.edge);

    // 5. Transit backdrop
    drawTransitBackdrop(ctx);
  });

  // Drill Down Click Listener
  network.on("click", function (params) {
    if (params.nodes.length > 0) {
      const nodeId = params.nodes[0];
      if (nodeId.startsWith('__anchor')) return;

      if (nodeId === "evpn-transit") {
        showTransitDetails();
      } else if (nodeId.startsWith("evpn-edge")) {
        showEdgeDetails(nodeId);
      } else if (nodeId.startsWith("svc-")) {
        const vipIP = getVIPFromNodeId(nodeId);
        if (vipIP) {
          showVIPRoutes(vipIP);
        } else {
          showNodeDetails(nodeId);
        }
      } else if (isWorkloadNode(nodeId)) {
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

function getVIPFromNodeId(nodeId) {
  const svcName = nodeId.replace('svc-', '');
  if (currentTopology && currentTopology.bgp_services && currentTopology.bgp_services.vips) {
    const vip = currentTopology.bgp_services.vips.find(v => v.service === svcName || nodeId.includes(v.ip));
    if (vip) return vip.ip;
  }
  return null;
}

function isWorkloadNode(nodeId) {
  if (currentTopology && currentTopology.workloads) {
    return currentTopology.workloads.some(w => w.name === nodeId || nodeId.startsWith(w.name));
  }
  return false;
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
  ctx.fillText(label.toUpperCase(), x + 12, y + 18);
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
  const x = -200, y = 225, width = 400, height = 70;
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
  ctx.fillText(('TRANSIT ' + topo.transit_subnet).toUpperCase(), x + 12, y + 20);
  ctx.restore();
}

function drawNamespaceBackdrops(ctx) {
  ['c1', 'c2'].forEach(cluster => {
    const layouts = currentNamespaceLayouts[cluster] || {};
    Object.keys(layouts).forEach(nsName => {
      const item = layouts[nsName];
      if (!item || !item.box) return;
      drawNamespaceCard(ctx, item.box, nsName, item.udn, item.theme, item.isMetalLB, cluster);
    });
  });
}

function drawNamespaceCard(ctx, box, nsName, udnInfo, theme, isMetalLB, cluster) {
  ctx.save();

  const color = theme.color || '#8b949e';
  const r = 6;

  // 1. Box background & border
  ctx.fillStyle = color + '0e'; // ~6% opacity tint
  ctx.strokeStyle = color + '44';
  ctx.lineWidth = 1.5;
  ctx.setLineDash([3, 3]);

  ctx.beginPath();
  ctx.moveTo(box.x + r, box.y);
  ctx.lineTo(box.x + box.width - r, box.y);
  ctx.quadraticCurveTo(box.x + box.width, box.y, box.x + box.width, box.y + r);
  ctx.lineTo(box.x + box.width, box.y + box.height - r);
  ctx.quadraticCurveTo(box.x + box.width, box.y + box.height, box.x + box.width - r, box.y + box.height);
  ctx.lineTo(box.x + r, box.y + box.height);
  ctx.quadraticCurveTo(box.x, box.y + box.height, box.x, box.y + box.height - r);
  ctx.lineTo(box.x, box.y + r);
  ctx.quadraticCurveTo(box.x, box.y, box.x + r, box.y);
  ctx.closePath();
  ctx.fill();
  ctx.stroke();

  // 2. Header bar
  ctx.setLineDash([]);
  ctx.fillStyle = color + '1e';
  ctx.beginPath();
  ctx.moveTo(box.x + r, box.y);
  ctx.lineTo(box.x + box.width - r, box.y);
  ctx.quadraticCurveTo(box.x + box.width, box.y, box.x + box.width, box.y + r);
  ctx.lineTo(box.x + box.width, box.y + 22);
  ctx.lineTo(box.x, box.y + 22);
  ctx.lineTo(box.x, box.y + r);
  ctx.quadraticCurveTo(box.x, box.y, box.x + r, box.y);
  ctx.closePath();
  ctx.fill();

  // 3. Header text: Namespace name
  ctx.fillStyle = color;
  ctx.font = 'bold 10px monospace';
  ctx.fillText('📦 NS: ' + nsName.toUpperCase(), box.x + 8, box.y + 15);

  // 4. Subtitle: UDN / Network type information
  ctx.fillStyle = '#8b949e';
  ctx.font = '9px monospace';
  let subText = '';
  if (udnInfo) {
    const topo = udnInfo.topology || 'UDN';
    const sub = (udnInfo.subnets && udnInfo.subnets.length) ? udnInfo.subnets[0] : '';
    const tag = udnInfo.transport === 'EVPN' ? `EVPN VNI ${udnInfo.vni || 110}` : (udnInfo.advertised ? 'BGP' : '');
    subText = `🌐 ${udnInfo.name} [${topo}${tag ? ' • ' + tag : ''}] ${sub}`;
  } else if (isMetalLB) {
    subText = cluster === 'c1' ? '⚡ MetalLB LoadBalancer VIP' : '⚡ Host-Network Client';
  } else {
    subText = 'Cluster Network';
  }

  const maxChars = Math.floor(box.width / 6.5);
  if (subText.length > maxChars) {
    subText = subText.substring(0, maxChars - 2) + '..';
  }
  ctx.fillText(subText, box.x + 8, box.y + 36);

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

// Compute dynamic container boxes and item centers for active namespaces
function computeNamespaceLayouts(topo) {
  const layouts = { c1: {}, c2: {} };

  ['c1', 'c2'].forEach(cluster => {
    const nsSet = new Set();

    // From UDNs
    (topo.udns || []).filter(u => u.cluster === cluster).forEach(u => {
      if (u.namespace) nsSet.add(u.namespace);
    });

    // From Workloads
    (topo.workloads || []).filter(w => w.cluster === cluster).forEach(w => {
      if (w.namespace && w.namespace !== 'default') nsSet.add(w.namespace);
    });

    // From MetalLB VIPs
    if (topo.bgp_services && topo.bgp_services.vips) {
      topo.bgp_services.vips.filter(v => v.cluster === cluster).forEach(v => {
        if (v.namespace) nsSet.add(v.namespace);
      });
    }

    const orderC1 = ['tenant-a', 'udn-bgp', 'vm-workloads', 'l3-services'];
    const orderC2 = ['vm-workloads', 'l3-services', 'tenant-a', 'udn-bgp'];
    const order = cluster === 'c1' ? orderC1 : orderC2;

    const sortedNs = Array.from(nsSet).sort((a, b) => {
      const ia = order.indexOf(a) >= 0 ? order.indexOf(a) : 99;
      const ib = order.indexOf(b) >= 0 ? order.indexOf(b) : 99;
      return ia - ib;
    });

    const total = sortedNs.length;
    if (total === 0) return;

    const baseX = cluster === 'c1' ? -475 : 105;
    const fullWidth = 370;

    sortedNs.forEach((nsName, idx) => {
      let box, center;

      if (cluster === 'c1') {
        if (total === 1) {
          box = { x: baseX, y: -275, width: fullWidth, height: 185 };
          center = { x: baseX + fullWidth / 2, y: -165 };
        } else if (total === 2) {
          // If 2 namespaces: if vm-workloads is one of them, put it on right (facing C2)
          const isRight = nsName === 'vm-workloads' || (idx === 1 && !sortedNs.includes('vm-workloads'));
          const x = isRight ? baseX + 195 : baseX;
          box = { x: x, y: -275, width: 175, height: 185 };
          center = { x: x + 175 / 2, y: -165 };
        } else {
          // 3 or 4 namespaces: 2x2 grid
          // Dedicated clean slots:
          // tenant-a:     Row 0, Col 0 (Top-Left)
          // udn-bgp:      Row 0, Col 1 (Top-Right)
          // l3-services:  Row 1, Col 0 (Bottom-Left)
          // vm-workloads: Row 1, Col 1 (Bottom-Right -> directly facing C2!)
          let row = 0, col = 0;
          if (nsName === 'tenant-a') { row = 0; col = 0; }
          else if (nsName === 'udn-bgp') { row = 0; col = 1; }
          else if (nsName === 'l3-services') { row = 1; col = 0; }
          else if (nsName === 'vm-workloads') { row = 1; col = 1; }
          else { col = idx % 2; row = Math.floor(idx / 2); }

          const w = 175, h = 88;
          const x = baseX + col * 195;
          const y = row === 0 ? -275 : -180;
          box = { x, y, width: w, height: h };
          center = { x: x + w / 2, y: y + 54 };
        }
      } else {
        // Cluster 2
        if (total === 1) {
          box = { x: baseX, y: -275, width: fullWidth, height: 185 };
          center = { x: baseX + fullWidth / 2, y: -165 };
        } else {
          // Dedicated clean slots for C2:
          // vm-workloads: Col 0 (Left side -> directly facing C1 vm-workloads!)
          // l3-services:  Col 1 (Right side)
          let col = nsName === 'vm-workloads' ? 0 : 1;
          const w = 175;
          const x = baseX + col * 195;
          box = { x, y: -275, width: w, height: 185 };
          center = { x: x + w / 2, y: -165 };
        }
      }

      const udn = (topo.udns || []).find(u => u.cluster === cluster && (u.namespace === nsName || u.name === nsName));
      const isMetalLB = nsName === 'l3-services';
      const theme = getNSTheme(nsName);

      layouts[cluster][nsName] = { box, center, udn, isMetalLB, theme };
    });
  });

  return layouts;
}

function addClusterElementsToGraph(topo, nodes, edges) {
  currentNamespaceLayouts = computeNamespaceLayouts(topo);

  ['c1', 'c2'].forEach(cluster => {
    const layouts = currentNamespaceLayouts[cluster] || {};
    const clusterWorkloads = (topo.workloads || []).filter(w => w.cluster === cluster);
    const clusterVIPs = (topo.bgp_services && topo.bgp_services.vips)
      ? topo.bgp_services.vips.filter(v => v.cluster === cluster)
      : [];

    Object.keys(layouts).forEach(nsName => {
      const slot = layouts[nsName];
      const nsTheme = slot.theme;
      const nsWls = clusterWorkloads.filter(w => w.namespace === nsName);
      const nsVIPs = clusterVIPs.filter(v => v.namespace === nsName);

      const totalItems = nsWls.length + nsVIPs.length;

      let itemIdx = 0;
      function getItemPos() {
        if (totalItems <= 1) {
          return { x: slot.center.x, y: slot.center.y };
        }
        if (totalItems === 2) {
          const offset = itemIdx === 0 ? -44 : 44;
          itemIdx++;
          return { x: slot.center.x + offset, y: slot.center.y };
        }
        const spread = Math.min(slot.box.width - 80, totalItems * 70);
        const step = spread / (totalItems - 1);
        const x = (slot.center.x - spread / 2) + itemIdx * step;
        itemIdx++;
        return { x: x, y: slot.center.y };
      }

      // 1. MetalLB VIP Node (in l3-services on C1)
      nsVIPs.forEach(vip => {
        const pos = getItemPos();
        const svcNodeId = 'svc-' + vip.service;

        nodes.push({
          id: svcNodeId,
          label: `VIP ${vip.ip}\n${vip.service}:8080`,
          x: pos.x,
          y: pos.y,
          shape: 'box',
          color: { background: '#251b05', border: '#d29922' },
          font: { size: 10, color: '#f0883e', face: 'monospace', bold: true },
          shapeProperties: { borderRadius: 4 },
          title: `MetalLB Service: ${vip.service}\nVIP: ${vip.ip}/32\nPool: ${vip.pool || 'evpn-pool'}\nNamespace: ${vip.namespace}\nCluster: ${cluster.toUpperCase()}`,
          group: 'service',
        });

        // Link VIP to Edge 1 (BGP Announcement route)
        if (cluster === 'c1') {
          edges.push({
            id: 'bgp-adv-' + svcNodeId,
            from: svcNodeId,
            to: 'evpn-edge1',
            color: { color: '#d29922aa', opacity: 0.8 },
            width: 2,
            dashes: [4, 4],
            label: `BGP: ${vip.ip}/32`,
            font: { size: 9, color: '#d29922', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
            title: `BGP Route: ${vip.ip}/32 announced via iBGP to edge1`,
          });
        }
      });

      // 2. Pod Nodes
      nsWls.forEach(w => {
        const pos = getItemPos();
        const podId = w.name;
        const displayName = w.name.startsWith('web-') ? 'web' : w.name;

        nodes.push({
          id: podId,
          label: `${displayName}\n${w.cudn_ip || w.state}`,
          x: pos.x,
          y: pos.y,
          shape: 'box',
          color: { background: '#161b22', border: nsTheme.color },
          font: { size: 9, color: '#e6edf3', face: 'monospace' },
          shapeProperties: { borderRadius: 6 },
          title: `Pod: ${w.name}\nNamespace: ${w.namespace}\nCluster: ${w.cluster.toUpperCase()}\nIP: ${w.cudn_ip || '—'}\nMAC: ${w.mac || '—'}\nNet: ${w.network || 'default'} (${w.net_type || ''})\nNode: ${w.node || '—'}\nState: ${w.state}`,
          group: 'pod',
        });

        // Dotted line connecting pod to host node
        if (w.node && POSITIONS[w.node]) {
          edges.push({
            id: `${w.node}-${podId}`,
            from: w.node,
            to: podId,
            color: { color: nsTheme.color + '55', opacity: 0.4 },
            width: 1,
            dashes: [3, 3],
            title: `Hosted on ${w.node}`,
          });
        }

        // MetalLB backend link: if pod is named 'web' in l3-services, link to svc-web
        if (nsName === 'l3-services' && w.name.includes('web') && nsVIPs.length > 0) {
          const svcNodeId = 'svc-' + nsVIPs[0].service;
          edges.push({
            id: `dnat-${svcNodeId}-${podId}`,
            from: svcNodeId,
            to: podId,
            color: { color: '#d2992288', opacity: 0.6 },
            width: 1.5,
            dashes: [3, 2],
            label: 'DNAT',
            font: { size: 8, color: '#d29922', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
            title: `Service target: DNAT VIP to backend pod ${w.name}`,
          });
        }

        // MetalLB client link: if pod is 'vip-client' on C2, link towards edge2
        if (cluster === 'c2' && nsName === 'l3-services' && w.name.includes('client')) {
          edges.push({
            id: `client-query-${podId}`,
            from: podId,
            to: 'evpn-edge2',
            color: { color: '#d2992288', opacity: 0.6 },
            width: 1.5,
            dashes: [4, 4],
            label: 'curl → VIP',
            font: { size: 9, color: '#d29922', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
            title: 'Cross-site BGP transit query to VIP 192.170.2.100',
          });
        }

        // BGP UDN Export link (Act 2): if pod is 'udn-web' in udn-bgp, link to edge1
        if (cluster === 'c1' && nsName === 'udn-bgp') {
          edges.push({
            id: `bgp-export-${podId}`,
            from: podId,
            to: 'evpn-edge1',
            color: { color: '#2ea043aa', opacity: 0.7 },
            width: 1.5,
            dashes: [4, 4],
            label: 'BGP: 192.170.10.0/24',
            font: { size: 9, color: '#2ea043', strokeWidth: 2, strokeColor: '#0d1117', face: 'monospace' },
            title: 'BGP Route: 192.170.10.0/24 advertised into default VRF (no EVPN)',
          });
        }
      });
    });
  });

  // 3. EVPN Stretched L2 link between vm-a (C1) and vm-b (C2)
  const c1VM = (topo.workloads || []).find(w => w.cluster === 'c1' && w.name.includes('vm-a') && w.state === 'Running');
  const c2VM = (topo.workloads || []).find(w => w.cluster === 'c2' && w.name.includes('vm-b') && w.state === 'Running');

  if (c1VM && c2VM) {
    edges.push({
      id: `l2-stretch-${c1VM.name}-${c2VM.name}`,
      from: c1VM.name,
      to: c2VM.name,
      color: { color: '#58a6ffcc', opacity: 0.9 },
      width: 2.5,
      dashes: [6, 4],
      label: 'EVPN Stretched L2 (VNI 110 • 192.170.1.0/24)',
      font: { size: 10, color: '#58a6ff', strokeWidth: 3, strokeColor: '#0d1117', face: 'monospace', align: 'center' },
      smooth: { type: 'curvedCW', roundness: 0.08 },
      title: 'EVPN MAC-VRF: Stretched L2 Subnet 192.170.1.0/24 (VNI 110, RT 64512:110)',
    });
  }

  // 4. Invisible boundary anchors to guarantee vis-network.fit() always frames the entire topology
  nodes.push({ id: '__anchor_tl__', x: -500, y: -320, size: 0, shape: 'dot', color: 'rgba(0,0,0,0)', hidden: false });
  nodes.push({ id: '__anchor_br__', x: 500, y: 290, size: 0, shape: 'dot', color: 'rgba(0,0,0,0)', hidden: false });
}

function updateGraph(topo) {
  const nodes = [];
  const edges = [];

  const ipMap = buildIPMap(topo);

  // 1. Cluster nodes (control-plane, worker)
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

  // 2. Provider Edges
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

  // 3. Transit network node + links
  if (topo.transit_subnet && topo.edges && topo.edges.length >= 2) {
    const e1 = topo.edges[0];
    const e2 = topo.edges[1];
    nodes.push({
      id: 'evpn-transit',
      label: topo.transit_subnet,
      x: 0,
      y: 260,
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

  // 4. Add namespaces, UDNs, pods, and MetalLB elements
  addClusterElementsToGraph(topo, nodes, edges);

  // 5. BGP Sessions (lines between nodes and edges, edge1 <-> edge2)
  (topo.bgp || []).forEach(session => {
    const localNode = session.local;
    const remoteName = ipMap[session.remote] || session.remote_name || session.remote;
    if (!localNode || !remoteName) return;

    const edgeId = localNode + '-' + remoteName;

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

  // Synchronize vis DataSets
  const newNodeIds = new Set(nodes.map(n => n.id));
  const deadNodes = [];
  topologyData.nodes.forEach(n => {
    if (!newNodeIds.has(n.id)) deadNodes.push(n.id);
  });
  if (deadNodes.length > 0) topologyData.nodes.remove(deadNodes);
  topologyData.nodes.update(nodes);

  const newEdgeIds = new Set(edges.map(e => e.id));
  const deadEdges = [];
  topologyData.edges.forEach(e => {
    if (!newEdgeIds.has(e.id)) deadEdges.push(e.id);
  });
  if (deadEdges.length > 0) topologyData.edges.remove(deadEdges);
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

  for (let i = 0; i < event.path.length - 1; i++) {
    const a = event.path[i];
    const b = event.path[i + 1];
    const id1 = a + '-' + b;
    const id2 = b + '-' + a;
    if (edges.get(id1)) edgeIds.push(id1);
    else if (edges.get(id2)) edgeIds.push(id2);
  }

  if (edgeIds.length === 0) return;

  edgeIds.forEach(id => animatedEdges.add(id));

  const label = event.type === 'type2' ? ' NEW ROUTE ' : ' IMET ';

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

  let pulseOn = true;
  const pulseInterval = setInterval(() => {
    pulseOn = !pulseOn;
    const opacity = pulseOn ? 1.0 : 0.25;
    edgeIds.forEach(id => {
      edges.update({ id: id, color: { color: '#d29922', opacity: opacity } });
    });
  }, 350);

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
