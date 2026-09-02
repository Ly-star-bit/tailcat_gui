package fileshare

import (
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
)

// handlers builds the pkg/sftp request-server handlers for this share.
func (s *Server) handlers() sftp.Handlers {
	h := &shareHandlers{s: s}
	return sftp.Handlers{FileGet: h, FilePut: h, FileCmd: h, FileList: h}
}

type shareHandlers struct {
	s *Server
}

// rel converts an SFTP absolute path ("/a/b") to a path relative to the
// root. os.Root refuses anything that would escape, so this only needs to
// normalise.
func rel(p string) string {
	p = path.Clean("/" + strings.TrimSpace(p))
	p = strings.TrimPrefix(p, "/")
	if p == "" {
		return "."
	}
	return p
}

func (h *shareHandlers) canRead() bool  { return h.s.mode != WriteOnly }
func (h *shareHandlers) canWrite() bool { return h.s.mode != ReadOnly }

// Fileread serves downloads.
func (h *shareHandlers) Fileread(r *sftp.Request) (io.ReaderAt, error) {
	if !h.canRead() {
		return nil, sftp.ErrSSHFxPermissionDenied
	}
	f, err := h.s.fs.Open(rel(r.Filepath))
	if err != nil {
		return nil, mapErr(err)
	}
	total := int64(-1)
	if st, err := f.Stat(); err == nil {
		if st.IsDir() {
			f.Close()
			return nil, sftp.ErrSSHFxFailure
		}
		total = st.Size()
	}
	return &countingFile{f: f, path: r.Filepath, total: total, dir: DirUpload, hooks: h.s.hooks, start: time.Now()}, nil
}

// Filewrite serves uploads.
func (h *shareHandlers) Filewrite(r *sftp.Request) (io.WriterAt, error) {
	if !h.canWrite() {
		return nil, sftp.ErrSSHFxPermissionDenied
	}
	flags := r.Pflags()
	oflag := os.O_WRONLY
	if flags.Read {
		oflag = os.O_RDWR
	}
	if flags.Creat {
		oflag |= os.O_CREATE
	}
	if flags.Trunc {
		oflag |= os.O_TRUNC
	}
	if flags.Excl {
		oflag |= os.O_EXCL
	}
	if flags.Append {
		oflag |= os.O_APPEND
	}
	f, err := h.s.fs.OpenFile(rel(r.Filepath), oflag, 0o644)
	if err != nil {
		return nil, mapErr(err)
	}
	return &countingFile{f: f, path: r.Filepath, total: -1, dir: DirDownload, hooks: h.s.hooks, start: time.Now()}, nil
}

// OpenFile serves opens with both read and write (rare; used by some
// clients for resume). It satisfies sftp.OpenFileWriter.
func (h *shareHandlers) OpenFile(r *sftp.Request) (sftp.WriterAtReaderAt, error) {
	if !h.canWrite() || !h.canRead() {
		return nil, sftp.ErrSSHFxPermissionDenied
	}
	flags := r.Pflags()
	oflag := os.O_RDWR
	if flags.Creat {
		oflag |= os.O_CREATE
	}
	if flags.Trunc {
		oflag |= os.O_TRUNC
	}
	f, err := h.s.fs.OpenFile(rel(r.Filepath), oflag, 0o644)
	if err != nil {
		return nil, mapErr(err)
	}
	return f, nil
}

// Filecmd handles metadata operations.
func (h *shareHandlers) Filecmd(r *sftp.Request) error {
	if !h.canWrite() {
		return sftp.ErrSSHFxPermissionDenied
	}
	root := h.s.fs
	switch r.Method {
	case "Mkdir":
		return mapErr(root.Mkdir(rel(r.Filepath), 0o755))
	case "Setstat":
		// Best effort: honour mtime/mode when given, never fail an upload
		// because of it.
		attrs := r.Attributes()
		if attrs == nil {
			return nil
		}
		p := rel(r.Filepath)
		if r.AttrFlags().Permissions {
			_ = root.Chmod(p, attrs.FileMode().Perm())
		}
		if r.AttrFlags().Acmodtime {
			mt := time.Unix(int64(attrs.Mtime), 0)
			at := time.Unix(int64(attrs.Atime), 0)
			_ = root.Chtimes(p, at, mt)
		}
		if r.AttrFlags().Size && h.s.mode != WriteOnly {
			if f, err := root.OpenFile(p, os.O_WRONLY, 0); err == nil {
				_ = f.Truncate(int64(attrs.Size))
				f.Close()
			}
		}
		return nil
	}
	if h.s.mode == WriteOnly {
		// A drop box must not let clients rename/remove what is there.
		return sftp.ErrSSHFxPermissionDenied
	}
	switch r.Method {
	case "Rename", "PosixRename":
		return mapErr(root.Rename(rel(r.Filepath), rel(r.Target)))
	case "Rmdir":
		return mapErr(root.Remove(rel(r.Filepath)))
	case "Remove":
		return mapErr(root.Remove(rel(r.Filepath)))
	case "Symlink":
		return mapErr(root.Symlink(r.Target, rel(r.Filepath)))
	case "Link":
		return mapErr(root.Link(rel(r.Target), rel(r.Filepath)))
	}
	return sftp.ErrSSHFxOpUnsupported
}

// Filelist handles List / Stat / Readlink.
func (h *shareHandlers) Filelist(r *sftp.Request) (sftp.ListerAt, error) {
	root := h.s.fs
	p := rel(r.Filepath)
	switch r.Method {
	case "List":
		if !h.canRead() {
			return nil, sftp.ErrSSHFxPermissionDenied
		}
		infos, err := root.ReadDir(p)
		if err != nil {
			return nil, mapErr(err)
		}
		return listerAt(infos), nil
	case "Stat", "Lstat":
		// Stat is allowed in write-only mode so uploaders can check the
		// target directory exists; it is the one read a drop box permits.
		var fi os.FileInfo
		var err error
		if r.Method == "Lstat" {
			fi, err = root.Lstat(p)
		} else {
			fi, err = root.Stat(p)
		}
		if err != nil {
			return nil, mapErr(err)
		}
		return listerAt([]os.FileInfo{fi}), nil
	case "Readlink":
		if !h.canRead() {
			return nil, sftp.ErrSSHFxPermissionDenied
		}
		target, err := root.Readlink(p)
		if err != nil {
			return nil, mapErr(err)
		}
		return listerAt([]os.FileInfo{linkInfo(target)}), nil
	}
	return nil, sftp.ErrSSHFxOpUnsupported
}

// Lstat satisfies sftp.LstatFileLister.
func (h *shareHandlers) Lstat(r *sftp.Request) (sftp.ListerAt, error) {
	return h.Filelist(r)
}

// mapErr turns os errors into SFTP status codes clients understand.
func mapErr(err error) error {
	switch {
	case err == nil:
		return nil
	case os.IsNotExist(err):
		return sftp.ErrSSHFxNoSuchFile
	case os.IsPermission(err), errors.Is(err, errReadOnly):
		return sftp.ErrSSHFxPermissionDenied
	}
	return err
}

// listerAt is the simplest sftp.ListerAt.
type listerAt []os.FileInfo

func (l listerAt) ListAt(ls []os.FileInfo, offset int64) (int, error) {
	if offset >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(ls, l[offset:])
	if n < len(ls) {
		return n, io.EOF
	}
	return n, nil
}

// linkInfo is a fake FileInfo whose Name carries a symlink target, which is
// how pkg/sftp expects Readlink results.
type linkInfo string

func (l linkInfo) Name() string       { return string(l) }
func (l linkInfo) Size() int64        { return 0 }
func (l linkInfo) Mode() os.FileMode  { return os.ModeSymlink }
func (l linkInfo) ModTime() time.Time { return time.Time{} }
func (l linkInfo) IsDir() bool        { return false }
func (l linkInfo) Sys() any           { return nil }

// countingFile wraps an *os.File and reports progress. For uploads the
// total is unknown, so Bytes is the high-water mark of offset+len.
type countingFile struct {
	f     *os.File
	path  string
	total int64
	dir   string
	hooks Hooks
	start time.Time

	mu    sync.Mutex
	bytes int64
}

func (c *countingFile) ReadAt(p []byte, off int64) (int, error) {
	n, err := c.f.ReadAt(p, off)
	c.advance(off + int64(n))
	return n, err
}

func (c *countingFile) WriteAt(p []byte, off int64) (int, error) {
	n, err := c.f.WriteAt(p, off)
	c.advance(off + int64(n))
	return n, err
}

func (c *countingFile) advance(end int64) {
	c.mu.Lock()
	if c.total >= 0 && end > c.total {
		end = c.total // concurrent readers probe past EOF
	}
	if end > c.bytes {
		c.bytes = end
	}
	b := c.bytes
	c.mu.Unlock()
	c.hooks.progress(Progress{Path: c.path, Bytes: b, Total: c.total, Direction: c.dir, RateBPS: rate(b, c.start)})
}

func (c *countingFile) Close() error {
	err := c.f.Close()
	c.mu.Lock()
	b := c.bytes
	c.mu.Unlock()
	total := c.total
	if total < 0 {
		total = b
	}
	c.hooks.progress(Progress{Path: c.path, Bytes: b, Total: total, Direction: c.dir, RateBPS: rate(b, c.start), Done: true})
	return err
}

func rate(bytes int64, start time.Time) float64 {
	d := time.Since(start).Seconds()
	if d <= 0 {
		return 0
	}
	return float64(bytes) / d
}
