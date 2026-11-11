// The by-hand yard behind scripts/fake-edge's edge: the PAKE a typed
// code is redeemed through and the channel a paired device calls on,
// as the yard serves them (yardr internal/rpc userpair.go and
// usere2e.go, which this file is held against). Python stays the
// edge and routes those two paths here; the board stays there, so an
// inner call an envelope opens is forwarded as plain HTTP to the
// upstream URL this helper was started with, and its answer sealed.
//
// None of the crypto is written here: the PAKE and the channel are
// the binding's own (AnswerPairingPAKE and OpenChannel), driven as
// the yard drives its libraries. The helper holds one pairing's code
// (the one the by-hand tests type), one live PAKE run and its
// sessions in memory, and mints its yard channel keypair at startup,
// logging its public half for the device to pin from the PAKE's
// sealed answer.
//
// Usage: fakeedge <upstream-url>. The helper's own URL is its one
// line on standard output, for the edge to route to; everything else
// goes to standard error.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"footplate/channel"
)

var enc = base64.RawURLEncoding

// The code the by-hand tests type (FootplateUITests/AAPairForHand
// types K7QM-2XPD): the one pairing this yard has open. The
// responder always runs on it, so any other code runs the exchange
// and fails at its confirmation, as a wrong code should. It is never
// spent: a stand-in serves repeated fresh installs.
const pairingCode = "K7QM-2XPD"

// The pairing's user, device and yard, as the stand-in edge answers
// a plain redemption (scripts/fake-edge).
const (
	pairUser   = "jo"
	pairDevice = "phone"
	pairYard   = "south"
)

// A PAKE run's sealed answer beside the token: the yard's channel
// public key for the device to pin, and the push voucher the by-hand
// tests never redeem.
const pairVoucher = "yardr-voucher-fake"

// How long a PAKE run may take its steps, as the yard's
// pakeSessionLife bounds its own.
const pakeRunLife = 2 * time.Minute

// One outer call's record run is bounded as the yard bounds it.
const maxOuterBody = (1 << 20) + (64 << 10)

// A whole inner call's answer is waited on this long; a stream owns
// its request's context instead and runs until it ends.
const wholeCallTimeout = 60 * time.Second

// pakeAsk is one step of a PAKE redemption as it crosses, as the
// yard reads it.
type pakeAsk struct {
	Step    string `json:"step"`
	Session string `json:"session,omitempty"`
	Msg     string `json:"msg,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	Key     string `json:"key,omitempty"`
}

// pakeReply is a PAKE step as the yard answers it.
type pakeReply struct {
	Step    string `json:"step"`
	Session string `json:"session,omitempty"`
	Msg     string `json:"msg,omitempty"`
	Confirm string `json:"confirm,omitempty"`
	Answer  string `json:"answer,omitempty"`
}

// The yard's one live PAKE run: its half of the exchange and whether
// the device's confirmation has held in it. A new start replaces it,
// and a failed confirmation or a finish spends it.
type pakeRun struct {
	id            string
	responder     *channel.PairingPAKEResponder
	confirmed     bool
	deviceConfirm []byte
	yardConfirm   []byte
	expires       time.Time
}

// e2eRequestHead is an inner call's head as it travels sealed: its
// method, its path with its query, and its headers.
type e2eRequestHead struct {
	Method string      `json:"method"`
	Path   string      `json:"path"`
	Header http.Header `json:"header"`
}

// e2eAnswerHead is an inner answer's head as it travels sealed: its
// status and its headers, told to the device alone.
type e2eAnswerHead struct {
	Status int         `json:"status"`
	Header http.Header `json:"header"`
}

// A by-hand yard: its upstream edge, its channel key, and its runs,
// tokens, pinned device keys and sessions in memory.
type yard struct {
	upstream string
	private  []byte
	public   string
	client   *http.Client

	mu       sync.Mutex
	pake     *pakeRun
	minted   int
	pinned   map[string]bool
	sessions map[string]*channel.Session
}

func newYard(upstream string, private, public []byte) *yard {
	return &yard{
		upstream: strings.TrimSuffix(upstream, "/"),
		private:  private,
		public:   enc.EncodeToString(public),
		client:   &http.Client{},
		pinned:   map[string]bool{},
		sessions: map[string]*channel.Session{},
	}
}

func (y *yard) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /user/pair", y.pair)
	mux.HandleFunc("POST /user/e2e", y.e2e)
	return mux
}

// pair serves one step of the PAKE on the pairing this yard has
// open, as the yard's pairPAKE serves it: a first message that does
// not open is 400 and no try, a confirmation that does not hold is
// one wrong_code, counted alone here, and only a confirmed run's
// finish redeems, sealing the token and this yard's channel key.
func (y *yard) pair(w http.ResponseWriter, r *http.Request) {
	var asked struct {
		PAKE *pakeAsk `json:"pake"`
	}
	if err := json.NewDecoder(r.Body).Decode(&asked); err != nil || asked.PAKE == nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	switch asked.PAKE.Step {
	case "start":
		y.pakeStart(w, asked.PAKE)
	case "confirm":
		y.pakeConfirm(w, asked.PAKE)
	case "finish":
		y.pakeFinish(w, r, asked.PAKE)
	default:
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
	}
}

func (y *yard) pakeStart(w http.ResponseWriter, ask *pakeAsk) {
	first, err := enc.DecodeString(ask.Msg)
	var responder *channel.PairingPAKEResponder
	if err == nil {
		responder, err = channel.AnswerPairingPAKE(pairingCode, first)
	}
	var session string
	if err == nil {
		var raw []byte
		if raw, err = channel.NewCallID(); err == nil {
			session = enc.EncodeToString(raw)
			y.mu.Lock()
			y.pake = &pakeRun{id: session, responder: responder, expires: time.Now().Add(pakeRunLife)}
			y.mu.Unlock()
		}
	}
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	writeJSON(w, map[string]pakeReply{"pake": {Step: "exchange", Session: session, Msg: enc.EncodeToString(responder.Second)}})
}

// pakeRunFor answers the live run ask names, and whether there is
// one: a spent, replaced or run-out run is none, and a run-out one
// is cleared as it is found.
func (y *yard) pakeRunFor(ask *pakeAsk) (*pakeRun, bool) {
	y.mu.Lock()
	defer y.mu.Unlock()
	run := y.pake
	if run == nil || run.id != ask.Session {
		return nil, false
	}
	if !time.Now().Before(run.expires) {
		y.pake = nil
		return nil, false
	}
	return run, true
}

// pakeConfirm checks a run's device confirmation and answers the
// yard's: the step a wrong code spends its one online guess at. A
// repeated valid confirmation gets the same answer if a relay lost
// it; a replaced run or a different second confirmation is no live
// step and spends no try.
func (y *yard) pakeConfirm(w http.ResponseWriter, ask *pakeAsk) {
	run, ok := y.pakeRunFor(ask)
	if !ok {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	confirm, err := enc.DecodeString(ask.Confirm)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	y.mu.Lock()
	live := y.pake == run
	var yardConfirm []byte
	if live && run.confirmed {
		if !bytes.Equal(confirm, run.deviceConfirm) {
			live = false
		} else {
			yardConfirm = append([]byte(nil), run.yardConfirm...)
		}
	} else if live {
		yardConfirm, err = run.responder.Confirm(confirm)
		// The run is spent whether its confirmation failed or the
		// responder found an unexpected state error. Only a failed
		// confirmation is a wrong-code try at the caller.
		y.pake = nil
		if err == nil {
			run.confirmed = true
			run.deviceConfirm = append([]byte(nil), confirm...)
			run.yardConfirm = append([]byte(nil), yardConfirm...)
			y.pake = run
		}
	}
	y.mu.Unlock()
	if !live {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	if err != nil {
		if isUnconfirmed(err) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"refused": "wrong_code"}`))
			return
		}
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	writeJSON(w, map[string]pakeReply{"pake": {Step: "confirmed", Confirm: enc.EncodeToString(yardConfirm)}})
}

// pakeFinish redeems a confirmed run: the device's sealed channel
// key in, the token and the yard's channel key sealed out. A finish
// of a confirmed run spends it whatever it carries, and one sent
// before its run is confirmed is 400 with the run still live.
func (y *yard) pakeFinish(w http.ResponseWriter, r *http.Request, ask *pakeAsk) {
	run, ok := y.pakeRunFor(ask)
	if !ok {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	y.mu.Lock()
	confirmed := y.pake == run && run.confirmed
	if confirmed {
		y.pake = nil
	}
	y.mu.Unlock()
	if !confirmed {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	sealedKey, err := enc.DecodeString(ask.Key)
	var deviceKey string
	if err == nil {
		deviceKey, err = run.responder.OpenKey(sealedKey)
	}
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	y.mu.Lock()
	y.minted++
	token := fmt.Sprintf("stand-in-token-%d", y.minted)
	y.pinned[deviceKey] = true
	y.mu.Unlock()
	name := r.Header.Get("X-Edge-Yard")
	if name == "" {
		name = pairYard
	}
	answer, err := json.Marshal(map[string]string{
		"token": token, "user": pairUser, "device": pairDevice, "yard": name,
		"voucher": pairVoucher, "channel_key": y.public,
	})
	var reply []byte
	if err == nil {
		reply, err = run.responder.SealAnswer(answer)
	}
	if err != nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	// The one answer that holds the token, sealed: nothing between
	// keeps it readable but the device.
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, map[string]pakeReply{"pake": {Step: "done", Answer: enc.EncodeToString(reply)}})
}

// isUnconfirmed is the run's one failure that proves a guess was
// made: the confirmation does not hold. The binding names it by its
// sentence, which the app reads the same way.
func isUnconfirmed(err error) bool {
	return err != nil && strings.Contains(err.Error(), channel.PAKEUnconfirmed)
}

// e2e serves one outer call: a channel handshake when it names no
// call, an enveloped whole call when it does, as the yard's e2e
// serves them.
func (y *yard) e2e(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxOuterBody))
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	if r.Header.Get("X-Edge-E2E-Call") == "" {
		y.e2eHandshake(w, body)
		return
	}
	y.e2eCall(w, r, body)
}

// e2eHandshake opens a channel handshake's first message with this
// yard's channel key and founds its session: the device the message
// proves must be one a pairing pinned, or no session is made.
func (y *yard) e2eHandshake(w http.ResponseWriter, first []byte) {
	opened, err := channel.OpenChannel(y.private, first)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	y.mu.Lock()
	pinned := y.pinned[opened.DeviceKey]
	y.mu.Unlock()
	if !pinned {
		http.Error(w, http.StatusText(http.StatusUnauthorized), http.StatusUnauthorized)
		return
	}
	tag, err := channel.NewCallID()
	var reply []byte
	if err == nil {
		reply, err = opened.SealAnswer(tag)
	}
	if err != nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	session := opened.Session()
	if session == nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	y.mu.Lock()
	y.sessions[string(tag)] = session
	y.mu.Unlock()
	// The answer founds a session and holds its tag: nothing between
	// keeps it readable but the device.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Edge-E2E", "handshake")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(reply)
}

// e2eCall opens one enveloped call and seals its answer: whole when
// the inner call is no marked stream, record by record as the
// upstream flushes when it is, and closed by the sealed final record
// either way. Its outer head is the envelope's alone.
func (y *yard) e2eCall(w http.ResponseWriter, r *http.Request, run []byte) {
	call, err := enc.DecodeString(r.Header.Get("X-Edge-E2E-Call"))
	if err != nil || len(call) != 16 {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	tag := firstRecordTag(run)
	y.mu.Lock()
	session := y.sessions[string(tag)]
	y.mu.Unlock()
	if session == nil {
		http.Error(w, http.StatusText(http.StatusUnauthorized), http.StatusUnauthorized)
		return
	}
	marker := r.Header.Get("X-Edge-E2E-Stream")
	_, present := r.Header[http.CanonicalHeaderKey("X-Edge-E2E-Stream")]
	plain, err := session.OpenWhole(run, call, marker, present)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	head, innerBody, err := splitE2EHead(plain)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	var asked e2eRequestHead
	if err := json.Unmarshal(head, &asked); err != nil {
		http.Error(w, http.StatusText(http.StatusBadRequest), http.StatusBadRequest)
		return
	}
	if present && !isEventsCall(asked) {
		// A marked call is checked only now, after the envelope has
		// opened: a mark buys a long-lived slot for the events stream
		// alone, and any other inner call is refused sealed, unserved,
		// and holding no stream slot.
		y.sealAnswer(w, session, call, marker, present, http.StatusForbidden,
			http.Header{"Content-Type": {"text/plain; charset=utf-8"}},
			[]byte("a call marked long-lived may open only the events stream\n"))
		return
	}
	if asked.Path != "/user" && !strings.HasPrefix(asked.Path, "/user/") {
		y.sealAnswer(w, session, call, marker, present, http.StatusNotFound, http.Header{}, []byte("not found\n"))
		return
	}
	if _, err := url.ParseRequestURI(asked.Path); err != nil {
		y.sealAnswer(w, session, call, marker, present, http.StatusBadRequest, http.Header{}, []byte("bad request\n"))
		return
	}
	if present {
		y.e2eStream(w, r, session, call, marker, asked, innerBody)
		return
	}
	y.e2eWhole(w, r, session, call, marker, asked, innerBody)
}

// e2eWhole forwards one inner call to the upstream edge and seals
// its whole answer.
func (y *yard) e2eWhole(w http.ResponseWriter, r *http.Request, session *channel.Session, call []byte, marker string, asked e2eRequestHead, innerBody []byte) {
	ctx, cancel := context.WithTimeout(r.Context(), wholeCallTimeout)
	defer cancel()
	upstream, err := y.forward(ctx, asked, innerBody)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadGateway), http.StatusBadGateway)
		return
	}
	defer upstream.Body.Close()
	answer, err := io.ReadAll(upstream.Body)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadGateway), http.StatusBadGateway)
		return
	}
	y.sealAnswer(w, session, call, marker, false, upstream.StatusCode, upstream.Header, answer)
}

// e2eStream forwards the marked events stream to the upstream edge
// and seals its answer record by record as it flushes: the inner
// head travels in the first record, sealed, and the outer head shows
// the envelope's alone.
func (y *yard) e2eStream(w http.ResponseWriter, r *http.Request, session *channel.Session, call []byte, marker string, asked e2eRequestHead, innerBody []byte) {
	upstream, err := y.forward(r.Context(), asked, innerBody)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusBadGateway), http.StatusBadGateway)
		return
	}
	defer upstream.Body.Close()
	raw, err := json.Marshal(e2eAnswerHead{Status: upstream.StatusCode, Header: upstream.Header})
	if err != nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	sealer := session.NewSealer(call, marker, true)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Edge-E2E", "sealed")
	w.Header().Set("X-Edge-E2E-Call", enc.EncodeToString(call))
	w.WriteHeader(http.StatusOK)
	// The stream's first records carry the sealed inner head with
	// what body already stands behind it; every flush after seals
	// the body written since the last.
	chunk := make([]byte, 32<<10)
	first := true
	for {
		n, err := upstream.Body.Read(chunk)
		if n > 0 {
			var sealed []byte
			if first {
				sealed, err = sealer.Seal(joinE2EHead(raw, chunk[:n]))
				first = false
			} else {
				sealed, err = sealer.Seal(chunk[:n])
			}
			if err != nil {
				return
			}
			if _, err := w.Write(sealed); err != nil {
				return
			}
			flusher.Flush()
		}
		if err != nil {
			break
		}
	}
	if first {
		// An upstream that answered with no body still seals its
		// head, so the device reads an answer and not a cut stream.
		sealed, err := sealer.Seal(joinE2EHead(raw, nil))
		if err != nil {
			return
		}
		if _, err := w.Write(sealed); err != nil {
			return
		}
	}
	final, err := sealer.SealFinal()
	if err != nil {
		return
	}
	_, _ = w.Write(final)
	flusher.Flush()
}

// forward sends an opened inner call to the upstream edge as the
// plain call it is there. The channel is the credential: a token
// sealed inside is read by nobody, and the envelope's own headers
// name the outer call, never the inner one.
func (y *yard) forward(ctx context.Context, asked e2eRequestHead, body []byte) (*http.Response, error) {
	upstream, err := http.NewRequestWithContext(ctx, asked.Method, y.upstream+asked.Path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for name, values := range asked.Header {
		if strings.EqualFold(name, "Authorization") ||
			strings.EqualFold(name, "X-Edge-E2E-Call") ||
			strings.EqualFold(name, "X-Edge-E2E-Stream") {
			continue
		}
		for _, value := range values {
			upstream.Header.Add(name, value)
		}
	}
	return y.client.Do(upstream)
}

// sealAnswer seals one inner answer whole under the call that asked
// for it.
func (y *yard) sealAnswer(w http.ResponseWriter, session *channel.Session, call []byte, marker string, present bool, status int, header http.Header, body []byte) {
	raw, err := json.Marshal(e2eAnswerHead{Status: status, Header: header})
	var sealed []byte
	if err == nil {
		sealed, err = session.SealWhole(call, marker, present, joinE2EHead(raw, body))
	}
	if err != nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Edge-E2E", "sealed")
	w.Header().Set("X-Edge-E2E-Call", enc.EncodeToString(call))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(sealed)
}

// isEventsCall says whether an opened inner call is the events
// stream: the one inner call a marked outer call may carry.
func isEventsCall(asked e2eRequestHead) bool {
	path := asked.Path
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	return asked.Method == http.MethodGet && path == "/user/events"
}

// firstRecordTag is the tag a record run's first message carries, or
// nil where the run holds none.
func firstRecordTag(run []byte) []byte {
	if len(run) < 4+16 {
		return nil
	}
	n := int(binary.BigEndian.Uint32(run))
	if n < 16 || len(run) < 4+n {
		return nil
	}
	return run[4 : 4+16]
}

// joinE2EHead is a sealed plaintext whole: the head as a
// length-prefixed JSON block, then the body as it stands.
func joinE2EHead(head []byte, body []byte) []byte {
	out := binary.BigEndian.AppendUint32(nil, uint32(len(head)))
	out = append(out, head...)
	return append(out, body...)
}

// splitE2EHead is joinE2EHead read back.
func splitE2EHead(plain []byte) (head, body []byte, err error) {
	if len(plain) < 4 {
		return nil, nil, fmt.Errorf("a sealed call with no head")
	}
	n := int(binary.BigEndian.Uint32(plain))
	if n > len(plain)-4 {
		return nil, nil, fmt.Errorf("a sealed head of %d bytes in %d", n, len(plain))
	}
	return plain[4 : 4+n], plain[4+n:], nil
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	raw, err := json.Marshal(value)
	if err != nil {
		http.Error(w, http.StatusText(http.StatusInternalServerError), http.StatusInternalServerError)
		return
	}
	_, _ = w.Write(raw)
}

// statusWriter keeps the status a handler answered, for the log.
// It carries Flush through: without it the wrapper hides the
// streamer's Flusher and the sealed events end in 500.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Flush() {
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wrote := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrote, r)
		log.Printf("%s %s -> %d", r.Method, r.URL.Path, wrote.status)
	})
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: fakeedge <upstream-url>")
		os.Exit(1)
	}
	upstream, err := url.Parse(os.Args[1])
	if err != nil || upstream.Host == "" {
		fmt.Fprintf(os.Stderr, "fakeedge: no upstream URL in %q\n", os.Args[1])
		os.Exit(1)
	}
	pair, err := channel.GenerateKey()
	if err != nil {
		fmt.Fprintf(os.Stderr, "fakeedge: no yard channel key: %v\n", err)
		os.Exit(1)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "fakeedge: cannot listen: %v\n", err)
		os.Exit(1)
	}
	// The URL alone on standard output, for the edge to route to.
	fmt.Printf("http://%s\n", listener.Addr())
	log.Printf("by-hand yard at http://%s (channel public %s) over %s", listener.Addr(), enc.EncodeToString(pair.Public), strings.TrimSuffix(os.Args[1], "/"))
	if err := http.Serve(listener, logged(newYard(os.Args[1], pair.Private, pair.Public).routes())); err != nil {
		fmt.Fprintf(os.Stderr, "fakeedge: %v\n", err)
		os.Exit(1)
	}
}
