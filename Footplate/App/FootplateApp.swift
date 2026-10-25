import SwiftUI

@main
struct FootplateApp: App {
    var body: some Scene {
        WindowGroup {
            PairScreen()
                .tint(ThemeColor.textAccent.color)
        }
    }
}
