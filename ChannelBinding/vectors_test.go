package channel

import (
	"bytes"
	"encoding/hex"
	"testing"

	"github.com/flynn/noise"
)

// The proofs the design asks for before channel work (section
// 3.2): the bound flynn/noise v1.1.0 held against the Noise
// specification's vectors, and the binding's framing held against
// the yard's and the desktop's own sealing of the same record.
// None of them runs both ends through this binding: the vector is
// the specification's, the yard record is yardkey's, and the snow
// record is the desktop's, each made by that code itself.

func mustHex(t *testing.T, text string) []byte {
	t.Helper()
	raw, err := hex.DecodeString(text)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func mustKey(t *testing.T, text string) [32]byte {
	t.Helper()
	raw := mustHex(t, text)
	if len(raw) != 32 {
		t.Fatalf("a key of %d bytes", len(raw))
	}
	var key [32]byte
	copy(key[:], raw)
	return key
}

// The Noise_IK_25519_ChaChaPoly_SHA256 vector of the Noise
// specification (revision 34), as flynn/noise carries it in
// vectors.txt: the one pattern and suite a channel runs.
const (
	vectorInitStatic      = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	vectorRespStatic      = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	vectorInitEphemeral   = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
	vectorRespEphemeral   = "4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60"
	vectorFirstEmpty      = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd1662544f8445e5dc2467b1e32653192d05dee85c4781bf0dd8d33ceebb5905a7a069f09e0d3f2cad1c842930a762eb75e52827f01d2c85189d527644b3221b4c3fc5cc"
	vectorFirstPayload    = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd1662544f8445e5dc2467b1e32653192d05dee85c4781bf0dd8d33ceebb5905a7a069f09e0d3f2cad1c842930a762eb75e528270337527f958f92050deefa1892482d74328fee90d08201bba3cc"
	vectorSecondEmpty     = "64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466aabfe2e5b1650bbaa88e33679893fc77"
	vectorSecondPayload   = "64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466cb4a35db52355821787bb891112ba10f4d3dfe08b27d634db8af"
	vectorTransportFirst  = "226ca869f2777611f37350a7ab446f650c0cfe2855b7f020ce658bcf100f2d"
	vectorTransportSecond = "90d84d69cd44829283b05d684879b53b8d714e51619b601438a1ae67caacd9"
)

func vectorStates(t *testing.T) (initiator, responder *noise.HandshakeState) {
	t.Helper()
	initStatic, err := noise.DH25519.GenerateKeypair(bytes.NewReader(mustHex(t, vectorInitStatic)))
	if err != nil {
		t.Fatal(err)
	}
	respStatic, err := noise.DH25519.GenerateKeypair(bytes.NewReader(mustHex(t, vectorRespStatic)))
	if err != nil {
		t.Fatal(err)
	}
	initiator, err = noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        bytes.NewReader(mustHex(t, vectorInitEphemeral)),
		Pattern:       noise.HandshakeIK,
		Initiator:     true,
		StaticKeypair: initStatic,
		PeerStatic:    respStatic.Public,
	})
	if err != nil {
		t.Fatal(err)
	}
	responder, err = noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        bytes.NewReader(mustHex(t, vectorRespEphemeral)),
		Pattern:       noise.HandshakeIK,
		Initiator:     false,
		StaticKeypair: respStatic,
	})
	if err != nil {
		t.Fatal(err)
	}
	return initiator, responder
}

func TestNoiseIKSpecificationVector(t *testing.T) {
	initiator, responder := vectorStates(t)
	first, _, _, err := initiator.WriteMessage(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(first); got != vectorFirstEmpty {
		t.Fatalf("first message = %s, want the vector's %s", got, vectorFirstEmpty)
	}
	payload, _, _, err := responder.ReadMessage(nil, first)
	if err != nil || len(payload) != 0 {
		t.Fatalf("responder opened %x, %v", payload, err)
	}
	second, respSend, respRecv, err := responder.WriteMessage(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(second); got != vectorSecondEmpty {
		t.Fatalf("second message = %s, want the vector's %s", got, vectorSecondEmpty)
	}
	payload, initSend, initRecv, err := initiator.ReadMessage(nil, second)
	if err != nil || len(payload) != 0 {
		t.Fatalf("initiator opened %x, %v", payload, err)
	}
	// The transport keys the handshake split, at the vector's
	// payloads (yellow submarine, submarineyellow).
	sealed, err := initSend.Encrypt(nil, nil, mustHex(t, "79656c6c6f777375626d6172696e65"))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(sealed); got != vectorTransportFirst {
		t.Fatalf("first transport = %s, want the vector's %s", got, vectorTransportFirst)
	}
	opened, err := respSend.Decrypt(nil, nil, sealed)
	if err != nil || string(opened) != "yellowsubmarine" {
		t.Fatalf("responder opened %q, %v", opened, err)
	}
	sealed, err = respRecv.Encrypt(nil, nil, mustHex(t, "7375626d6172696e6579656c6c6f77"))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(sealed); got != vectorTransportSecond {
		t.Fatalf("second transport = %s, want the vector's %s", got, vectorTransportSecond)
	}
	opened, err = initRecv.Decrypt(nil, nil, sealed)
	if err != nil || string(opened) != "submarineyellow" {
		t.Fatalf("initiator opened %q, %v", opened, err)
	}
}

// The binding's own first messages, at the vector's keys and
// ephemeral: a channel's (no payload) and a pairing's (the code
// test_msg_0 as its payload) are the vector's ciphertexts byte
// for byte, so the gomobile artifact, and not only the library
// under it, is held to the specification.
func TestBindingFirstMessagesMatchTheVector(t *testing.T) {
	held := randReader
	defer func() { randReader = held }()
	devicePrivate := mustHex(t, vectorInitStatic)
	yardPublic, err := PublicOf(mustHex(t, vectorRespStatic))
	if err != nil {
		t.Fatal(err)
	}
	randReader = bytes.NewReader(mustHex(t, vectorInitEphemeral))
	channel, err := StartChannel(devicePrivate, yardPublic)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(channel.First); got != vectorFirstEmpty {
		t.Fatalf("channel first = %s, want the vector's %s", got, vectorFirstEmpty)
	}
	randReader = bytes.NewReader(mustHex(t, vectorInitEphemeral))
	pairing, err := StartPairing(devicePrivate, yardPublic, "test_msg_0")
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(pairing.First); got != vectorFirstPayload {
		t.Fatalf("pairing first = %s, want the vector's %s", got, vectorFirstPayload)
	}
}

// fixedSession is one end of a session over known keys, as the
// desktop's tests found one: the device end sends under send in
// the request direction, the yard end under recv in the answer.
func fixedSession(tag []byte, send, recv [32]byte, deviceEnd bool) *Session {
	sendDir, recvDir := dirAnswer, dirRequest
	if deviceEnd {
		sendDir, recvDir = dirRequest, dirAnswer
	}
	return &Session{
		tag:     append([]byte(nil), tag...),
		sendKey: send, recvKey: recv,
		sendDir: sendDir, recvDir: recvDir,
	}
}

func TestYardSealedRecordOpensAndSealsTheSame(t *testing.T) {
	// Made by yardkey (yardr b52d9f71, internal/yardkey over
	// flynn/noise) sealing over the tag, keys, call and binding
	// below, then removed there; the same bytes stand in the
	// desktop's the_yards_sealed_record_opens_and_seals_the_same.
	tag := mustHex(t, "000102030405060708090a0b0c0d0e0f")
	send := mustKey(t, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	recv := mustKey(t, "6465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80818283")
	call := mustHex(t, "101112131415161718191a1b1c1d1e1f")
	first := binding(StreamLongLived, true)
	device := fixedSession(tag, send, recv, true)
	yardEnd := fixedSession(tag, recv, send, false)
	theirs := mustHex(t, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f0000000000000000000000000000000070dd2e5dc2c6dfb0610530388fbe21c563177fcff3566fa69816")
	ours, err := device.seal(call, 0, first, []byte("hello yard"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ours, theirs) {
		t.Fatalf("device sealed %x, the yard sealed %x", ours, theirs)
	}
	index, plain, err := yardEnd.open(theirs, call, first)
	if err != nil || index != 0 || string(plain) != "hello yard" {
		t.Fatalf("yard record opened at %d as %q, %v", index, plain, err)
	}
	back := mustHex(t, "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f000000000000000000000000000000007036073b1cc86f27181581f7d4b7cfba8599c7bfde02e0c16f44e8ad")
	sealedBack, err := yardEnd.seal(call, 0, first, []byte("hello device"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sealedBack, back) {
		t.Fatalf("yard sealed %x, this binding's yard end sealed %x", back, sealedBack)
	}
	deviceEnd := fixedSession(tag, send, recv, true)
	index, plain, err = deviceEnd.open(back, call, first)
	if err != nil || index != 0 || string(plain) != "hello device" {
		t.Fatalf("yard answer opened at %d as %q, %v", index, plain, err)
	}
}

func TestSnowSealedRecordOpensAndSealsTheSame(t *testing.T) {
	// Made by snow (footplate 96cef03, src/e2e.rs over snow
	// 0.10.0) sealing over the tag, keys, call and binding below,
	// then removed there. Other keys and words than the yard's,
	// so this record is the desktop's alone.
	tag := mustHex(t, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
	send := mustKey(t, "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
	recv := mustKey(t, "505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f")
	call := mustHex(t, "202122232425262728292a2b2c2d2e2f")
	first := binding(StreamLongLived, true)
	device := fixedSession(tag, send, recv, true)
	yardEnd := fixedSession(tag, recv, send, false)
	theirs := mustHex(t, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf202122232425262728292a2b2c2d2e2f0000000000000000000000000000000050287fe4f61389fe0ad1f0b1a084f75b69c1d6d588a5a1505dd2d448af446524ae1c9528c86e")
	ours, err := device.seal(call, 0, first, []byte("hello from snow device"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ours, theirs) {
		t.Fatalf("device sealed %x, snow sealed %x", ours, theirs)
	}
	index, plain, err := yardEnd.open(theirs, call, first)
	if err != nil || index != 0 || string(plain) != "hello from snow device" {
		t.Fatalf("snow record opened at %d as %q, %v", index, plain, err)
	}
	back := mustHex(t, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf202122232425262728292a2b2c2d2e2f000000000000000000000000000000006fb04f2ae3f63c15cf57d64e278beb0117caf389ad7b0cb9a559d40bf66926dbb171a0fc")
	sealedBack, err := yardEnd.seal(call, 0, first, []byte("hello from snow yard"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sealedBack, back) {
		t.Fatalf("snow sealed %x, this binding's yard end sealed %x", back, sealedBack)
	}
	deviceEnd := fixedSession(tag, send, recv, true)
	index, plain, err = deviceEnd.open(back, call, first)
	if err != nil || index != 0 || string(plain) != "hello from snow yard" {
		t.Fatalf("snow answer opened at %d as %q, %v", index, plain, err)
	}
}

// openTranscript recreates the device end of a deterministic
// handshake transcript (fixed statics, fixed ephemerals, the
// tag as sixteen 0x33, the call as sixteen 0x44) and holds the
// binding against the other end's bytes: its first message is
// the transcript's, its session opens the transcript's answer
// run, and its own sealed run is the transcript's byte for byte.
func openTranscript(t *testing.T, first, answer, deviceRun, yardRun, callPlain, answerPlain string) {
	t.Helper()
	held := randReader
	defer func() { randReader = held }()
	devicePrivate := bytes.Repeat([]byte{0x11}, 32)
	yardPublic, err := PublicOf(bytes.Repeat([]byte{0x22}, 32))
	if err != nil {
		t.Fatal(err)
	}
	randReader = bytes.NewReader(bytes.Repeat([]byte{0xa5}, 32))
	opening, err := StartChannel(devicePrivate, yardPublic)
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(opening.First); got != first {
		t.Fatalf("first = %s, want the transcript's %s", got, first)
	}
	session, err := opening.OpenAnswer(mustHex(t, answer))
	if err != nil {
		t.Fatal(err)
	}
	call := bytes.Repeat([]byte{0x44}, 16)
	run, err := session.SealWhole(call, "", false, []byte(callPlain))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(run); got != deviceRun {
		t.Fatalf("sealed run = %s, want the transcript's %s", got, deviceRun)
	}
	opened, err := session.OpenWhole(mustHex(t, yardRun), call, "", false)
	if err != nil || string(opened) != answerPlain {
		t.Fatalf("opened %q, %v", opened, err)
	}
}

func TestYardHandshakeTranscript(t *testing.T) {
	// Made by yardkey (yardr b52d9f71) over flynn/noise with the
	// fixed keys above, its SealWhole/OpenWhole throughout, then
	// removed there. Its first and answer are snow's too (the
	// next test), as one handshake over the same ephemerals must.
	openTranscript(t,
		"5fef13fc76023a9ee6ded987b6aa93958cdc2097ef9fc845d5319c9ca100d35ed8ec3ae52907fddf42a0b17fe940ebdc6e3dc880f8acf94cc54a0896fb3bbc68bd7599b5e273edd85796861be90330575e5094f18dcf3960749f8658542fe12e",
		"b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2cac3984421284d16ac307637301bd942a71afc77fea33127544122dd742394b5a",
		"000000533333333333333333333333333333333344444444444444444444444444444444000000000000000000000000000000003d255735931b659081a5f2ae31aa81b4f6185937048aa6fbcb552130a631852e5686540000005033333333333333333333333333333333444444444444444444444444444444440000000000000001000000000000000100c8bf55e4ba58ba39b5d763e0d567663fbdd78dc1db99fdf2d7a39a08c4e12a",
		"0000005533333333333333333333333333333333444444444444444444444444444444440000000000000000000000000000000015572c1ca26c1f9eeca64711fc8208f848f18bfbcb0796c410909a7231a6289d07df6c2f7d00000050333333333333333333333333333333334444444444444444444444444444444400000000000000010000000000000001ad01d0e0e606f2e5cd1ccc1ead90125dda0cd77a1485db48e942a65f53e7f2df",
		"yard handshake call", "yard handshake answer")
}

func TestSnowHandshakeTranscript(t *testing.T) {
	// Made by snow (footplate 96cef03, src/e2e.rs, snow's
	// testing-only fixed ephemeral) over the same fixed keys,
	// its seal_whole/open_whole throughout, then removed there.
	openTranscript(t,
		"5fef13fc76023a9ee6ded987b6aa93958cdc2097ef9fc845d5319c9ca100d35ed8ec3ae52907fddf42a0b17fe940ebdc6e3dc880f8acf94cc54a0896fb3bbc68bd7599b5e273edd85796861be90330575e5094f18dcf3960749f8658542fe12e",
		"b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2cac3984421284d16ac307637301bd942a71afc77fea33127544122dd742394b5a",
		"00000053333333333333333333333333333333334444444444444444444444444444444400000000000000000000000000000000372a4a26931b659081a5f2ae31aa81b4f61859160c63f29c12cf1e048e6662011a71fd0000005033333333333333333333333333333333444444444444444444444444444444440000000000000001000000000000000100c8bf55e4ba58ba39b5d763e0d567663fbdd78dc1db99fdf2d7a39a08c4e12a",
		"000000553333333333333333333333333333333344444444444444444444444444444444000000000000000000000000000000001f58310fa26c1f9eeca64711fc8208f848f18bfbcbce5170ad9840e0e9fcad0b2d49a44abe00000050333333333333333333333333333333334444444444444444444444444444444400000000000000010000000000000001ad01d0e0e606f2e5cd1ccc1ead90125dda0cd77a1485db48e942a65f53e7f2df",
		"snow handshake call", "snow handshake answer")
}
