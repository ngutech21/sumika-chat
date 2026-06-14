import Foundation
import LocalCoderCore

enum AppNavigationSelection: Hashable {
  case models
  case session(ChatSession.ID)
}
