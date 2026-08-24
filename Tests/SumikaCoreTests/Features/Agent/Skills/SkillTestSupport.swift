import Foundation

func skillMentionRanges(of token: String, in text: String) -> [NSRange] {
  let source = text as NSString
  var result: [NSRange] = []
  var searchRange = NSRange(location: 0, length: source.length)
  while searchRange.length > 0 {
    let range = source.range(of: token, options: [], range: searchRange)
    guard range.location != NSNotFound else {
      break
    }
    result.append(range)
    let nextLocation = NSMaxRange(range)
    searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
  }
  return result
}
