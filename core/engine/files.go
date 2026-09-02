package engine

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"tailcat_gui/core/engine/fileshare"

	"github.com/tailscale/tailcat"
)

// progressEmitter converts fileshare progress callbacks into throttled
// progress events (at most one per file per 100ms, plus the final one).
func (s *Session) progressEmitter() func(fileshare.Progress) {
	var mu sync.Mutex
	last := map[string]time.Time{}
	return func(p fileshare.Progress) {
		mu.Lock()
		now := time.Now()
		if !p.Done && now.Sub(last[p.Path]) < 100*time.Millisecond {
			mu.Unlock()
			return
		}
		if p.Done {
			delete(last, p.Path)
		} else {
			last[p.Path] = now
		}
		mu.Unlock()
		s.events.Push(Event{
			"type": EvProgress, "session_id": s.ID,
			"file": p.Path, "bytes": p.Bytes, "total": p.Total,
			"direction": p.Direction, "done": p.Done,
			"rate_bps": p.RateBPS,
		})
	}
}

// openShare dials the server's SFTP port and opens a file client.
func (e *Engine) openShare(ctx context.Context, s *Session, cb tailcat.ConnBlob) (*tailcat.Client, *fileshare.Client, error) {
	cl := e.newClient(s, cb)
	if err := warmClient(ctx, cl, s.logf); err != nil {
		cl.Close()
		return nil, nil, err
	}
	dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	conn, err := cl.DialTCPPort(dctx, sftpPort)
	cancel()
	if err != nil {
		cl.Close()
		return nil, nil, fmt.Errorf("connect to file service: %w", err)
	}
	fc, err := fileshare.NewClient(conn)
	if err != nil {
		conn.Close()
		cl.Close()
		return nil, nil, fmt.Errorf("open file service: %w", err)
	}
	return cl, fc, nil
}

// sendFiles uploads local paths (files or directories) to the server share.
func (e *Engine) sendFiles(a SendFilesArgs) (any, error) {
	if len(a.Paths) == 0 {
		return nil, errCode(CodeBadRequest, "no paths given")
	}
	for _, p := range a.Paths {
		if _, err := os.Stat(p); err != nil {
			return nil, errCode(CodeBadRequest, "%v", err)
		}
	}
	ctx, cancel := context.WithTimeout(e.ctx, 10*time.Second)
	cb, err := normalizeToken(ctx, a.Token)
	cancel()
	if err != nil {
		return nil, err
	}
	s, err := e.newSession(KindSend)
	if err != nil {
		return nil, err
	}
	s.setInfo("paths", a.Paths)
	s.setInfo("remote_dir", a.RemoteDir)
	go func() {
		s.setState(StateStarting, "connecting")
		cl, fc, err := e.openShare(s.Context(), s, cb)
		if err != nil {
			s.fail(err)
			return
		}
		s.addCloser(cl)
		s.addCloser(fc)
		s.setState(StateRunning, "uploading")
		emit := s.progressEmitter()
		for _, p := range a.Paths {
			if err := fc.Upload(s.Context(), p, a.RemoteDir, emit); err != nil {
				if s.Context().Err() != nil {
					return
				}
				s.fail(fmt.Errorf("upload %s: %w", p, err))
				return
			}
		}
		s.setState(StateDone, "uploaded")
		s.shutdown()
	}()
	return map[string]any{"session_id": s.ID}, nil
}

// listRemote lists a directory on the server share synchronously.
func (e *Engine) listRemote(a ListRemoteArgs) (any, error) {
	ctx, cancel := context.WithTimeout(e.ctx, 45*time.Second)
	defer cancel()
	cb, err := normalizeToken(ctx, a.Token)
	if err != nil {
		return nil, err
	}
	s, err := e.newSession(KindRecv)
	if err != nil {
		return nil, err
	}
	defer s.shutdown()
	cl, fc, err := e.openShare(ctx, s, cb)
	if err != nil {
		s.setState(StateFailed, err.Error())
		return nil, errCode(CodeInternal, "%v", err)
	}
	defer cl.Close()
	defer fc.Close()
	entries, err := fc.List(a.Dir)
	if err != nil {
		s.setState(StateFailed, err.Error())
		return nil, errCode(CodeInternal, "list %q: %v", a.Dir, err)
	}
	s.setState(StateDone, "")
	return map[string]any{"entries": entries}, nil
}

// download fetches remote paths (files or directories) into local_dir.
func (e *Engine) download(a DownloadArgs) (any, error) {
	if len(a.RemotePaths) == 0 {
		return nil, errCode(CodeBadRequest, "no remote_paths given")
	}
	if st, err := os.Stat(a.LocalDir); err != nil || !st.IsDir() {
		return nil, errCode(CodeBadRequest, "local_dir %q is not a directory", a.LocalDir)
	}
	ctx, cancel := context.WithTimeout(e.ctx, 10*time.Second)
	cb, err := normalizeToken(ctx, a.Token)
	cancel()
	if err != nil {
		return nil, err
	}
	s, err := e.newSession(KindRecv)
	if err != nil {
		return nil, err
	}
	s.setInfo("remote_paths", a.RemotePaths)
	s.setInfo("local_dir", a.LocalDir)
	go func() {
		s.setState(StateStarting, "connecting")
		cl, fc, err := e.openShare(s.Context(), s, cb)
		if err != nil {
			s.fail(err)
			return
		}
		s.addCloser(cl)
		s.addCloser(fc)
		s.setState(StateRunning, "downloading")
		emit := s.progressEmitter()
		for _, p := range a.RemotePaths {
			if err := fc.Download(s.Context(), p, a.LocalDir, emit); err != nil {
				if s.Context().Err() != nil {
					return
				}
				s.fail(fmt.Errorf("download %s: %w", p, err))
				return
			}
		}
		s.setState(StateDone, "downloaded")
		s.shutdown()
	}()
	return map[string]any{"session_id": s.ID}, nil
}
