package engine

import (
	"context"
	"time"

	"github.com/tailscale/tailcat"
)

// Path probing: the UI shows whether traffic is relayed (DERP) or direct.
// Probes run every few seconds while a session is active and only emit an
// event when something changed (or once a minute as a heartbeat).

const (
	probeInterval  = 5 * time.Second
	probeHeartbeat = 60 * time.Second
)

// clientPathProbe keeps disco-pinging, which also drives NAT traversal so a
// relayed connection upgrades to direct when possible.
func clientPathProbe(s *Session, cl *tailcat.Client, lastVia string) {
	lastEmit := time.Now()
	t := time.NewTicker(probeInterval)
	defer t.Stop()
	for {
		select {
		case <-s.Context().Done():
			return
		case <-t.C:
		}
		ctx, cancel := context.WithTimeout(s.Context(), probeInterval)
		pr, err := cl.DiscoPing(ctx)
		cancel()
		if err != nil {
			continue
		}
		via, detail := classifyPing(pr.Endpoint, pr.DERPRegionCode, int(pr.DERPRegionID))
		if via != lastVia || time.Since(lastEmit) > probeHeartbeat {
			lastVia = via
			lastEmit = time.Now()
			s.events.Push(Event{"type": EvPath, "session_id": s.ID, "via": via,
				"detail": detail, "latency_ms": pr.LatencySeconds * 1000})
		}
	}
}

// serverPathProbe watches the server's peer table: how many clients are
// connected and whether any of them reached us directly.
func serverPathProbe(s *Session, srv *tailcat.Server) {
	lastPeers, lastVia := -1, ""
	lastEmit := time.Now()
	t := time.NewTicker(probeInterval)
	defer t.Stop()
	for {
		select {
		case <-s.Context().Done():
			return
		case <-t.C:
		}
		st := srv.Status()
		if st == nil {
			continue
		}
		peers, via, detail := 0, "", ""
		for _, p := range st.Peer {
			if p == nil || !p.Active && p.CurAddr == "" && p.Relay == "" {
				continue
			}
			peers++
			if p.CurAddr != "" {
				via, detail = "direct", p.CurAddr
			} else if via == "" {
				via, detail = "derp", "DERP("+p.Relay+")"
			}
		}
		if peers != lastPeers || via != lastVia || time.Since(lastEmit) > probeHeartbeat {
			lastPeers, lastVia = peers, via
			lastEmit = time.Now()
			s.setInfo("peers", peers)
			s.events.Push(Event{"type": EvPath, "session_id": s.ID, "via": via,
				"detail": detail, "peers": peers})
		}
	}
}
