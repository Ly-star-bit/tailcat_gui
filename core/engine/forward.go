package engine

import (
	"context"
	"errors"
	"fmt"
	"net"
	"runtime"
	"strconv"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
)

// startForward listens on a local TCP port and forwards every accepted
// connection to remote_port on the server. This is the client-side
// counterpart of `tailcat serve <port>` that the CLI does not offer.
func (e *Engine) startForward(a StartForwardArgs, kind Kind) (any, error) {
	if a.RemotePort < 1 || a.RemotePort > 65535 {
		return nil, errCode(CodeBadRequest, "remote_port out of range: %d", a.RemotePort)
	}
	if a.LocalPort < 0 || a.LocalPort > 65535 {
		return nil, errCode(CodeBadRequest, "local_port out of range: %d", a.LocalPort)
	}
	ctx, cancel := context.WithTimeout(e.ctx, 10e9)
	cb, err := normalizeToken(ctx, a.Token)
	cancel()
	if err != nil {
		return nil, err
	}
	host := "127.0.0.1"
	if a.BindAll {
		host = ""
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(a.LocalPort)))
	if err != nil {
		return nil, errCode(CodeInternal, "listen: %v", err)
	}
	localPort := ln.Addr().(*net.TCPAddr).Port

	s, err := e.newSession(kind)
	if err != nil {
		ln.Close()
		return nil, err
	}
	cl := e.newClient(s, cb)
	s.addCloser(cl)
	s.addCloser(ln)
	s.setInfo("local_port", localPort)
	s.setInfo("remote_port", a.RemotePort)
	s.setInfo("listen", ln.Addr().String())

	go acceptLoop(s, ln, func(c net.Conn) {
		rc, err := cl.DialTCPPort(s.Context(), uint16(a.RemotePort))
		if err != nil {
			s.logf("dial remote port %d: %v", a.RemotePort, err)
			c.Close()
			return
		}
		tailcat.ProxyConns(c, rc)
	})
	go clientWarmup(s, cl)

	res := map[string]any{"session_id": s.ID, "local_port": localPort}
	if kind == KindSSH {
		res["command"] = sshCommand(localPort)
	}
	return res, nil
}

// startSSHForward is start_forward to port 22 plus the ssh command line the
// UI shows or launches in a terminal.
func (e *Engine) startSSHForward(a TokenArgs) (any, error) {
	return e.startForward(StartForwardArgs{Token: a.Token, RemotePort: sftpPort}, KindSSH)
}

// sshCommand is what the user runs in a system terminal. Host key checking
// is disabled because the WireGuard tunnel already authenticated the server.
func sshCommand(localPort int) string {
	devnull := "/dev/null"
	if runtime.GOOS == "windows" {
		devnull = "NUL"
	}
	return fmt.Sprintf("ssh -p %d -o StrictHostKeyChecking=no -o UserKnownHostsFile=%s -o LogLevel=ERROR tailcat@127.0.0.1", localPort, devnull)
}

// acceptLoop serves ln until the session stops.
func acceptLoop(s *Session, ln net.Listener, handle func(net.Conn)) {
	for {
		c, err := ln.Accept()
		if err != nil {
			if s.Context().Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			s.fail(fmt.Errorf("accept: %w", err))
			return
		}
		go handle(c)
	}
}

// clientWarmup pings the server so the UI learns quickly whether the token
// works, then keeps probing the path (DERP vs direct).
func clientWarmup(s *Session, cl *tailcat.Client) {
	s.setState(StateStarting, "connecting")
	ctx, cancel := context.WithTimeout(s.Context(), 30*time.Second)
	err := warmClient(ctx, cl, s.logf)
	var pr *ipnstate.PingResult
	if err == nil {
		pr, err = cl.DiscoPing(ctx)
	}
	cancel()
	if err != nil {
		if s.Context().Err() != nil {
			return
		}
		s.fail(fmt.Errorf("connect to server: %w", err))
		return
	}
	via, detail := classifyPing(pr.Endpoint, pr.DERPRegionCode, int(pr.DERPRegionID))
	s.setState(StateRunning, "connected via "+detail)
	s.events.Push(Event{"type": EvPath, "session_id": s.ID, "via": via, "detail": detail,
		"latency_ms": pr.LatencySeconds * 1000})
	clientPathProbe(s, cl, via)
}
