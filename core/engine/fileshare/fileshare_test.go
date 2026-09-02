package fileshare

import (
	"bytes"
	"context"
	"crypto/rand"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// startLoopback serves dir on 127.0.0.1 and returns a dial func.
func startLoopback(t *testing.T, dir string, mode Mode, hooks Hooks) (*Server, func() net.Conn) {
	t.Helper()
	srv, err := NewServer(dir, mode, hooks)
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	h := srv.Handler()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go h(c)
		}
	}()
	t.Cleanup(func() { ln.Close(); srv.Close() })
	return srv, func() net.Conn {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
}

func newTestClient(t *testing.T, dial func() net.Conn) *Client {
	t.Helper()
	cl, err := NewClient(dial())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cl.Close() })
	return cl
}

type recorder struct {
	mu   sync.Mutex
	last map[string]Progress
	n    int
}

func (r *recorder) hook(p Progress) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.last == nil {
		r.last = map[string]Progress{}
	}
	r.last[p.Path] = p
	r.n++
}

func TestRoundTripReadWrite(t *testing.T) {
	share := t.TempDir()
	local := t.TempDir()
	srvRec := &recorder{}
	_, dial := startLoopback(t, share, ReadWrite, Hooks{OnProgress: srvRec.hook})
	cl := newTestClient(t, dial)

	payload := make([]byte, 3*1024*1024+123)
	rand.Read(payload)
	src := filepath.Join(local, "big.bin")
	if err := os.WriteFile(src, payload, 0o644); err != nil {
		t.Fatal(err)
	}

	cliRec := &recorder{}
	ctx := context.Background()
	if err := cl.Upload(ctx, src, "inbox", cliRec.hook); err != nil {
		t.Fatalf("upload: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(share, "inbox", "big.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("uploaded bytes differ")
	}
	if p := cliRec.last["inbox/big.bin"]; !p.Done || p.Bytes != int64(len(payload)) || p.Total != int64(len(payload)) {
		t.Fatalf("client progress = %+v", p)
	}
	// Server saw the upload as a download with the final size.
	srvRec.mu.Lock()
	sp := srvRec.last["/inbox/big.bin"]
	srvRec.mu.Unlock()
	if !sp.Done || sp.Bytes != int64(len(payload)) || sp.Direction != DirDownload {
		t.Fatalf("server progress = %+v", sp)
	}

	entries, err := cl.List("inbox")
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name != "big.bin" || entries[0].Size != int64(len(payload)) {
		t.Fatalf("list = %+v", entries)
	}

	down := t.TempDir()
	dlRec := &recorder{}
	if err := cl.Download(ctx, "inbox/big.bin", down, dlRec.hook); err != nil {
		t.Fatalf("download: %v", err)
	}
	got, err = os.ReadFile(filepath.Join(down, "big.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("downloaded bytes differ")
	}
	if p := dlRec.last["inbox/big.bin"]; !p.Done || p.Bytes != int64(len(payload)) || p.Direction != DirDownload {
		t.Fatalf("download progress = %+v", p)
	}
}

func TestDirectoryUploadAndDownload(t *testing.T) {
	share := t.TempDir()
	local := t.TempDir()
	tree := filepath.Join(local, "tree")
	os.MkdirAll(filepath.Join(tree, "a", "b"), 0o755)
	os.WriteFile(filepath.Join(tree, "top.txt"), []byte("top"), 0o644)
	os.WriteFile(filepath.Join(tree, "a", "b", "deep.txt"), []byte("deep"), 0o644)

	_, dial := startLoopback(t, share, ReadWrite, Hooks{})
	cl := newTestClient(t, dial)
	ctx := context.Background()
	if err := cl.Upload(ctx, tree, "", nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(share, "tree", "a", "b", "deep.txt")); string(b) != "deep" {
		t.Fatalf("deep.txt = %q", b)
	}
	down := t.TempDir()
	if err := cl.Download(ctx, "tree", down, nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(down, "tree", "top.txt")); string(b) != "top" {
		t.Fatalf("top.txt = %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(down, "tree", "a", "b", "deep.txt")); string(b) != "deep" {
		t.Fatalf("deep.txt = %q", b)
	}
}

func TestReadOnlyDeniesWrites(t *testing.T) {
	share := t.TempDir()
	os.WriteFile(filepath.Join(share, "x.txt"), []byte("x"), 0o644)
	_, dial := startLoopback(t, share, ReadOnly, Hooks{})
	cl := newTestClient(t, dial)
	src := filepath.Join(t.TempDir(), "y.txt")
	os.WriteFile(src, []byte("y"), 0o644)
	if err := cl.Upload(context.Background(), src, "", nil); err == nil {
		t.Fatal("upload succeeded on read-only share")
	}
	if err := cl.sftp.Mkdir("d"); err == nil {
		t.Fatal("mkdir succeeded on read-only share")
	}
	if _, err := cl.List(""); err != nil {
		t.Fatalf("list on read-only share: %v", err)
	}
}

func TestWriteOnlyIsADropBox(t *testing.T) {
	share := t.TempDir()
	os.WriteFile(filepath.Join(share, "secret.txt"), []byte("s"), 0o644)
	_, dial := startLoopback(t, share, WriteOnly, Hooks{})
	cl := newTestClient(t, dial)
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "drop.txt")
	os.WriteFile(src, []byte("dropped"), 0o644)
	if err := cl.Upload(ctx, src, "", nil); err != nil {
		t.Fatalf("upload to drop box: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(share, "drop.txt")); string(b) != "dropped" {
		t.Fatalf("drop.txt = %q", b)
	}
	if _, err := cl.List(""); err == nil {
		t.Fatal("list succeeded on write-only share")
	}
	if err := cl.Download(ctx, "secret.txt", t.TempDir(), nil); err == nil {
		t.Fatal("download succeeded on write-only share")
	}
	if err := cl.sftp.Remove("secret.txt"); err == nil {
		t.Fatal("remove succeeded on write-only share")
	}
}

func TestPathEscapeIsBlocked(t *testing.T) {
	parent := t.TempDir()
	share := filepath.Join(parent, "share")
	os.MkdirAll(share, 0o755)
	os.WriteFile(filepath.Join(parent, "outside.txt"), []byte("outside"), 0o644)
	os.Symlink(filepath.Join(parent, "outside.txt"), filepath.Join(share, "link"))
	_, dial := startLoopback(t, share, ReadWrite, Hooks{})
	cl := newTestClient(t, dial)
	for _, p := range []string{"../outside.txt", "/../outside.txt", "link"} {
		if f, err := cl.sftp.Open(p); err == nil {
			f.Close()
			t.Fatalf("read %q escaped the share root", p)
		}
	}
	// SFTP paths are absolute: "/../pwned" clamps to the root, like a real FS.
	_ = cl.sftp.Mkdir("../pwned")
	if _, err := os.Stat(filepath.Join(parent, "pwned")); err == nil {
		t.Fatal("mkdir escaped the share root")
	}
	if _, err := os.Stat(filepath.Join(share, "pwned")); err != nil {
		t.Fatalf("mkdir ../pwned should land inside the share: %v", err)
	}
}

func TestCancelAbortsTransfer(t *testing.T) {
	share := t.TempDir()
	_, dial := startLoopback(t, share, ReadWrite, Hooks{})
	cl := newTestClient(t, dial)
	src := filepath.Join(t.TempDir(), "huge.bin")
	f, _ := os.Create(src)
	f.Truncate(64 << 20)
	f.Close()
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
		cl.Close()
	}()
	if err := cl.Upload(ctx, src, "", nil); err == nil {
		t.Fatal("upload finished despite cancel")
	}
}
