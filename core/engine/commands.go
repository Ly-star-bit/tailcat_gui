package engine

import (
	"encoding/json"
	"errors"
	"fmt"
)

// Request is the JSON envelope passed to Engine.Call.
type Request struct {
	Op   string          `json:"op"`
	Args json.RawMessage `json:"args"`
}

// Response is the JSON envelope returned by Engine.Call.
type Response struct {
	OK     bool       `json:"ok"`
	Result any        `json:"result,omitempty"`
	Error  *ErrorBody `json:"error,omitempty"`
}

// ErrorBody carries a machine-readable code plus a human message.
type ErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Error codes.
const (
	CodeBadRequest   = "bad_request"
	CodeInvalidToken = "invalid_token"
	CodeUnsupported  = "unsupported"
	CodeNotFound     = "not_found"
	CodeInternal     = "internal"
)

// codedError is an error with an API error code attached.
type codedError struct {
	code string
	err  error
}

func (e *codedError) Error() string { return e.err.Error() }
func (e *codedError) Unwrap() error { return e.err }

func errCode(code string, format string, args ...any) error {
	return &codedError{code: code, err: fmt.Errorf(format, args...)}
}

func codeOf(err error) string {
	var ce *codedError
	if errors.As(err, &ce) {
		return ce.code
	}
	return CodeInternal
}

// ---- command argument structs ----

// FilesSpec describes a directory to share over SFTP.
type FilesSpec struct {
	Dir  string `json:"dir"`
	Mode string `json:"mode"` // ro | rw | wo
}

// StartServerArgs mirrors `tailcat serve`.
type StartServerArgs struct {
	Ports    []int      `json:"ports"`     // TCP ports on localhost to expose
	All      bool       `json:"all"`       // expose every local port
	ExitNode bool       `json:"exit_node"` // allow arbitrary destinations (SOCKS via us)
	Files    *FilesSpec `json:"files"`     // SFTP share on port 22
	SSH      bool       `json:"ssh"`       // no-auth SSH shell on port 22 (desktop only)
	Key      string     `json:"key"`       // "" | "new" | saved key name (reserved)
}

// StartForwardArgs: listen locally, forward each connection to the server's remote_port.
type StartForwardArgs struct {
	Token      string `json:"token"`
	LocalPort  int    `json:"local_port"` // 0 = pick a free port
	RemotePort int    `json:"remote_port"`
	BindAll    bool   `json:"bind_all"` // listen on 0.0.0.0 instead of 127.0.0.1
}

// StartSocksArgs: local SOCKS5 proxy whose connections go through the server.
type StartSocksArgs struct {
	Token  string `json:"token"`
	Listen string `json:"listen"` // "[addr]:port"; bare port = localhost
}

// SendFilesArgs uploads local files into the server's shared directory.
type SendFilesArgs struct {
	Token     string   `json:"token"`
	Paths     []string `json:"paths"`
	RemoteDir string   `json:"remote_dir"`
}

// ListRemoteArgs lists a directory on the server's share.
type ListRemoteArgs struct {
	Token string `json:"token"`
	Dir   string `json:"dir"`
}

// DownloadArgs fetches remote files into a local directory.
type DownloadArgs struct {
	Token       string   `json:"token"`
	RemotePaths []string `json:"remote_paths"`
	LocalDir    string   `json:"local_dir"`
}

// TokenArgs is shared by ping / parse_token / start_ssh_forward.
type TokenArgs struct {
	Token   string  `json:"token"`
	Timeout float64 `json:"timeout_s"`
}

// SessionArgs identifies a session.
type SessionArgs struct {
	SessionID string `json:"session_id"`
}

// Call parses a JSON request, dispatches it and returns the JSON response.
// It never panics and never returns invalid JSON.
func (e *Engine) Call(reqJSON []byte) (out []byte) {
	defer func() {
		if r := recover(); r != nil {
			out = mustJSON(Response{OK: false, Error: &ErrorBody{
				Code: CodeInternal, Message: fmt.Sprintf("panic: %v", r),
			}})
		}
	}()
	var req Request
	if err := json.Unmarshal(reqJSON, &req); err != nil {
		return mustJSON(Response{OK: false, Error: &ErrorBody{
			Code: CodeBadRequest, Message: "invalid JSON request: " + err.Error(),
		}})
	}
	res, err := e.dispatch(req)
	if err != nil {
		return mustJSON(Response{OK: false, Error: &ErrorBody{
			Code: codeOf(err), Message: err.Error(),
		}})
	}
	if res == nil {
		res = map[string]any{}
	}
	return mustJSON(Response{OK: true, Result: res})
}

func (e *Engine) dispatch(req Request) (any, error) {
	if len(req.Args) == 0 {
		req.Args = json.RawMessage("{}")
	}
	switch req.Op {
	case "get_caps":
		return e.caps(), nil
	case "list_sessions":
		return e.listSessions(), nil
	case "stop":
		var a SessionArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return nil, e.stopSession(a.SessionID)
	case "parse_token":
		var a TokenArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return parseToken(a.Token)
	case "ping":
		var a TokenArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.ping(a)
	case "start_server":
		var a StartServerArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.startServer(a)
	case "start_forward":
		var a StartForwardArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.startForward(a, KindForward)
	case "start_ssh_forward":
		var a TokenArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.startSSHForward(a)
	case "start_socks":
		var a StartSocksArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.startSocks(a)
	case "send_files":
		var a SendFilesArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.sendFiles(a)
	case "list_remote":
		var a ListRemoteArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.listRemote(a)
	case "download":
		var a DownloadArgs
		if err := decode(req.Args, &a); err != nil {
			return nil, err
		}
		return e.download(a)
	default:
		return nil, errCode(CodeBadRequest, "unknown op %q", req.Op)
	}
}

func decode(raw json.RawMessage, into any) error {
	if err := json.Unmarshal(raw, into); err != nil {
		return errCode(CodeBadRequest, "invalid args: %v", err)
	}
	return nil
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		// Only reachable if a result contains an unmarshalable value; keep
		// the contract of always returning valid JSON.
		return []byte(`{"ok":false,"error":{"code":"internal","message":"marshal failure"}}`)
	}
	return b
}
