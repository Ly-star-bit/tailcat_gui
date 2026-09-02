//go:build !((linux || darwin || windows) && !ts_omit_ssh)

package engine

import (
	"net"

	"github.com/tailscale/tailcat"
)

func sshShellSupported() bool { return false }

func sshShellHandler(*tailcat.Server, *FilesSpec) (func(net.Conn), error) {
	return nil, errCode(CodeUnsupported, "no-auth SSH server is not supported on this platform")
}
