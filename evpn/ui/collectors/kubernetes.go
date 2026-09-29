package collectors

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

var systemNamespaces = map[string]bool{
	"kube-system":        true,
	"kube-public":        true,
	"kube-node-lease":    true,
	"ovn-kubernetes":     true,
	"ovn-host-network":   true,
	"local-path-storage": true,
	"metallb-system":     true,
	"frr-k8s-system":     true,
}

type k8sCollector struct {
	cfg          Config
	execWithKcfg func(ctx context.Context, cluster, node string, cmd ...string) ([]byte, error)
}

func newK8sCollector(cfg Config) *k8sCollector {
	return &k8sCollector{cfg: cfg}
}

func (k *k8sCollector) setExec(fn func(ctx context.Context, cluster, node string, cmd ...string) ([]byte, error)) {
	k.execWithKcfg = fn
}

func (k *k8sCollector) clusterLabel(clusterName string) string {
	if clusterName == k.cfg.Cluster2Name {
		return "c2"
	}
	return "c1"
}

func (k *k8sCollector) cpNode(clusterName string) string {
	return clusterName + "-control-plane"
}

// collectWorkloads gathers all demo / tenant pods across all non-system namespaces.
func (k *k8sCollector) collectWorkloads(ctx context.Context) []model.Workload {
	var (
		mu        sync.Mutex
		workloads []model.Workload
		wg        sync.WaitGroup
	)

	for _, clusterName := range []string{k.cfg.Cluster1Name, k.cfg.Cluster2Name} {
		clusterName := clusterName
		wg.Add(1)
		go func() {
			defer wg.Done()
			cpNode := k.cpNode(clusterName)
			clusterLabel := k.clusterLabel(clusterName)

			out, err := k.execWithKcfg(ctx, clusterName, cpNode,
				"kubectl", "get", "pods", "-A", "-o", "json")
			if err != nil {
				log.Printf("workloads %s: %v", clusterName, err)
				return
			}

			var podList struct {
				Items []struct {
					Metadata struct {
						Name              string            `json:"name"`
						Namespace         string            `json:"namespace"`
						CreationTimestamp string            `json:"creationTimestamp"`
						Annotations       map[string]string `json:"annotations"`
					} `json:"metadata"`
					Spec struct {
						NodeName    string `json:"nodeName"`
						HostNetwork bool   `json:"hostNetwork"`
					} `json:"spec"`
					Status struct {
						Phase string `json:"phase"`
						PodIP string `json:"podIP"`
					} `json:"status"`
				} `json:"items"`
			}

			if json.Unmarshal(out, &podList) != nil {
				return
			}

			var localWls []model.Workload
			for _, pod := range podList.Items {
				ns := pod.Metadata.Namespace
				if systemNamespaces[ns] {
					continue
				}

				ip, mac, netName, netType := parsePodNetwork(pod.Metadata.Annotations, pod.Status.PodIP, pod.Spec.HostNetwork)
				age := formatAge(time.Now(), pod.Metadata.CreationTimestamp)

				name := pod.Metadata.Name
				// For deployment pods like web-6b9fc47949-slfl4, keep clean short name
				if strings.HasPrefix(name, "vm-") {
					parts := strings.Split(name, "-")
					if len(parts) >= 3 {
						name = strings.Join(parts[:2], "-")
					}
				} else if strings.HasPrefix(name, "web-") {
					name = "web"
				}

				localWls = append(localWls, model.Workload{
					Name:      name,
					Cluster:   clusterLabel,
					Namespace: ns,
					Node:      pod.Spec.NodeName,
					CUDNIP:    ip,
					MAC:       mac,
					Network:   netName,
					NetType:   netType,
					State:     pod.Status.Phase,
					Age:       age,
				})
			}

			mu.Lock()
			workloads = append(workloads, localWls...)
			mu.Unlock()
		}()
	}

	wg.Wait()
	return workloads
}

// collectNamespaces gathers tenant and demo namespaces on each cluster.
func (k *k8sCollector) collectNamespaces(ctx context.Context) []model.NamespaceInfo {
	var (
		mu         sync.Mutex
		namespaces []model.NamespaceInfo
		wg         sync.WaitGroup
	)

	for _, clusterName := range []string{k.cfg.Cluster1Name, k.cfg.Cluster2Name} {
		clusterName := clusterName
		wg.Add(1)
		go func() {
			defer wg.Done()
			cpNode := k.cpNode(clusterName)
			clusterLabel := k.clusterLabel(clusterName)

			out, err := k.execWithKcfg(ctx, clusterName, cpNode,
				"kubectl", "get", "namespaces", "-o", "json")
			if err != nil {
				return
			}

			var nsList struct {
				Items []struct {
					Metadata struct {
						Name   string            `json:"name"`
						Labels map[string]string `json:"labels"`
					} `json:"metadata"`
				} `json:"items"`
			}

			if json.Unmarshal(out, &nsList) != nil {
				return
			}

			var localNs []model.NamespaceInfo
			for _, ns := range nsList.Items {
				name := ns.Metadata.Name
				if systemNamespaces[name] {
					continue
				}

				_, isPrimaryUDN := ns.Metadata.Labels["k8s.ovn.org/primary-user-defined-network"]
				primaryStr := ""
				if isPrimaryUDN {
					primaryStr = "primary"
				}

				localNs = append(localNs, model.NamespaceInfo{
					Cluster:    clusterLabel,
					Name:       name,
					PrimaryUDN: primaryStr,
				})
			}

			mu.Lock()
			namespaces = append(namespaces, localNs...)
			mu.Unlock()
		}()
	}

	wg.Wait()
	return namespaces
}

// collectUDNs gathers UserDefinedNetworks and ClusterUserDefinedNetworks on each cluster.
func (k *k8sCollector) collectUDNs(ctx context.Context) []model.UDNInfo {
	var (
		mu   sync.Mutex
		udns []model.UDNInfo
		wg   sync.WaitGroup
	)

	for _, clusterName := range []string{k.cfg.Cluster1Name, k.cfg.Cluster2Name} {
		clusterName := clusterName
		wg.Add(1)
		go func() {
			defer wg.Done()
			cpNode := k.cpNode(clusterName)
			clusterLabel := k.clusterLabel(clusterName)

			// 1. Collect RouteAdvertisements to mark which UDNs/CUDNs are advertised
			advertisedNetworks := make(map[string]bool)
			raOut, err := k.execWithKcfg(ctx, clusterName, cpNode,
				"kubectl", "get", "routeadvertisements", "-o", "json")
			if err == nil {
				var raList struct {
					Items []struct {
						Metadata struct {
							Name string `json:"name"`
						} `json:"metadata"`
						Status struct {
							Conditions []struct {
								Type   string `json:"type"`
								Status string `json:"status"`
							} `json:"conditions"`
						} `json:"status"`
					} `json:"items"`
				}
				if json.Unmarshal(raOut, &raList) == nil {
					for _, ra := range raList.Items {
						isAccepted := false
						for _, cond := range ra.Status.Conditions {
							if cond.Type == "Accepted" && cond.Status == "True" {
								isAccepted = true
								break
							}
						}
						// Match naming conventions: udn-bgp-ra -> bgp-l2, evpn-ra -> stretched-l2
						if isAccepted {
							advertisedNetworks[ra.Metadata.Name] = true
							if strings.Contains(ra.Metadata.Name, "bgp") {
								advertisedNetworks["bgp-l2"] = true
							}
							if strings.Contains(ra.Metadata.Name, "evpn") {
								advertisedNetworks["stretched-l2"] = true
							}
						}
					}
				}
			}

			var localUDNs []model.UDNInfo

			// 2. Collect namespaced UDNs
			udnOut, err := k.execWithKcfg(ctx, clusterName, cpNode,
				"kubectl", "get", "userdefinednetworks", "-A", "-o", "json")
			if err == nil {
				var list struct {
					Items []struct {
						Metadata struct {
							Name      string `json:"name"`
							Namespace string `json:"namespace"`
						} `json:"metadata"`
						Spec struct {
							Topology string `json:"topology"`
							Layer3   struct {
								Role    string `json:"role"`
								Subnets []struct {
									CIDR string `json:"cidr"`
								} `json:"subnets"`
							} `json:"layer3"`
							Layer2 struct {
								Role    string   `json:"role"`
								Subnets []string `json:"subnets"`
							} `json:"layer2"`
						} `json:"spec"`
						Status struct {
							Conditions []struct {
								Type   string `json:"type"`
								Status string `json:"status"`
							} `json:"conditions"`
						} `json:"status"`
					} `json:"items"`
				}
				if json.Unmarshal(udnOut, &list) == nil {
					for _, u := range list.Items {
						role := u.Spec.Layer3.Role
						if role == "" {
							role = u.Spec.Layer2.Role
						}
						if role == "" {
							role = "Primary"
						}

						var subnets []string
						for _, s := range u.Spec.Layer3.Subnets {
							if s.CIDR != "" {
								subnets = append(subnets, s.CIDR)
							}
						}
						if len(subnets) == 0 {
							subnets = u.Spec.Layer2.Subnets
						}

						status := "Ready"
						for _, cond := range u.Status.Conditions {
							if cond.Type == "NetworkCreated" && cond.Status != "True" {
								status = "Pending"
							}
						}

						localUDNs = append(localUDNs, model.UDNInfo{
							Cluster:    clusterLabel,
							Name:       u.Metadata.Name,
							Namespace:  u.Metadata.Namespace,
							Scope:      "Namespace",
							Topology:   u.Spec.Topology,
							Role:       role,
							Subnets:    subnets,
							Advertised: advertisedNetworks[u.Metadata.Name],
							Status:     status,
						})
					}
				}
			}

			// 3. Collect cluster-scoped CUDNs
			cudnOut, err := k.execWithKcfg(ctx, clusterName, cpNode,
				"kubectl", "get", "clusteruserdefinednetworks", "-o", "json")
			if err == nil {
				var list struct {
					Items []struct {
						Metadata struct {
							Name   string            `json:"name"`
							Labels map[string]string `json:"labels"`
						} `json:"metadata"`
						Spec struct {
							NamespaceSelector struct {
								MatchLabels map[string]string `json:"matchLabels"`
							} `json:"namespaceSelector"`
							Network struct {
								Topology string `json:"topology"`
								Layer2   struct {
									Role    string   `json:"role"`
									Subnets []string `json:"subnets"`
								} `json:"layer2"`
								Layer3 struct {
									Role    string `json:"role"`
									Subnets []struct {
										CIDR string `json:"cidr"`
									} `json:"subnets"`
								} `json:"layer3"`
								Transport string `json:"transport"`
								EVPN      struct {
									MacVRF struct {
										VNI int `json:"vni"`
									} `json:"macVRF"`
								} `json:"evpn"`
							} `json:"network"`
						} `json:"spec"`
						Status struct {
							Conditions []struct {
								Type   string `json:"type"`
								Status string `json:"status"`
							} `json:"conditions"`
						} `json:"status"`
					} `json:"items"`
				}
				if json.Unmarshal(cudnOut, &list) == nil {
					for _, c := range list.Items {
						targetNs := c.Spec.NamespaceSelector.MatchLabels["kubernetes.io/metadata.name"]

						role := c.Spec.Network.Layer2.Role
						if role == "" {
							role = c.Spec.Network.Layer3.Role
						}
						if role == "" {
							role = "Primary"
						}

						subnets := c.Spec.Network.Layer2.Subnets
						if len(subnets) == 0 {
							for _, s := range c.Spec.Network.Layer3.Subnets {
								if s.CIDR != "" {
									subnets = append(subnets, s.CIDR)
								}
							}
						}

						status := "Ready"
						for _, cond := range c.Status.Conditions {
							if cond.Type == "NetworkCreated" && cond.Status != "True" {
								status = "Pending"
							}
						}

						vni := c.Spec.Network.EVPN.MacVRF.VNI
						transport := c.Spec.Network.Transport
						if transport == "" && vni > 0 {
							transport = "EVPN"
						}

						isAdv := advertisedNetworks[c.Metadata.Name] || c.Metadata.Labels["advertise"] == "bgp"

						localUDNs = append(localUDNs, model.UDNInfo{
							Cluster:    clusterLabel,
							Name:       c.Metadata.Name,
							Namespace:  targetNs,
							Scope:      "Cluster",
							Topology:   c.Spec.Network.Topology,
							Role:       role,
							Subnets:    subnets,
							Transport:  transport,
							VNI:        vni,
							Advertised: isAdv,
							Status:     status,
						})
					}
				}
			}

			mu.Lock()
			udns = append(udns, localUDNs...)
			mu.Unlock()
		}()
	}

	wg.Wait()
	return udns
}

// parsePodNetwork extracts primary network IP, MAC, and descriptive type.
func parsePodNetwork(annotations map[string]string, podIP string, hostNetwork bool) (ip string, mac string, netName string, netType string) {
	pnRaw, ok := annotations["k8s.ovn.org/pod-networks"]
	if !ok || pnRaw == "" {
		if hostNetwork {
			return podIP, "", "host", "hostNetwork"
		}
		if podIP != "" {
			return podIP, "", "default", "Cluster Network"
		}
		return "", "", "", ""
	}

	var pn map[string]interface{}
	if json.Unmarshal([]byte(pnRaw), &pn) != nil {
		return podIP, "", "default", "Cluster Network"
	}

	// 1. Look for entry with role == "primary"
	for key, val := range pn {
		entry, ok := val.(map[string]interface{})
		if !ok {
			continue
		}
		role, _ := entry["role"].(string)
		if role == "primary" {
			// Extract network name from key: "tenant-a/prod-net" -> "prod-net"
			netName = key
			if strings.Contains(key, "/") {
				parts := strings.Split(key, "/")
				netName = parts[len(parts)-1]
			}

			ip = extractIPFromEntry(entry)
			mac = extractMACFromEntry(entry, ip)

			if netName == "default" {
				netType = "Cluster Network"
			} else if strings.Contains(netName, "stretched") || strings.Contains(netName, "evpn") {
				netType = "EVPN L2"
			} else if strings.Contains(netName, "bgp") {
				netType = "Layer2 BGP"
			} else if strings.Contains(netName, "prod") || strings.Contains(ip, "103.103") {
				netType = "Layer3 UDN"
			} else {
				netType = "Primary UDN"
			}
			return ip, mac, netName, netType
		}
	}

	// 2. Check for any non-default network entry
	for key, val := range pn {
		if key == "default" {
			continue
		}
		entry, ok := val.(map[string]interface{})
		if !ok {
			continue
		}
		netName = key
		if strings.Contains(key, "/") {
			parts := strings.Split(key, "/")
			netName = parts[len(parts)-1]
		}
		ip = extractIPFromEntry(entry)
		mac = extractMACFromEntry(entry, ip)
		netType = "Secondary UDN"
		return ip, mac, netName, netType
	}

	// 3. Fall back to default network
	if defEntry, ok := pn["default"].(map[string]interface{}); ok {
		ip = extractIPFromEntry(defEntry)
		mac = extractMACFromEntry(defEntry, ip)
		return ip, mac, "default", "Cluster Network"
	}

	if hostNetwork {
		return podIP, "", "host", "hostNetwork"
	}
	return podIP, "", "default", "Cluster Network"
}

func extractIPFromEntry(entry map[string]interface{}) string {
	if ipAddr, ok := entry["ip_address"].(string); ok && ipAddr != "" {
		return strings.Split(ipAddr, "/")[0]
	}
	if ips, ok := entry["ip_addresses"].([]interface{}); ok && len(ips) > 0 {
		if firstIP, ok := ips[0].(string); ok && firstIP != "" {
			return strings.Split(firstIP, "/")[0]
		}
	}
	return ""
}

func extractMACFromEntry(entry map[string]interface{}, ip string) string {
	if mac, ok := entry["mac_address"].(string); ok && mac != "" {
		return mac
	}
	if mac, ok := entry["mac"].(string); ok && mac != "" {
		return mac
	}
	if ip != "" {
		return deriveMAC(ip)
	}
	return ""
}

func deriveMAC(ip string) string {
	parts := strings.Split(ip, "/")
	octets := strings.Split(parts[0], ".")
	if len(octets) != 4 {
		return ""
	}
	return "0a:58:" + octetHex(octets[0]) + ":" + octetHex(octets[1]) + ":" + octetHex(octets[2]) + ":" + octetHex(octets[3])
}

func octetHex(s string) string {
	n := 0
	for _, c := range s {
		n = n*10 + int(c-'0')
	}
	return padHex(n)
}

func padHex(n int) string {
	const hex = "0123456789abcdef"
	return string([]byte{hex[n>>4], hex[n&0xf]})
}

func formatAge(now time.Time, created string) string {
	t, err := time.Parse(time.RFC3339, created)
	if err != nil {
		return ""
	}
	d := now.Sub(t)
	if d < time.Minute {
		return d.Truncate(time.Second).String()
	}
	if d < time.Hour {
		return d.Truncate(time.Minute).String()
	}
	return d.Truncate(time.Hour).String()
}
