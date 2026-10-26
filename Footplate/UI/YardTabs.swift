import SwiftUI
import UserNotifications

// The three places as tabs (design 3.5): Crew, Decide with the waiting
// count as its badge, and Lines, each a NavigationStack. Pair another
// yard and Sign in are covers over the tabs; the notification
// permission is asked once the tabs open.
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
    @State private var askingNotifications = false

    var body: some View {
        TabView(selection: $nav.place) {
            Tab("Crew", systemImage: "person.2", value: Place.crew) {
                CrewScreen(model: inbox, nav: nav, conversation: conversation)
            }
            Tab("Decide", systemImage: "checkmark.circle", value: Place.decide) {
                DecisionsScreen(inbox: inbox, model: decisions, decision: decision, nav: nav)
            }
            .badge(badge)
            Tab("Lines", systemImage: "list.bullet", value: Place.lines) {
                LinesScreen(inbox: inbox, records: records, model: line)
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
        .alert("Notifications", isPresented: $askingNotifications) {
            Button("Continue") {
                records.noteNotificationsAsked()
                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
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
