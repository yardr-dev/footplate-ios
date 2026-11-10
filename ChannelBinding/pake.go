package channel

// A pairing code that is typed or read aloud, redeemed through a
// PAKE (yard design 2026-11-05-yardr-device-e2e.md, section 3.1
// candidate 1A and section 6 beads 16 and 18): the device and the
// yard run SPAKE2 with the code as the password and exchange their
// channel keys under the key it derives, so whoever carries the
// run, and may rewrite every message of it, gets one online guess
// at the code and no way to test a recorded run against candidates
// afterwards. It holds only for a code the carrier never read: a
// code the edge handed out, as the router does a member's, is
// known to it, which can then sit in the run as either end.
//
// None of the PAKE is written here: the run is
// github.com/backkem/spake2-go v0.0.1's, the module the yard runs
// (internal/yardkey/pake.go, which this file is transcribed from
// and held against), under the same maintained-library rule as the
// Noise of channel.go. It states it has had no formal audit, and
// nothing here claims one for it. What is here is the yard's
// pinned choices around it, so the transcript is the yard's own.

import (
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/backkem/spake2-go"
	"golang.org/x/crypto/chacha20poly1305"
)

// PAKESuite is the suite the yard pins for the clients: RFC 9382
// section 6's SPAKE2-P256-SHA256-HKDF-HMAC, with the suite's own
// M and N, the identities "A" (the device) and "B" (the yard), and
// no additional authenticated data. The AAD is empty on purpose:
// the library folds a non-empty one into the transcript as well as
// into the confirmation KDF, which an RFC client would not do, so
// a non-empty one would pin a client to the library's variant.
// The password is the cleaned code as eight ASCII bytes, and w is
// derived from it as the suite's hash derives it. Every length in
// the transcript is the RFC's eight-byte little-endian one, and
// the derived Ke, the first half of the transcript's SHA-256, is
// the key the static keys and the answer cross under.
const PAKESuite = "SPAKE2-P256-SHA256-HKDF-HMAC"

// PAKEUnconfirmed starts the sentence of the one failure of a run
// that proves a guess was made: the other side's confirmation does
// not hold, so its code was not this side's or a message was
// rewritten on the way. The app reads it by this word, since a
// bound error carries no more than its text.
const PAKEUnconfirmed = "the pairing confirmation does not hold"

// ErrPAKEConfirmation is that failure, as the yard names it.
var ErrPAKEConfirmation = errors.New(PAKEUnconfirmed)

const (
	pakeDeviceKeyInfo = "yardr pake device key v1"
	pakeAnswerInfo    = "yardr pake answer v1"
	pakePointSize     = 65 // an uncompressed P-256 point
	codeSize          = 8
	codeAlphabet      = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
)

// pakeOptions is a fresh set of the pinned suite's options, as
// spake2-go's defaults state them: the P-256 suite, the identities
// above and no AAD. A variable so a test can stand a fixed scalar
// in for the run's random one, as randReader stands for the
// binding's.
var pakeOptions = spake2.DefaultOptions

// pakePassword is a pairing code, as it was typed or as the yard
// holds it, in the form both sides run the PAKE on: the cleaned
// code's eight ASCII bytes. It is cleaned as the yard's CleanCode
// cleans it (no dash or space, capitals, and I and L as 1, O as
// 0), but over ASCII alone: a letter the yard would fold into one
// of these by Unicode's rules is refused here, before anything is
// sent, where another password would be one wrong guess.
func pakePassword(code string) ([]byte, error) {
	clean := make([]byte, 0, codeSize)
	start, end := 0, len(code)
	for start < end && isSpace(code[start]) {
		start++
	}
	for end > start && isSpace(code[end-1]) {
		end--
	}
	for i := start; i < end; i++ {
		c := code[i]
		switch {
		case c == '-' || c == ' ':
			continue
		case c >= 'a' && c <= 'z':
			c -= 'a' - 'A'
		}
		switch c {
		case 'I', 'L':
			c = '1'
		case 'O':
			c = '0'
		}
		clean = append(clean, c)
	}
	if len(clean) != codeSize {
		return nil, errors.New("that is no pairing code: want its eight characters, such as K7QM-2XPD")
	}
	for _, c := range clean {
		if !isCodeChar(c) {
			return nil, errors.New("that is no pairing code: want its eight characters, such as K7QM-2XPD")
		}
	}
	return clean, nil
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func isCodeChar(c byte) bool {
	for i := 0; i < len(codeAlphabet); i++ {
		if codeAlphabet[i] == c {
			return true
		}
	}
	return false
}

// pakePoint refuses a SPAKE2 message that is no point of the
// pinned suite, before the library is handed it: ecdh takes only
// the 65-byte uncompressed encoding of a point on P-256 and
// refuses the point at infinity, where the library would take a
// lone byte or a prefix and zeros as that point, and index past
// the end of an empty message and panic. A message refused here is
// no guess at the code.
func pakePoint(msg []byte) error {
	if _, err := ecdh.P256().NewPublicKey(msg); err != nil {
		return fmt.Errorf("a pairing PAKE message of %d bytes is no point of %s", len(msg), PAKESuite)
	}
	return nil
}

func pakeAEAD(ke []byte, info string) (cipher.AEAD, error) {
	key, err := hkdf.Key(sha256.New, ke, nil, info, chacha20poly1305.KeySize)
	if err != nil {
		return nil, err
	}
	return chacha20poly1305.New(key)
}

// pakeSeal seals plain under a key derived from the run's Ke for
// info: HKDF-SHA256 with no salt to a ChaCha20-Poly1305 key, then
// a fresh nonce and the sealed bytes.
func pakeSeal(ke []byte, info string, plain []byte) ([]byte, error) {
	aead, err := pakeAEAD(ke, info)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(randReader, nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, plain, nil), nil
}

// pakeOpen opens what pakeSeal sealed for info.
func pakeOpen(ke []byte, info string, sealed []byte) ([]byte, error) {
	aead, err := pakeAEAD(ke, info)
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, fmt.Errorf("a sealed PAKE message of %d bytes holds no nonce", len(sealed))
	}
	return aead.Open(nil, sealed[:aead.NonceSize()], sealed[aead.NonceSize():], nil)
}

// A typed-code pairing a device has begun: its first message sent,
// its confirmation still to make. First is the run's blinded P-256
// point, 65 bytes uncompressed; the device's own channel key
// crosses later, sealed under the derived key (SealKey).
type PairingPAKEOpening struct {
	First  []byte
	run    *spake2.SPAKE2
	device []byte
}

// StartPairingPAKE begins a run for the device channel key
// devicePrivate on the pairing code, as the device typed it.
func StartPairingPAKE(devicePrivate []byte, code string) (*PairingPAKEOpening, error) {
	// The bytes that cross the bound boundary are the caller's,
	// and freed when the call returns.
	devicePrivate = append([]byte(nil), devicePrivate...)
	public, err := PublicOf(devicePrivate)
	if err != nil {
		return nil, err
	}
	password, err := pakePassword(code)
	if err != nil {
		return nil, err
	}
	run := spake2.NewClient(password, pakeOptions())
	first, err := run.Start()
	if err != nil {
		return nil, err
	}
	return &PairingPAKEOpening{First: first, run: run, device: public}, nil
}

// Finish takes the yard's second message and answers the device's
// confirmation of the run: 32 bytes, the HMAC of the transcript
// under its confirmation key (RFC 9382, section 4).
func (o *PairingPAKEOpening) Finish(second []byte) ([]byte, error) {
	// The library keeps the message in its transcript for the
	// confirmation checked later, past this call, which frees the
	// caller's bytes.
	second = append([]byte(nil), second...)
	if err := pakePoint(second); err != nil {
		return nil, err
	}
	confirm, err := o.run.Finish(second)
	if err != nil {
		return nil, fmt.Errorf("a pairing PAKE second message that does not open: %w", err)
	}
	return confirm, nil
}

// Verify checks the yard's confirmation of the run. Only a run
// that passes it has a yard at its other end that holds the code:
// until then the device seals nothing and trusts nothing it is
// answered, which the library holds too, giving no key before it.
func (o *PairingPAKEOpening) Verify(yardConfirm []byte) error {
	if err := o.run.Verify(yardConfirm); err != nil {
		if errors.Is(err, spake2.ErrInvalidConfirmation) {
			return fmt.Errorf("%w: %w", ErrPAKEConfirmation, err)
		}
		return fmt.Errorf("a pairing PAKE confirmation could not be checked: %w", err)
	}
	return nil
}

// SealKey seals the device's channel public key under the run's
// derived key, for the yard to record beside the token it issues.
func (o *PairingPAKEOpening) SealKey() ([]byte, error) {
	ke, err := o.run.SharedKey()
	if err != nil {
		return nil, err
	}
	return pakeSeal(ke, pakeDeviceKeyInfo, o.device)
}

// OpenAnswer opens the yard's sealed answer to this run: the
// pairing's answer (the token, the user, the device and the yard,
// with a push voucher) and the yard's channel public key as
// channel_key, for the device to pin, readable by this device
// alone.
func (o *PairingPAKEOpening) OpenAnswer(sealed []byte) ([]byte, error) {
	ke, err := o.run.SharedKey()
	if err != nil {
		return nil, err
	}
	plain, err := pakeOpen(ke, pakeAnswerInfo, sealed)
	if err != nil {
		return nil, fmt.Errorf("a pairing PAKE answer that does not open: %w", err)
	}
	return plain, nil
}

// The yard's half of the run, carried as the desktop's module
// carries it: the stand-in yard of the app's tests, and nothing
// the app calls on its own behalf. It is the yard's own
// AnswerPairingPAKE and its responder over the same library.

// A typed-code pairing the yard has answered: its second message
// sent, the device's confirmation still to check. Second is the
// yard's blinded point, 65 bytes uncompressed.
type PairingPAKEResponder struct {
	Second []byte
	run    *spake2.SPAKE2
}

// AnswerPairingPAKE answers a run's first message with the
// yard's second, on the code of the pairing it has open. A first
// message that is no point of the suite is refused here, before
// any confirmation can be tried against it: it is no guess at the
// code.
func AnswerPairingPAKE(code string, first []byte) (*PairingPAKEResponder, error) {
	first = append([]byte(nil), first...)
	if err := pakePoint(first); err != nil {
		return nil, err
	}
	password, err := pakePassword(code)
	if err != nil {
		return nil, err
	}
	run := spake2.NewServer(password, pakeOptions())
	second, err := run.Exchange(first)
	if err != nil {
		return nil, fmt.Errorf("a pairing PAKE first message that does not open: %w", err)
	}
	return &PairingPAKEResponder{Second: second, run: run}, nil
}

// Confirm checks the device's confirmation of the run and answers
// the yard's. One that does not hold fails with PAKEUnconfirmed's
// sentence: one online guess at the code, spent. The device key
// is opened only after this passes, and the answer sealed only in
// a run that passed it.
func (r *PairingPAKEResponder) Confirm(device []byte) ([]byte, error) {
	yardConfirm, err := r.run.Confirm(device)
	if err != nil {
		if errors.Is(err, spake2.ErrInvalidConfirmation) {
			return nil, fmt.Errorf("%w: %w", ErrPAKEConfirmation, err)
		}
		return nil, fmt.Errorf("a pairing PAKE confirmation could not be checked: %w", err)
	}
	return yardConfirm, nil
}

// OpenKey opens the device's sealed channel public key in a
// confirmed run, as PublicString writes it: the key the device is
// recorded with.
func (r *PairingPAKEResponder) OpenKey(sealed []byte) (string, error) {
	ke, err := r.run.SharedKey()
	if err != nil {
		return "", err
	}
	plain, err := pakeOpen(ke, pakeDeviceKeyInfo, sealed)
	if err != nil {
		return "", fmt.Errorf("a pairing PAKE device key that does not open: %w", err)
	}
	if len(plain) != 32 {
		return "", fmt.Errorf("a pairing PAKE device key of %d bytes is no channel public key", len(plain))
	}
	return PublicString(plain), nil
}

// SealAnswer seals payload as a confirmed run's answer: the
// pairing's answer, readable by the device that ran it alone.
func (r *PairingPAKEResponder) SealAnswer(payload []byte) ([]byte, error) {
	ke, err := r.run.SharedKey()
	if err != nil {
		return nil, err
	}
	return pakeSeal(ke, pakeAnswerInfo, payload)
}
