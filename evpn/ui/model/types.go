package model

import "time"

type Topology struct {
	Clusters       []Cluster    `json:"clusters"`
	Edges          []Edge       `json:"edges"`
	Workloads      []Workload   `json:"workloads"`
	BGP            []BGPSession `json:"bgp"`
	EVPN           EVPNState    `json:"evpn"`
	RouteEvents    []RouteEvent `json:"route_events,omitempty"`
	TransitSubnet  string       `json:"transit_subnet,omitempty"`
	GeneratedAt    time.Time    `json:"generated_at"`
}

type RouteEvent struct {
	Type    string   `json:"type"`    // "type2" or "type3"
	VNI     int      `json:"vni"`
	Source  string   `json:"source"`  // originating node name
	Cluster string   `json:"cluster"` // "c1" or "c2"
	Path    []string `json:"path"`    // propagation hop sequence
}

type Cluster struct {
	Name  string `json:"name"`
	Nodes []Node `json:"nodes"`
}

type Node struct {
	Name    string   `json:"name"`
	Role    string   `json:"role"`
	IP      string   `json:"ip"`
	KindIP  string   `json:"kind_ip"`
	Devices []Device `json:"devices,omitempty"`
}

type Device struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
	VNI  int    `json:"vni,omitempty"`
}

type Edge struct {
	Name       string `json:"name"`
	IP         string `json:"ip"`
	TransitIP  string `json:"transit_ip,omitempty"`
	Role       string `json:"role"`
	State      string `json:"state"`
	AS         int    `json:"as"`
}

type Workload struct {
	Name      string `json:"name"`
	Cluster   string `json:"cluster"`
	Namespace string `json:"namespace"`
	Node      string `json:"node"`
	CUDNIP    string `json:"cudn_ip"`
	MAC       string `json:"mac"`
	State     string `json:"state"`
	Age       string `json:"age"`
}

type BGPSession struct {
	Local      string `json:"local"`
	Remote     string `json:"remote"`
	RemoteName string `json:"remote_name,omitempty"`
	State      string `json:"state"`
	Uptime     string `json:"uptime"`
	PfxRcd     int    `json:"pfx_rcd"`
	PeerType   string `json:"peer_type"`
}

type EVPNState struct {
	VNIs       []VNI       `json:"vnis"`
	Type2Count int         `json:"type2_count"`
	Type3Count int         `json:"type3_count"`
	Routes     []EVPNRoute `json:"routes"`
}

type VNI struct {
	VNI         int      `json:"vni"`
	RD          string   `json:"rd"`
	RT          string   `json:"rt"`
	RemoteVTEPs []string `json:"remote_vteps"`
}

type EVPNRoute struct {
	Type      int    `json:"type"`
	MAC       string `json:"mac,omitempty"`
	IP        string `json:"ip,omitempty"`
	IPLen     int    `json:"ip_len,omitempty"`
	NextHop   string `json:"next_hop"`
	PeerID    string `json:"peer_id"`
	RemoteVTEP string `json:"remote_vtep,omitempty"`
	VNI       int    `json:"vni"`
}
