package engine

import (
	"context"
	"net"
	"net/netip"
	"strconv"
	"time"

	"tailscale.com/net/socks5"
)

// startSocks runs a local SOCKS5 proxy whose connections traverse the
// tunnel, mirroring `tailcat socks --listen`.
//
// Destination rules (same as the CLI): host "server.tailcat", "localhost"
// or empty targets the server itself; an IP or hostname is reached through
// the server as an exit node (the server must serve exit_node).
func (e *Engine) startSocks(a StartSocksArgs) (any, error) {
	ctx, cancel := context.WithTimeout(e.ctx, 10e9)
	cb, err := normalizeToken(ctx, a.Token)
	cancel()
	if err != nil {
		return nil, err
	}
	addr, err := listenAddr(a.Listen, 1080)
	if err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, errCode(CodeInternal, "listen: %v", err)
	}

	s, err := e.newSession(KindSocks)
	if err != nil {
		ln.Close()
		return nil, err
	}
	cl := e.newClient(s, cb)
	s.addCloser(cl)
	s.addCloser(ln)
	s.setInfo("listen", ln.Addr().String())
	s.setInfo("local_port", ln.Addr().(*net.TCPAddr).Port)

	srv := &socks5.Server{
		Logf: s.tailcatLogf(),
		Dialer: func(ctx context.Context, network, addr string) (net.Conn, error) {
			// Do not race the tunnel handshake; a browser can hit the proxy
			// the moment the port is open.
			if err := s.waitReady(45 * time.Second); err != nil {
				return nil, err
			}
			host, portStr, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			port, err := strconv.Atoi(portStr)
			if err != nil || port < 0 || port > 65535 {
				return nil, errCode(CodeBadRequest, "bad port %q", portStr)
			}
			switch host {
			case "", "server.tailcat", "localhost", "127.0.0.1", "::1":
				return cl.DialTCPPort(ctx, uint16(port))
			}
			if ip, err := netip.ParseAddr(host); err == nil {
				return cl.DialTCP(ctx, netip.AddrPortFrom(ip.Unmap(), uint16(port)))
			}
			// Hostname: resolved relative to the server (exit node).
			return cl.Dial(ctx, network, addr)
		},
	}
	go func() {
		if err := srv.Serve(ln); err != nil && s.Context().Err() == nil {
			s.logf("socks5 server stopped: %v", err)
		}
	}()
	go clientWarmup(s, cl)

	return map[string]any{"session_id": s.ID, "listen": ln.Addr().String()}, nil
}
