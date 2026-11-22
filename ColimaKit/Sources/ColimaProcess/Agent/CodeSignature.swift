import Foundation
import Security

package enum CodeSignature {
  /// Ad-hoc signing has no team to anchor on, so the cdhash is the only stable identity of a build.
  package static func cdhash(of url: URL) -> String? {
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let cdhash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    else { return nil }
    return cdhash.map { String(format: "%02x", $0) }.joined()
  }
}
