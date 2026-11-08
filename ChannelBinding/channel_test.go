package channel

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"

	"github.com/flynn/noise"
)

// The yard's half of every exchange, transcribed from the
// yard's internal/yardkey (channel.go, e2e.go) over flynn/noise
// alone, as the stand-in yard of the yard's own tests stands:
// the binding is held against it, never against itself.

type fixedRand struct{ state uint64 }

func (r *fixedRand) Read(p []byte) (int, error) {
	for i := range p {
		r.state ^= r.state << 13
		r.state ^= r.state >> 7
		r.state ^= r.state << 17
		p[i] = byte(r.state >> 32)
	}
	return len(p), nil
}

func fixedKey(fill byte) (priv, pub []byte) {
	priv = bytes.Repeat([]byte{fill}, 32)
	pub, err := PublicOf(priv)
	if err != nil {
		panic(err)
	}
	return priv, pub
}

func yardHandshake(yardPriv []byte, initiator bool, first []byte) (*noise.HandshakeState, []byte, error) {
	pub, err := PublicOf(yardPriv)
	if err != nil {
		return nil, nil, err
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        &fixedRand{state: 99},
		Pattern:       noise.HandshakeIK,
		Initiator:     false,
		StaticKeypair: noise.DHKey{Private: yardPriv, Public: pub},
	})
	if err != nil {
		return nil, nil, err
	}
	payload, _, _, err := hs.ReadMessage(nil, first)
	return hs, payload, err
}

// yardPairAnswer opens a pairing first message as the yard
// does and seals the answer payload into it.
func yardPairAnswer(t *testing.T, yardPriv, first, answer []byte) []byte {
	t.Helper()
	hs, code, err := yardHandshake(yardPriv, false, first)
	if err != nil {
		t.Fatalf("yard opens pairing: %v", err)
	}
	if string(code) != "K7QM-2XPD" {
		t.Fatalf("yard read code %q", code)
	}
	if got := PublicString(hs.PeerStatic()); got != PublicString(mustPublic(t, devicePriv)) {
		t.Fatalf("yard proved device %s", got)
	}
	reply, _, _, err := hs.WriteMessage(nil, answer)
	if err != nil {
		t.Fatalf("yard seals pairing answer: %v", err)
	}
	return reply
}

var devicePriv, yardPriv []byte

func mustPublic(t *testing.T, priv []byte) []byte {
	t.Helper()
	pub, err := PublicOf(priv)
	if err != nil {
		t.Fatal(err)
	}
	return pub
}

func TestKeysRoundTrip(t *testing.T) {
	pair, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	priv, pub := pair.Private, pair.Public
	again, err := PublicOf(priv)
	if err != nil || !bytes.Equal(again, pub) {
		t.Fatalf("PublicOf = %x, %v; key made %x", again, err, pub)
	}
	parsed, err := ParsePublic(PublicString(pub))
	if err != nil || !bytes.Equal(parsed, pub) {
		t.Fatalf("ParsePublic = %x, %v", parsed, err)
	}
	if _, err := ParsePublic("not a key"); err == nil {
		t.Fatal("ParsePublic took words")
	}
}

func TestPairingAgainstTheYard(t *testing.T) {
	devicePriv, _ = fixedKey(0x11)
	yardPriv, _ = fixedKey(0x22)
	yardPub := mustPublic(t, yardPriv)
	opening, err := StartPairing(devicePriv, yardPub, "K7QM-2XPD")
	if err != nil {
		t.Fatal(err)
	}
	answer := []byte(`{"token":"yardr-dev-test","user":"sam","device":"phone","yard":"south","voucher":"yardr-voucher-x.y"}`)
	reply := yardPairAnswer(t, yardPriv, opening.First, answer)
	got, err := opening.OpenAnswer(reply)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, answer) {
		t.Fatalf("opened %s", got)
	}
}

// yardChannel opens a channel first message as the yard does,
// seals tag as its answer and answers the yard's session: it
// opens under the handshake's first transport key and sends
// under its second.
func yardChannel(t *testing.T, yardPriv, first, tag []byte) (*Session, []byte) {
	t.Helper()
	hs, payload, err := yardHandshake(yardPriv, false, first)
	if err != nil {
		t.Fatalf("yard opens channel: %v", err)
	}
	if len(payload) != 0 {
		t.Fatalf("channel first message carried %d payload bytes", len(payload))
	}
	if got := PublicString(hs.PeerStatic()); got != PublicString(mustPublic(t, devicePriv)) {
		t.Fatalf("yard proved device %s", got)
	}
	reply, send, recv, err := hs.WriteMessage(nil, tag)
	if err != nil {
		t.Fatalf("yard seals channel answer: %v", err)
	}
	return &Session{
		tag:     append([]byte(nil), tag...),
		sendKey: recv.UnsafeKey(), recvKey: send.UnsafeKey(),
		sendDir: dirAnswer, recvDir: dirRequest,
	}, reply
}

func pairedSessions(t *testing.T) (device, yard *Session, call []byte) {
	t.Helper()
	devicePriv, _ = fixedKey(0x11)
	yardPriv, _ = fixedKey(0x22)
	yardPub := mustPublic(t, yardPriv)
	opening, err := StartChannel(devicePriv, yardPub)
	if err != nil {
		t.Fatal(err)
	}
	tag := bytes.Repeat([]byte{0x33}, tagSize)
	yard, reply := yardChannel(t, yardPriv, opening.First, tag)
	device, err = opening.OpenAnswer(reply)
	if err != nil {
		t.Fatal(err)
	}
	call = bytes.Repeat([]byte{0x44}, callSize)
	return device, yard, call
}

func TestChannelWholeCallAgainstTheYard(t *testing.T) {
	device, yard, call := pairedSessions(t)
	plain := []byte("the inner call, whole")
	run, err := device.SealWhole(call, "", false, plain)
	if err != nil {
		t.Fatal(err)
	}
	got, err := yard.OpenWhole(run, call, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("yard opened %q", got)
	}
	answer := bytes.Repeat([]byte("answer "), 20000) // several records
	sealed, err := yard.SealWhole(call, "", false, answer)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := device.OpenWhole(sealed, call, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(opened, answer) {
		t.Fatal("device opened a different answer")
	}
}

func TestMarkerBindingAndReplay(t *testing.T) {
	device, yard, call := pairedSessions(t)
	run, err := device.SealWhole(call, StreamLongLived, true, []byte("events"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := yard.OpenWhole(run, call, "", false); err == nil {
		t.Fatal("yard opened a marked call as unmarked")
	}
	if _, err := yard.OpenWhole(run, call, "rewritten", true); err == nil {
		t.Fatal("yard opened a rewritten marker")
	}
	got, err := yard.OpenWhole(run, call, StreamLongLived, true)
	if err != nil || string(got) != "events" {
		t.Fatalf("marked open = %q, %v", got, err)
	}
	if _, err := yard.OpenWhole(run, call, StreamLongLived, true); !errors.Is(err, ErrReplay) {
		t.Fatalf("replayed run: %v", err)
	}
	other := bytes.Repeat([]byte{0x55}, callSize)
	if _, err := yard.OpenWhole(run, other, StreamLongLived, true); err == nil {
		t.Fatal("yard opened a record of another call")
	}
}

func TestStreamedAnswerGapAndTruncation(t *testing.T) {
	device, yard, call := pairedSessions(t)
	sealer := yard.NewSealer(call, "", false)
	first, err := sealer.Seal([]byte("one "))
	if err != nil {
		t.Fatal(err)
	}
	second, err := sealer.Seal([]byte("two"))
	if err != nil {
		t.Fatal(err)
	}
	final, err := sealer.SealFinal()
	if err != nil {
		t.Fatal(err)
	}
	msgs := [][]byte{}
	for _, run := range [][]byte{first, second, final} {
		split, err := splitRecords(run)
		if err != nil {
			t.Fatal(err)
		}
		msgs = append(msgs, split...)
	}
	opener := device.NewOpener(call, "", false)
	opened, err := opener.Open(msgs[0])
	if err != nil || string(opened.Plain) != "one " {
		t.Fatalf("first record = %q, %v", opened.Plain, err)
	}
	if _, err := opener.Open(msgs[2]); !errors.Is(err, ErrRecordGap) {
		t.Fatalf("record past a gap: %v", err)
	}
	if err := opener.Close(); !errors.Is(err, ErrTruncated) {
		t.Fatalf("close before final: %v", err)
	}
	opened, err = opener.Open(msgs[1])
	if err != nil || string(opened.Plain) != "two" {
		t.Fatalf("second record = %q, %v", opened.Plain, err)
	}
	last, err := opener.Open(msgs[2])
	if err != nil || !last.Final {
		t.Fatalf("final record = %+v, %v", last, err)
	}
	if err := opener.Close(); err != nil {
		t.Fatal(err)
	}
	// A beat (a zero-length record) splits off and opens nothing.
	if msgs, err := splitRecords(binary.BigEndian.AppendUint32(nil, 0)); err != nil || len(msgs) != 0 {
		t.Fatalf("beat split = %v, %v", msgs, err)
	}
}

func TestExportedYardHalves(t *testing.T) {
	devicePriv, _ = fixedKey(0x11)
	yardPriv, _ = fixedKey(0x22)
	yardPub := mustPublic(t, yardPriv)

	opening, err := StartPairing(devicePriv, yardPub, "K7QM-2XPD")
	if err != nil {
		t.Fatal(err)
	}
	handshake, err := OpenPairing(yardPriv, opening.First)
	if err != nil {
		t.Fatal(err)
	}
	if handshake.Code != "K7QM-2XPD" || handshake.DeviceKey != PublicString(mustPublic(t, devicePriv)) {
		t.Fatalf("yard opened %+v", handshake)
	}
	reply, err := handshake.SealAnswer([]byte("the token answer"))
	if err != nil {
		t.Fatal(err)
	}
	got, err := opening.OpenAnswer(reply)
	if err != nil || string(got) != "the token answer" {
		t.Fatalf("device opened %q, %v", got, err)
	}

	channelOpening, err := StartChannel(devicePriv, yardPub)
	if err != nil {
		t.Fatal(err)
	}
	channelHandshake, err := OpenChannel(yardPriv, channelOpening.First)
	if err != nil {
		t.Fatal(err)
	}
	tag := bytes.Repeat([]byte{0x33}, tagSize)
	answer, err := channelHandshake.SealAnswer(tag)
	if err != nil {
		t.Fatal(err)
	}
	yard := channelHandshake.Session()
	device, err := channelOpening.OpenAnswer(answer)
	if err != nil {
		t.Fatal(err)
	}
	call := bytes.Repeat([]byte{0x44}, callSize)
	run, err := device.SealWhole(call, "", false, []byte("sealed through the exported halves"))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := yard.OpenWhole(run, call, "", false)
	if err != nil || string(plain) != "sealed through the exported halves" {
		t.Fatalf("yard opened %q, %v", plain, err)
	}
}
