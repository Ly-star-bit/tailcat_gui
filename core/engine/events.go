package engine

import (
	"sync"
	"time"
)

// Event is a single JSON-serialisable event delivered to the UI.
// Every event carries "type" and "ts" (unix milliseconds); most carry
// "session_id". The remaining keys depend on the type.
type Event map[string]any

// Event types.
const (
	EvSessionState = "session_state"
	EvTokenReady   = "token_ready"
	EvLog          = "log"
	EvProgress     = "progress"
	EvPath         = "path"
	EvError        = "error"
)

// maxQueuedEvents bounds the queue; when the UI stops polling we drop the
// oldest events instead of growing without limit.
const maxQueuedEvents = 5000

// EventQueue is a bounded FIFO of events shared between engine goroutines
// (producers) and the FFI poll call (single consumer).
type EventQueue struct {
	mu      sync.Mutex
	events  []Event
	dropped int
}

// Push appends an event, stamping "ts" if absent.
func (q *EventQueue) Push(ev Event) {
	if _, ok := ev["ts"]; !ok {
		ev["ts"] = time.Now().UnixMilli()
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.events) >= maxQueuedEvents {
		// Drop the oldest half so we do not do this on every push.
		n := len(q.events) / 2
		q.dropped += n
		q.events = append(q.events[:0], q.events[n:]...)
	}
	q.events = append(q.events, ev)
}

// Drain returns all queued events and clears the queue.
func (q *EventQueue) Drain() []Event {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.events) == 0 {
		return nil
	}
	out := q.events
	q.events = make([]Event, 0, 64)
	if q.dropped > 0 {
		out = append([]Event{{
			"type": EvLog, "ts": time.Now().UnixMilli(), "level": "warn",
			"msg": "event queue overflow; some events were dropped",
		}}, out...)
		q.dropped = 0
	}
	return out
}

// Len reports the number of queued events (for tests).
func (q *EventQueue) Len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.events)
}
