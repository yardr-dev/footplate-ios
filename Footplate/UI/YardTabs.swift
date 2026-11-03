import SwiftUI
import UIKit
import UserNotifications

// The three places as tabs (design 3.5): Crew, Decide with the waiting
// count as its badge, and Lines, each a NavigationStack. The yard
// switch is one sheet over the tabs, since a sheet in every place on
// the one flag opens on no first tap, with Forget's confirmation and
// Rename's prompt after it; Pair another yard and Sign in are covers
// over the tabs; the notification permission is asked once the tabs
// open.
struct TabsView: View {
    @Bindable var nav: Nav
    @Bindable var inbox: InboxModel
    @Bindable var records: Records
    @Bindable var conversation: ConversationModel
    @Bindable var decisions: DecisionsModel
    @Bindable var decision: DecisionModel
    @Bindable var line: LineModel
    @Bindable var pair: PairModel
    @Bindable var signIn: SignInModel
    @Bindable var notifier: Notifier
    @State private var askingNotifications = false
    /// What the rename prompt's field holds: the name given so far, then
    /// whatever is typed.
    @State private var newName = ""

    var body: some View {
        TabView(selection: $nav.place) {
            Tab("Crew", systemImage: "person.2", value: Place.crew) {
                CrewScreen(model: inbox, nav: nav, conversation: conversation, line: line, notifier: notifier)
            }
            Tab("Decide", systemImage: "checkmark.circle", value: Place.decide) {
                DecisionsScreen(inbox: inbox, model: decisions, decision: decision, nav: nav)
            }
            .badge(badge)
            Tab("Lines", systemImage: "list.bullet", value: Place.lines) {
                LinesScreen(inbox: inbox, records: records, model: line, nav: nav)
            }
        }
        .fullScreenCover(isPresented: $nav.pairing, onDismiss: {
            pair.close()
        }) {
            PairScreen(model: pair, canGoBack: true, onBack: {
                if !pair.back() {
                    pair.close()
                    nav.pairing = false
                }
            })
            .fullScreenCover(isPresented: pairSignIn) {
                signInScreen
            }
        }
        .fullScreenCover(isPresented: tabsSignIn) {
            signInScreen
        }
        .sheet(isPresented: $nav.yardListShown) {
            YardSwitchView(
                state: inbox.state,
                onSelect: { name in
                    inbox.select(name)
                    nav.yardListShown = false
                },
                onPairAnother: {
                    nav.yardListShown = false
                    inbox.pairAnother()
                },
                onRename: {
                    nav.yardListShown = false
                    newName = inbox.renaming()?.given ?? ""
                    nav.renaming = true
                },
                onForget: {
                    nav.yardListShown = false
                    nav.confirmingForget = true
                }
            )
        }
        .alert("Rename this yard", isPresented: $nav.renaming) {
            // The yard's own name stands in the field while none is
            // given, and is what an empty field brings back.
            TextField(inbox.renaming()?.original ?? "", text: $newName)
            Button("Rename") { inbox.rename(newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let original = inbox.renaming()?.original {
                Text("The name stays on this phone. Leave it empty to bring back \(original)")
            }
        }
        .alert("Forget this yard", isPresented: $nav.confirmingForget) {
            Button("Keep", role: .cancel) {}
            Button("Forget", role: .destructive) {
                Task { await inbox.forget() }
            }
        } message: {
            if let sentence = inbox.forgetting() {
                Text(sentence)
            }
        }
        .alert("Notifications", isPresented: $askingNotifications) {
            Button("Continue") {
                records.noteNotificationsAsked()
                Task {
                    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                    if granted {
                        // The system gives the push token from here:
                        // the registrar registers it through the edge.
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    await notifier.refresh()
                }
            }
        } message: {
            Text("footplate tells you of letters and decisions while it is open, if you allow it.")
        }
        .onAppear {
            if !records.notificationsAsked {
                askingNotifications = true
            }
        }
    }

    /// The Decide tab's badge: the waiting count, else none.
    private var badge: Text? {
        let waiting = inbox.state.waiting
        return waiting > 0 ? Text("\(waiting)") : nil
    }

    private var signInScreen: some View {
        SignInScreen(model: signIn, again: nav.signIn?.again ?? false, onBack: {
            nav.signIn = nil
        })
    }

    /// Sign in over the tabs; not while the Pair cover shows it.
    private var tabsSignIn: Binding<Bool> {
        Binding(
            get: { nav.signIn != nil && !nav.pairing },
            set: { if !$0 { nav.signIn = nil } }
        )
    }

    /// Sign in over the Pair cover.
    private var pairSignIn: Binding<Bool> {
        Binding(
            get: { nav.signIn != nil },
            set: { if !$0 { nav.signIn = nil } }
        )
    }
}
