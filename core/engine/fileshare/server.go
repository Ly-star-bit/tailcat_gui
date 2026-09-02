// Package fileshare implements the file side of the Tailcat GUI: a tiny
// authentication-free SSH server that only speaks the SFTP subsystem, rooted
// in one directory, plus an SFTP client.
//
// It is wire-compatible with the tailcat CLI (`tailcat cp`, `tailcat ls`,
// `tailcat recv`): those connect to port 22 as user "tailcat" with no
// authentication and ignore the host key, because the WireGuard tunnel has
// already authenticated both ends.
//
// tailcat's own SSH/SFTP server is unavailable on Android (build tags), so
// the GUI uses this package on every platform for consistent behaviour and
// progress reporting.
package fileshare

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"sync"

	"github.com/pkg/sftp"
	"github.com/tailscale/tailcat"
	"golang.org/x/crypto/ssh"
)

// Mode says what clients may do inside the shared directory.
type Mode byte

const (
	// ReadOnly lets clients list, stat and download; nothing may change.
	ReadOnly Mode = iota
	// ReadWrite lets clients do everything.
	ReadWrite
	// WriteOnly is a drop box: clients can upload and mkdir but neither
	// list nor read anything back (like `tailcat recv`).
	WriteOnly
)

// ParseMode parses "ro" | "rw" | "wo" (case-insensitive, "" = ro).
func ParseMode(s string) (Mode, error) {
	switch s {
	case "", "ro", "RO", "readonly", "read-only":
		return ReadOnly, nil
	case "rw", "RW", "readwrite", "read-write":
		return ReadWrite, nil
	case "wo", "WO", "writeonly", "write-only":
		return WriteOnly, nil
	}
	return 0, fmt.Errorf("unknown file share mode %q (want ro, rw or wo)", s)
}

func (m Mode) String() string {
	switch m {
	case ReadWrite:
		return "rw"
	case WriteOnly:
		return "wo"
	}
	return "ro"
}

// TailcatMode maps to tailcat's own FileServeMode (used on desktop when
// tailcat's SSH server hosts the share instead of this package).
func (m Mode) TailcatMode() tailcat.FileServeMode {
	switch m {
	case ReadWrite:
		return tailcat.FileServeRW
	case WriteOnly:
		return tailcat.FileServeWO
	}
	return tailcat.FileServeRO
}

// Progress reports transfer progress for one file.
type Progress struct {
	Path      string  `json:"path"`
	Bytes     int64   `json:"bytes"`
	Total     int64   `json:"total"` // -1 when unknown (uploads seen by the server)
	Direction string  `json:"direction"`
	RateBPS   float64 `json:"rate_bps"`
	Done      bool    `json:"done"`
}

// Directions, always from the reporting side's point of view.
const (
	DirUpload   = "up"   // bytes leaving this machine
	DirDownload = "down" // bytes arriving on this machine
)

// Hooks are optional callbacks from the server.
type Hooks struct {
	OnProgress func(Progress)
	Logf       func(format string, args ...any)
}

func (h Hooks) logf(format string, args ...any) {
	if h.Logf != nil {
		h.Logf(format, args...)
	}
}

func (h Hooks) progress(p Progress) {
	if h.OnProgress != nil {
		h.OnProgress(p)
	}
}

// Server serves one directory over SFTP.
type Server struct {
	root  *os.Root
	mode  Mode
	hooks Hooks
	cfg   *ssh.ServerConfig

	mu    sync.Mutex
	conns map[net.Conn]struct{}
	done  bool
}

// NewServer opens dir and prepares an SSH server config with a fresh
// ed25519 host key. Clients ignore host keys, so a new key per server is
// fine and keeps the package free of persistent state.
func NewServer(dir string, mode Mode, hooks Hooks) (*Server, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		root.Close()
		return nil, err
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		root.Close()
		return nil, err
	}
	cfg := &ssh.ServerConfig{NoClientAuth: true}
	cfg.AddHostKey(signer)
	return &Server{
		root:  root,
		mode:  mode,
		hooks: hooks,
		cfg:   cfg,
		conns: map[net.Conn]struct{}{},
	}, nil
}

// Mode returns the share mode.
func (s *Server) Mode() Mode { return s.mode }

// Handler returns a func suitable for tailcat.Server.OnTCP: it serves one
// incoming connection as an SSH session offering only the sftp subsystem.
func (s *Server) Handler() func(net.Conn) {
	return func(c net.Conn) {
		if !s.track(c) {
			c.Close()
			return
		}
		defer s.untrack(c)
		defer c.Close()
		sconn, chans, reqs, err := ssh.NewServerConn(c, s.cfg)
		if err != nil {
			s.hooks.logf("ssh handshake from %v failed: %v", c.RemoteAddr(), err)
			return
		}
		defer sconn.Close()
		go ssh.DiscardRequests(reqs)
		for newCh := range chans {
			if newCh.ChannelType() != "session" {
				newCh.Reject(ssh.UnknownChannelType, "only session channels are supported")
				continue
			}
			ch, requests, err := newCh.Accept()
			if err != nil {
				continue
			}
			go s.serveSession(ch, requests)
		}
	}
}

// serveSession waits for a "subsystem sftp" request and runs the SFTP
// server on the channel. Shell/exec requests are refused.
func (s *Server) serveSession(ch ssh.Channel, requests <-chan *ssh.Request) {
	defer ch.Close()
	for req := range requests {
		switch req.Type {
		case "subsystem":
			if subsystemName(req.Payload) != "sftp" {
				req.Reply(false, nil)
				continue
			}
			req.Reply(true, nil)
			srv := sftp.NewRequestServer(ch, s.handlers())
			err := srv.Serve()
			srv.Close()
			if err != nil && err.Error() != "EOF" {
				s.hooks.logf("sftp session ended: %v", err)
			}
			ch.SendRequest("exit-status", false, []byte{0, 0, 0, 0})
			return
		case "env", "pty-req", "window-change":
			// Harmless; accept so scp/sftp clients that send them proceed.
			req.Reply(true, nil)
		default: // shell, exec, ...
			req.Reply(false, nil)
		}
	}
}

func subsystemName(payload []byte) string {
	if len(payload) < 4 {
		return ""
	}
	n := binary.BigEndian.Uint32(payload)
	if int(n) > len(payload)-4 {
		return ""
	}
	return string(payload[4 : 4+n])
}

func (s *Server) track(c net.Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return false
	}
	s.conns[c] = struct{}{}
	return true
}

func (s *Server) untrack(c net.Conn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

// Close stops accepting sessions, closes live connections and the root.
func (s *Server) Close() error {
	s.mu.Lock()
	if s.done {
		s.mu.Unlock()
		return nil
	}
	s.done = true
	conns := make([]net.Conn, 0, len(s.conns))
	for c := range s.conns {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	for _, c := range conns {
		c.Close()
	}
	return s.root.Close()
}
