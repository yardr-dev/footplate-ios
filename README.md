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

A person has one account, and a yard another person owns and made them a
member of pairs beside their own: from a scanned pairing QR that names it
`owner/yard`, signed in as themselves. The head line and the yard switch call
it `lab — member of alice's yard`. When its owner removes the membership, the
yard leaves the phone with one sentence that says so. A code typed for
another account's yard is refused before anything is sent, and stays good: the
edge hands a member's code out, so a typed one could not seal the phone. The QR
the yard's operator opens on the yard's own screen does.

A code typed or read aloud pairs through a PAKE (SPAKE2, RFC 9382). The phone
and the yard run it on the code and swap their channel keys under the key it
derives, so the edge that relays the run reads no code, token or key. It gets
one online guess at the code a run, and a recorded run gives it nothing to test
candidates against. That holds for a code that never crossed the edge, such as
one shown on the yard's own screen; a code the edge hands out, a member's for
one, is outside it. A typed code is never redeemed plain at the edge. A yard
that takes no run (no channel key, or older than the PAKE) is said so with the
code unspent, and the person scans the QR its operator opens instead. A scanned
QR with no fourth field keeps its plain redemption, and so does a yard of your
own address. The PAKE is the yard's own `spake2-go`, bound the way `flynn/noise`
is (`ChannelBinding/`). It states it has had no formal audit, nothing here
claims one, and the phone shows no sealed claim yet.

A paired yard can be given a name of the person's own, since the name the
edge gives it, or its address's host and port, tells few yards apart. Rename
this yard, on the yard switch beside Forget this yard, sets it for the
selected yard, and clearing it brings the old name back. The head line, the
switch and the notifications that name a yard show it, and a yard of another
account keeps its `member of …'s yard` note beside it. The name stays on the
phone: no yard is told it.

One secret crosses the edge: the one-time code a harness's sign-in page
gives. Its decision card links the page and takes the code behind the
unlock; API keys and every other secret are answered on the yard's machine.

A phone already paired can pair another device of its user. A `user device
pair` decision says under its weight which door its approval crosses: sealed
to this phone, where the yard's channel was pinned at its pairing, so that the
edge carries the answer unread; otherwise with the token in the clear, so that
the code is to be shown to the device and to nobody else, since whoever
carries the approval could spend it first. Approving it, behind the unlock,
answers the pairing it opened, once, and the card gives way to its QR screen:
the QR for the new device to scan, the code beside it for one with no camera,
the minutes it is good for, and End, which ends the pairing. The QR and the
code are held in that screen's memory alone, and leaving the screen, the end
of the ten minutes and End drop them. Nothing writes or logs them, the code
cannot be copied, and neither is drawn while the app is out of the front, so
the system's snapshot for the app switcher holds neither. End is the user's
own: the yard serves it to a device for its own user's pairing alone, so an
operator's approval of a member's pairing is told where to end it, on the
yard. The new device scans the QR as it scans any pairing's, pinning the
yard's channel key from its fourth field and redeeming the code sealed, or
types the code.

A phone with no yard to pair can look around in a made-up one: the Pair
screen's Try a demo opens a demo yard with some crew, mail, a few beads and
one question to answer, under a banner that says it is made up and has Pair
a real yard to leave by. The demo lives in the app: no request leaves the
phone in it, what is sent or answered in it stays in memory, and leaving it
leaves nothing behind (no token in the Keychain, no yard in the saved list,
no push registration).

A bead opened from the lines place shows what the yard holds of it, its
labels, description and notes, with its page in the web view one tap away
for the rest. A note that carries pictures draws them under its words, on the
bead's card and in a decision's details alike, and a tap opens one full
screen; its pages and other files are told by name. A bead's card whose notes
carry any picture has a Media row under its labels, Media · 3 for three, which
opens all of them in one grid, the newest note's first; a tap opens one full
size, to swipe to the next and the previous, with who attached it and when. A decision's card shows
the ask's context, with its own bead one row away (its description and notes)
and one more row for each bead the ask is about, and Ask about this under
Later and Decline, which opens the coordinator's conversation with the bead's
id first in its draft. A depot pack too large to read whole comes as a summary
card: its summary is the first screen, and each file's line opens that file's
whole text over the card, under its name, its action and its old and new
SHA-256.

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
xcodebuild passes environment to the test process only with the
`TEST_RUNNER_` prefix, so the screenshot suites take their output
directory that way:

```sh
TEST_RUNNER_LINE_SHOTS_DIR=$(mktemp -d) sh .yardr/test LineScreenshotTests
```

The theme test compares the catalogue's dark and light appearances and the
phone type roles with vendored yardr-design tokens, and checks the bundled
fonts are registered. `FootplateUITests` runs separately by hand, against the
stand-in edge below.

## The by-hand UI tests

`scripts/fake-edge` stands in for the edge on loopback: Kratos's sign-in
and logout, one account's pairing, `/user/me`, every `/user/call/<Method>`
answered from `FootplateTests/FakeYard/Canned.swift`'s board, the
`/user/events` stream with a heartbeat every 25 seconds, and a page per
bead. It checks no credentials and serves `127.0.0.1` alone. A typed code
pairs through the PAKE and a paired device calls sealed, as through a
yard: that half is the Go yard-helper (`ChannelBinding/fakeedge/`, over
the channel binding), which the script starts with `go run` and routes
`/user/pair` PAKE bodies and all of `/user/e2e` to; the board stays in
Python, which the helper forwards opened inner calls back to. Go must be
on `PATH` (`brew install go`); without it the stand-in refuses to run.
It prints its URL, for the build's `EDGE_URL`, and every request to
standard error:

Run `python3 scripts/test-fake-edge.py` to check that values in its JSON
responses and bead pages stay data, and that PAKE bodies and the channel
route to the yard half. Run `go test ./fakeedge/` from `ChannelBinding/`
to check the yard half pairs a typed code and serves a sealed call.

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

The stand-in speaks the PAKE and the channel through its yard half,
so `AAPairForHand`, which types a code, pairs against it; the classes
after it start from a paired simulator.

`LineScreenTests` checks that the app reads the canned line board from
the stand-in edge. `MediaScreenTests` opens `yd-gate`, whose notes carry
three pictures that the stand-in makes and serves by their hash, to its
Media grid, and swipes through them full size.

The shell trap stops the edge by its pid and removes its files when the
shell exits, including after an interrupted test run.

The pairing and the notification answer stay in the simulator, so a
later run pairs nothing and starts from the tabs. For a fresh run,
uninstall the test build first — and after any restart of the
stand-in, whose yard half mints a new channel keypair every run: a
pairing pinned to the last run's key seals nothing to the next:

```sh
xcrun simctl uninstall 7EC91353-EDF5-4E93-B644-46A44BA6CFCB dev.yardr.footplate.edge
```

`PairScreenTests` walks the unpaired journey, so it runs alone, without
`AAPairForHand`, on a fresh install. So does `DemoScreenTests`, which
walks the demo from the first screen and out again, and needs no stand-in
edge: the demo answers in the app. Nothing runs the stand-in from
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
