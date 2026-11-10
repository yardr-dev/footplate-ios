# The channel binding

The phone's half of the channel between a paired device and its
yard (yardr design `2026-11-05-yardr-device-e2e.md`, sections 3.1
and 3.2, in the yardr repository), bound from Go for iOS. Every
Noise construction is `github.com/flynn/noise` **v1.1.0**, pinned
in `go.mod`: this binding marshals bytes, holds keys and carries
the design's explicit-nonce and replay framing (transcribed from
the yard's `internal/yardkey`, as footplate's `e2e.rs` carries it
over `snow`), and constructs no Noise of its own.

The PAKE a typed code is redeemed through (design section 3.1,
candidate 1A, and bead 18; `pake.go`) is `github.com/backkem/spake2-go`
**v0.0.1**, pinned in `go.mod` to the version the yard runs
(`yardkey/pake.go`, which `pake.go` is transcribed from): SPAKE2 as RFC
9382 specifies it, suite SPAKE2-P256-SHA256-HKDF-HMAC, the identities
`A` and `B`, no AAD. No Swift library implements it (CryptoKit and
swift-crypto carry no PAKE, and neither adds two P-256 points), and a
PAKE of our own is not an option in any bead, so the phone binds the
yard's own library as it binds the yard's Noise: the binding builds
none of it. What it adds is the yard's pinned choices around the run:
the cleaned code as the password, the 65-byte point check before the
library sees a message, and the run's key spent through HKDF-SHA256 to a
ChaCha20-Poly1305 key that seals the device's channel key and the yard's
answer. The yard's half stands beside the device's, for the stand-in
yard of the app's tests and nothing the app calls.

Two rules the code holds:

- Nothing here is called audited. flynn/noise at the pinned
  version and this binding are **not yet independently reviewed**
  for conformance, spake2-go states it has had no formal audit, and
  the app shows no sealed claim on their word: a yard with a channel
  stands "not yet sealed" until that review passes.
- Bytes that cross the bound boundary are the caller's and are
  freed when the call returns, so every key a handshake or a
  session holds is the binding's own copy, made at its boundary.
  (A yard of tests once opened while the device it answered
  could not: the device's static key was the freed buffer.)

## Proofs

`vectors_test.go` holds the proofs the design asks for before
channel work, none of them both ends through this binding: the
Noise specification's `Noise_IK_25519_ChaChaPoly_SHA256` vector
(revision 34, as flynn/noise carries it in `vectors.txt`) against
the binding's suite and against its own first messages; a record
sealed by the yard's `internal/yardkey` (yardr `b52d9f71`) and
one sealed by the desktop's `snow` (`src/e2e.rs`, footplate
`96cef03`), each opened here and sealed byte for byte; and a
deterministic handshake transcript from each of those two ends,
recreated and opened here. Each golden names its maker and its
fixed keys in its comment. To remake one, add a temporary
printing test at that end over the same keys (the yard's with
flynn/noise and its `SealWhole`, the desktop's with snow's
testing-only fixed ephemeral), run it, paste its hex, and remove
the test there. The app's `ChannelTests` holds the same
specification first messages through the built XCFramework.

The PAKE is held the same way, against what it did not make.
`vectors_test.go` replays a run recorded against the yard's own
library (spake2-go v0.0.1 with yardkey's seal and open as they
stand, recorded by the desktop's bead, footplate `1274fc9`): the
code `K7QM-2XPD`, the device's scalar fixed to the 64 bytes `0x00`
to `0x3f` reduced mod the group order, the yard's random. The
device's half, with that scalar stood in for its random one,
makes the recorded first message and confirmation, accepts the
recorded yard confirmation, derives the recorded key and opens the
recorded sealed answer. `pake_test.go` holds the yard's own
`pake_test.go` cases (the keys cross sealed, a wrong code fails at
the confirmation, a turned message fails at the next check, no
message that is no point reaches the library, a recorded run gives
no offline test of the code), and the app's `ChannelTests` holds
the same loop through the built XCFramework and a run through a
relay that rewrites each step. The yard's half here is this
binding's own, so its agreement with the yard's is held by a live
run, which no gate repeats: a temporary test in a yardr checkout,
importing this module by a `replace` directive, runs the binding as
the device of the yard's own `pairPAKE` handler (internal/rpc, the
`pairYard` harness: three posts of `/user/pair`, the device
recorded with its key pinned) and as the yard's `AnswerPairingPAKE`
answering the yard's own device, then is removed there. The bead's
note records that run.
These are proofs of agreement, not of review: the rule above
stands.

## Rebuilding the bound library

The app links the built `Footplate/API/NoiseChannel.xcframework`,
which is committed. To rebuild it after a change here:

```sh
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init   # once, on a fresh machine
cd ChannelBinding
go test ./...   # held against the yard's half, transcribed
gomobile bind -target ios,iossimulator -o /tmp/NoiseChannel.xcframework .
cp -R /tmp/NoiseChannel.xcframework/. ../Footplate/API/NoiseChannel.xcframework/
```

The `tool` directive in `go.mod` keeps `gobind` in the module, as
current `gomobile` asks. A change to the pinned flynn/noise or
spake2-go version is a design change, not a tidy: it reopens the
review question above, and the transcript tests here and the app's
channel tests must both still pass.
