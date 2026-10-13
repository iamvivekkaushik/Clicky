import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--probe") {
            Probe.run(Array(arguments[(index + 1)...]))
        } else {
            ClickyApp.main()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tv = TVController()

    func applicationWillTerminate(_ notification: Notification) {
        tv.activity.flush()
    }
}

struct ClickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(tv: delegate.tv)
        } label: {
            MenuBarIcon(tv: delegate.tv)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var tv: TVController

    var body: some View {
        Image(systemName: tv.menuBarSymbol)
    }
}
