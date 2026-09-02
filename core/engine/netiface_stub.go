//go:build !(cgo && (android || linux || darwin))

package engine

import (
	"errors"

	"tailscale.com/net/netmon"
)

// getifaddrsInterfaces is unavailable without cgo on a POSIX platform.
func getifaddrsInterfaces() ([]netmon.Interface, error) {
	return nil, errors.New("getifaddrs is unavailable on this build")
}
