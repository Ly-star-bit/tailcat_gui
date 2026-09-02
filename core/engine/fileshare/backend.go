package fileshare

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// backend is the filesystem a share exposes. dirBackend serves one
// directory (rooted via os.Root); pathsBackend serves a hand-picked set of
// files and folders as a read-only virtual root ("send these files").
type backend interface {
	Open(rel string) (*os.File, error)
	OpenFile(rel string, flag int, perm os.FileMode) (*os.File, error)
	Stat(rel string) (os.FileInfo, error)
	Lstat(rel string) (os.FileInfo, error)
	ReadDir(rel string) ([]os.FileInfo, error)
	Readlink(rel string) (string, error)
	Mkdir(rel string, perm os.FileMode) error
	Remove(rel string) error
	Rename(from, to string) error
	Symlink(target, rel string) error
	Link(from, rel string) error
	Chmod(rel string, mode os.FileMode) error
	Chtimes(rel string, atime, mtime time.Time) error
	Close() error
}

// ---- one directory ----

type dirBackend struct{ root *os.Root }

func newDirBackend(dir string) (*dirBackend, error) {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return nil, err
	}
	return &dirBackend{root: root}, nil
}

func (d *dirBackend) Open(rel string) (*os.File, error) { return d.root.Open(rel) }
func (d *dirBackend) OpenFile(rel string, flag int, perm os.FileMode) (*os.File, error) {
	return d.root.OpenFile(rel, flag, perm)
}
func (d *dirBackend) Stat(rel string) (os.FileInfo, error)  { return d.root.Stat(rel) }
func (d *dirBackend) Lstat(rel string) (os.FileInfo, error) { return d.root.Lstat(rel) }
func (d *dirBackend) ReadDir(rel string) ([]os.FileInfo, error) {
	entries, err := fs.ReadDir(d.root.FS(), rel)
	if err != nil {
		return nil, err
	}
	infos := make([]os.FileInfo, 0, len(entries))
	for _, e := range entries {
		if fi, err := e.Info(); err == nil {
			infos = append(infos, fi)
		}
	}
	return infos, nil
}
func (d *dirBackend) Readlink(rel string) (string, error)       { return d.root.Readlink(rel) }
func (d *dirBackend) Mkdir(rel string, perm os.FileMode) error  { return d.root.Mkdir(rel, perm) }
func (d *dirBackend) Remove(rel string) error                   { return d.root.Remove(rel) }
func (d *dirBackend) Rename(from, to string) error              { return d.root.Rename(from, to) }
func (d *dirBackend) Symlink(target, rel string) error          { return d.root.Symlink(target, rel) }
func (d *dirBackend) Link(from, rel string) error               { return d.root.Link(from, rel) }
func (d *dirBackend) Chmod(rel string, mode os.FileMode) error  { return d.root.Chmod(rel, mode) }
func (d *dirBackend) Chtimes(rel string, a, m time.Time) error  { return d.root.Chtimes(rel, a, m) }
func (d *dirBackend) Close() error                              { return d.root.Close() }

// ---- a picked set of files / folders, read-only ----

// ShareItem describes one top-level item of a pathsBackend (also reported in
// the server manifest so receivers can show what is on offer).
type ShareItem struct {
	Name  string `json:"name"`
	Size  int64  `json:"size"`
	IsDir bool   `json:"is_dir"`
	Path  string `json:"-"`
}

type pathsBackend struct {
	entries []ShareItem
	byName  map[string]ShareItem
	roots   map[string]*os.Root // for directories
}

var errReadOnly = errors.New("read-only share")

func newPathsBackend(paths []string) (*pathsBackend, error) {
	b := &pathsBackend{byName: map[string]ShareItem{}, roots: map[string]*os.Root{}}
	for _, p := range paths {
		st, err := os.Stat(p)
		if err != nil {
			b.Close()
			return nil, err
		}
		name := uniqueName(b.byName, filepath.Base(p))
		e := ShareItem{Name: name, Size: st.Size(), IsDir: st.IsDir(), Path: p}
		if st.IsDir() {
			root, err := os.OpenRoot(p)
			if err != nil {
				b.Close()
				return nil, err
			}
			b.roots[name] = root
			e.Size = 0
		}
		b.entries = append(b.entries, e)
		b.byName[name] = e
	}
	sort.Slice(b.entries, func(i, j int) bool { return b.entries[i].Name < b.entries[j].Name })
	return b, nil
}

func uniqueName(taken map[string]ShareItem, name string) string {
	if _, ok := taken[name]; !ok {
		return name
	}
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for i := 2; ; i++ {
		cand := fmt.Sprintf("%s (%d)%s", base, i, ext)
		if _, ok := taken[cand]; !ok {
			return cand
		}
	}
}

// Entries lists the top-level items.
func (b *pathsBackend) Entries() []ShareItem { return b.entries }

// split resolves "name/sub/path" into the entry and the path inside it.
func (b *pathsBackend) split(rel string) (ShareItem, string, bool) {
	if rel == "." || rel == "" {
		return ShareItem{}, "", false
	}
	name, sub, _ := strings.Cut(rel, "/")
	e, ok := b.byName[name]
	if !ok {
		return ShareItem{}, "", false
	}
	if sub == "" {
		sub = "."
	}
	return e, sub, true
}

func (b *pathsBackend) Open(rel string) (*os.File, error) {
	e, sub, ok := b.split(rel)
	if !ok {
		return nil, os.ErrNotExist
	}
	if !e.IsDir {
		if sub != "." {
			return nil, os.ErrNotExist
		}
		return os.Open(e.Path)
	}
	return b.roots[e.Name].Open(sub)
}

func (b *pathsBackend) OpenFile(rel string, flag int, perm os.FileMode) (*os.File, error) {
	if flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC|os.O_APPEND) != 0 {
		return nil, errReadOnly
	}
	return b.Open(rel)
}

func (b *pathsBackend) Stat(rel string) (os.FileInfo, error) {
	if rel == "." || rel == "" {
		return virtualDir("."), nil
	}
	e, sub, ok := b.split(rel)
	if !ok {
		return nil, os.ErrNotExist
	}
	if !e.IsDir {
		if sub != "." {
			return nil, os.ErrNotExist
		}
		return os.Stat(e.Path)
	}
	return b.roots[e.Name].Stat(sub)
}

func (b *pathsBackend) Lstat(rel string) (os.FileInfo, error) { return b.Stat(rel) }

func (b *pathsBackend) ReadDir(rel string) ([]os.FileInfo, error) {
	if rel == "." || rel == "" {
		out := make([]os.FileInfo, 0, len(b.entries))
		for _, e := range b.entries {
			if e.IsDir {
				out = append(out, renamedInfo{virtualDir(e.Name), e.Name})
				continue
			}
			if fi, err := os.Stat(e.Path); err == nil {
				out = append(out, renamedInfo{fi, e.Name})
			}
		}
		return out, nil
	}
	e, sub, ok := b.split(rel)
	if !ok || !e.IsDir {
		return nil, os.ErrNotExist
	}
	entries, err := fs.ReadDir(b.roots[e.Name].FS(), sub)
	if err != nil {
		return nil, err
	}
	infos := make([]os.FileInfo, 0, len(entries))
	for _, de := range entries {
		if fi, err := de.Info(); err == nil {
			infos = append(infos, fi)
		}
	}
	return infos, nil
}

func (b *pathsBackend) Readlink(string) (string, error)           { return "", os.ErrNotExist }
func (b *pathsBackend) Mkdir(string, os.FileMode) error           { return errReadOnly }
func (b *pathsBackend) Remove(string) error                       { return errReadOnly }
func (b *pathsBackend) Rename(string, string) error               { return errReadOnly }
func (b *pathsBackend) Symlink(string, string) error              { return errReadOnly }
func (b *pathsBackend) Link(string, string) error                 { return errReadOnly }
func (b *pathsBackend) Chmod(string, os.FileMode) error           { return errReadOnly }
func (b *pathsBackend) Chtimes(string, time.Time, time.Time) error { return errReadOnly }

func (b *pathsBackend) Close() error {
	for _, r := range b.roots {
		r.Close()
	}
	return nil
}

// virtualDir is a FileInfo for a directory that exists only in the share.
type virtualDir string

func (v virtualDir) Name() string       { return string(v) }
func (v virtualDir) Size() int64        { return 0 }
func (v virtualDir) Mode() os.FileMode  { return os.ModeDir | 0o755 }
func (v virtualDir) ModTime() time.Time { return time.Time{} }
func (v virtualDir) IsDir() bool        { return true }
func (v virtualDir) Sys() any           { return nil }

// renamedInfo presents a FileInfo under a (possibly de-duplicated) name.
type renamedInfo struct {
	os.FileInfo
	name string
}

func (r renamedInfo) Name() string { return r.name }
