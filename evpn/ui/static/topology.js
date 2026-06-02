// EVPN UI — Topology Graph (vis-network)

let network = null;
let topologyData = {nodes: new vis.DataSet(), edges: new vis.DataSet()};
let initialized = false;
const POSITIONS = {
  'evpn-cluster1-control-plane': {x: -350, y: -100},
  'evpn-cluster1-worker':        {x: -250, y: -100},
  'evpn-cluster2-control-plane': {x: 250, y: -100},
  'evpn-cluster2-worker':        {x: 350, y: -100},
  'evpn-edge1':                  {x: -300, y: 100},
  'evpn-edge2':                  {x: 300, y: 100},
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
      smooth: { type: 'curvedCW', roundness: 0.2 },
    },
  };

  network = new vis.Network(container, topologyData, options);
  resizeObserver(container);
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
    const dashes = session.state !== 'Up';

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
