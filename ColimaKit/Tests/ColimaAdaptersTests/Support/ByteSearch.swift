extension Array where Element == UInt8 {
  func contains(subsequence needle: [UInt8]) -> Bool {
    range(of: needle) != nil
  }

  func range(of needle: [UInt8], from start: Int = 0) -> Range<Int>? {
    guard !needle.isEmpty, count >= needle.count, start <= count - needle.count else { return nil }
    for index in start...(count - needle.count) where self[index] == needle[0] {
      if self[index..<(index + needle.count)].elementsEqual(needle) {
        return index..<(index + needle.count)
      }
    }
    return nil
  }
}
