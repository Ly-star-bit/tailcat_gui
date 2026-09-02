// Package engine is the platform-independent core of the Tailcat GUI.
//
// It wraps github.com/tailscale/tailcat in a small session model and exposes
// a JSON command/event API that the FFI bridge (core/bridge) hands to the
// Flutter UI. Nothing in this package knows about Dart or C.
package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/tailscale/tailcat"
)

// Version is the GUI core version; overridden at build time via
// -ldflags "-X tailcat_gui/core/engine.Version=...".
var Version = "dev"

// Config configures a new Engine.
type Config struct {
	// DataDir is a writable directory for persistent state (reserved for
	// saved keys / host keys). May be empty.
	DataDir string
	// DERPMapURL overrides tailcat.DefaultDERPMapURL when non-empty.
	DERPMapURL string
	// Logf receives engine-level log lines. If nil, logs go only to the
	// event queue.
	Logf func(format string, args ...any)
}

// Engine owns all sessions and the outgoing event queue.
type Engine struct {
	cfg    Config
	events *EventQueue
	ctx    context.Context
	cancel context.CancelFunc

	mu       sync.Mutex
	sessions map[string]*Session
	nextID   atomic.Int64
	closed   bool
}

// New creates an Engine. Call Close to stop every session.
func New(cfg Config) *Engine {
	ctx, cancel := context.WithCancel(context.Background())
	return &Engine{
		cfg:      cfg,
		events:   &EventQueue{},
		ctx:      ctx,
		cancel:   cancel,
		sessions: map[string]*Session{},
	}
}

// Poll drains queued events as a JSON object {"events":[...]}.
func (e *Engine) Poll() []byte {
	evs := e.events.Drain()
	if evs == nil {
		evs = []Event{}
	}
	return mustJSON(map[string]any{"events": evs})
}

// PollEvents drains queued events (for Go callers and tests).
func (e *Engine) PollEvents() []Event { return e.events.Drain() }

// Close stops all sessions.
func (e *Engine) Close() {
	e.mu.Lock()
	e.closed = true
	sessions := make([]*Session, 0, len(e.sessions))
	for _, s := range e.sessions {
		sessions = append(sessions, s)
	}
	e.mu.Unlock()
	for _, s := range sessions {
		s.stop()
	}
	e.cancel()
}

func (e *Engine) logf(format string, args ...any) {
	if e.cfg.Logf != nil {
		e.cfg.Logf(format, args...)
	}
	e.events.Push(Event{"type": EvLog, "level": "info", "msg": fmt.Sprintf(format, args...)})
}

// newSession registers a new session of the given kind.
func (e *Engine) newSession(kind Kind) (*Session, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return nil, errCode(CodeInternal, "engine is closed")
	}
	id := fmt.Sprintf("%s-%d", kind, e.nextID.Add(1))
	s := newSession(e.ctx, id, kind, e.events)
	e.sessions[id] = s
	return s, nil
}

func (e *Engine) session(id string) (*Session, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	s, ok := e.sessions[id]
	if !ok {
		return nil, errCode(CodeNotFound, "no session %q", id)
	}
	return s, nil
}

func (e *Engine) stopSession(id string) error {
	s, err := e.session(id)
	if err != nil {
		return err
	}
	s.stop()
	return nil
}

func (e *Engine) listSessions() map[string]any {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := make([]map[string]any, 0, len(e.sessions))
	for _, s := range e.sessions {
		out = append(out, s.snapshot())
	}
	// Stable order: by creation.
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j]["created_ms"].(int64) < out[j-1]["created_ms"].(int64); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return map[string]any{"sessions": out}
}

// activeSessions reports how many sessions are starting or running.
func (e *Engine) activeSessions() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	n := 0
	for _, s := range e.sessions {
		if s.active() {
			n++
		}
	}
	return n
}

func (e *Engine) caps() map[string]any {
	return map[string]any{
		"platform":       runtime.GOOS,
		"arch":           runtime.GOARCH,
		"version":        Version,
		"tailcat":        tailcatVersion(),
		"ssh_server":     sshShellSupported(),
		"active_session": e.activeSessions(),
	}
}

func tailcatVersion() string {
	bi, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, d := range bi.Deps {
		if d.Path == "github.com/tailscale/tailcat" {
			if d.Replace != nil {
				return d.Replace.Version
			}
			return d.Version
		}
	}
	return "unknown"
}

// ---- tokens ----

// normalizeToken accepts what a user may paste: surrounding whitespace, a
// "tailcat=" DNS TXT prefix, or a hostname whose TXT record carries the token.
func normalizeToken(ctx context.Context, tok string) (tailcat.ConnBlob, error) {
	tok = strings.TrimSpace(tok)
	tok = strings.TrimPrefix(tok, "tailcat=")
	if tok == "" {
		return "", errCode(CodeInvalidToken, "empty token")
	}
	if strings.Contains(tok, ".") && !strings.HasPrefix(tok, "tc") {
		// Looks like a hostname: resolve TXT record like the CLI does.
		txts, err := net.DefaultResolver.LookupTXT(ctx, tok)
		if err != nil {
			return "", errCode(CodeInvalidToken, "lookup TXT %q: %v", tok, err)
		}
		for _, t := range txts {
			if v, ok := strings.CutPrefix(t, "tailcat="); ok {
				tok = strings.TrimSpace(v)
				break
			}
		}
	}
	cb := tailcat.ConnBlob(tok)
	if _, err := tailcat.ParseConnBlob(cb); err != nil {
		return "", errCode(CodeInvalidToken, "invalid token: %v", err)
	}
	return cb, nil
}

func parseToken(tok string) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cb, err := normalizeToken(ctx, tok)
	if err != nil {
		return nil, err
	}
	ci, err := tailcat.ParseConnBlob(cb)
	if err != nil {
		return nil, errCode(CodeInvalidToken, "invalid token: %v", err)
	}
	res := map[string]any{
		"valid":      true,
		"token":      string(cb),
		"region_id":  int(ci.RegionID),
		"public_key": ci.ServerPublic.String(),
		"embedded":   len(ci.Region) > 0,
	}
	if len(ci.Region) > 0 && ci.Region[0] != nil {
		res["region_code"] = ci.Region[0].RegionCode
		res["region_name"] = ci.Region[0].RegionName
	}
	return res, nil
}

// newClient builds a tailcat client bound to a session's logger.
func (e *Engine) newClient(s *Session, cb tailcat.ConnBlob) *tailcat.Client {
	cl := tailcat.NewClient(cb)
	cl.Logf = s.tailcatLogf()
	if e.cfg.DERPMapURL != "" {
		cl.DERPMapURL = e.cfg.DERPMapURL
	}
	return cl
}

// tailcatLogf routes tailcat's debug logging into the event stream at
// level "debug" so the UI can show or hide it.
func (s *Session) tailcatLogf() func(string, ...any) {
	return func(format string, args ...any) {
		s.events.Push(Event{
			"type": EvLog, "session_id": s.ID, "level": "debug",
			"msg": fmt.Sprintf(format, args...),
		})
	}
}

// ping connects to a server, measures latency and reports the path.
func (e *Engine) ping(a TokenArgs) (any, error) {
	timeout := 15 * time.Second
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
	start := time.Now()
	pr, err := cl.DiscoPing(ctx)
	if err != nil {
		return nil, errCode(CodeInternal, "ping: %v", err)
	}
	via, detail := classifyPing(pr.Endpoint, pr.DERPRegionCode, int(pr.DERPRegionID))
	lat := pr.LatencySeconds * 1000
	if lat == 0 {
		lat = float64(time.Since(start)) / float64(time.Millisecond)
	}
	return map[string]any{"latency_ms": lat, "via": via, "detail": detail}, nil
}

func classifyPing(endpoint, regionCode string, regionID int) (via, detail string) {
	if endpoint != "" {
		return "direct", endpoint
	}
	if regionCode != "" {
		return "derp", "DERP(" + regionCode + ")"
	}
	if regionID != 0 {
		return "derp", "DERP(" + strconv.Itoa(regionID) + ")"
	}
	return "derp", "DERP"
}

// closerFunc adapts a func to io.Closer.
type closerFunc func() error

func (f closerFunc) Close() error { return f() }

// listenAddr turns user input into a listen address: "" -> 127.0.0.1:0,
// "1080" -> 127.0.0.1:1080, ":1080" -> all interfaces, "host:port" as is.
func listenAddr(in string, defaultPort int) (string, error) {
	in = strings.TrimSpace(in)
	if in == "" {
		return "127.0.0.1:" + strconv.Itoa(defaultPort), nil
	}
	if p, err := strconv.Atoi(in); err == nil {
		if p < 0 || p > 65535 {
			return "", errCode(CodeBadRequest, "port out of range: %d", p)
		}
		return "127.0.0.1:" + in, nil
	}
	if _, _, err := net.SplitHostPort(in); err != nil {
		return "", errCode(CodeBadRequest, "bad listen address %q: %v", in, err)
	}
	return in, nil
}

// resultJSON is a helper for tests.
func resultJSON(v any) string { return string(mustJSON(v)) }

var _ = json.Marshal
