# footplate-ios

footplate for iOS (Swift, SwiftUI). Product behaviour: `README.md`. Design
notes: `docs/design/`. The yard's side of the protocol (`docs/api.md`, the
`/user/*` calls and the `/user/events` stream) and the edge that relays it
(`docs/design/2026-10-20-yardr-hosted-050n-one-edge.md`) live in the yardr
repository, not here. footplate-android is the reference for behaviour.
`.yardr/depot.md` holds the yard's rules for builders.

## Layout

`Footplate.xcodeproj` is hand-kept, with filesystem-synchronised source
folders and no external dependencies. `Config/Debug.xcconfig`,
`Config/Release.xcconfig` and `Config/Edge.xcconfig` hold build settings.

Targets: `Footplate` (SwiftUI app, iOS 18+, iPhone and iPad),
`FootplateTests` (unit tests, run by `.yardr/test` on the named iPhone
simulator), `FootplateUITests` (UI/instrumentation, run by hand,
never by the gate), and `NotifyService` (the notification service
extension that fills a closed phone's wakes in, over the shared
core in `Push/` and its neighbours listed in the project). `FootplateTests/Tokens/` vendors the design tokens
for the theme test. The iPad layout is a readable single column; its
simulator run is by hand.

Under `Footplate/`:

- `App/`: app entry point and shared scene composition.
- `API/`: the edge (Kratos sign-in, logout and session identity lookup,
  pairing), one paired yard's client and events stream, the wire types and
  the refusal reading, over a transport seam that `URLSession` implements;
  `FootplateTests/FakeYard/` implements the same seam in the tests, and
  `Demo/` serves a made-up yard on it. `Channel.swift` and the bound
  `NoiseChannel.xcframework` beside it are the device's channel to a
  yard that pinned its key: `ChannelBinding/` at the root holds the
  Go binding over `flynn/noise` v1.1.0 (see its README; neither is
  independently reviewed yet).
- `Session/`: one follower per paired yard, with `load`, the stream after
  the head, the retries, the clock and the network watch, and the
  `Followed` seam the screen models read a followed yard through;
  `FootplateTests/Session/` follows the fake yard.
- `Model/`: screen models and navigation (`Nav`, `PairModel`,
  `SignInModel`, `InboxModel`, `ConversationModel`, `DecisionsModel`,
  `DecisionModel`, `LineModel`), the inbox board (`Board`) and the
  boards' keeping (`Mailroom`). `LineModel` holds the Lines place: the
  overview, a line's route map and a bead's card with the bead's
  details (the pictures of its notes among them, for the Media grid) and its web view link. The conversation's pictures (`Images` shrinks one for a letter,
  `Pictures` keeps the ones shown, by hash; `NotePictures` asks for the ones a
  bead's notes carry, for the bead card and a decision's details) and `Links` (the web
  addresses in a card's words) stand beside them, and so does `Markdown`,
  which reads a letter's words into the blocks they are drawn as, as the
  desktop's `markdown.rs` does and over Unicode scalars as it does.
- `UI/`: SwiftUI screens (Pair, Sign in, Crew, Decide, Decision,
  Conversation, and the Lines place's Lines, Route map, Bead card and
  Media, the grid of a bead's note pictures with its full-size pager),
  the tabs (`YardTabs`, and `DemoTabs` with the demo's banner) and the
  chrome the places share (`YardPlace`, `YardSwitchView`), the shared
  controls (`NoteFiles` among them: a note's pictures and files under its
  words), `MessageText` (a letter's words drawn by their `Markdown`
  blocks, a code block with its Copy), the scanner, theme and resources
  (catalogue, Plex fonts and licence).
- `Unlock/`: which picks pass the gate and its reasons as plain
  functions, and the `LAContext` prompt behind its protocol.
- `Notify/`: what is told of as plain functions with the 3-second
  burst, the local notifications threaded per yard and row through
  `UNUserNotificationCenter`, and the tap opening the app on that
  yard and there; `FootplateTests/Notify/` drives the rules and
  the bursts.
- `Push/`: waking a closed phone — the content-free wake and its
  link, the per-yard checkpoints and wake landings the app group
  shares with the extension, the wake engine that fills a wake in
  through `Notify`'s rules, and the registrar that keeps the
  relay's rows through the edge; `FootplateTests/Push/` drives
  them against the fake yard.
- `Yard/`: the account and per-yard records in the Keychain, the QR
  read, and the pairer (sign-in, pairing, forgetting).
- `Demo/`: the demo yard behind Try a demo on the Pair screen, for a
  person with no yard (and for App Review): `DemoYard` is a made-up
  yard's state and writes, `DemoTransport` the `HTTPTransport` that
  serves it in memory (no `URLSession`, no request leaves the phone),
  and `Demo` the app's models over it, on records in memory, with no
  registrar, so leaving it leaves no token, saved yard or push
  registration; `FootplateTests/Demo/` drives them.

`NotifyService/` holds the extension itself: a thin
`UNNotificationServiceExtension` over the shared core, with its own
`Info.plist` and entitlements beside it.

`ChannelBinding/` holds the Go module the channel is bound from
(`flynn/noise` v1.1.0 under the design's framing), its tests held
against the yard's half, and the README that says how the
committed `Footplate/API/NoiseChannel.xcframework` is rebuilt.

`.yardr/` holds the
flow, roles and simulator gate; `docs/design/` holds design decisions.
A change moving or adding a target, module, package or folder updates this
section in the same commit.

## TestFlight

`scripts/testflight` archives the Release configuration and uploads the
build to App Store Connect, for mckean's iPhone and iPad. A per-build run
is the yardmaster's or mckean's, never a builder's: on a clean checkout of
`main`, with the API key's IDs in the environment,
`ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/testflight`. The
build number is `main`'s commit count, set by the script and never
committed. `scripts/testflight --no-upload` archives and exports locally
without uploading. The `.p8` stays in
`~/.appstoreconnect/private_keys/` and is never copied, committed,
printed or noted.
