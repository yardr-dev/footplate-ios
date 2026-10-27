# footplate-ios

footplate for an iPhone: an iOS app onto a yardr yard. It pairs with a yard
by a code, puts the yard's decisions in front of you to answer where you
are, and carries the conversation with the crew, as the desktop
[footplate](https://github.com/yardr-dev/footplate) does on macOS and Linux
and [footplate-android](https://github.com/yardr-dev/footplate-android) does
on Android. The footplate is the cab floor a locomotive driver stands on:
the place a person drives their yard from without a terminal.

It speaks to the yard through the edge at `https://my.yardr.dev`, which
relays `/user/*` calls and the `/user/events` stream to the yard a device is
paired with. The protocol is yardr's `/user/*` API; the yard runs as it
does. No code is shared with the other footplates: this one is Swift drawn
with SwiftUI on the same protocol.

One secret crosses the edge: the one-time code a harness's sign-in page
gives. Its decision card links the page and takes the code behind the
unlock; API keys and every other secret are answered on the yard's machine.

Tracked in the yard as the `footplate-ios` depot. `.yardr/` holds its flow,
roles and merge gate. Every change is reviewed twice before it lands:
against its bead, then for security alone.

## Build and test

Open `Footplate.xcodeproj` in Xcode 26.3 and run the shared `Footplate`
scheme. The app supports iOS 18 and later on iPhone and iPad. It pairs
with a yard by a scanned or typed code and signs in at the edge; after
pairing it opens an empty crew place.
The crew, decide and lines places are built.
The project uses platform frameworks only and needs no generator or package
installation. For a physical device, select your signing team in Xcode.

Run the depot gate from the worktree:

```sh
sh .yardr/test
```

It builds the app and runs `FootplateTests` on iPhone 17 Pro simulator
`7EC91353-EDF5-4E93-B644-46A44BA6CFCB`. A missing simulator fails the gate.
The theme test compares the catalogue's dark and light appearances and the
phone type roles with vendored yardr-design tokens, and checks the bundled
fonts are registered. `FootplateUITests` runs separately by hand, against the
stand-in edge below.

## The by-hand UI tests

`scripts/fake-edge` stands in for the edge on loopback: Kratos's sign-in
and logout, one account's pairing, `/user/me`, every `/user/call/<Method>`
answered from `FootplateTests/FakeYard/Canned.swift`'s board, the
`/user/events` stream with a heartbeat every 25 seconds, and a page per
bead. It checks no credentials and serves `127.0.0.1` alone. It prints
its URL, for the build's `EDGE_URL`, and every request to standard
error:

Run `python3 scripts/test-fake-edge.py` to check that values in its JSON
responses and bead pages stay data.

```sh
edge_dir=$(mktemp -d)
scripts/fake-edge >"$edge_dir/url" 2>"$edge_dir/edge.log" &
edge_pid=$!
cleanup_edge() {
  kill "$edge_pid" 2>/dev/null || true
  wait "$edge_pid" 2>/dev/null || true
  rm -rf "$edge_dir"
}
trap cleanup_edge EXIT
```

`FootplateUITests/AAPairForHand` pairs the simulator with the stand-in
before the class under test runs (XCTest runs classes alphabetically,
so it goes first) and leaves the app on the Crew tab. A run goes:

```sh
xcodebuild test -project Footplate.xcodeproj -scheme Footplate \
  -destination 'platform=iOS Simulator,id=7EC91353-EDF5-4E93-B644-46A44BA6CFCB' \
  EDGE_URL="$(cat "$edge_dir/url")" \
  -only-testing:FootplateUITests/AAPairForHand \
  -only-testing:FootplateUITests/LineScreenTests
```

`LineScreenTests` checks that the app reads the canned line board from
the stand-in edge.

The shell trap stops the edge by its pid and removes its files when the
shell exits, including after an interrupted test run.

The pairing and the notification answer stay in the simulator, so a
later run pairs nothing and starts from the tabs. For a fresh run,
uninstall the test build first:

```sh
xcrun simctl uninstall 7EC91353-EDF5-4E93-B644-46A44BA6CFCB dev.yardr.footplate.edge
```

`PairScreenTests` walks the unpaired journey, so it runs alone, without
`AAPairForHand`, on a fresh install. Nothing runs the stand-in from
the gate: the UI tests stay by hand.

The build settings live in `Config/`. The default edge is
`https://my.yardr.dev`; overriding `EDGE_URL` automatically changes the app's
bundle identifier to `dev.yardr.footplate.edge`, so a test build installs
beside the production app. Its Pair screen shows the test edge's host.
The display name stays **yardr footplate**. For example:

```sh
xcodebuild build -project Footplate.xcodeproj -scheme Footplate \
  -destination 'generic/platform=iOS Simulator' \
  EDGE_URL=https://test.yardr.dev
```

The exact default URL maps to `dev.yardr.footplate`; every other value gets
`.edge`. In an xcconfig URL use `https:/$()/host` to avoid its `//` comment
syntax. Tokens in `FootplateTests/Tokens/` and the theme assets are copied
from yardr-design; update both together when that design changes. The Plex
font licence ships with the app in `Footplate/UI/Resources/Fonts/OFL.txt`.
