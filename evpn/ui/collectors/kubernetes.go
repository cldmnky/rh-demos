package collectors

import (
	"context"
	"encoding/json"
	"log"
	"strings"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

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

func (k *k8sCollector) collectWorkloads(ctx context.Context) []model.Workload {
	var workloads []model.Workload

	for _, clusterName := range []string{k.cfg.Cluster1Name, k.cfg.Cluster2Name} {
		cpNode := clusterName + "-control-plane"

		out, err := k.execWithKcfg(ctx, clusterName, cpNode,
			"kubectl", "get", "pods", "-n", "vm-workloads",
			"-o", "json", "--no-headers")
		if err != nil {
			log.Printf("workloads %s: %v", clusterName, err)
			continue
		}

		var podList struct {
			Items []struct {
				Metadata struct {
					Name              string `json:"name"`
					Namespace         string `json:"namespace"`
					CreationTimestamp string `json:"creationTimestamp"`
					Annotations       map[string]string `json:"annotations"`
				} `json:"metadata"`
				Spec struct {
					NodeName string `json:"nodeName"`
				} `json:"spec"`
				Status struct {
					Phase string `json:"phase"`
				} `json:"status"`
			} `json:"items"`
		}

		if json.Unmarshal(out, &podList) != nil {
			continue
		}

		clusterLabel := "c1"
		if clusterName == k.cfg.Cluster2Name {
			clusterLabel = "c2"
		}

		for _, pod := range podList.Items {
			cudnIP, mac := parseCUDNIP(pod.Metadata.Annotations, clusterName)
			age := formatAge(time.Now(), pod.Metadata.CreationTimestamp)

			name := pod.Metadata.Name
			if len(name) > 4 && strings.HasPrefix(name, "vm-") {
				// trim the random suffix: vm-a-58b7f... → vm-a
				parts := strings.Split(name, "-")
				if len(parts) >= 3 {
					name = strings.Join(parts[:2], "-")
				}
			}

			workloads = append(workloads, model.Workload{
				Name:      name,
				Cluster:   clusterLabel,
				Namespace: pod.Metadata.Namespace,
				Node:      pod.Spec.NodeName,
				CUDNIP:    cudnIP,
				MAC:       mac,
				State:     pod.Status.Phase,
				Age:       age,
			})
		}
	}

	return workloads
}

func parseCUDNIP(annotations map[string]string, clusterName string) (ip string, mac string) {
	pnRaw, ok := annotations["k8s.ovn.org/pod-networks"]
	if !ok {
		return "", ""
	}

	var pn map[string]interface{}
	if json.Unmarshal([]byte(pnRaw), &pn) != nil {
		return "", ""
	}

	key := "vm-workloads/stretched-l2"
	cudn, ok := pn[key].(map[string]interface{})
	if !ok {
		return "", ""
	}

	ips, _ := cudn["ip_addresses"].([]interface{})
	if len(ips) == 0 {
		return "", ""
	}
	ip = ips[0].(string)

	gatewayIPs, _ := cudn["gateway_ips"].([]interface{})
	if len(gatewayIPs) > 0 {
		_ = gatewayIPs
	}

	macAddrs, _ := cudn["mac_address"].(string)
	if macAddrs != "" {
		mac = macAddrs
	}

	macStr, _ := cudn["mac"].(string)
	if macStr != "" {
		mac = macStr
	}

	if mac == "" {
		mac = deriveMAC(ip)
	}

	return strings.TrimSuffix(ip, "/24"), mac
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
