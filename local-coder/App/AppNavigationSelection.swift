import Foundation
import LocalCoderCore

enum AppNavigationSelection: Hashable {
  case models
  case session(CodingSession.ID)
}
