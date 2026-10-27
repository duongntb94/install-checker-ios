import SwiftUI
import UIKit

@main
struct NetworkCheckerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = InspectionViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { await model.start() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iOS đánh thức app khi background download của model xong.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard let downloader = ModelDownloader.all.first(where: { $0.sessionID == identifier }) else {
            return completionHandler()
        }
        downloader.backgroundCompletionHandler = completionHandler
        downloader.reconnect()
    }
}
