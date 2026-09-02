//go:build cgo && (android || linux || darwin)

package engine

// Interface enumeration via libc getifaddrs(3).
//
// Go's net.Interfaces() dumps the routing table over a NETLINK_ROUTE socket
// (RTM_GETLINK). Android 11 (API 30) forbids that for apps, so on a phone it
// fails with "route ip+net: netlinkrib: permission denied" and every part of
// tailscale that needs the interface list dies with it.
//
// libc's getifaddrs() is the supported path on Android: it is what Java's
// NetworkInterface uses, and bionic implements it without the forbidden
// netlink dump. Calling it directly keeps everything inside Go, with no JNI
// or Kotlin glue in the FFI plugin.
//
// The same code builds on Linux and macOS, where it is unused in production
// but exercised by tests against net.Interfaces().

/*
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

// tc_if_mtu returns the interface MTU, or 0 if it cannot be read.
static int tc_if_mtu(const char *name) {
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		return 0;
	}
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
	int mtu = 0;
	if (ioctl(fd, SIOCGIFMTU, &ifr) == 0) {
		mtu = ifr.ifr_mtu;
	}
	close(fd);
	return mtu;
}
*/
import "C"

import (
	"errors"
	"net"
	"unsafe"

	"tailscale.com/net/netmon"
)

// getifaddrsInterfaces lists the machine's interfaces and their addresses
// using libc, bypassing Go's netlink implementation.
func getifaddrsInterfaces() ([]netmon.Interface, error) {
	var head *C.struct_ifaddrs
	if rc, err := C.getifaddrs(&head); rc != 0 {
		if err == nil {
			err = errors.New("getifaddrs failed")
		}
		return nil, err
	}
	defer C.freeifaddrs(head)

	byName := map[string]*netmon.Interface{}
	var order []string
	for ifa := head; ifa != nil; ifa = ifa.ifa_next {
		if ifa.ifa_name == nil {
			continue
		}
		name := C.GoString(ifa.ifa_name)
		iface, ok := byName[name]
		if !ok {
			ni := &net.Interface{
				Index: int(C.if_nametoindex(ifa.ifa_name)),
				Name:  name,
				MTU:   int(C.tc_if_mtu(ifa.ifa_name)),
				Flags: goFlags(uint32(ifa.ifa_flags)),
			}
			// AltAddrs must be non-nil for netmon.Interface.Addrs to use it
			// instead of falling back to the standard library.
			iface = &netmon.Interface{Interface: ni, AltAddrs: []net.Addr{}}
			byName[name] = iface
			order = append(order, name)
		}
		if addr := goAddr(ifa.ifa_addr, ifa.ifa_netmask); addr != nil {
			iface.AltAddrs = append(iface.AltAddrs, addr)
		}
	}

	out := make([]netmon.Interface, 0, len(order))
	for _, name := range order {
		out = append(out, *byName[name])
	}
	if len(out) == 0 {
		return nil, errors.New("getifaddrs returned no interfaces")
	}
	return out, nil
}

// goAddr converts one getifaddrs address/netmask pair into a *net.IPNet,
// matching what net.Interface.Addrs returns. Non-IP families yield nil.
func goAddr(sa, mask *C.struct_sockaddr) net.Addr {
	if sa == nil {
		return nil
	}
	switch sa.sa_family {
	case C.AF_INET:
		in := (*C.struct_sockaddr_in)(unsafe.Pointer(sa))
		ip := make(net.IP, net.IPv4len)
		copy(ip, (*[net.IPv4len]byte)(unsafe.Pointer(&in.sin_addr))[:])
		return &net.IPNet{IP: ip, Mask: ipv4Mask(mask)}
	case C.AF_INET6:
		in6 := (*C.struct_sockaddr_in6)(unsafe.Pointer(sa))
		ip := make(net.IP, net.IPv6len)
		copy(ip, (*[net.IPv6len]byte)(unsafe.Pointer(&in6.sin6_addr))[:])
		return &net.IPNet{IP: ip, Mask: ipv6Mask(mask)}
	}
	return nil
}

func ipv4Mask(mask *C.struct_sockaddr) net.IPMask {
	if mask == nil || mask.sa_family != C.AF_INET {
		return net.CIDRMask(32, 32)
	}
	in := (*C.struct_sockaddr_in)(unsafe.Pointer(mask))
	m := make(net.IPMask, net.IPv4len)
	copy(m, (*[net.IPv4len]byte)(unsafe.Pointer(&in.sin_addr))[:])
	return m
}

func ipv6Mask(mask *C.struct_sockaddr) net.IPMask {
	if mask == nil || mask.sa_family != C.AF_INET6 {
		return net.CIDRMask(128, 128)
	}
	in6 := (*C.struct_sockaddr_in6)(unsafe.Pointer(mask))
	m := make(net.IPMask, net.IPv6len)
	copy(m, (*[net.IPv6len]byte)(unsafe.Pointer(&in6.sin6_addr))[:])
	return m
}

// goFlags maps IFF_* bits onto net.Flags, the way the standard library does.
func goFlags(f uint32) net.Flags {
	var out net.Flags
	for _, m := range []struct {
		c uint32
		g net.Flags
	}{
		{C.IFF_UP, net.FlagUp},
		{C.IFF_RUNNING, net.FlagRunning},
		{C.IFF_BROADCAST, net.FlagBroadcast},
		{C.IFF_LOOPBACK, net.FlagLoopback},
		{C.IFF_POINTOPOINT, net.FlagPointToPoint},
		{C.IFF_MULTICAST, net.FlagMulticast},
	} {
		if f&m.c != 0 {
			out |= m.g
		}
	}
	return out
}
