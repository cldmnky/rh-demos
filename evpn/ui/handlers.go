package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"

	"github.com/cldmnky/rh-demos/evpn/ui/collectors"
)

type createWorkloadReq struct {
	Cluster string `json:"cluster"`  // "c1" or "c2"
	Name    string `json:"name"`     // "vm-c"
	CUDNIP  string `json:"cudn_ip"`  // e.g. "192.170.1.30" (optional)
}

func handleCreateWorkload(w http.ResponseWriter, r *http.Request) {
	var req createWorkloadReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	req.Cluster = strings.ToLower(strings.TrimSpace(req.Cluster))
	req.Name = strings.ToLower(strings.TrimSpace(req.Name))
	req.CUDNIP = strings.TrimSpace(req.CUDNIP)

	if req.Cluster != "c1" && req.Cluster != "c2" {
		http.Error(w, "invalid cluster, must be c1 or c2", http.StatusBadRequest)
		return
	}
	if req.Name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}

	// Map cluster label to control plane node
	cpNode := "evpn-cluster1-control-plane"
	workerNode := "evpn-cluster1-worker"
	if req.Cluster == "c2" {
		cpNode = "evpn-cluster2-control-plane"
		workerNode = "evpn-cluster2-worker"
	}

	// Prepare overrides
	overrides := map[string]interface{}{
		"spec": map[string]interface{}{
			"nodeSelector": map[string]string{
				"kubernetes.io/hostname": workerNode,
			},
		},
	}

	if req.CUDNIP != "" {
		cidr := req.CUDNIP
		if !strings.Contains(cidr, "/") {
			cidr = cidr + "/24"
		}
		// For primary CUDN preconfigured IP assignment
		cudnKey := "vm-workloads/stretched-l2"
		pnAnn := fmt.Sprintf(`{"%s":{"ip_addresses":["%s"]}}`, cudnKey, cidr)
		overrides["metadata"] = map[string]interface{}{
			"annotations": map[string]string{
				"k8s.ovn.org/pod-networks": pnAnn,
			},
		}
	}

	overridesJSON, _ := json.Marshal(overrides)

	cmd := []string{
		"kubectl", "run", req.Name,
		"-n", "vm-workloads",
		"--image=registry.k8s.io/e2e-test-images/agnhost:2.66.1",
		"--overrides=" + string(overridesJSON),
		"--", "sleep", "infinity",
	}

	out, err := collectors.ContainerExec(r.Context(), cpNode, cmd)
	if err != nil {
		log.Printf("Create workload failed on %s: %v, out: %s", cpNode, err, out)
		http.Error(w, fmt.Sprintf("failed to run pod: %v, out: %s", err, out), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"created"}`))
}

func handleDeleteWorkload(w http.ResponseWriter, r *http.Request) {
	cluster := r.PathValue("cluster")
	name := r.PathValue("name")

	cluster = strings.ToLower(strings.TrimSpace(cluster))
	name = strings.ToLower(strings.TrimSpace(name))

	if cluster != "c1" && cluster != "c2" {
		http.Error(w, "invalid cluster, must be c1 or c2", http.StatusBadRequest)
		return
	}
	if name == "" {
		http.Error(w, "name is required", http.StatusBadRequest)
		return
	}

	cpNode := "evpn-cluster1-control-plane"
	if cluster == "c2" {
		cpNode = "evpn-cluster2-control-plane"
	}

	cmd := []string{"kubectl", "delete", "pod", name, "-n", "vm-workloads", "--grace-period=0", "--force"}
	out, err := collectors.ContainerExec(r.Context(), cpNode, cmd)
	if err != nil {
		log.Printf("Delete workload failed on %s: %v, out: %s", cpNode, err, out)
		http.Error(w, fmt.Sprintf("failed to delete pod: %v, out: %s", err, out), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status":"deleted"}`))
}

func handlePingStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	fromCluster := r.URL.Query().Get("from_cluster") // "c1" or "c2"
	fromPod := r.URL.Query().Get("from_pod")         // "vm-a"
	toIP := r.URL.Query().Get("to_ip")               // "192.170.1.11"

	fromCluster = strings.ToLower(strings.TrimSpace(fromCluster))
	fromPod = strings.ToLower(strings.TrimSpace(fromPod))
	toIP = strings.TrimSpace(toIP)

	if fromCluster != "c1" && fromCluster != "c2" {
		http.Error(w, "invalid from_cluster, must be c1 or c2", http.StatusBadRequest)
		return
	}
	if fromPod == "" || toIP == "" {
		http.Error(w, "missing from_pod or to_ip", http.StatusBadRequest)
		return
	}

	cpNode := "evpn-cluster1-control-plane"
	if fromCluster == "c2" {
		cpNode = "evpn-cluster2-control-plane"
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	flusher.Flush()

	// Exec ping 10 times, interval 0.5s
	cmd := []string{"kubectl", "exec", "-n", "vm-workloads", fromPod, "--", "ping", "-c", "10", "-i", "0.5", toIP}

	stream, err := collectors.ContainerExecStream(r.Context(), cpNode, cmd)
	if err != nil {
		fmt.Fprintf(w, "data: Error starting stream: %v\n\n", err)
		flusher.Flush()
		return
	}
	defer stream.Close()

	scanner := bufio.NewScanner(stream)
	for scanner.Scan() {
		line := scanner.Text()
		fmt.Fprintf(w, "data: %s\n\n", line)
		flusher.Flush()
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(w, "data: Stream read error: %v\n\n", err)
		flusher.Flush()
	}
}

func handleNodeFDB(w http.ResponseWriter, r *http.Request) {
	nodeName := r.PathValue("name")
	if nodeName == "" {
		http.Error(w, "node name is required", http.StatusBadRequest)
		return
	}

	// Exec bridge fdb show
	cmd := []string{"bridge", "fdb", "show", "dev", "evbr-evpn-vtep"}
	out, err := collectors.ContainerExec(r.Context(), nodeName, cmd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func handleNodeNeigh(w http.ResponseWriter, r *http.Request) {
	nodeName := r.PathValue("name")
	if nodeName == "" {
		http.Error(w, "node name is required", http.StatusBadRequest)
		return
	}

	// The L2 SVI VLAN id depends on the node's allocation order (svl2.1,
	// svl2.2, ...), so resolve the first matching interface dynamically.
	cmd := []string{"bash", "-c",
		`dev=$(ip -br link | awk -F'@' '/^svl2\./{print $1; exit}'); ` +
			`if [ -n "$dev" ]; then echo "# SVI $dev"; ip neigh show dev "$dev"; ` +
			`else echo "no svl2.* interface found"; fi`}
	out, err := collectors.ContainerExec(r.Context(), nodeName, cmd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func handleNodeDevices(w http.ResponseWriter, r *http.Request) {
	nodeName := r.PathValue("name")
	if nodeName == "" {
		http.Error(w, "node name is required", http.StatusBadRequest)
		return
	}

	cmd := []string{"bash", "-c", "ip -j link show type bridge 2>/dev/null; echo '---'; ip -j link show type vxlan 2>/dev/null"}
	out, err := collectors.ContainerExec(r.Context(), nodeName, cmd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func handleEdgeRoutes(w http.ResponseWriter, r *http.Request) {
	edgeName := r.PathValue("name")
	if edgeName != "evpn-edge1" && edgeName != "evpn-edge2" {
		http.Error(w, "invalid edge, must be evpn-edge1 or evpn-edge2", http.StatusBadRequest)
		return
	}

	cmd := []string{"vtysh", "-c", "show bgp l2vpn evpn"}
	out, err := collectors.ContainerExec(r.Context(), edgeName, cmd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// clean up config error if present
	idx := strings.Index(string(out), "Route Distinguisher:")
	if idx >= 0 {
		out = out[idx:]
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

func handleClusterResources(w http.ResponseWriter, r *http.Request) {
	cluster := r.PathValue("cluster")
	cluster = strings.ToLower(strings.TrimSpace(cluster))

	if cluster != "c1" && cluster != "c2" {
		http.Error(w, "invalid cluster, must be c1 or c2", http.StatusBadRequest)
		return
	}

	cpNode := "evpn-cluster1-control-plane"
	if cluster == "c2" {
		cpNode = "evpn-cluster2-control-plane"
	}

	// OVN-K/frr-k8s resources plus (when installed) the MetalLB BGP service
	// resources and LoadBalancer services. The MetalLB part degrades to a
	// short note instead of failing the whole diagnostics view.
	cmd := []string{"bash", "-c",
		`kubectl get vtep,cudn,routeadvertisements,frrconfiguration -A -o wide; ` +
			`echo; echo '--- MetalLB ---'; ` +
			`kubectl get ipaddresspool,bgppeer,bgpadvertisement -n metallb-system -o wide 2>/dev/null ` +
			`|| echo 'MetalLB not installed'; ` +
			`echo; echo '--- LoadBalancer services ---'; ` +
			`kubectl get svc -A --field-selector spec.type=LoadBalancer`}
	out, err := collectors.ContainerExec(r.Context(), cpNode, cmd)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to get resources: %v, out: %s", err, out), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}

// handleEdgeVIPRoute shows how a single VIP /32 is present in one provider
// edge's IPv4 unicast RIB (used by the BGP Services panel drill-down).
func handleEdgeVIPRoute(w http.ResponseWriter, r *http.Request) {
	edgeName := r.PathValue("name")
	vip := strings.TrimSpace(r.PathValue("ip"))

	if edgeName != "evpn-edge1" && edgeName != "evpn-edge2" {
		http.Error(w, "invalid edge, must be evpn-edge1 or evpn-edge2", http.StatusBadRequest)
		return
	}
	if net.ParseIP(vip) == nil {
		http.Error(w, "invalid IP address", http.StatusBadRequest)
		return
	}

	cmd := []string{"vtysh", "-c", "show bgp ipv4 unicast " + vip + "/32"}
	out, err := collectors.ContainerExec(r.Context(), edgeName, cmd)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/plain")
	w.Write(out)
}
