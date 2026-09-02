package fileshare

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func startPathsLoopback(t *testing.T, paths []string) (*Server, func() net.Conn) {
	t.Helper()
	srv, err := NewPathsServer(paths, Hooks{})
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

func TestPathsShareServesPickedFilesReadOnly(t *testing.T) {
	src := t.TempDir()
	other := t.TempDir()
	os.WriteFile(filepath.Join(src, "a.txt"), []byte("aaa"), 0o644)
	os.WriteFile(filepath.Join(other, "a.txt"), []byte("second a"), 0o644) // name clash
	os.MkdirAll(filepath.Join(src, "folder", "sub"), 0o755)
	os.WriteFile(filepath.Join(src, "folder", "sub", "deep.txt"), []byte("deep"), 0o644)
	os.WriteFile(filepath.Join(src, "hidden.txt"), []byte("not shared"), 0o644)

	srv, dial := startPathsLoopback(t, []string{
		filepath.Join(src, "a.txt"), filepath.Join(other, "a.txt"), filepath.Join(src, "folder"),
	})
	items := srv.Entries()
	if len(items) != 3 {
		t.Fatalf("entries = %+v", items)
	}
	cl := newTestClient(t, dial)

	entries, err := cl.List(".")
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, e := range entries {
		names[e.Name] = true
	}
	if !names["a.txt"] || !names["a (2).txt"] || !names["folder"] || names["hidden.txt"] {
		t.Fatalf("root listing = %v", names)
	}

	down := t.TempDir()
	ctx := context.Background()
	if err := cl.Download(ctx, ".", down, nil); err != nil {
		t.Fatalf("download all: %v", err)
	}
	for f, want := range map[string]string{
		"a.txt": "aaa", "a (2).txt": "second a", filepath.Join("folder", "sub", "deep.txt"): "deep",
	} {
		if b, _ := os.ReadFile(filepath.Join(down, f)); string(b) != want {
			t.Fatalf("%s = %q, want %q", f, b, want)
		}
	}
	if _, err := os.Stat(filepath.Join(down, "hidden.txt")); err == nil {
		t.Fatal("unshared file leaked")
	}

	up := filepath.Join(t.TempDir(), "x.txt")
	os.WriteFile(up, []byte("x"), 0o644)
	if err := cl.Upload(ctx, up, "", nil); err == nil {
		t.Fatal("upload succeeded on a paths share")
	}
	if err := cl.sftp.Remove("a.txt"); err == nil {
		t.Fatal("remove succeeded on a paths share")
	}
	if _, err := cl.sftp.Stat("a.txt/../hidden.txt"); err == nil {
		t.Fatal("path traversal reached an unshared file")
	}
}
