# The channel binding

The phone's half of the channel between a paired device and its
yard (yardr design `2026-11-05-yardr-device-e2e.md`, sections 3.1
and 3.2, in the yardr repository), bound from Go for iOS. Every
Noise construction is `github.com/flynn/noise` **v1.1.0**, pinned
in `go.mod`: this binding marshals bytes, holds keys and carries
the design's explicit-nonce and replay framing (transcribed from
the yard's `internal/yardkey`, as footplate's `e2e.rs` carries it
over `snow`), and constructs no Noise of its own.

Two rules the code holds:

- Nothing here is called audited. flynn/noise at the pinned
  version and this binding are **not yet independently reviewed**
  for conformance, and the app shows no sealed claim on their
  word: a yard with a channel stands "not yet sealed" until that
  review passes.
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
current `gomobile` asks. A change to the pinned flynn/noise
version is a design change, not a tidy: it reopens the review
question above, and the transcript tests here and the app's
channel tests must both still pass.
