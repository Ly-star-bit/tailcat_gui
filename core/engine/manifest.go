package engine

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"runtime"
	"strings"
	"time"

	"tailcat_gui/core/engine/fileshare"
)

// manifestPort is where a GUI server describes what it offers. It is the
// tailcat CLI's default pipe port, so `tailcat <token>` against a GUI server
// prints the manifest, which is a reasonable "hello".
const manifestPort = 1

// manifestApp identifies our manifest among arbitrary port-1 services.
const manifestApp = "tailcat-gui"

// Manifest is what a GUI server publishes on manifestPort so the other side
// can show the right actions without the user picking a mode.
type Manifest struct {
	App      string   `json:"app"`
	Version  string   `json:"version"`
	Name     string   `json:"name"`     // device name
	Platform string   `json:"platform"` // GOOS
	Ports    []int    `json:"ports,omitempty"`
	All      bool     `json:"all,omitempty"`
	ExitNode bool     `json:"exit_node,omitempty"`
	SSH      bool     `json:"ssh,omitempty"`
	// Files is non-nil when port 22 serves SFTP. Mode is ro|rw|wo.
	Files *ManifestFiles `json:"files,omitempty"`
}

// ManifestFiles describes the file service.
type ManifestFiles struct {
	Mode string `json:"mode"`
	// Items lists what a "send these files" share offers (nil for a
	// directory share).
	Items []fileshare.ShareItem `json:"items,omitempty"`
	// Dir is the shared directory's base name (informational).
	Dir string `json:"dir,omitempty"`
}

func deviceName(override string) string {
	if override = strings.TrimSpace(override); override != "" {
		return override
	}
	if h, err := os.Hostname(); err == nil && h != "" {
		return strings.TrimSuffix(h, ".local")
	}
	return runtime.GOOS
}

// manifestHandler writes the manifest as one JSON line and closes.
func manifestHandler(m Manifest) func(net.Conn) {
	body, _ := json.Marshal(m)
	body = append(body, '\n')
	return func(c net.Conn) {
		defer c.Close()
		c.SetWriteDeadline(time.Now().Add(10 * time.Second))
		c.Write(body)
	}
}

// readManifest reads one JSON line from a manifest connection.
func readManifest(ctx context.Context, conn net.Conn) (*Manifest, error) {
	if dl, ok := ctx.Deadline(); ok {
		conn.SetReadDeadline(dl)
	}
	line, err := bufio.NewReader(io.LimitReader(conn, 1<<20)).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(line, &m); err != nil {
		return nil, err
	}
	if m.App != manifestApp {
		return nil, errCode(CodeInternal, "not a tailcat-gui manifest")
	}
	return &m, nil
}
