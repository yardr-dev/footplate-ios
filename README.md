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
pairing it opens an empty crew place. The crew and decide places are
built; the line screen is not built yet.
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
fonts are registered. `FootplateUITests` runs separately by hand, for example:

```sh
xcodebuild test -project Footplate.xcodeproj -scheme Footplate \
  -destination 'platform=iOS Simulator,id=77724F1C-CB67-476C-AF33-074587FD90A7' \
  -only-testing:FootplateUITests
```

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
