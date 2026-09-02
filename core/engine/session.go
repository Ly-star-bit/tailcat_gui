package engine

import (
	"context"
	"fmt"
	"io"
	"sync"
	"time"
)

// Kind identifies what a session does.
type Kind string

const (
	KindServer  Kind = "server"  // serving ports / files / ssh, owns a tailcat.Server
	KindForward Kind = "forward" // local TCP listener -> remote port
	KindSocks   Kind = "socks"   // local SOCKS5 listener -> remote
	KindSend    Kind = "send"    // SFTP upload job
	KindRecv    Kind = "recv"    // SFTP download job
	KindSSH     Kind = "ssh"     // forward to remote port 22 for a system ssh client
)

// State is the lifecycle state of a session.
type State string

const (
	StateStarting State = "starting"
	StateRunning  State = "running"
	StateDone     State = "done"
	StateStopped  State = "stopped"
	StateFailed   State = "failed"
)

// Session is one running unit of work owned by the Engine.
type Session struct {
	ID      string
	Kind    Kind
	Created time.Time

	ctx    context.Context
	cancel context.CancelFunc
	events *EventQueue

	// ready is closed once the tunnel handshake with the peer succeeded,
	// so connection handlers do not dial before the client is usable.
	ready     chan struct{}
	readyOnce sync.Once

	mu      sync.Mutex
	state   State
	token   string
	detail  string
	info    map[string]any // extra JSON fields (local_port, listen, ...)
	closers []io.Closer
	closed  bool
}

func newSession(parent context.Context, id string, kind Kind, q *EventQueue) *Session {
	ctx, cancel := context.WithCancel(parent)
	return &Session{
		ID:      id,
		Kind:    kind,
		Created: time.Now(),
		ready:   make(chan struct{}),
		ctx:     ctx,
		cancel:  cancel,
		events:  q,
		state:   StateStarting,
		info:    map[string]any{},
	}
}

// Context is cancelled when the session is stopped.
func (s *Session) Context() context.Context { return s.ctx }

// markReady reports that the tunnel is up and dialling can proceed.
func (s *Session) markReady() {
	s.readyOnce.Do(func() { close(s.ready) })
}

// waitReady blocks until the tunnel is up, the session stops, or timeout.
func (s *Session) waitReady(timeout time.Duration) error {
	select {
	case <-s.ready:
		return nil
	case <-s.ctx.Done():
		return s.ctx.Err()
	case <-time.After(timeout):
		return fmt.Errorf("timed out waiting for the tunnel to come up")
	}
}

// addCloser registers something to close when the session stops.
func (s *Session) addCloser(c io.Closer) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		s.mu.Unlock()
		c.Close()
		s.mu.Lock()
		return
	}
	s.closers = append(s.closers, c)
}

// setInfo stores an extra field reported in list_sessions and state events.
func (s *Session) setInfo(k string, v any) {
	s.mu.Lock()
	s.info[k] = v
	s.mu.Unlock()
}

// setState transitions the session and emits a session_state event.
func (s *Session) setState(st State, detail string) {
	s.mu.Lock()
	if s.state == st && s.detail == detail {
		s.mu.Unlock()
		return
	}
	// Terminal states are sticky.
	if s.state == StateStopped || s.state == StateFailed || s.state == StateDone {
		s.mu.Unlock()
		return
	}
	s.state = st
	s.detail = detail
	ev := s.stateEventLocked()
	s.mu.Unlock()
	s.events.Push(ev)
}

func (s *Session) stateEventLocked() Event {
	ev := Event{
		"type":       EvSessionState,
		"session_id": s.ID,
		"kind":       string(s.Kind),
		"state":      string(s.state),
		"detail":     s.detail,
	}
	for k, v := range s.info {
		ev[k] = v
	}
	return ev
}

// fail marks the session failed with the error and emits an error event.
func (s *Session) fail(err error) {
	s.events.Push(Event{
		"type": EvError, "session_id": s.ID,
		"code": "session_failed", "message": err.Error(),
	})
	s.setState(StateFailed, err.Error())
	s.shutdown()
}

// setToken records the server token and emits token_ready.
func (s *Session) setToken(token string) {
	s.mu.Lock()
	s.token = token
	s.mu.Unlock()
	s.events.Push(Event{"type": EvTokenReady, "session_id": s.ID, "token": token})
}

// logf emits a log event scoped to this session.
func (s *Session) logf(format string, args ...any) {
	s.events.Push(Event{
		"type": EvLog, "session_id": s.ID, "level": "info",
		"msg": fmt.Sprintf(format, args...),
	})
}

// stop cancels the session and closes everything it owns.
func (s *Session) stop() {
	s.setState(StateStopped, "")
	s.shutdown()
}

func (s *Session) shutdown() {
	s.cancel()
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	closers := s.closers
	s.closers = nil
	s.mu.Unlock()
	// Close in reverse registration order: listeners before the tailcat
	// server/client that they depend on.
	for i := len(closers) - 1; i >= 0; i-- {
		closers[i].Close()
	}
}

// snapshot returns the JSON view used by list_sessions.
func (s *Session) snapshot() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := map[string]any{
		"session_id": s.ID,
		"kind":       string(s.Kind),
		"state":      string(s.state),
		"detail":     s.detail,
		"created_ms": s.Created.UnixMilli(),
	}
	if s.token != "" {
		m["token"] = s.token
	}
	for k, v := range s.info {
		m[k] = v
	}
	return m
}

// active reports whether the session is still starting or running.
func (s *Session) active() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state == StateStarting || s.state == StateRunning
}
