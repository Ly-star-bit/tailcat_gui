//go:build android

package engine

import (
	"net"

	"tailscale.com/net/netmon"
)

// On Android 11 (API 30) and later, an app may not dump the routing table
// over netlink, so Go's net.Interfaces() fails with
//
//	route ip+net: netlinkrib: permission denied
//
// and tailscale's network monitor, netcheck and magicsock all fail with it.
// tailscale exposes RegisterInterfaceGetter for exactly this case; we answer
// it with libc's getifaddrs(3), the same call Java's NetworkInterface makes.
func init() {
	netmon.RegisterInterfaceGetter(androidInterfaces)
}

func androidInterfaces() ([]netmon.Interface, error) {
	ifs, err := getifaddrsInterfaces()
	if err == nil {
		return ifs, nil
	}
	// Older Android versions still allow the netlink dump; if getifaddrs is
	// the one that failed, the standard library may still work.
	stdIfs, stdErr := net.Interfaces()
	if stdErr != nil {
		return nil, err
	}
	out := make([]netmon.Interface, len(stdIfs))
	for i := range stdIfs {
		out[i].Interface = &stdIfs[i]
	}
	return out, nil
}
