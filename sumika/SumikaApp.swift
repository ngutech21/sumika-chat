import SumikaApp
import SwiftUI

@main
enum SumikaExecutable {
  @MainActor
  // SwiftUI invokes this entry point through @main.
  // swiftlint:disable:next unused_declaration
  static func main() {
    SumikaApplication.main()
  }
}
