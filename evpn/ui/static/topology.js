// EVPN UI — Topology Graph (vis-network) with Click Drilling and Groups

let network = null;
let topologyData = {nodes: new vis.DataSet(), edges: new vis.DataSet()};
let initialized = false;
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
    drawGroupBackdrop(ctx, -410, -170, 260, 120, "Cluster 1 (East)", COLORS.c1);
    drawGroupBackdrop(ctx, 150, -170, 260, 120, "Cluster 2 (West)", COLORS.c2);
    drawGroupBackdrop(ctx, -340, 40, 680, 120, "Provider Edge Core (BGP EVPN)", COLORS.edge);
  });

  // Drill Down Click Listener
  network.on("click", function (params) {
    if (params.nodes.length > 0) {
      const nodeId = params.nodes[0];
      if (nodeId.startsWith("evpn-edge")) {
        showEdgeDetails(nodeId);
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
  ctx.fillStyle = color + '0a'; // very low opacity background (e.g. 4% opacity)
  ctx.strokeStyle = color + '22'; // dashed border (e.g. 13% opacity)
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);

  // Draw rounded rect
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

  // Draw group label
  ctx.setLineDash([]);
  ctx.fillStyle = color + 'aa';
  ctx.font = 'bold 11px monospace';
  ctx.fillText(label.toUpperCase(), x + 12, y + 20);
  ctx.restore();
}

function updateGraph(topo) {
  const nodes = [];
  const edges = [];

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

  (topo.bgp || []).forEach(session => {
    const localNode = session.local;
    const remoteNode = session.remote;
    if (!localNode || !remoteNode) return;

    const color = session.state === 'Up' || session.state === 'Established'
      ? '#3fb950' : (session.state === 'Active' ? '#d29922' : '#f85149');
    const dashes = session.state !== 'Up' && session.state !== 'Established';

    edges.push({
      id: localNode + '-' + remoteNode,
      from: localNode,
      to: remoteNode,
      color: { color: color, opacity: 0.6 },
      dashes: dashes,
      title: `${localNode} ↔ ${remoteNode}\n${session.state} | uptime: ${session.uptime}\nprefixes: ${session.pfx_rcd}`,
    });
  });

  topologyData.nodes.update(nodes);
  topologyData.edges.update(edges);

  if (!initialized) {
    network.fit({ animation: { duration: 500 } });
  }
}

function resizeObserver(el) {
  new ResizeObserver(() => {
    if (network) {
      network.redraw();
      network.fit({ animation: false });
    }
  }).observe(el);
}
