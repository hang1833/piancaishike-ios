import SwiftUI

@main
struct PianCaiShiKeApp: App {
    @StateObject private var storeManager = StoreManager()

    var body: some Scene {
        WindowGroup {
            WebViewContainer(storeManager: storeManager)
                .ignoresSafeArea()
                .background(Color(red: 4/255, green: 11/255, blue: 14/255))
        }
    }
}
