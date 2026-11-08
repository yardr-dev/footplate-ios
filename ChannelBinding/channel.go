// The phone's half of the channel between a paired device and its
// yard (yardr design 2026-11-05-yardr-device-e2e.md, sections 3.1
// and 3.2), bound from Go for iOS by gomobile. Every Noise
// construction is github.com/flynn/noise v1.1.0's: this binding
// marshals bytes, holds keys and carries the design's
// explicit-nonce and replay framing (transcribed from the yard's
// internal/yardkey, as footplate's e2e.rs carries it over snow),
// and constructs no Noise of its own. The bound v1.1.0 and this
// binding are not yet independently reviewed; nothing here calls
// them audited, and the app shows no sealed claim on their word.
package channel

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"

	"github.com/flynn/noise"
	"golang.org/x/crypto/curve25519"
)

// OuterPath is the one fixed outer path of an enveloped call, as
// the device addresses it and as a first record binds it.
const OuterPath = "/user/e2e"

// StreamLongLived is the outer stream marker's one value: set
// exactly when the inner answer may sit idle without bound (the
// events stream, and nothing else today).
const StreamLongLived = "long-lived"

const (
	tagSize    = 16 // a session tag: sixteen random bytes the yard mints
	callSize   = 16 // a call id: sixteen random bytes the device mints
	headerSize = tagSize + callSize + 8 + 8
	// maxRecordPlain is the most plaintext one transport message
	// carries: the Noise bound of 65,535 bytes, its clear header
	// and its AEAD tag counted.
	maxRecordPlain = noise.MaxMsgLen - headerSize - 16
	// replayWindow is how many opened sequences a receiver
	// remembers in one direction of a session.
	replayWindow = 65536
)

// The directions a message travels, as the associated data names
// them.
const (
	dirRequest byte = 0 // device to yard
	dirAnswer  byte = 1 // yard to device
)

var suite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashSHA256)

var enc = base64.RawURLEncoding

// randReader is the binding's randomness; the tests stand a
// counted reader in its place to mint golden transcripts.
var randReader io.Reader = rand.Reader

// A channel key pair: 32 bytes a half.
type KeyPair struct {
	Private []byte
	Public  []byte
}

// GenerateKey makes a fresh X25519 channel key pair for one yard,
// by flynn/noise as the yard makes its own. The private half is
// the device's secret for that yard, kept in the platform's
// keeping and shown nowhere; the public half travels.
func GenerateKey() (*KeyPair, error) {
	pair, err := noise.DH25519.GenerateKeypair(randReader)
	if err != nil {
		return nil, err
	}
	return &KeyPair{Private: pair.Private, Public: pair.Public}, nil
}

// PublicOf answers the public half of a channel private key, as
// the key was generated with: Curve25519's base-point
// multiplication, so a key kept as its private half alone still
// names itself.
func PublicOf(private []byte) ([]byte, error) {
	if len(private) != 32 {
		return nil, fmt.Errorf("a channel private key is 32 bytes, not %d", len(private))
	}
	return curve25519.X25519(private, curve25519.Basepoint)
}

// PublicString is a channel public key as it travels: in a
// pairing QR's fourth field and in a device record beside its
// token's hash. Base64url, no padding, as the yard writes it.
func PublicString(public []byte) string { return enc.EncodeToString(public) }

// ParsePublic reads a channel public key as PublicString writes
// it; what is no such key is refused before anything is sent
// under it.
func ParsePublic(s string) ([]byte, error) {
	b, err := enc.Strict().DecodeString(s)
	if err != nil || len(b) != 32 {
		return nil, fmt.Errorf("no channel public key")
	}
	return b, nil
}

// NewCallID mints a call id: sixteen random bytes, once for each
// call a device opens, never reused inside a session.
func NewCallID() ([]byte, error) {
	id := make([]byte, callSize)
	_, err := io.ReadFull(randReader, id)
	return id, err
}

// A pairing handshake a device has begun: its first message sent,
// its answer still to open. First carries the pairing code as its
// payload and seals the device's static key inside it, where only
// the yard can read either.
type PairingOpening struct {
	First []byte
	hs    *noise.HandshakeState
}

// StartPairing begins a pairing handshake to the yard channel
// public key a device pinned from the pairing QR, with the device
// key pair the app made for that yard and the pairing code as the
// first message's payload: the device's half of a sealed
// redemption, run by flynn/noise.
func StartPairing(devicePrivate, yardPublic []byte, code string) (*PairingOpening, error) {
	// The bytes that cross the bound boundary are the caller's,
	// and freed when the call returns: the keys a handshake
	// holds are the binding's own copies.
	devicePrivate = append([]byte(nil), devicePrivate...)
	yardPublic = append([]byte(nil), yardPublic...)
	public, err := PublicOf(devicePrivate)
	if err != nil {
		return nil, err
	}
	if len(yardPublic) != 32 {
		return nil, fmt.Errorf("a yard channel public key is 32 bytes, not %d", len(yardPublic))
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        randReader,
		Pattern:       noise.HandshakeIK,
		Initiator:     true,
		StaticKeypair: noise.DHKey{Private: devicePrivate, Public: public},
		PeerStatic:    yardPublic,
	})
	if err != nil {
		return nil, err
	}
	first, _, _, err := hs.WriteMessage(nil, []byte(code))
	if err != nil {
		return nil, err
	}
	return &PairingOpening{First: first, hs: hs}, nil
}

// OpenAnswer opens the yard's sealed answer to this opening: the
// pairing's answer (the token, the user, the device and the
// yard, with a push voucher beside them), readable by this
// device alone.
func (o *PairingOpening) OpenAnswer(reply []byte) ([]byte, error) {
	payload, _, _, err := o.hs.ReadMessage(nil, reply)
	return payload, err
}

// A channel handshake a device has begun: its first message
// sent, its answer still to open. Its first message names no
// call, which is how the yard tells it from an enveloped call.
type ChannelOpening struct {
	First []byte
	hs    *noise.HandshakeState
}

// StartChannel begins a channel handshake to the yard channel
// public key a device pinned at pairing, with the device's own
// channel key as its static: the device's half of opening a
// session, run by flynn/noise.
func StartChannel(devicePrivate, yardPublic []byte) (*ChannelOpening, error) {
	devicePrivate = append([]byte(nil), devicePrivate...)
	yardPublic = append([]byte(nil), yardPublic...)
	public, err := PublicOf(devicePrivate)
	if err != nil {
		return nil, err
	}
	if len(yardPublic) != 32 {
		return nil, fmt.Errorf("a yard channel public key is 32 bytes, not %d", len(yardPublic))
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        randReader,
		Pattern:       noise.HandshakeIK,
		Initiator:     true,
		StaticKeypair: noise.DHKey{Private: devicePrivate, Public: public},
		PeerStatic:    yardPublic,
	})
	if err != nil {
		return nil, err
	}
	first, _, _, err := hs.WriteMessage(nil, nil)
	if err != nil {
		return nil, err
	}
	return &ChannelOpening{First: first, hs: hs}, nil
}

// OpenAnswer opens the yard's handshake answer, whose payload is
// the session tag the yard minted, and answers the session it
// founds: this device sends under the handshake's first
// transport key and opens under its second.
func (o *ChannelOpening) OpenAnswer(reply []byte) (*Session, error) {
	payload, send, recv, err := o.hs.ReadMessage(nil, reply)
	if err != nil {
		return nil, fmt.Errorf("a channel handshake answer that does not open: %w", err)
	}
	if len(payload) != tagSize {
		return nil, fmt.Errorf("a channel handshake answer names no session tag")
	}
	return &Session{
		tag:     append([]byte(nil), payload...),
		sendKey: send.UnsafeKey(), recvKey: recv.UnsafeKey(),
		sendDir: dirRequest, recvDir: dirAnswer,
	}, nil
}

// firstBinding is what a call's first record in a direction binds
// beside the clear header: the fixed outer path both ends know
// without it crossing, and the outer stream marker's presence
// and value as the sender sent them. A first record whose outer
// path or marker was rewritten between the device and the yard
// fails its opening, and its call with it.
type firstBinding struct {
	path    string
	marker  string
	present bool
}

func binding(marker string, present bool) *firstBinding {
	return &firstBinding{path: OuterPath, marker: marker, present: present}
}

// associated builds the AEAD's associated data for one message:
// the tag, the direction, the call id, the sequence and the
// index, and, for a call's first record (first != nil), the
// outer path and the stream marker's presence and value, each
// length-named so no two writings agree by accident.
func associated(tag []byte, dir byte, call []byte, seq, index uint64, first *firstBinding) []byte {
	ad := make([]byte, 0, headerSize+64)
	ad = append(ad, tag...)
	ad = append(ad, dir)
	ad = append(ad, call...)
	ad = binary.BigEndian.AppendUint64(ad, seq)
	ad = binary.BigEndian.AppendUint64(ad, index)
	if first == nil {
		return append(ad, 0)
	}
	ad = append(ad, 1)
	ad = binary.BigEndian.AppendUint16(ad, uint16(len(first.path)))
	ad = append(ad, first.path...)
	if first.present {
		ad = append(ad, 1)
	} else {
		ad = append(ad, 0)
	}
	ad = binary.BigEndian.AppendUint16(ad, uint16(len(first.marker)))
	ad = append(ad, first.marker...)
	return ad
}

// Session is one device-to-yard channel after its handshake: the
// two transport keys, never mutated, and the sender's sequence
// allocator. Transport messages do not ride the handshake's
// counters: each message carries its number with it and is
// sealed with a fresh copy of its direction's key at that nonce
// (flynn/noise's UnsafeNewCipherState, as the yard seals), so any
// number of calls seal and open at once, none waiting on
// another. One is made by a handshake (StartChannel) alone.
type Session struct {
	tag     []byte
	sendKey [32]byte
	recvKey [32]byte
	sendDir byte
	recvDir byte
	next    atomic.Uint64

	replayMu  sync.Mutex
	highest   uint64
	hasOpened bool
	bits      []uint64 // replayWindow bits, by sequence modulo the window
	closed    map[string]uint64
}

// Tag is the session's tag, as its messages carry it.
func (s *Session) Tag() []byte { return append([]byte(nil), s.tag...) }

// nextSequence takes the session's next nonce once, or refuses
// after the reserved exhaustion value.
func (s *Session) nextSequence() (uint64, error) {
	for {
		seq := s.next.Load()
		if seq > noise.MaxNonce || seq == ^uint64(0) {
			return 0, noise.ErrMaxNonce
		}
		if s.next.CompareAndSwap(seq, seq+1) {
			return seq, nil
		}
	}
}

// seal seals one transport message of the call call at record
// index, bound to first when it is the call's first record in
// this direction (first != nil exactly at index 0).
func (s *Session) seal(call []byte, index uint64, first *firstBinding, plaintext []byte) ([]byte, error) {
	if len(call) != callSize {
		return nil, fmt.Errorf("a call id is %d bytes, not %d", callSize, len(call))
	}
	if len(plaintext) > maxRecordPlain {
		return nil, fmt.Errorf("a record holds at most %d bytes of plaintext, not %d", maxRecordPlain, len(plaintext))
	}
	if (index == 0) != (first != nil) {
		return nil, fmt.Errorf("record 0 alone carries the first binding")
	}
	seq, err := s.nextSequence()
	if err != nil {
		return nil, err
	}
	cs := noise.UnsafeNewCipherState(suite, s.sendKey, seq)
	ciphertext, err := cs.Encrypt(nil, associated(s.tag, s.sendDir, call, seq, index, first), plaintext)
	if err != nil {
		return nil, err
	}
	msg := make([]byte, 0, headerSize+len(ciphertext))
	msg = append(msg, s.tag...)
	msg = append(msg, call...)
	msg = binary.BigEndian.AppendUint64(msg, seq)
	msg = binary.BigEndian.AppendUint64(msg, index)
	return append(msg, ciphertext...), nil
}

// ErrReplay is a transport message refused by the replay rule:
// its sequence already opened in this direction, has fallen
// below the replay window, or names a call that has already
// closed. A refusal marks nothing, so the honest message that
// follows still opens.
var ErrReplay = errors.New("a transport message already opened, below the replay window, or of a closed call")

// ErrTruncated is a stream whose outer ending came with no
// final record: the part that arrived is no whole answer.
var ErrTruncated = errors.New("a sealed stream ended without its final record")

// ErrRecordGap is a record that stands at an index other than
// the next its call expects.
var ErrRecordGap = errors.New("a sealed record stands at an index its call does not expect")

// messageHeader reads a transport message's clear header: its
// call, sequence and record index.
func messageHeader(msg []byte) (call []byte, seq, index uint64, ok bool) {
	if len(msg) < headerSize {
		return nil, 0, 0, false
	}
	return msg[tagSize : headerSize-16],
		binary.BigEndian.Uint64(msg[headerSize-16 : headerSize-8]),
		binary.BigEndian.Uint64(msg[headerSize-8 : headerSize]), true
}

func (s *Session) bit(seq uint64) bool {
	i := seq % replayWindow
	return s.bits[i/64]&(1<<(i%64)) != 0
}

func (s *Session) setBit(seq uint64, on bool) {
	i := seq % replayWindow
	if on {
		s.bits[i/64] |= 1 << (i % 64)
	} else {
		s.bits[i/64] &^= 1 << (i % 64)
	}
}

func (s *Session) replayErrLocked(call []byte, seq uint64) error {
	if _, gone := s.closed[string(call)]; gone {
		return fmt.Errorf("%w: a record of a closed call", ErrReplay)
	}
	if !s.hasOpened || seq > s.highest {
		return nil
	}
	if s.highest-seq >= replayWindow {
		return fmt.Errorf("%w: sequence %d has fallen below the window at %d", ErrReplay, seq, s.highest)
	}
	if s.bit(seq) {
		return fmt.Errorf("%w: sequence %d already opened", ErrReplay, seq)
	}
	return nil
}

func (s *Session) markOpened(call []byte, seq uint64) error {
	s.replayMu.Lock()
	defer s.replayMu.Unlock()
	if err := s.replayErrLocked(call, seq); err != nil {
		return err
	}
	if s.bits == nil {
		s.bits = make([]uint64, replayWindow/64)
	}
	switch {
	case !s.hasOpened:
		s.hasOpened, s.highest = true, seq
	case seq > s.highest:
		if seq-s.highest >= replayWindow {
			clear(s.bits)
		} else {
			for n := s.highest + 1; n <= seq; n++ {
				s.setBit(n, false)
			}
		}
		s.highest = seq
	}
	s.setBit(seq, true)
	for id, last := range s.closed {
		if s.highest > last && s.highest-last > replayWindow {
			delete(s.closed, id)
		}
	}
	return nil
}

func (s *Session) closeCall(call []byte, seq uint64) {
	s.replayMu.Lock()
	defer s.replayMu.Unlock()
	if s.closed == nil {
		s.closed = map[string]uint64{}
	}
	s.closed[string(call)] = seq
}

// open opens one transport message that names the call want and
// answers its record index and plaintext. The clear header is
// checked against the session, the call and the first binding
// before a copied cipher state is spent on it; replay is judged
// on numbers that opened, never on numbers merely seen.
func (s *Session) open(msg, want []byte, first *firstBinding) (index uint64, plaintext []byte, err error) {
	if len(msg) < headerSize+16 {
		return 0, nil, fmt.Errorf("a transport message is %d bytes, too short to open", len(msg))
	}
	tag, call := msg[:tagSize], msg[tagSize:headerSize-16]
	if string(tag) != string(s.tag) {
		return 0, nil, fmt.Errorf("a transport message of no session this one knows")
	}
	if want != nil && string(call) != string(want) {
		return 0, nil, fmt.Errorf("a transport message of another call")
	}
	seq := binary.BigEndian.Uint64(msg[headerSize-16 : headerSize-8])
	index = binary.BigEndian.Uint64(msg[headerSize-8 : headerSize])
	if seq > noise.MaxNonce {
		return 0, nil, noise.ErrMaxNonce
	}
	if (index == 0) != (first != nil) {
		return 0, nil, fmt.Errorf("record 0 alone carries the first binding")
	}
	s.replayMu.Lock()
	replayErr := s.replayErrLocked(call, seq)
	s.replayMu.Unlock()
	if replayErr != nil {
		return 0, nil, replayErr
	}
	cs := noise.UnsafeNewCipherState(suite, s.recvKey, seq)
	plaintext, err = cs.Decrypt(nil, associated(tag, s.recvDir, call, seq, index, first), msg[headerSize:])
	if err != nil {
		return 0, nil, fmt.Errorf("a transport message that does not open: %w", err)
	}
	if err := s.markOpened(call, seq); err != nil {
		return 0, nil, err
	}
	return index, plaintext, nil
}

// frameRecord appends one transport message to a record run as
// it travels: a four-byte big-endian length, then the message.
func frameRecord(run, msg []byte) []byte {
	run = binary.BigEndian.AppendUint32(run, uint32(len(msg)))
	return append(run, msg...)
}

// splitRecords splits a record run into its transport messages.
// A zero-length record is the router's beat, no message, and is
// dropped here, before any opening.
func splitRecords(run []byte) ([][]byte, error) {
	var out [][]byte
	for len(run) > 0 {
		if len(run) < 4 {
			return nil, fmt.Errorf("a record run ends inside a length")
		}
		n := int(binary.BigEndian.Uint32(run))
		run = run[4:]
		if n > len(run) {
			return nil, fmt.Errorf("a record claims %d bytes of a run with %d left", n, len(run))
		}
		if n > 0 {
			out = append(out, run[:n])
		}
		run = run[n:]
	}
	return out, nil
}

// finalPlain is a final record's plaintext: the data count
// again, and the total length of the data records' plaintext.
func finalPlain(dataCount, total uint64) []byte {
	plain := binary.BigEndian.AppendUint64(nil, dataCount)
	return binary.BigEndian.AppendUint64(plain, total)
}

// isFinal says whether plain, opened at index with total data
// bytes before it, is the final record it closes.
func isFinal(plain []byte, index, total uint64) bool {
	return len(plain) == 16 &&
		binary.BigEndian.Uint64(plain) == index &&
		binary.BigEndian.Uint64(plain[8:]) == total
}

// CallSealer seals one call's records in order: a whole call's
// run at once (SealWhole), its index counting the call's records
// from zero and its final record closing the call.
type CallSealer struct {
	session *Session
	call    []byte
	first   *firstBinding
	index   uint64
	total   uint64
	done    bool
}

func (s *Session) newSealer(call []byte, first *firstBinding) *CallSealer {
	return &CallSealer{session: s, call: append([]byte(nil), call...), first: first}
}

func (c *CallSealer) sealChunk(chunk []byte) ([]byte, error) {
	if c.done {
		return nil, fmt.Errorf("a call sealed past its final record")
	}
	var run []byte
	for len(chunk) > 0 {
		n := min(len(chunk), maxRecordPlain)
		if isFinal(chunk[:n], c.index, c.total) {
			n = 8
		}
		if err := c.sealOne(&run, chunk[:n]); err != nil {
			return nil, err
		}
		chunk = chunk[n:]
	}
	return run, nil
}

func (c *CallSealer) sealOne(run *[]byte, plain []byte) error {
	var bind *firstBinding
	if c.index == 0 {
		bind = c.first
	}
	msg, err := c.session.seal(c.call, c.index, bind, plain)
	if err != nil {
		return err
	}
	*run = frameRecord(*run, msg)
	c.index++
	c.total += uint64(len(plain))
	return nil
}

func (c *CallSealer) sealFinal() ([]byte, error) {
	if c.done {
		return nil, fmt.Errorf("a call sealed past its final record")
	}
	var run []byte
	if c.index == 0 {
		if err := c.sealOne(&run, nil); err != nil {
			return nil, err
		}
	}
	msg, err := c.session.seal(c.call, c.index, nil, finalPlain(c.index, c.total))
	if err != nil {
		return nil, err
	}
	c.done = true
	return frameRecord(run, msg), nil
}

// SealWhole seals a whole call's joined plaintext as a record
// run bound to the outer path and to the stream marker the
// device sends (marker, with present saying the marker was sent
// at all): the plaintext chopped into records, the first bound,
// and the sealed final record closing the run. An empty
// plaintext still travels as one empty record.
func (s *Session) SealWhole(call []byte, marker string, present bool, plaintext []byte) ([]byte, error) {
	sealer := s.newSealer(call, binding(marker, present))
	run, err := sealer.sealChunk(plaintext)
	if err != nil {
		return nil, err
	}
	final, err := sealer.sealFinal()
	if err != nil {
		return nil, err
	}
	return append(run, final...), nil
}

// Sealer seals one call's records as its plaintext is handed
// over, for a caller that streams: Seal answers each chunk's
// framed records, SealFinal the closing one.
type Sealer struct{ c *CallSealer }

// NewSealer starts sealing a call's records under session, bound
// as SealWhole binds its first record.
func (s *Session) NewSealer(call []byte, marker string, present bool) *Sealer {
	return &Sealer{c: s.newSealer(call, binding(marker, present))}
}

// Seal seals chunk as the call's next data records, framed.
func (s *Sealer) Seal(chunk []byte) ([]byte, error) { return s.c.sealChunk(chunk) }

// SealFinal seals the call's final record, framed.
func (s *Sealer) SealFinal() ([]byte, error) { return s.c.sealFinal() }

// Opened is one opened record: its plaintext, and whether it
// was the call's final record (which carries none of the call's
// own plaintext).
type Opened struct {
	Plain []byte
	Final bool
}

// Opener opens one call's records in one direction as they
// arrive, each at the index the last left off. Records before a
// gap stand delivered; the record at a gap opens as nothing.
type Opener struct {
	session *Session
	call    []byte
	first   *firstBinding
	index   uint64
	total   uint64
	done    bool
}

// NewOpener starts opening a call's records under session: the
// first record must be bound to the outer path and the stream
// marker as the yard sent them (for an answer, what the frame
// carried, which is what the device sent unless rewritten).
func (s *Session) NewOpener(call []byte, marker string, present bool) *Opener {
	return &Opener{session: s, call: append([]byte(nil), call...), first: binding(marker, present)}
}

// Open opens one transport message of the call (without its
// record length: the caller reads records off the wire). A
// record at any index but the next expected is refused at the
// gap and marks nothing.
func (o *Opener) Open(msg []byte) (*Opened, error) {
	if o.done {
		return nil, fmt.Errorf("a record stands after a call's final record")
	}
	if _, _, index, ok := messageHeader(msg); ok && index != o.index {
		return nil, fmt.Errorf("%w: record %d where %d was due", ErrRecordGap, index, o.index)
	}
	var bind *firstBinding
	if o.index == 0 {
		bind = o.first
	}
	index, plain, err := o.session.open(msg, o.call, bind)
	if err != nil {
		return nil, err
	}
	if index != o.index {
		return nil, fmt.Errorf("%w: record %d where %d was due", ErrRecordGap, index, o.index)
	}
	if isFinal(plain, index, o.total) {
		o.done = true
		if _, seq, _, ok := messageHeader(msg); ok {
			o.session.closeCall(o.call, seq)
		}
		return &Opened{Final: true}, nil
	}
	o.index++
	o.total += uint64(len(plain))
	return &Opened{Plain: plain}, nil
}

// Done says whether the call's final record has opened.
func (o *Opener) Done() bool { return o.done }

// Close ends the call at its outer ending: nil once the final
// record opened, ErrTruncated while it has not.
func (o *Opener) Close() error {
	if !o.done {
		return ErrTruncated
	}
	return nil
}

// OpenWhole opens a whole answer's record run and joins its
// records in the order they stand, bound as NewOpener binds:
// the run must close with its final record, and nothing of a
// truncated run is answered.
func (s *Session) OpenWhole(run, call []byte, marker string, present bool) ([]byte, error) {
	msgs, err := splitRecords(run)
	if err != nil {
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, fmt.Errorf("an enveloped call with no first record")
	}
	opener := s.NewOpener(call, marker, present)
	var plain []byte
	for i, msg := range msgs {
		opened, err := opener.Open(msg)
		if err != nil {
			return nil, err
		}
		if opened.Final && i != len(msgs)-1 {
			return nil, fmt.Errorf("a record stands after a call's final record")
		}
		plain = append(plain, opened.Plain...)
	}
	if err := opener.Close(); err != nil {
		return nil, err
	}
	return plain, nil
}

// The yard's halves of the two handshakes, carried as the
// desktop's module carries them: the stand-in yard of the app's
// tests, and nothing the app calls. Each is flynn/noise opened
// with the yard's key, as the yard opens it.

// PairingHandshake is a device pairing's first message as the
// yard opened it: the code it carried and the device key it
// proved, as PublicString writes it.
type PairingHandshake struct {
	Code      string
	DeviceKey string
	hs        *noise.HandshakeState
}

// OpenPairing opens the first message of a pairing handshake to
// the yard's channel key. A message that does not open is
// refused here, before any code is read.
func OpenPairing(yardPrivate, first []byte) (*PairingHandshake, error) {
	yardPrivate = append([]byte(nil), yardPrivate...)
	public, err := PublicOf(yardPrivate)
	if err != nil {
		return nil, err
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        randReader,
		Pattern:       noise.HandshakeIK,
		Initiator:     false,
		StaticKeypair: noise.DHKey{Private: yardPrivate, Public: public},
	})
	if err != nil {
		return nil, err
	}
	payload, _, _, err := hs.ReadMessage(nil, first)
	if err != nil {
		return nil, fmt.Errorf("a pairing handshake that does not open: %w", err)
	}
	device := hs.PeerStatic()
	if len(device) != 32 {
		return nil, fmt.Errorf("a pairing handshake with no device key")
	}
	return &PairingHandshake{hs: hs, Code: string(payload), DeviceKey: PublicString(device)}, nil
}

// SealAnswer seals payload as the handshake's second message:
// the one answer that holds the device's token.
func (h *PairingHandshake) SealAnswer(payload []byte) ([]byte, error) {
	reply, _, _, err := h.hs.WriteMessage(nil, payload)
	return reply, err
}

// ChannelHandshake is a channel handshake's first message as
// the yard opened it: the device key it proved, as PublicString
// writes it, and the state its answer is sealed with.
type ChannelHandshake struct {
	DeviceKey string
	hs        *noise.HandshakeState
	session   *Session
}

// OpenChannel opens the first message of a channel handshake to
// the yard's channel key, before any device is looked for.
func OpenChannel(yardPrivate, first []byte) (*ChannelHandshake, error) {
	yardPrivate = append([]byte(nil), yardPrivate...)
	public, err := PublicOf(yardPrivate)
	if err != nil {
		return nil, err
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:   suite,
		Random:        randReader,
		Pattern:       noise.HandshakeIK,
		Initiator:     false,
		StaticKeypair: noise.DHKey{Private: yardPrivate, Public: public},
	})
	if err != nil {
		return nil, err
	}
	if _, _, _, err := hs.ReadMessage(nil, first); err != nil {
		return nil, fmt.Errorf("a channel handshake that does not open: %w", err)
	}
	device := hs.PeerStatic()
	if len(device) != 32 {
		return nil, fmt.Errorf("a channel handshake with no device key")
	}
	return &ChannelHandshake{hs: hs, DeviceKey: PublicString(device)}, nil
}

// SealAnswer seals the session tag as the handshake's second
// message and founds the yard's session it answers with
// (Session): the yard opens under the handshake's first
// transport key and sends under its second.
func (h *ChannelHandshake) SealAnswer(tag []byte) ([]byte, error) {
	if len(tag) != tagSize {
		return nil, fmt.Errorf("a session tag is %d bytes, not %d", tagSize, len(tag))
	}
	reply, send, recv, err := h.hs.WriteMessage(nil, tag)
	if err != nil {
		return nil, err
	}
	h.session = &Session{
		tag:     append([]byte(nil), tag...),
		sendKey: recv.UnsafeKey(), recvKey: send.UnsafeKey(),
		sendDir: dirAnswer, recvDir: dirRequest,
	}
	return reply, nil
}

// Session answers the session SealAnswer founded, nil before it.
func (h *ChannelHandshake) Session() *Session { return h.session }
