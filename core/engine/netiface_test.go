package engine

import (
	"net"
	"runtime"
	"sort"
	"testing"
)

// TestGetifaddrsMatchesStdlib checks the libc-based interface lister used on
// Android against the standard library on a platform where both work.
func TestGetifaddrsMatchesStdlib(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skipf("no getifaddrs on %s", runtime.GOOS)
	}
	got, err := getifaddrsInterfaces()
	if err != nil {
		t.Skipf("getifaddrs unavailable: %v", err)
	}
	want, err := net.Interfaces()
	if err != nil {
		t.Skipf("net.Interfaces unavailable: %v", err)
	}

	gotByName := map[string]int{}   // name -> index
	gotAddrs := map[string][]string{}
	for _, i := range got {
		if i.Interface == nil {
			t.Fatalf("interface %+v has no net.Interface", i)
		}
		gotByName[i.Name] = i.Index
		addrs, err := i.Addrs()
		if err != nil {
			t.Fatalf("Addrs(%s): %v", i.Name, err)
		}
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				t.Fatalf("Addrs(%s) returned %T, want *net.IPNet", i.Name, a)
			}
			gotAddrs[i.Name] = append(gotAddrs[i.Name], ipn.String())
		}
	}

	for _, w := range want {
		idx, ok := gotByName[w.Name]
		if !ok {
			t.Errorf("interface %q missing from getifaddrs", w.Name)
			continue
		}
		if idx != w.Index {
			t.Errorf("interface %q index = %d, want %d", w.Name, idx, w.Index)
		}
		wantAddrs, err := w.Addrs()
		if err != nil {
			continue
		}
		var wantStrs []string
		for _, a := range wantAddrs {
			if ipn, ok := a.(*net.IPNet); ok {
				wantStrs = append(wantStrs, ipn.String())
			}
		}
		gotStrs := gotAddrs[w.Name]
		sort.Strings(wantStrs)
		sort.Strings(gotStrs)
		if len(wantStrs) != len(gotStrs) {
			t.Errorf("interface %q addrs = %v, want %v", w.Name, gotStrs, wantStrs)
			continue
		}
		for i := range wantStrs {
			if wantStrs[i] != gotStrs[i] {
				t.Errorf("interface %q addr %d = %s, want %s", w.Name, i, gotStrs[i], wantStrs[i])
			}
		}
	}

	// Flags that tailscale actually branches on must agree.
	for _, w := range want {
		for _, g := range got {
			if g.Name != w.Name {
				continue
			}
			if g.IsUp() != (w.Flags&net.FlagUp != 0) {
				t.Errorf("interface %q up = %v, want %v", w.Name, g.IsUp(), w.Flags&net.FlagUp != 0)
			}
			if g.IsLoopback() != (w.Flags&net.FlagLoopback != 0) {
				t.Errorf("interface %q loopback = %v, want %v", w.Name, g.IsLoopback(), w.Flags&net.FlagLoopback != 0)
			}
		}
	}
}
