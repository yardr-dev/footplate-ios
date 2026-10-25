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
simulator), and `FootplateUITests` (UI/instrumentation, run by hand,
never by the gate). `FootplateTests/Tokens/` vendors the design tokens
for the theme test. The iPad layout is a readable single column; its
simulator run is by hand.

Under `Footplate/`:

- `App/`: app entry point and shared scene composition.
- `API/`: reserved for the edge, yard client and wire types.
- `Session/`: reserved for each paired yard's follower and retries.
- `Model/`: reserved for screen models, navigation and state rules.
- `UI/`: SwiftUI screens, theme and resources (catalogue, Plex fonts and licence).
- `Unlock/`: reserved for approval gates and the system unlock prompt.
- `Notify/`: reserved for notification rules, delivery and taps.
- `Yard/`: reserved for records, Keychain, QR reading and pairing.

The reserved folders contain no implementation yet. `.yardr/` holds the
flow, roles and simulator gate; `docs/design/` holds design decisions.
A change moving or adding a target, module, package or folder updates this
section in the same commit.
