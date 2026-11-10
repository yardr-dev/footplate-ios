import Foundation
import NoiseChannel

// The channel between a paired device and its yard (yardr design
// 2026-11-05-yardr-device-e2e.md, sections 3.1 and 3.2), as the
// bound library speaks it: `flynn/noise` v1.1.0 bound from Go by
// gomobile (ChannelBinding/, NoiseChannel.xcframework), holding
// no Noise construction of its own, and beside it the PAKE a typed
// code is redeemed through, `spake2-go` v0.0.1, the yard's own
// library, bound the same way and holding no PAKE of its own.
// This file marshals bytes across that boundary and names its
// failures; what a failure is said as to a person is the
// client's. The bound versions and the binding are not yet
// independently reviewed (spake2-go states it has had no formal
// audit), and nothing here calls them audited: the app shows no
// sealed claim on their word, and a yard with a channel is shown
// not yet sealed.

/// Why a channel step did not go: the binding's sentence, kept
/// for the log of the call that failed. No key stands in it.
struct ChannelFailure: Error, Equatable, Sendable, CustomStringConvertible {
    var description: String

    /// Whether this is a PAKE run's one failure that proves a guess
    /// was made: the other side's confirmation did not hold. The
    /// binding's errors carry their text alone, so it is read by the
    /// sentence the binding starts it with.
    var unconfirmed: Bool {
        description.hasPrefix(ChannelPAKEUnconfirmed)
    }
}

/// Runs a step of the bound library, naming its failure as the
/// channel's own where it throws.
private func bound<T>(_ step: () throws -> T) throws -> T {
    do {
        return try step()
    } catch {
        throw ChannelFailure(description: (error as NSError).localizedDescription)
    }
}

/// One yard's channel key pair as the records keep it: the
/// device's private half (32 bytes, the Keychain's alone) and the
/// yard channel public key it pins (32 bytes, as a pairing QR's
/// fourth field carries it).
struct ChannelKeys: Equatable, Sendable {
    var devicePrivate: Data
    var yardPublic: Data

    /// The device's public half, as it travels.
    var devicePublic: Data {
        (try? channelPublicOf(devicePrivate)) ?? Data()
    }
}

/// Makes a fresh device channel key pair for one yard, by the
/// bound library as the yard makes its own, answering its two
/// halves apart: the private half for the Keychain, the public
/// half for the yard's record at a pairing.
func makeDeviceKey() throws -> (devicePrivate: Data, devicePublic: Data) {
    var error: NSError?
    guard let pair = ChannelGenerateKey(&error), let secret = pair.private, let published = pair.public else {
        throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
    }
    return (secret, published)
}

/// The public half of a channel private key.
func channelPublicOf(_ devicePrivate: Data) throws -> Data {
    var error: NSError?
    guard let publicKey = ChannelPublicOf(devicePrivate, &error) else {
        throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
    }
    return publicKey
}

/// A channel public key as it travels: base64url, no padding, as
/// the yard writes it in a QR's fourth field.
func channelPublicString(_ publicKey: Data) -> String {
    ChannelPublicString(publicKey)
}

/// Reads a channel public key as `channelPublicString` writes
/// it; what is no such key throws, before anything is sent under
/// it.
func parseChannelPublic(_ text: String) throws -> Data {
    var error: NSError?
    guard let publicKey = ChannelParsePublic(text, &error) else {
        throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
    }
    return publicKey
}

/// Mints a call id: sixteen random bytes, once for each call a
/// device opens, never reused inside a session.
func newCallID() throws -> Data {
    var error: NSError?
    guard let id = ChannelNewCallID(&error) else {
        throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
    }
    return id
}

/// A pairing handshake a device has begun: its first message,
/// carrying the code as its payload and sealing the device's
/// static key inside it.
final class PairingOpening: @unchecked Sendable {
    private let opening: ChannelPairingOpening
    /// The handshake's first message, for the pair call's body.
    let first: Data

    init(devicePrivate: Data, yardPublic: Data, code: String) throws {
        var error: NSError?
        guard let opening = ChannelStartPairing(devicePrivate, yardPublic, code, &error),
              let first = opening.first
        else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.opening = opening
        self.first = first
    }

    /// Opens the yard's sealed answer: the pairing's answer,
    /// readable by this device alone.
    func openAnswer(_ reply: Data) throws -> Data {
        try opening.openAnswer(reply)
    }
}

/// A typed-code pairing a device has begun, to be redeemed through a
/// PAKE (design 3.1 candidate 1A, bead 18): SPAKE2 on the code, run by
/// the bound spake2-go v0.0.1 as the yard runs it, with none of the
/// PAKE written here. The device and the yard exchange their channel
/// keys under the key the run derives, so whoever carries the run
/// gets one online guess at the code and no way to test a recorded
/// one. The library states it has had no formal audit, and nothing
/// here calls it audited. Its steps come in the order the run has
/// them, and the device's key is sealed only after the yard's
/// confirmation holds: the library gives no key before it.
final class PairingPAKEOpening: @unchecked Sendable {
    private let opening: ChannelPairingPAKEOpening
    /// The run's first message, the blinded point of the suite (65
    /// bytes uncompressed), for the start step's body.
    let first: Data

    init(devicePrivate: Data, code: String) throws {
        var error: NSError?
        guard let opening = ChannelStartPairingPAKE(devicePrivate, code, &error),
              let first = opening.first
        else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.opening = opening
        self.first = first
    }

    /// Takes the yard's second message and makes the device's
    /// confirmation of the run (32 bytes).
    func finish(_ second: Data) throws -> Data {
        try bound { try opening.finish(second) }
    }

    /// Holds the yard's confirmation to the code. Only a run that
    /// passes has a yard at its other end that holds the code, and
    /// a failure of it is `ChannelFailure.unconfirmed`.
    func verify(_ yardConfirmation: Data) throws {
        try bound { try opening.verify(yardConfirmation) }
    }

    /// The device's channel public key sealed under the run's key,
    /// for the yard to record beside the token it issues.
    func sealKey() throws -> Data {
        try bound { try opening.sealKey() }
    }

    /// Opens the yard's sealed answer to this run: the pairing's
    /// answer with the yard's channel public key beside it,
    /// readable by this device alone.
    func openAnswer(_ sealed: Data) throws -> Data {
        try bound { try opening.openAnswer(sealed) }
    }
}

/// One live channel session with a yard, after its handshake:
/// its transport messages seal and open under the session's
/// keys, each with its number carried with it. The binding's
/// session is safe to call at once, as the yard serves at once.
final class SealedSession: @unchecked Sendable {
    private let session: ChannelSession

    init(_ handle: ChannelSession) {
        session = handle
    }

    /// The session's tag, as its messages carry it.
    var tag: Data { session.tag() ?? Data() }

    /// Seals a whole call's joined plaintext as a record run:
    /// `marker` the outer stream marker the device sends, with
    /// `present` saying the marker was sent at all.
    func sealWhole(call: Data, marker: String, present: Bool, plaintext: Data) throws -> Data {
        try session.sealWhole(call, marker: marker, present: present, plaintext: plaintext)
    }

    /// Opens a whole answer's record run and joins its records:
    /// the run must close with its final record, and nothing of
    /// a truncated run is answered.
    func openWhole(run: Data, call: Data, marker: String, present: Bool) throws -> Data {
        try session.openWhole(run, call: call, marker: marker, present: present)
    }

    /// Starts opening one call's records as they arrive, bound
    /// as `openWhole` binds its first.
    func opener(call: Data, marker: String, present: Bool) -> SealedOpener {
        SealedOpener(session.newOpener(call, marker: marker, present: present)!)
    }

    /// Starts sealing one call's records as they are handed
    /// over, for a yard that streams: bound as `sealWhole` binds
    /// its first.
    func sealer(call: Data, marker: String, present: Bool) -> SealedSealer {
        SealedSealer(session.newSealer(call, marker: marker, present: present)!)
    }
}

/// Opens one call's records in order as they arrive: each record
/// at the index the last left off, a beat (a zero-length record)
/// read past by the caller before any opening, as the router's
/// framing asks.
final class SealedOpener: @unchecked Sendable {
    private let opener: ChannelOpener

    init(_ handle: ChannelOpener) {
        opener = handle
    }

    /// Opens one transport message (without its record length):
    /// its plaintext, or the call's end where it was the final
    /// record, which carries none of the call's own.
    func open(_ message: Data) throws -> (plain: Data, final: Bool) {
        let opened = try opener.open(message)
        return (opened.plain ?? Data(), opened.final)
    }

    /// Whether the call's final record has opened.
    var done: Bool { opener.done() }

    /// Ends the call at its outer ending: throws where the final
    /// record has not opened, so a part is never read as a whole.
    func close() throws {
        try opener.close()
    }
}

/// Seals one call's records as its plaintext is handed over, for
/// a yard that streams its answer: each chunk's framed records,
/// then the closing one.
final class SealedSealer: @unchecked Sendable {
    private let sealer: ChannelSealer

    init(_ handle: ChannelSealer) {
        sealer = handle
    }

    func seal(_ chunk: Data) throws -> Data {
        try sealer.seal(chunk)
    }

    func sealFinal() throws -> Data {
        try sealer.sealFinal()
    }
}

/// A channel handshake a device has begun: its first message,
/// naming no call, which is how the yard tells it from an
/// enveloped call.
final class ChannelOpening: @unchecked Sendable {
    private let opening: ChannelChannelOpening
    /// The handshake's first message, for the outer call's body.
    let first: Data

    init(devicePrivate: Data, yardPublic: Data) throws {
        var error: NSError?
        guard let opening = ChannelStartChannel(devicePrivate, yardPublic, &error),
              let first = opening.first
        else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.opening = opening
        self.first = first
    }

    /// Opens the yard's handshake answer and answers the session
    /// it founds.
    func openAnswer(_ reply: Data) throws -> SealedSession {
        SealedSession(try opening.openAnswer(reply))
    }
}

// The yard's halves of the two handshakes, carried as the
// desktop's module carries them: the stand-in yard of the tests
// (the fake yard), and nothing the app calls on its own behalf.

/// A pairing handshake as the yard opened it: the code it
/// carried and the device key it proved, as
/// `channelPublicString` writes it.
final class YardPairingHandshake: @unchecked Sendable {
    private let handshake: ChannelPairingHandshake

    init(yardPrivate: Data, first: Data) throws {
        var error: NSError?
        guard let handshake = ChannelOpenPairing(yardPrivate, first, &error) else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.handshake = handshake
    }

    var code: String { handshake.code }
    var deviceKey: String { handshake.deviceKey }

    /// Seals the pairing's answer as the handshake's second
    /// message: the one answer that holds the device's token.
    func sealAnswer(_ payload: Data) throws -> Data {
        try handshake.sealAnswer(payload)
    }
}

/// A typed-code pairing's run as the yard answered it: its second
/// message, and the device's confirmation still to hold to the code.
final class YardPAKEHandshake: @unchecked Sendable {
    private let responder: ChannelPairingPAKEResponder
    /// The yard's second message, for the start step's answer.
    let second: Data

    init(code: String, first: Data) throws {
        var error: NSError?
        guard let responder = ChannelAnswerPairingPAKE(code, first, &error),
              let second = responder.second
        else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.responder = responder
        self.second = second
    }

    /// Holds the device's confirmation to the code and answers the
    /// yard's; one that does not hold is `ChannelFailure.unconfirmed`,
    /// one online guess at the code, spent.
    func confirm(_ device: Data) throws -> Data {
        try bound { try responder.confirm(device) }
    }

    /// The device's channel public key, as `channelPublicString`
    /// writes it, opened in a confirmed run alone.
    func openKey(_ sealed: Data) throws -> String {
        // The binding answers a string, which gomobile imports with
        // an error pointer in place of `throws`.
        var error: NSError?
        let key = responder.openKey(sealed, error: &error)
        if let error {
            throw ChannelFailure(description: error.localizedDescription)
        }
        return key
    }

    /// Seals the pairing's answer, in a confirmed run alone.
    func sealAnswer(_ payload: Data) throws -> Data {
        try bound { try responder.sealAnswer(payload) }
    }
}

/// A channel handshake as the yard opened it: the device key it
/// proved, as `channelPublicString` writes it.
final class YardChannelHandshake: @unchecked Sendable {
    private let handshake: ChannelChannelHandshake

    init(yardPrivate: Data, first: Data) throws {
        var error: NSError?
        guard let handshake = ChannelOpenChannel(yardPrivate, first, &error) else {
            throw ChannelFailure(description: error?.localizedDescription ?? "the channel refused")
        }
        self.handshake = handshake
    }

    var deviceKey: String { handshake.deviceKey }

    /// Seals the session tag as the handshake's second message
    /// and founds the yard's session, answered by `session`.
    func sealAnswer(tag: Data) throws -> Data {
        try handshake.sealAnswer(tag)
    }

    /// The yard's session `sealAnswer` founded.
    var session: SealedSession? {
        handshake.session().map(SealedSession.init)
    }
}
