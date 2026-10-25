import SwiftUI

@main
struct FootplateApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            FootplateScene(services: services)
        }
    }
}

@MainActor
private final class AppServices {
    let yards = Yards(foreground: false)
    private var networkWatch: NetworkWatch?

    func start() {
        guard networkWatch == nil else { return }
        let yards = self.yards
        let watch = NetworkWatch {
            Task { @MainActor in
                yards.noteNetworkChanged()
            }
        }
        networkWatch = watch
        watch.start()
    }

    func setForeground(_ foreground: Bool) {
        yards.foreground = foreground
    }
}

private struct FootplateScene: View {
    @Environment(\.scenePhase) private var scenePhase
    let services: AppServices

    var body: some View {
        PairScreen()
            .tint(ThemeColor.textAccent.color)
            .onAppear(perform: services.start)
            .onChange(of: scenePhase, initial: true) { _, phase in
                services.setForeground(phase == .active)
            }
    }
}
