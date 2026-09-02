package fileshare

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path"
	"path/filepath"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

// Entry is one remote directory entry.
type Entry struct {
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	IsDir   bool   `json:"is_dir"`
	ModMS   int64  `json:"mtime_ms"`
	Mode    string `json:"mode"`
	IsLink  bool   `json:"is_link"`
	Dirpath string `json:"dir"`
}

// Client is an SFTP client over an already-established net.Conn (normally
// tailcat.Client.DialTCPPort(22)).
type Client struct {
	conn net.Conn
	ssh  *ssh.Client
	sftp *sftp.Client
}

// NewClient runs the SSH handshake the way the tailcat CLI does and opens
// the sftp subsystem.
func NewClient(conn net.Conn) (*Client, error) {
	cfg := &ssh.ClientConfig{
		User:            "tailcat",
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), // tunnel already authenticated the peer
		Timeout:         30 * time.Second,
	}
	sc, chans, reqs, err := ssh.NewClientConn(conn, "tailcat", cfg)
	if err != nil {
		return nil, fmt.Errorf("ssh handshake: %w", err)
	}
	cl := ssh.NewClient(sc, chans, reqs)
	sf, err := sftp.NewClient(cl, sftp.UseConcurrentWrites(true), sftp.UseConcurrentReads(true))
	if err != nil {
		cl.Close()
		return nil, fmt.Errorf("open sftp: %w", err)
	}
	return &Client{conn: conn, ssh: cl, sftp: sf}, nil
}

// Close tears everything down. Safe to call from another goroutine to
// abort an in-flight transfer.
func (c *Client) Close() error {
	c.sftp.Close()
	err := c.ssh.Close()
	c.conn.Close()
	return err
}

// List returns the entries of a remote directory ("" or "." = share root).
func (c *Client) List(dir string) ([]Entry, error) {
	if dir == "" {
		dir = "."
	}
	infos, err := c.sftp.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := make([]Entry, 0, len(infos))
	for _, fi := range infos {
		out = append(out, Entry{
			Name:    fi.Name(),
			Size:    fi.Size(),
			IsDir:   fi.IsDir(),
			ModMS:   fi.ModTime().UnixMilli(),
			Mode:    fi.Mode().String(),
			IsLink:  fi.Mode()&os.ModeSymlink != 0,
			Dirpath: dir,
		})
	}
	return out, nil
}

// Upload copies a local file or directory tree into remoteDir.
func (c *Client) Upload(ctx context.Context, local, remoteDir string, progress func(Progress)) error {
	if remoteDir == "" {
		remoteDir = "."
	}
	st, err := os.Stat(local)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return c.uploadFile(ctx, local, path.Join(remoteDir, filepath.Base(local)), st.Size(), progress)
	}
	base := filepath.Base(local)
	return filepath.WalkDir(local, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		relp, err := filepath.Rel(local, p)
		if err != nil {
			return err
		}
		remote := path.Join(remoteDir, base, filepath.ToSlash(relp))
		if d.IsDir() {
			return c.sftp.MkdirAll(remote)
		}
		if !d.Type().IsRegular() {
			return nil // skip sockets, symlinks, ...
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		return c.uploadFile(ctx, p, remote, info.Size(), progress)
	})
}

func (c *Client) uploadFile(ctx context.Context, local, remote string, size int64, progress func(Progress)) error {
	in, err := os.Open(local)
	if err != nil {
		return err
	}
	defer in.Close()
	if dir := path.Dir(remote); dir != "." && dir != "/" {
		_ = c.sftp.MkdirAll(dir)
	}
	out, err := c.sftp.OpenFile(remote, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
	if err != nil {
		return err
	}
	pr := &progressReader{r: in, p: Progress{Path: remote, Total: size, Direction: DirUpload}, cb: progress, start: time.Now()}
	// sftp.File.ReadFrom issues pipelined writes; io.Copy picks it up.
	_, err = io.Copy(out, pr)
	cerr := out.Close()
	if err == nil {
		err = cerr
	}
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	pr.finish(err == nil)
	return err
}

// Download copies a remote file or directory tree into localDir.
func (c *Client) Download(ctx context.Context, remote, localDir string, progress func(Progress)) error {
	remote = path.Clean(remote)
	if remote == "." || remote == "/" || remote == "" {
		// "Everything": fetch each top-level entry into localDir directly.
		entries, err := c.List(".")
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := c.Download(ctx, e.Name, localDir, progress); err != nil {
				return err
			}
		}
		return nil
	}
	st, err := c.sftp.Stat(remote)
	if err != nil {
		return err
	}
	if !st.IsDir() {
		return c.downloadFile(ctx, remote, filepath.Join(localDir, path.Base(remote)), st.Size(), progress)
	}
	walker := c.sftp.Walk(remote)
	for walker.Step() {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := walker.Err(); err != nil {
			return err
		}
		rp := walker.Path()
		relp, err := filepath.Rel(filepath.FromSlash(path.Dir(remote)), filepath.FromSlash(rp))
		if err != nil {
			return err
		}
		lp := filepath.Join(localDir, relp)
		fi := walker.Stat()
		if fi.IsDir() {
			if err := os.MkdirAll(lp, 0o755); err != nil {
				return err
			}
			continue
		}
		if !fi.Mode().IsRegular() {
			continue
		}
		if err := c.downloadFile(ctx, rp, lp, fi.Size(), progress); err != nil {
			return err
		}
	}
	return nil
}

func (c *Client) downloadFile(ctx context.Context, remote, local string, size int64, progress func(Progress)) error {
	in, err := c.sftp.Open(remote)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
		return err
	}
	out, err := os.Create(local)
	if err != nil {
		return err
	}
	pw := &progressWriter{w: out, p: Progress{Path: remote, Total: size, Direction: DirDownload}, cb: progress, start: time.Now()}
	// sftp.File.WriteTo issues pipelined reads; io.Copy picks it up.
	_, err = io.Copy(pw, in)
	cerr := out.Close()
	if err == nil {
		err = cerr
	}
	if err == nil && ctx.Err() != nil {
		err = ctx.Err()
	}
	pw.finish(err == nil)
	return err
}

type progressReader struct {
	r     io.Reader
	p     Progress
	cb    func(Progress)
	start time.Time
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 {
		p.p.Bytes += int64(n)
		p.p.RateBPS = rate(p.p.Bytes, p.start)
		if p.cb != nil {
			p.cb(p.p)
		}
	}
	return n, err
}

func (p *progressReader) finish(ok bool) {
	if p.cb == nil {
		return
	}
	p.p.Done = true
	if ok && p.p.Total < 0 {
		p.p.Total = p.p.Bytes
	}
	p.cb(p.p)
}

type progressWriter struct {
	w     io.Writer
	p     Progress
	cb    func(Progress)
	start time.Time
}

func (p *progressWriter) Write(b []byte) (int, error) {
	n, err := p.w.Write(b)
	if n > 0 {
		p.p.Bytes += int64(n)
		p.p.RateBPS = rate(p.p.Bytes, p.start)
		if p.cb != nil {
			p.cb(p.p)
		}
	}
	return n, err
}

func (p *progressWriter) finish(ok bool) {
	if p.cb == nil {
		return
	}
	p.p.Done = true
	p.cb(p.p)
}
