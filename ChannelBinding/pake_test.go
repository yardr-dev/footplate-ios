package channel

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"github.com/backkem/spake2-go"
)

// The PAKE of a typed code (pake.go), held as the yard's own tests
// hold theirs (internal/yardkey/pake_test.go, which these are
// transcribed from): the two static keys cross under the key the run
// derives, the yard's answer is sealed the same way, a wrong code
// fails at the confirmation, and a message the carrier turns fails
// at the next check. The recorded run of the yard's own library,
// which holds the device's half against another maker, is in
// vectors_test.go; the yard's half here is this binding's, so what
// these hold is the run's behaviour, and that agreement is held there
// and by the live run against yardkey that the bead's note records.

func newDevice(t *testing.T) (priv, pub []byte) {
	t.Helper()
	pair, err := GenerateKey()
	if err != nil {
		t.Fatal(err)
	}
	return pair.Private, pair.Public
}

func TestPAKEOptionsArePinned(t *testing.T) {
	// What the client beads implement against (users.md, "By a typed
	// code, through a PAKE"): the identities A and B, no AAD, no
	// symmetric variant, and the suite's own M and N, which are the
	// RFC 9382 section 4 values for P-256. A library that moved any
	// of them would move the transcript.
	o := pakeOptions()
	if string(o.IdentityA) != "A" || string(o.IdentityB) != "B" {
		t.Errorf("identities %q, %q, want A and B", o.IdentityA, o.IdentityB)
	}
	if len(o.AAD) != 0 || o.SymmetricMode {
		t.Errorf("AAD %q, symmetric %v, want none and false", o.AAD, o.SymmetricMode)
	}
	if spake2.P256_M_HEX != "02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f" {
		t.Errorf("M is %s", spake2.P256_M_HEX)
	}
	if spake2.P256_N_HEX != "03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49" {
		t.Errorf("N is %s", spake2.P256_N_HEX)
	}
	if PAKESuite != "SPAKE2-P256-SHA256-HKDF-HMAC" {
		t.Errorf("suite %s", PAKESuite)
	}
}

func TestPAKECodeIsCleanedAsTheYardCleansIt(t *testing.T) {
	for _, row := range []struct {
		typed string
		clean string // "" where it is no code
	}{
		{"K7QM-2XPD", "K7QM2XPD"},
		{"k7qm 2xpd", "K7QM2XPD"},
		{"K7qm-2xPD", "K7QM2XPD"},
		{"  K7QM2XPD\n", "K7QM2XPD"},
		// The letters a code never has read as the digits they look like.
		{"1L0O-ILOi", "11001101"},
		// Too short, too long, a letter no code has, another script.
		{"K7QM-2XP", ""},
		{"K7QM-2XPDK", ""},
		{"K7QM-2XPU", ""},
		{"", ""},
		{"K7QM-2XPÐ", ""},
		// Unicode folds this to an I, which the yard would read as 1;
		// refused here, where another password would be one wrong guess.
		{"ıııııııı", ""},
	} {
		got, err := pakePassword(row.typed)
		switch {
		case row.clean == "" && err == nil:
			t.Errorf("%q cleaned to %q, want no code", row.typed, got)
		case row.clean != "" && (err != nil || string(got) != row.clean):
			t.Errorf("%q cleaned to %q, %v, want %q", row.typed, got, err, row.clean)
		}
	}
	// No run starts on what is no code.
	priv, _ := newDevice(t)
	if _, err := StartPairingPAKE(priv, "K7QM"); err == nil || !strings.Contains(err.Error(), "no pairing code") {
		t.Errorf("a short code started a run: %v", err)
	}
}

// A typed pairing code is redeemed through the PAKE: the two static
// channel keys cross under the key the run derives, the yard's answer
// is sealed the same way, and neither the code nor a key crosses
// readable.
func TestPairingPAKEExchangesTheStaticKeys(t *testing.T) {
	devicePriv, devicePub := newDevice(t)
	_, yardPub := newDevice(t)
	// As typed: lower case, with the dash.
	opening, err := StartPairingPAKE(devicePriv, "k7qm-2xpd")
	if err != nil {
		t.Fatal(err)
	}
	if len(opening.First) != 65 {
		t.Fatalf("the PAKE first message is %d bytes, want the 65 of an uncompressed P-256 point", len(opening.First))
	}
	responder, err := AnswerPairingPAKE("K7QM2XPD", opening.First)
	if err != nil {
		t.Fatal(err)
	}
	if len(responder.Second) != 65 {
		t.Fatalf("the PAKE second message is %d bytes, want 65", len(responder.Second))
	}
	confirm, err := opening.Finish(responder.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(confirm) != 32 {
		t.Fatalf("the device confirmation is %d bytes, want 32", len(confirm))
	}
	yardConfirm, err := responder.Confirm(confirm)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := responder.Confirm(confirm); err == nil || errors.Is(err, ErrPAKEConfirmation) {
		t.Errorf("a second confirmation = %v, want a state error, not a failed confirmation", err)
	}
	if len(yardConfirm) != 32 {
		t.Fatalf("the yard confirmation is %d bytes, want 32", len(yardConfirm))
	}
	if err := opening.Verify(yardConfirm); err != nil {
		t.Fatal(err)
	}
	sealedKey, err := opening.SealKey()
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealedKey, devicePub) {
		t.Error("the device channel public key crosses readable in its sealed form")
	}
	deviceKey, err := responder.OpenKey(sealedKey)
	if err != nil {
		t.Fatal(err)
	}
	if deviceKey != PublicString(devicePub) {
		t.Fatalf("the yard opened device key %q, want %q", deviceKey, PublicString(devicePub))
	}
	answer := []byte(`{"token":"yardr-dev-x","channel_key":"` + PublicString(yardPub) + `"}`)
	sealedAnswer, err := responder.SealAnswer(answer)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealedAnswer, []byte("yardr-dev-x")) || bytes.Contains(sealedAnswer, yardPub) {
		t.Error("the sealed PAKE answer crosses readable")
	}
	opened, err := opening.OpenAnswer(sealedAnswer)
	if err != nil || !bytes.Equal(opened, answer) {
		t.Fatalf("the device opened %q, %v", opened, err)
	}
	// What one purpose sealed does not open as the other.
	if _, err := responder.OpenKey(sealedAnswer); err == nil {
		t.Error("a sealed answer opened as a device key")
	}
}

// The device seals nothing and trusts nothing it is answered until the
// yard's confirmation holds: the library gives no key before it, and a
// run that was never confirmed has none to seal or open with.
func TestPairingPAKESealsNothingBeforeTheYardConfirms(t *testing.T) {
	devicePriv, _ := newDevice(t)
	opening, err := StartPairingPAKE(devicePriv, "K7QM-2XPD")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := opening.SealKey(); err == nil {
		t.Error("a key was sealed before the yard's second message")
	}
	responder, err := AnswerPairingPAKE("K7QM-2XPD", opening.First)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := opening.Finish(responder.Second); err != nil {
		t.Fatal(err)
	}
	if _, err := opening.SealKey(); err == nil {
		t.Error("a key was sealed before the yard's confirmation held")
	}
	if _, err := opening.OpenAnswer(make([]byte, 64)); err == nil {
		t.Error("an answer was opened before the yard's confirmation held")
	}
	// The yard in its turn opens and seals nothing before the device's
	// confirmation held.
	if _, err := responder.SealAnswer([]byte("{}")); err == nil {
		t.Error("an answer was sealed before the device's confirmation held")
	}
	if _, err := responder.OpenKey(make([]byte, 60)); err == nil {
		t.Error("a device key was opened before the device's confirmation held")
	}
	// An impostor yard that confirms with bytes of its own: refused,
	// with the sentence the app reads, and nothing opens past it.
	if err := opening.Verify(make([]byte, 32)); err == nil || !strings.HasPrefix(err.Error(), PAKEUnconfirmed) {
		t.Errorf("a made-up yard confirmation = %v, want the unconfirmed sentence", err)
	}
	if _, err := opening.SealKey(); err == nil {
		t.Error("a key was sealed after a confirmation that did not hold")
	}
}

// A run with the wrong code derives another key: its confirmation is
// refused as the pairing's confirmation, and no device key is opened
// from it.
func TestPairingPAKEWrongCodeFailsConfirmation(t *testing.T) {
	devicePriv, _ := newDevice(t)
	opening, err := StartPairingPAKE(devicePriv, "AAAA-AAAA")
	if err != nil {
		t.Fatal(err)
	}
	responder, err := AnswerPairingPAKE("K7QM2XPD", opening.First)
	if err != nil {
		t.Fatal(err)
	}
	confirm, err := opening.Finish(responder.Second)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := responder.Confirm(confirm); !errors.Is(err, ErrPAKEConfirmation) {
		t.Fatalf("a wrong code's confirmation = %v, want ErrPAKEConfirmation", err)
	}
	if sealedKey, err := opening.SealKey(); err == nil {
		if _, err := responder.OpenKey(sealedKey); err == nil {
			t.Error("the yard opened a device key in a run whose confirmation failed")
		}
	}
}

// Every message the carrier can rewrite is held by the confirmations
// and the seals: a byte turned in the second message, a confirmation,
// a sealed key or a sealed answer fails that step, and a confirmation
// replayed from a finished run confirms nothing in a new one.
func TestPairingPAKETamperedMessagesFail(t *testing.T) {
	devicePriv, _ := newDevice(t)
	run := func(t *testing.T) (*PairingPAKEOpening, *PairingPAKEResponder) {
		t.Helper()
		opening, err := StartPairingPAKE(devicePriv, "K7QM-2XPD")
		if err != nil {
			t.Fatal(err)
		}
		responder, err := AnswerPairingPAKE("K7QM2XPD", opening.First)
		if err != nil {
			t.Fatal(err)
		}
		return opening, responder
	}
	turn := func(b []byte) []byte {
		out := append([]byte(nil), b...)
		out[len(out)/2] ^= 0xff
		return out
	}

	opening, responder := run(t)
	if _, err := opening.Finish(turn(responder.Second)); err == nil {
		t.Error("a turned second message was finished")
	}

	opening, responder = run(t)
	confirm, err := opening.Finish(responder.Second)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := responder.Confirm(turn(confirm)); !errors.Is(err, ErrPAKEConfirmation) {
		t.Errorf("a turned confirmation = %v, want ErrPAKEConfirmation", err)
	}
	yardConfirm, err := responder.Confirm(confirm)
	if err != nil {
		t.Fatal(err)
	}
	if err := opening.Verify(turn(yardConfirm)); !errors.Is(err, ErrPAKEConfirmation) {
		t.Errorf("a turned yard confirmation = %v, want ErrPAKEConfirmation", err)
	}
	if err := opening.Verify(yardConfirm); err != nil {
		t.Fatal(err)
	}
	sealedKey, err := opening.SealKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := responder.OpenKey(turn(sealedKey)); err == nil {
		t.Error("a turned sealed device key opened")
	}
	sealedAnswer, err := responder.SealAnswer([]byte(`{"token":"yardr-dev-x"}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := opening.OpenAnswer(turn(sealedAnswer)); err == nil {
		t.Error("a turned sealed answer opened")
	}

	// The recorded confirmation, replayed into a fresh run for the same
	// code, confirms nothing there: the new run's transcript differs, so
	// the recorded MAC is over another one.
	_, responder = run(t)
	if _, err := responder.Confirm(confirm); !errors.Is(err, ErrPAKEConfirmation) {
		t.Errorf("a replayed confirmation = %v, want ErrPAKEConfirmation", err)
	}
}

// A message that is no point of the suite is refused as one, never
// handed on to the library: an empty one would have it index past the
// end of the bytes and panic, and an encoding of the point at infinity
// (a lone byte, or a prefix and zeros) it would take as a point. Each
// side refuses them.
func TestPairingPAKERefusesWhatIsNoPoint(t *testing.T) {
	devicePriv, _ := newDevice(t)
	noPoints := map[string][]byte{
		"empty":          {},
		"one byte":       {0x04},
		"infinity":       make([]byte, 65),
		"prefixed zeros": append([]byte{0x04}, make([]byte, 64)...),
		"compressed":     append([]byte{0x02}, bytes.Repeat([]byte{0x11}, 32)...),
		"off the curve":  append([]byte{0x04}, bytes.Repeat([]byte{0x01}, 64)...),
		"too long":       append([]byte{0x04}, bytes.Repeat([]byte{0x01}, 65)...),
	}
	for name, msg := range noPoints {
		t.Run(name, func(t *testing.T) {
			if _, err := AnswerPairingPAKE("K7QM2XPD", msg); err == nil {
				t.Error("the yard answered a first message that is no point")
			}
			opening, err := StartPairingPAKE(devicePriv, "K7QM2XPD")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := opening.Finish(msg); err == nil {
				t.Error("the device finished on a second message that is no point")
			}
		})
	}
}

// A recorded transcript carries neither the code nor the token as
// cleartext, and its confirmation and sealed answer do not replay into
// a fresh run, even one started with the same code. The candidates
// below demonstrate that cross-run property; they are not an offline
// test of SPAKE2's password security.
func TestPairingPAKETranscriptDoesNotRevealValuesOrReplay(t *testing.T) {
	devicePriv, _ := newDevice(t)
	opening, err := StartPairingPAKE(devicePriv, "K7QM-2XPD")
	if err != nil {
		t.Fatal(err)
	}
	responder, err := AnswerPairingPAKE("K7QM2XPD", opening.First)
	if err != nil {
		t.Fatal(err)
	}
	confirm, err := opening.Finish(responder.Second)
	if err != nil {
		t.Fatal(err)
	}
	yardConfirm, err := responder.Confirm(confirm)
	if err != nil {
		t.Fatal(err)
	}
	if err := opening.Verify(yardConfirm); err != nil {
		t.Fatal(err)
	}
	sealedAnswer, err := responder.SealAnswer([]byte(`{"token":"yardr-dev-x"}`))
	if err != nil {
		t.Fatal(err)
	}
	transcript := [][]byte{opening.First, responder.Second, confirm, yardConfirm, sealedAnswer}
	for _, msg := range transcript {
		if bytes.Contains(msg, []byte("K7QM2XPD")) || bytes.Contains(msg, []byte("yardr-dev-x")) {
			t.Error("a transcript message crosses readable")
		}
	}
	for _, candidate := range []string{"K7QM-2XPE", "AAAA-AAAA", "0000-0000", "K7QM-2XPD"} {
		guess, err := StartPairingPAKE(devicePriv, candidate)
		if err != nil {
			t.Fatal(err)
		}
		guessed, err := guess.Finish(responder.Second)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Equal(guessed, confirm) {
			t.Errorf("candidate %s reproduced the recorded confirmation offline", candidate)
		}
		if err := guess.Verify(yardConfirm); !errors.Is(err, ErrPAKEConfirmation) {
			t.Errorf("candidate %s: Verify = %v, want ErrPAKEConfirmation", candidate, err)
		}
		if _, err := guess.OpenAnswer(sealedAnswer); err == nil {
			t.Errorf("candidate %s opened the recorded sealed answer offline", candidate)
		}
	}
	// Bytes that are no first message are refused before any run.
	if _, err := AnswerPairingPAKE("K7QM2XPD", []byte("not a point")); err == nil {
		t.Error("bytes that are no first message were answered")
	}
}
