package main

// The by-hand yard, held through its wire: the binding's own device
// halves (StartPairingPAKE, StartChannel) pair with it and call
// through it, as the app pairs and calls through a yard. By hand:
// cd ChannelBinding && go test ./fakeedge/.

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"footplate/channel"
)

// The upstream edge the helper forwards opened inner calls to, as
// Python's stand-in answers them: a fixed answer naming the path it
// was asked for, and the events stream as two lines that end.
type stubUpstream struct {
	mu     sync.Mutex
	method string
	path   string
	header http.Header
	body   []byte
}

func (s *stubUpstream) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	s.mu.Lock()
	s.method, s.path, s.header, s.body = r.Method, r.URL.RequestURI(), r.Header.Clone(), body
	s.mu.Unlock()
	if r.URL.Path == "/user/events" {
		w.Header().Set("Content-Type", "application/x-ndjson")
		_, _ = w.Write([]byte("{\"seq\": 41}\n{\"seq\": 42}\n"))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	raw, _ := json.Marshal(map[string]any{"result": map[string]string{"path": r.URL.Path}})
	_, _ = w.Write(raw)
}

func (s *stubUpstream) last() (method, path string, header http.Header, body []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.method, s.path, s.header, s.body
}

func testYard(t *testing.T, upstream *stubUpstream) (*yard, *httptest.Server) {
	t.Helper()
	pair, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	edge := httptest.NewServer(upstream)
	t.Cleanup(edge.Close)
	y := newYard(edge.URL, pair.Private, pair.Public)
	// Through the logging wrapper, as main serves it: the wrapper
	// must carry what the handlers assert (the streamer's Flusher).
	server := httptest.NewServer(logged(y.routes()))
	t.Cleanup(server.Close)
	return y, server
}

func postJSON(t *testing.T, url string, value any) (int, map[string]any) {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.Post(url, "application/json", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(body, &decoded); err != nil {
		t.Fatalf("status %d with no JSON body %q", response.StatusCode, body)
	}
	return response.StatusCode, decoded
}

func postBytes(t *testing.T, url string, header map[string]string, body []byte) (int, http.Header, []byte) {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range header {
		request.Header.Set(name, value)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	answer, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, response.Header, answer
}

func pakeField(t *testing.T, decoded map[string]any, names ...string) map[string]string {
	t.Helper()
	ask, ok := decoded["pake"].(map[string]any)
	if !ok {
		t.Fatalf("no pake step in %v", decoded)
	}
	out := map[string]string{}
	for _, name := range names {
		value, _ := ask[name].(string)
		out[name] = value
	}
	return out
}

// pairDevice pairs devicePrivate with the yard on code and answers
// the opened sealed answer: the three posts of /user/pair, as the
// app's pairPAKE posts them.
func pairTyped(t *testing.T, server *httptest.Server, devicePrivate []byte, code string) []byte {
	t.Helper()
	opening, err := channel.StartPairingPAKE(devicePrivate, code)
	if err != nil {
		t.Fatal(err)
	}
	status, exchangeBody := postJSON(t, server.URL+"/user/pair", map[string]any{
		"pake": map[string]string{"step": "start", "msg": enc.EncodeToString(opening.First)},
	})
	if status != http.StatusOK {
		t.Fatalf("start answered %d", status)
	}
	exchange := pakeField(t, exchangeBody, "step", "session", "msg")
	if exchange["step"] != "exchange" || exchange["session"] == "" {
		t.Fatalf("start answered no exchange: %v", exchangeBody)
	}
	second, err := enc.DecodeString(exchange["msg"])
	if err != nil {
		t.Fatal(err)
	}
	confirm, err := opening.Finish(second)
	if err != nil {
		t.Fatal(err)
	}
	status, confirmedBody := postJSON(t, server.URL+"/user/pair", map[string]any{
		"pake": map[string]string{"step": "confirm", "session": exchange["session"], "confirm": enc.EncodeToString(confirm)},
	})
	if status != http.StatusOK {
		t.Fatalf("confirm answered %d", status)
	}
	confirmed := pakeField(t, confirmedBody, "step", "confirm")
	if confirmed["step"] != "confirmed" {
		t.Fatalf("confirm answered no confirmation: %v", confirmedBody)
	}
	yardConfirm, err := enc.DecodeString(confirmed["confirm"])
	if err != nil {
		t.Fatal(err)
	}
	if err := opening.Verify(yardConfirm); err != nil {
		t.Fatal(err)
	}
	sealedKey, err := opening.SealKey()
	if err != nil {
		t.Fatal(err)
	}
	status, doneBody := postJSON(t, server.URL+"/user/pair", map[string]any{
		"pake": map[string]string{"step": "finish", "session": exchange["session"], "key": enc.EncodeToString(sealedKey)},
	})
	if status != http.StatusOK {
		t.Fatalf("finish answered %d", status)
	}
	done := pakeField(t, doneBody, "step", "answer")
	if done["step"] != "done" {
		t.Fatalf("finish answered no answer: %v", doneBody)
	}
	sealed, err := enc.DecodeString(done["answer"])
	if err != nil {
		t.Fatal(err)
	}
	plain, err := opening.OpenAnswer(sealed)
	if err != nil {
		t.Fatal(err)
	}
	return plain
}

func sealInnerCall(t *testing.T, session *channel.Session, method, path string, header map[string][]string, body []byte) (call []byte, run []byte) {
	t.Helper()
	raw, err := json.Marshal(e2eRequestHead{Method: method, Path: path, Header: header})
	if err != nil {
		t.Fatal(err)
	}
	call, err = channel.NewCallID()
	if err != nil {
		t.Fatal(err)
	}
	run, err = session.SealWhole(call, "", false, joinE2EHead(raw, body))
	if err != nil {
		t.Fatal(err)
	}
	return call, run
}

func splitAnswer(t *testing.T, plain []byte) (int, []byte) {
	t.Helper()
	head, body, err := splitE2EHead(plain)
	if err != nil {
		t.Fatal(err)
	}
	var answer e2eAnswerHead
	if err := json.Unmarshal(head, &answer); err != nil {
		t.Fatal(err)
	}
	return answer.Status, body
}

// A device pairs through the PAKE on the typed code, and the sealed
// answer carries the token and this yard's channel key to pin.
func TestFakeEdgeYardPairsATypedCode(t *testing.T) {
	upstream := &stubUpstream{}
	y, server := testYard(t, upstream)
	device, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	plain := pairTyped(t, server, device.Private, "k7qm 2xpd")
	var answer struct {
		Token      string `json:"token"`
		User       string `json:"user"`
		Device     string `json:"device"`
		Yard       string `json:"yard"`
		ChannelKey string `json:"channel_key"`
	}
	if err := json.Unmarshal(plain, &answer); err != nil {
		t.Fatal(err)
	}
	if answer.Token == "" || answer.User != "jo" || answer.Device != "phone" || answer.Yard != "south" {
		t.Errorf("the sealed answer holds %+v", answer)
	}
	if answer.ChannelKey != y.public {
		t.Errorf("the sealed answer pins %q, want the yard's %q", answer.ChannelKey, y.public)
	}
}

func TestFakeEdgeYardRefusesAWrongCodeAtItsConfirmation(t *testing.T) {
	upstream := &stubUpstream{}
	_, server := testYard(t, upstream)
	device, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	opening, err := channel.StartPairingPAKE(device.Private, "AAAA-0000")
	if err != nil {
		t.Fatal(err)
	}
	status, exchangeBody := postJSON(t, server.URL+"/user/pair", map[string]any{
		"pake": map[string]string{"step": "start", "msg": enc.EncodeToString(opening.First)},
	})
	if status != http.StatusOK {
		t.Fatalf("start answered %d", status)
	}
	exchange := pakeField(t, exchangeBody, "session", "msg")
	second, err := enc.DecodeString(exchange["msg"])
	if err != nil {
		t.Fatal(err)
	}
	confirm, err := opening.Finish(second)
	if err != nil {
		t.Fatal(err)
	}
	status, refused := postJSON(t, server.URL+"/user/pair", map[string]any{
		"pake": map[string]string{"step": "confirm", "session": exchange["session"], "confirm": enc.EncodeToString(confirm)},
	})
	if status != http.StatusForbidden || refused["refused"] != "wrong_code" {
		t.Fatalf("a wrong code's confirmation answered %d %v, want 403 wrong_code", status, refused)
	}
	// The run is spent: its finish finds no live session.
	finish, err := json.Marshal(map[string]any{
		"pake": map[string]string{"step": "finish", "session": exchange["session"], "key": enc.EncodeToString(confirm)},
	})
	if err != nil {
		t.Fatal(err)
	}
	status, _, _ = postBytes(t, server.URL+"/user/pair", map[string]string{"Content-Type": "application/json"}, finish)
	if status != http.StatusBadRequest {
		t.Fatalf("a spent run's finish answered %d, want 400", status)
	}
}

// A device the yard pinned founds a channel and calls through it:
// the inner call crosses sealed and is served as the plain call it
// is upstream, and its answer opens against the call that asked for
// it. A key no pairing pinned founds none.
func TestFakeEdgeYardServesASealedCall(t *testing.T) {
	upstream := &stubUpstream{}
	y, server := testYard(t, upstream)
	device, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	plain := pairTyped(t, server, device.Private, "K7QM-2XPD")
	var paired struct {
		ChannelKey string `json:"channel_key"`
	}
	if err := json.Unmarshal(plain, &paired); err != nil {
		t.Fatal(err)
	}
	if paired.ChannelKey != y.public {
		t.Fatalf("the sealed answer pins %q, want the yard's %q", paired.ChannelKey, y.public)
	}
	yardPublic, err := channel.ParsePublic(paired.ChannelKey)
	if err != nil {
		t.Fatal(err)
	}
	handshake, err := channel.StartChannel(device.Private, yardPublic)
	if err != nil {
		t.Fatal(err)
	}
	status, header, reply := postBytes(t, server.URL+"/user/e2e", nil, handshake.First)
	if status != http.StatusOK || header.Get("X-Edge-E2E") != "handshake" {
		t.Fatalf("the handshake answered %d %v", status, header)
	}
	session, err := handshake.OpenAnswer(reply)
	if err != nil {
		t.Fatal(err)
	}
	call, run := sealInnerCall(t, session, "POST", "/user/call/Flows", map[string][]string{"Content-Type": {"application/json"}}, []byte(`{}`))
	status, header, sealed := postBytes(t, server.URL+"/user/e2e", map[string]string{"X-Edge-E2E-Call": enc.EncodeToString(call)}, run)
	if status != http.StatusOK || header.Get("X-Edge-E2E") != "sealed" {
		t.Fatalf("the enveloped call answered %d %v", status, header)
	}
	opened, err := session.OpenWhole(sealed, call, "", false)
	if err != nil {
		t.Fatal(err)
	}
	innerStatus, innerBody := splitAnswer(t, opened)
	if innerStatus != http.StatusOK {
		t.Fatalf("the inner answer holds status %d", innerStatus)
	}
	var result struct {
		Result map[string]string `json:"result"`
	}
	if err := json.Unmarshal(innerBody, &result); err != nil {
		t.Fatal(err)
	}
	if result.Result["path"] != "/user/call/Flows" {
		t.Errorf("the inner answer holds %v, want the upstream's answer for /user/call/Flows", result)
	}
	// The board stays upstream: the helper forwarded the opened
	// method, path, headers and body as the plain call they are.
	method, path, forwarded, forwardedBody := upstream.last()
	if method != "POST" || path != "/user/call/Flows" || string(forwardedBody) != `{}` {
		t.Errorf("the upstream was asked %s %s %q", method, path, forwardedBody)
	}
	if forwarded.Get("Content-Type") != "application/json" {
		t.Errorf("the upstream was asked with headers %v", forwarded)
	}

	// A key no pairing pinned founds no channel.
	stranger, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	opening, err := channel.StartChannel(stranger.Private, yardPublic)
	if err != nil {
		t.Fatal(err)
	}
	status, _, _ = postBytes(t, server.URL+"/user/e2e", nil, opening.First)
	if status != http.StatusUnauthorized {
		t.Fatalf("a stranger's handshake answered %d, want 401", status)
	}
}

// The marked events stream is sealed record by record as the
// upstream flushes: the sealed inner head first, then its lines, and
// the final record closing the run.
func TestFakeEdgeYardStreamsTheMarkedEvents(t *testing.T) {
	upstream := &stubUpstream{}
	_, server := testYard(t, upstream)
	device, err := channel.GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	plain := pairTyped(t, server, device.Private, "K7QM-2XPD")
	var paired struct {
		ChannelKey string `json:"channel_key"`
	}
	if err := json.Unmarshal(plain, &paired); err != nil {
		t.Fatal(err)
	}
	yardPublic, err := channel.ParsePublic(paired.ChannelKey)
	if err != nil {
		t.Fatal(err)
	}
	handshake, err := channel.StartChannel(device.Private, yardPublic)
	if err != nil {
		t.Fatal(err)
	}
	status, _, reply := postBytes(t, server.URL+"/user/e2e", nil, handshake.First)
	if status != http.StatusOK {
		t.Fatalf("the handshake answered %d", status)
	}
	session, err := handshake.OpenAnswer(reply)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(e2eRequestHead{Method: "GET", Path: "/user/events?after=0", Header: map[string][]string{"Accept": {"application/x-ndjson"}}})
	if err != nil {
		t.Fatal(err)
	}
	call, err := channel.NewCallID()
	if err != nil {
		t.Fatal(err)
	}
	run, err := session.SealWhole(call, channel.StreamLongLived, true, joinE2EHead(raw, nil))
	if err != nil {
		t.Fatal(err)
	}
	status, header, sealed := postBytes(t, server.URL+"/user/e2e", map[string]string{
		"X-Edge-E2E-Call":   enc.EncodeToString(call),
		"X-Edge-E2E-Stream": channel.StreamLongLived,
	}, run)
	if status != http.StatusOK || header.Get("X-Edge-E2E") != "sealed" {
		t.Fatalf("the marked call answered %d %v", status, header)
	}
	// The run as it crossed, record by record: each at the index
	// the last left off, closed by the final record.
	opener := session.NewOpener(call, channel.StreamLongLived, true)
	var joined []byte
	for len(sealed) > 0 {
		if len(sealed) < 4 {
			t.Fatalf("the sealed stream ends inside a length")
		}
		n := int(binary.BigEndian.Uint32(sealed))
		sealed = sealed[4:]
		if n > len(sealed) {
			t.Fatalf("a record claims %d bytes of %d left", n, len(sealed))
		}
		opened, err := opener.Open(sealed[:n])
		if err != nil {
			t.Fatal(err)
		}
		joined = append(joined, opened.Plain...)
		sealed = sealed[n:]
	}
	if err := opener.Close(); err != nil {
		t.Fatalf("the sealed stream ends %v", err)
	}
	innerStatus, innerBody := splitAnswer(t, joined)
	if innerStatus != http.StatusOK {
		t.Fatalf("the inner answer holds status %d", innerStatus)
	}
	if string(innerBody) != "{\"seq\": 41}\n{\"seq\": 42}\n" {
		t.Errorf("the sealed stream holds %q", innerBody)
	}
	method, path, _, _ := upstream.last()
	if method != "GET" || path != "/user/events?after=0" {
		t.Errorf("the upstream was asked %s %s", method, path)
	}
}
