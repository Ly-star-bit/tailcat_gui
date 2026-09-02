package engine

import (
	"context"
	"fmt"
	"time"

	"github.com/tailscale/tailcat"
)

// warmClient completes the client's handshake with the server, retrying.
//
// tailcat's handshake ("meow") sends a single packet via DERP and waits up
// to 10s with no retransmission. A server that has just started may not be
// registered with its relay yet, so the first packet is dropped and the
// caller would burn the full 10s. Short escalating attempts each send a
// fresh packet and normally succeed within a couple of seconds.
func warmClient(ctx context.Context, cl *tailcat.Client, logf func(string, ...any)) error {
	attempts := []time.Duration{2 * time.Second, 3 * time.Second, 5 * time.Second, 10 * time.Second}
	var last error
	for i, d := range attempts {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		actx, cancel := context.WithTimeout(ctx, d)
		_, err := cl.Ping(actx)
		cancel()
		if err == nil {
			return nil
		}
		last = err
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if logf != nil && i < len(attempts)-1 {
			logf("handshake attempt %d failed (%v); retrying", i+1, err)
		}
	}
	return fmt.Errorf("server not reachable: %w", last)
}
