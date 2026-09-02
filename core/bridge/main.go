// Package main builds the C shared library (libtailcat_core) that the
// Flutter app loads through dart:ffi. See bridge.h for the contract.
//
// Build (see ../../build/*.sh):
//
//	go build -buildmode=c-shared -o libtailcat_core.dylib ./bridge
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"unsafe"

	"tailcat_gui/core/engine"
)

var (
	mu  sync.Mutex
	eng *engine.Engine
	ver = C.CString("") // replaced lazily by tc_version
)

type initConfig struct {
	DataDir    string `json:"data_dir"`
	DERPMapURL string `json:"derpmap_url"`
}

func currentEngine() *engine.Engine {
	mu.Lock()
	defer mu.Unlock()
	if eng == nil {
		eng = engine.New(engine.Config{})
	}
	return eng
}

//export tc_init
func tc_init(configJSON *C.char) C.int {
	var cfg initConfig
	if configJSON != nil {
		s := C.GoString(configJSON)
		if s != "" {
			if err := json.Unmarshal([]byte(s), &cfg); err != nil {
				return 1
			}
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if eng != nil {
		return 0
	}
	if cfg.DataDir != "" {
		_ = os.MkdirAll(cfg.DataDir, 0o700)
	}
	eng = engine.New(engine.Config{DataDir: cfg.DataDir, DERPMapURL: cfg.DERPMapURL})
	return 0
}

//export tc_call
func tc_call(requestJSON *C.char) *C.char {
	req := ""
	if requestJSON != nil {
		req = C.GoString(requestJSON)
	}
	out := currentEngine().Call([]byte(req))
	return C.CString(string(out))
}

//export tc_poll
func tc_poll() *C.char {
	return C.CString(string(currentEngine().Poll()))
}

//export tc_free
func tc_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

var versionOnce sync.Once

//export tc_version
func tc_version() *C.char {
	versionOnce.Do(func() {
		ver = C.CString(fmt.Sprintf("core/%s", engine.Version))
	})
	return ver
}

//export tc_shutdown
func tc_shutdown() {
	mu.Lock()
	e := eng
	eng = nil
	mu.Unlock()
	if e != nil {
		e.Close()
	}
}

func main() {}
