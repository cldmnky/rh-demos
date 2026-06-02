package collectors

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/cldmnky/rh-demos/evpn/ui/model"
)

type frrCollector struct {
	cfg Config
}

func newFrrCollector(cfg Config) *frrCollector {
	return &frrCollector{cfg: cfg}
}

func (f *frrCollector) collectBGP(ctx context.Context) []model.BGPSession {
	var sessions []model.BGPSession
	for _, edge := range []string{"evpn-edge1", "evpn-edge2"} {
		sessions = append(sessions, f.bgpSessions(ctx, edge)...)
	}
	return sessions
}

func (f *frrCollector) collectEVPN(ctx context.Context) model.EVPNState {
	state := model.EVPNState{}
	seenVNI := map[int]bool{}

	vnis, type2, type3 := f.evpnState(ctx, "evpn-edge1")
	for _, v := range vnis {
		if !seenVNI[v.VNI] {
			seenVNI[v.VNI] = true
			state.VNIs = append(state.VNIs, v)
		}
	}
	state.Type2Count = type2
	state.Type3Count = type3

	if len(state.VNIs) == 0 {
		state.VNIs = []model.VNI{{
			VNI:         110,
			RD:          "10.244.0.2:2",
			RT:          "64512:110",
			RemoteVTEPs: []string{},
		}}
	}

	return state
}

func (f *frrCollector) bgpSessions(ctx context.Context, edge string) []model.BGPSession {
	ctx2, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	out, err := ContainerExecJSON(ctx2, edge, []string{"vtysh", "-c", "show bgp summary json"})
	if err != nil {
		log.Printf("vtysh bgp summary %s: %v", edge, err)
		return nil
	}

	type jsonBGP struct {
		IPv4Unicast struct {
			Peers map[string]struct {
				Hostname   string `json:"hostname"`
				RemoteAs   int    `json:"remoteAs"`
				State      string `json:"state"`
				PeerUptime string `json:"peerUptime"`
				PfxRcd     int    `json:"pfxRcd"`
				PfxSnt     int    `json:"pfxSnt"`
			} `json:"peers"`
		} `json:"ipv4Unicast"`
	}

	var bgp jsonBGP
	if json.Unmarshal(out, &bgp) != nil {
		return nil
	}

	var sessions []model.BGPSession
	for addr, peer := range bgp.IPv4Unicast.Peers {
		peerType := "node"
		if addr == "10.89.0.100" || addr == "10.89.0.101" {
			peerType = "edge"
		}
		sessions = append(sessions, model.BGPSession{
			Local:    edge,
			Remote:   addr,
			State:    peer.State,
			Uptime:   peer.PeerUptime,
			PfxRcd:   peer.PfxRcd,
			PeerType: peerType,
		})
	}
	return sessions
}

func (f *frrCollector) evpnState(ctx context.Context, edge string) (vnis []model.VNI, type2Count int, type3Count int) {
	ctx2, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	out, err := ContainerExecJSON(ctx2, edge, []string{"vtysh", "-c", "show bgp l2vpn evpn json"})
	if err != nil {
		log.Printf("vtysh bgp evpn %s: %v", edge, err)
		return
	}

	var raw map[string]interface{}
	if json.Unmarshal(out, &raw) != nil {
		return
	}

	knownKeys := map[string]bool{
		"bgpTableVersion":    true,
		"bgpLocalRouterId":   true,
		"defaultLocPrf":      true,
		"localAS":            true,
		"totalPrefixCounter": true,
		"failedToParseCounter": true,
	}

	vtepSet := map[string]bool{}
	for key, val := range raw {
		if knownKeys[key] {
			continue
		}
		entry, ok := val.(map[string]interface{})
		if !ok {
			continue
		}

		for routeKey, routeVal := range entry {
			if routeKey == "rd" {
				continue
			}
			route, ok := routeVal.(map[string]interface{})
			if !ok {
				continue
			}
			paths, ok := route["paths"].([]interface{})
			if !ok {
				continue
			}
			for _, p := range paths {
				path, ok := p.(map[string]interface{})
				if !ok {
					continue
				}
				rt, _ := path["routeType"].(float64)
				switch int(rt) {
				case 2:
					type2Count++
				case 3:
					type3Count++
				}

				if peer, ok := path["peerId"].(string); ok && peer != "" {
					vtepSet[peer] = true
				}
			}
		}
	}

	var remoteVTEPs []string
	for vtep := range vtepSet {
		remoteVTEPs = append(remoteVTEPs, vtep)
	}
	vnis = append(vnis, model.VNI{
		VNI:         110,
		RD:          "10.244.0.2:2",
		RT:          "64512:110",
		RemoteVTEPs: remoteVTEPs,
	})
	return vnis, type2Count, type3Count
}

func (f *frrCollector) evpnVNI(ctx context.Context, edge string) []model.VNI {
	ctx2, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	out, err := ContainerExecJSON(ctx2, edge, []string{"vtysh", "-c", "show evpn vni json"})
	if err == nil {
		var raw map[string]interface{}
		if json.Unmarshal(out, &raw) == nil && len(raw) > 0 {
			var result []model.VNI
			for _, v := range raw {
				entry, ok := v.(map[string]interface{})
				if !ok {
					continue
				}
				vni := model.VNI{RT: "64512:110"}
				if vniVal, ok := entry["vni"]; ok {
					switch n := vniVal.(type) {
					case float64:
						vni.VNI = int(n)
					case int:
						vni.VNI = n
					}
				}
				if rdVal, ok := entry["rd"]; ok {
					vni.RD = fmt.Sprintf("%v", rdVal)
				}
				if rtVal, ok := entry["exportRT"]; ok {
					vni.RT = fmt.Sprintf("%v", rtVal)
				}
				result = append(result, vni)
			}
			return result
		}
	}
	return nil
}
