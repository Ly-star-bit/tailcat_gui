package engine

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/proxy"
)

func call(t *testing.T, e *Engine, op string, args any) (Response, map[string]any) {
	t.Helper()
	a, _ := json.Marshal(args)
	raw := e.Call(mustJSON(Request{Op: op, Args: a}))
	var resp Response
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatalf("%s: invalid JSON response %s: %v", op, raw, err)
	}
	res, _ := resp.Result.(map[string]any)
	return resp, res
}

func mustOK(t *testing.T, e *Engine, op string, args any) map[string]any {
	t.Helper()
	resp, res := call(t, e, op, args)
	if !resp.OK {
		t.Fatalf("%s failed: %+v", op, resp.Error)
	}
	return res
}

func TestCallRejectsBadInput(t *testing.T) {
	e := New(Config{})
	defer e.Close()

	var resp Response
	json.Unmarshal(e.Call([]byte("not json")), &resp)
	if resp.OK || resp.Error.Code != CodeBadRequest {
		t.Fatalf("bad JSON: %+v", resp)
	}
	resp, _ = call(t, e, "nope", nil)
	if resp.OK || resp.Error.Code != CodeBadRequest {
		t.Fatalf("unknown op: %+v", resp)
	}
	resp, _ = call(t, e, "parse_token", TokenArgs{Token: "hello"})
	if resp.OK || resp.Error.Code != CodeInvalidToken {
		t.Fatalf("parse_token garbage: %+v", resp)
	}
	resp, _ = call(t, e, "start_forward", StartForwardArgs{Token: "tcgarbage", RemotePort: 80})
	if resp.OK || resp.Error.Code != CodeInvalidToken {
		t.Fatalf("start_forward garbage token: %+v", resp)
	}
	resp, _ = call(t, e, "start_server", StartServerArgs{})
	if resp.OK || resp.Error.Code != CodeBadRequest {
		t.Fatalf("empty start_server: %+v", resp)
	}
	resp, _ = call(t, e, "stop", SessionArgs{SessionID: "x"})
	if resp.OK || resp.Error.Code != CodeNotFound {
		t.Fatalf("stop unknown: %+v", resp)
	}
	res := mustOK(t, e, "get_caps", nil)
	if res["platform"] == "" || res["tailcat"] == "" {
		t.Fatalf("caps = %v", res)
	}
	res = mustOK(t, e, "list_sessions", nil)
	if n := len(res["sessions"].([]any)); n != 0 {
		t.Fatalf("sessions = %d", n)
	}
	if string(e.Poll()) != `{"events":[]}` {
		t.Fatalf("poll = %s", e.Poll())
	}
}

func TestEventQueueBounded(t *testing.T) {
	q := &EventQueue{}
	for i := 0; i < maxQueuedEvents+10; i++ {
		q.Push(Event{"type": "log", "i": i})
	}
	evs := q.Drain()
	if len(evs) > maxQueuedEvents {
		t.Fatalf("queue grew to %d", len(evs))
	}
	if evs[0]["msg"] == nil {
		t.Fatalf("expected overflow notice first, got %v", evs[0])
	}
	if q.Len() != 0 {
		t.Fatal("drain did not clear")
	}
}

func TestListenAddr(t *testing.T) {
	cases := map[string]string{"": "127.0.0.1:1080", "12000": "127.0.0.1:12000", ":9000": ":9000", "0.0.0.0:1": "0.0.0.0:1"}
	for in, want := range cases {
		got, err := listenAddr(in, 1080)
		if err != nil || got != want {
			t.Errorf("listenAddr(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := listenAddr("70000", 1); err == nil {
		t.Error("port 70000 accepted")
	}
}

func TestSessionLifecycleAndSnapshot(t *testing.T) {
	e := New(Config{})
	defer e.Close()
	s, _ := e.newSession(KindForward)
	s.setInfo("local_port", 1234)
	s.setState(StateRunning, "ok")
	s.stop()
	s.setState(StateRunning, "again") // terminal state is sticky
	snap := s.snapshot()
	if snap["state"] != string(StateStopped) || snap["local_port"] != 1234 {
		t.Fatalf("snapshot = %v", snap)
	}
	evs := e.PollEvents()
	var states []string
	for _, ev := range evs {
		if ev["type"] == EvSessionState {
			states = append(states, ev["state"].(string))
		}
	}
	if strings.Join(states, ",") != "running,stopped" {
		t.Fatalf("states = %v", states)
	}
}

// ---- end-to-end over the real DERP relays (TAILCAT_E2E=1) ----

func e2e(t *testing.T) *Engine {
	if os.Getenv("TAILCAT_E2E") == "" {
		t.Skip("set TAILCAT_E2E=1 to run tests that use Tailscale's public DERP relays")
	}
	e := New(Config{})
	t.Cleanup(e.Close)
	return e
}

// waitEvent polls until an event matching pred arrives or the deadline hits.
func waitEvent(t *testing.T, e *Engine, timeout time.Duration, pred func(Event) bool) Event {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, ev := range e.PollEvents() {
			if ev["type"] == EvError || os.Getenv("TAILCAT_E2E_VERBOSE") != "" {
				t.Logf("event: %v", ev)
			}
			if pred(ev) {
				return ev
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for event")
	return nil
}

func waitToken(t *testing.T, e *Engine, sid string) string {
	ev := waitEvent(t, e, 60*time.Second, func(ev Event) bool {
		if ev["session_id"] != sid {
			return false
		}
		if ev["type"] == EvSessionState && ev["state"] == string(StateFailed) {
			t.Fatalf("server failed: %v", ev["detail"])
		}
		return ev["type"] == EvTokenReady
	})
	return ev["token"].(string)
}

func TestE2EForwardAndSocks(t *testing.T) {
	e := e2e(t)
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "hello over tailcat")
	}))
	defer hs.Close()
	hport := hs.Listener.Addr().(*net.TCPAddr).Port

	srv := mustOK(t, e, "start_server", StartServerArgs{Ports: []int{hport}, ExitNode: true})
	token := waitToken(t, e, srv["session_id"].(string))
	t.Logf("token: %s", token)
	if res := mustOK(t, e, "parse_token", TokenArgs{Token: "  tailcat=" + token + " "}); res["valid"] != true {
		t.Fatalf("parse_token = %v", res)
	}

	fw := mustOK(t, e, "start_forward", StartForwardArgs{Token: token, RemotePort: hport})
	lp := int(fw["local_port"].(float64))
	body := httpGet(t, fmt.Sprintf("http://127.0.0.1:%d/", lp), nil)
	if body != "hello over tailcat" {
		t.Fatalf("forward body = %q", body)
	}
	waitEvent(t, e, 30*time.Second, func(ev Event) bool {
		return ev["session_id"] == fw["session_id"] && ev["type"] == EvSessionState && ev["state"] == string(StateRunning)
	})

	sk := mustOK(t, e, "start_socks", StartSocksArgs{Token: token, Listen: "0"})
	dialer, err := proxy.SOCKS5("tcp", sk["listen"].(string), nil, proxy.Direct)
	if err != nil {
		t.Fatal(err)
	}
	tr := &http.Transport{Dial: dialer.Dial}
	for _, host := range []string{"server.tailcat", "127.0.0.1"} {
		body := httpGet(t, fmt.Sprintf("http://%s:%d/", host, hport), tr)
		if body != "hello over tailcat" {
			t.Fatalf("socks via %s body = %q", host, body)
		}
	}

	ping := mustOK(t, e, "ping", TokenArgs{Token: token})
	t.Logf("ping: %v", ping)

	mustOK(t, e, "stop", SessionArgs{SessionID: sk["session_id"].(string)})
	mustOK(t, e, "stop", SessionArgs{SessionID: fw["session_id"].(string)})
	mustOK(t, e, "stop", SessionArgs{SessionID: srv["session_id"].(string)})
	if _, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", lp), time.Second); err == nil {
		t.Fatal("forward listener still open after stop")
	}
}

func TestE2EFiles(t *testing.T) {
	e := e2e(t)
	share := t.TempDir()
	srv := mustOK(t, e, "start_server", StartServerArgs{Files: &FilesSpec{Dir: share, Mode: "rw"}})
	token := waitToken(t, e, srv["session_id"].(string))

	src := filepath.Join(t.TempDir(), "payload.bin")
	data := make([]byte, 2<<20)
	for i := range data {
		data[i] = byte(i)
	}
	os.WriteFile(src, data, 0o644)

	up := mustOK(t, e, "send_files", SendFilesArgs{Token: token, Paths: []string{src}, RemoteDir: "in"})
	waitEvent(t, e, 120*time.Second, func(ev Event) bool {
		if ev["session_id"] != up["session_id"] {
			return false
		}
		if ev["type"] == EvSessionState && ev["state"] == string(StateFailed) {
			t.Fatalf("upload failed: %v", ev["detail"])
		}
		return ev["type"] == EvSessionState && ev["state"] == string(StateDone)
	})
	got, err := os.ReadFile(filepath.Join(share, "in", "payload.bin"))
	if err != nil || len(got) != len(data) {
		t.Fatalf("uploaded file: %v, %d bytes", err, len(got))
	}

	ls := mustOK(t, e, "list_remote", ListRemoteArgs{Token: token, Dir: "in"})
	if n := len(ls["entries"].([]any)); n != 1 {
		t.Fatalf("entries = %v", ls)
	}

	down := t.TempDir()
	dl := mustOK(t, e, "download", DownloadArgs{Token: token, RemotePaths: []string{"in/payload.bin"}, LocalDir: down})
	waitEvent(t, e, 120*time.Second, func(ev Event) bool {
		return ev["session_id"] == dl["session_id"] && ev["type"] == EvSessionState && ev["state"] == string(StateDone)
	})
	got, _ = os.ReadFile(filepath.Join(down, "payload.bin"))
	if len(got) != len(data) {
		t.Fatalf("downloaded %d bytes", len(got))
	}
	mustOK(t, e, "stop", SessionArgs{SessionID: srv["session_id"].(string)})
}

func httpGet(t *testing.T, url string, tr *http.Transport) string {
	t.Helper()
	c := &http.Client{Timeout: 60 * time.Second}
	if tr != nil {
		c.Transport = tr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := c.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}
