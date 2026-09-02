//go:build (linux || darwin || windows) && !ts_omit_ssh

package engine

import (
	"net"

	"tailcat_gui/core/engine/fileshare"

	"github.com/tailscale/tailcat"
)

// sshShellSupported reports whether `serve no-auth-ssh` works here.
func sshShellSupported() bool { return tailcat.SupportsSSHServer() }

// sshShellHandler returns tailcat's built-in auth-free SSH server (shell +
// SFTP). With files set, SFTP is rooted there; otherwise, as in the CLI,
// SFTP sees whatever the shell user can see.
func sshShellHandler(srv *tailcat.Server, files *FilesSpec) (func(net.Conn), error) {
	opts := tailcat.SSHOptions{Shell: true}
	if files != nil {
		m, err := fileshare.ParseMode(files.Mode)
		if err != nil {
			return nil, errCode(CodeBadRequest, "%v", err)
		}
		opts.Files = &tailcat.FileService{Dir: files.Dir, Mode: m.TailcatMode()}
	}
	return srv.SSHConnHandler(opts), nil
}
