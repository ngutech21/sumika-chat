import Foundation
import LocalCoderCore

enum AppNavigationSelection: Hashable {
  case settings
  case models
  case session(ChatSession.ID)
}
