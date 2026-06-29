import Foundation
import SumikaCore

enum AppNavigationSelection: Hashable {
  case models
  case workspace(Workspace.ID)
  case session(ChatSession.ID)
}
