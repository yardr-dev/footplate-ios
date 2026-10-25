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

Tracked in the yard as the `footplate-ios` depot. `.yardr/` holds its flow,
roles and merge gate. Every change is reviewed twice before it lands:
against its bead, then for security alone.
