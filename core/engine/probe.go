package engine

import (
	"context"
	"errors"
	"net"
	"time"

	"github.com/pkg/sftp"
	"github.com/tailscale/tailcat"
	"golang.org/x/crypto/ssh"
)

// ProbeResult tells the UI what the other side offers.
type ProbeResult struct {
	Reachable bool      `json:"reachable"`
	Via       string    `json:"via"`
	Detail    string    `json:"detail"`
	LatencyMS float64   `json:"latency_ms"`
	Manifest  *Manifest `json:"manifest,omitempty"`
	// Fallbacks when the server is a plain tailcat CLI (no manifest):
	SFTP        bool `json:"sftp"`         // port 22 speaks SSH
	SFTPList    bool `json:"sftp_list"`    // root directory is listable (ro/rw)
	SSHShell    bool `json:"ssh_shell"`    // shell sessions accepted
	CLIFallback bool `json:"cli_fallback"` // no manifest; ports unknown
}

// probe connects to a token and discovers what it serves. Cheap and read-only
// apart from one short-lived shell request when no manifest exists.
func (e *Engine) probe(a TokenArgs) (any, error) {
	timeout := 25 * time.Second
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout * float64(time.Second))
	}
	ctx, cancel := context.WithTimeout(e.ctx, timeout)
	defer cancel()
	cb, err := normalizeToken(ctx, a.Token)
	if err != nil {
		return nil, err
	}
	cl := tailcat.NewClient(cb)
	cl.Logf = func(string, ...any) {}
	if e.cfg.DERPMapURL != "" {
		cl.DERPMapURL = e.cfg.DERPMapURL
	}
	defer cl.Close()

	res := ProbeResult{}
	if err := warmClient(ctx, cl, nil); err != nil {
		return nil, errCode(CodeInternal, "connect: %v", err)
	}
	pr, err := cl.DiscoPing(ctx)
	if err != nil {
		return nil, errCode(CodeInternal, "connect: %v", err)
	}
	res.Reachable = true
	res.Via, res.Detail = classifyPing(pr.Endpoint, pr.DERPRegionCode, int(pr.DERPRegionID))
	res.LatencyMS = pr.LatencySeconds * 1000

	// 1. Our manifest.
	if conn, err := dialShort(ctx, cl, manifestPort, 4*time.Second); err == nil {
		mctx, mcancel := context.WithTimeout(ctx, 4*time.Second)
		m, merr := readManifest(mctx, conn)
		mcancel()
		conn.Close()
		if merr == nil {
			res.Manifest = m
			res.SFTP = m.Files != nil || m.SSH
			res.SFTPList = m.Files != nil && m.Files.Mode != "wo"
			res.SSHShell = m.SSH
			return res, nil
		}
	}

	// 2. Plain tailcat CLI: see whether port 22 speaks SSH, and what it allows.
	res.CLIFallback = true
	conn, err := dialShort(ctx, cl, sftpPort, 4*time.Second)
	if err != nil {
		return res, nil
	}
	defer conn.Close()
	sc, chans, reqs, err := ssh.NewClientConn(conn, "tailcat", &ssh.ClientConfig{
		User: "tailcat", HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 5 * time.Second,
	})
	if err != nil {
		return res, nil
	}
	client := ssh.NewClient(sc, chans, reqs)
	defer client.Close()
	res.SFTP = true
	if sf, err := sftp.NewClient(client); err == nil {
		if _, err := sf.ReadDir("."); err == nil {
			res.SFTPList = true
		}
		sf.Close()
	}
	if sess, err := client.NewSession(); err == nil {
		// A shell request is accepted only by tailcat's full SSH server.
		if err := sess.Shell(); err == nil {
			res.SSHShell = true
		}
		sess.Close()
	}
	return res, nil
}

// dialShort dials a port with its own timeout so a filtered port does not
// eat the whole probe budget.
func dialShort(ctx context.Context, cl *tailcat.Client, port uint16, d time.Duration) (net.Conn, error) {
	dctx, cancel := context.WithTimeout(ctx, d)
	defer cancel()
	conn, err := cl.DialTCPPort(dctx, port)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, errors.Join(err)
	}
	return conn, nil
}
