import Foundation
import SumikaCore

enum AppNavigationSelection: Hashable {
  case models
  case session(ChatSession.ID)
}
