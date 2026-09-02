package engine

import (
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"

	"tailcat_gui/core/engine/fileshare"

	"github.com/tailscale/tailcat"
	"tailscale.com/wgengine/filter"
)

// sftpPort is where tailcat CLI clients expect SSH/SFTP.
const sftpPort = 22

// startServer implements `tailcat serve` semantics in-process.
func (e *Engine) startServer(a StartServerArgs) (any, error) {
	if len(a.Ports) == 0 && !a.All && !a.ExitNode && a.Files == nil && !a.SSH && len(a.SharePaths) == 0 {
		return nil, errCode(CodeBadRequest, "nothing to serve: give ports, all, exit_node, files, share_paths or ssh")
	}
	if a.Files != nil && len(a.SharePaths) > 0 {
		return nil, errCode(CodeBadRequest, "files and share_paths are mutually exclusive")
	}
	for _, p := range a.SharePaths {
		if _, err := os.Stat(p); err != nil {
			return nil, errCode(CodeBadRequest, "share path: %v", err)
		}
	}
	for _, p := range a.Ports {
		if p < 1 || p > 65535 {
			return nil, errCode(CodeBadRequest, "port out of range: %d", p)
		}
	}
	if a.SSH && !sshShellSupported() {
		return nil, errCode(CodeUnsupported, "no-auth SSH server is not supported on this platform")
	}
	var (
		fsMode fileshare.Mode
		err    error
	)
	if a.Files != nil {
		fsMode, err = fileshare.ParseMode(a.Files.Mode)
		if err != nil {
			return nil, errCode(CodeBadRequest, "%v", err)
		}
		st, err := os.Stat(a.Files.Dir)
		if err != nil {
			return nil, errCode(CodeBadRequest, "files dir: %v", err)
		}
		if !st.IsDir() {
			return nil, errCode(CodeBadRequest, "files dir %q is not a directory", a.Files.Dir)
		}
	}

	s, err := e.newSession(KindServer)
	if err != nil {
		return nil, err
	}
	srv := &tailcat.Server{Logf: s.tailcatLogf()}
	if e.cfg.DERPMapURL != "" {
		srv.DERPMapURL = e.cfg.DERPMapURL
	}

	// Port 22 handler: either tailcat's shell+sftp server (desktop) or our
	// SFTP-only share (all platforms).
	var port22 func(net.Conn)
	var mfFiles *ManifestFiles
	hooks := fileshare.Hooks{OnProgress: s.progressEmitter(), Logf: s.logf}
	switch {
	case a.SSH:
		port22, err = sshShellHandler(srv, a.Files)
		if err != nil {
			s.fail(err)
			return nil, err
		}
		if a.Files != nil {
			mfFiles = &ManifestFiles{Mode: fsMode.String(), Dir: filepath.Base(a.Files.Dir)}
		}
	case len(a.SharePaths) > 0:
		fs, err := fileshare.NewPathsServer(a.SharePaths, hooks)
		if err != nil {
			s.fail(err)
			return nil, errCode(CodeInternal, "file share: %v", err)
		}
		s.addCloser(fs)
		port22 = fs.Handler()
		fsMode = fileshare.ReadOnly
		mfFiles = &ManifestFiles{Mode: "ro", Items: fs.Entries()}
	case a.Files != nil:
		fs, err := fileshare.NewServer(a.Files.Dir, fsMode, hooks)
		if err != nil {
			s.fail(err)
			return nil, errCode(CodeInternal, "file share: %v", err)
		}
		s.addCloser(fs)
		port22 = fs.Handler()
		mfFiles = &ManifestFiles{Mode: fsMode.String(), Dir: filepath.Base(a.Files.Dir)}
	}

	portSet := make(map[uint16]bool, len(a.Ports))
	for _, p := range a.Ports {
		portSet[uint16(p)] = true
	}
	manifest := manifestHandler(Manifest{
		App: manifestApp, Version: Version, Name: deviceName(a.Name), Platform: runtime.GOOS,
		Ports: a.Ports, All: a.All, ExitNode: a.ExitNode, SSH: a.SSH, Files: mfFiles,
	})
	srv.OnTCP = func(port uint16) func(net.Conn) {
		if port == manifestPort && !portSet[manifestPort] {
			return manifest
		}
		if port == sftpPort && port22 != nil {
			return port22
		}
		if a.All || portSet[port] {
			return tcpForwardTo(s, "localhost:"+strconv.Itoa(int(port)))
		}
		return nil
	}
	if !a.All {
		ports := slices.Clone(a.Ports)
		ports = append(ports, manifestPort)
		if port22 != nil {
			ports = append(ports, sftpPort)
		}
		slices.Sort(ports)
		for _, p := range slices.Compact(ports) {
			srv.ServedTCPPorts = append(srv.ServedTCPPorts, filter.PortRange{First: uint16(p), Last: uint16(p)})
		}
	}
	if a.ExitNode {
		srv.OnTCPForward = func(dst netip.AddrPort) func(net.Conn) {
			return tcpForwardTo(s, dst.String())
		}
	}

	s.setInfo("ports", a.Ports)
	s.setInfo("all", a.All)
	s.setInfo("exit_node", a.ExitNode)
	s.setInfo("ssh", a.SSH)
	s.setInfo("name", deviceName(a.Name))
	if a.Files != nil {
		s.setInfo("files_dir", a.Files.Dir)
		s.setInfo("files_mode", fsMode.String())
	}
	if len(a.SharePaths) > 0 {
		s.setInfo("share_paths", a.SharePaths)
		s.setInfo("files_mode", "ro")
	}

	go func() {
		s.setState(StateStarting, "selecting relay")
		if err := srv.Start(); err != nil {
			s.fail(fmt.Errorf("start server: %w", err))
			return
		}
		// If the session was stopped while Start was in flight, addCloser
		// closes the server immediately.
		s.addCloser(closerFunc(srv.Close))
		s.setToken(string(srv.ConnBlob()))
		s.setState(StateRunning, "listening")
		go serverPathProbe(s, srv)
	}()
	return map[string]any{"session_id": s.ID}, nil
}

// tcpForwardTo returns a handler that proxies an incoming tunnel connection
// to a local/remote TCP address, like the tailcat CLI does.
func tcpForwardTo(s *Session, addr string) func(net.Conn) {
	return func(c net.Conn) {
		var d net.Dialer
		local, err := d.DialContext(s.Context(), "tcp", addr)
		if err != nil {
			s.logf("proxy to %v failed: %v", addr, err)
			c.Close()
			return
		}
		tailcat.ProxyConns(c, local)
	}
}
