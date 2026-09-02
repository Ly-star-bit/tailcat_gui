// Command sshprobe serves the GUI's no-auth SFTP/SSH server on localhost so
// SSH clients can be tested against it without a tunnel. Debug aid only.
package main

import (
	"flag"
	"log"
	"net"
	"os"

	"tailcat_gui/core/engine/fileshare"
)

func main() {
	addr := flag.String("listen", "127.0.0.1:0", "listen address")
	flag.Parse()
	dir, err := os.MkdirTemp("", "sshprobe")
	if err != nil {
		log.Fatal(err)
	}
	srv, err := fileshare.NewServer(dir, fileshare.ReadWrite, fileshare.Hooks{
		Logf: func(f string, a ...any) { log.Printf(f, a...) },
	})
	if err != nil {
		log.Fatal(err)
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("PORT=%d", ln.Addr().(*net.TCPAddr).Port)
	h := srv.Handler()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go h(c)
	}
}
