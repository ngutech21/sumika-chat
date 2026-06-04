//

import SwiftUI

@main
struct LocalCoderApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(appState: AppLaunchConfiguration.makeAppState())
    }
  }
}
