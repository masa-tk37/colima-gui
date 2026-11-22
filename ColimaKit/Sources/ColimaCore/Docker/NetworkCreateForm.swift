import Foundation

public enum NetworkField: Sendable { case name, subnet }

public struct NetworkFieldError: Sendable, Equatable {
  public let field: NetworkField
  public let message: String

  public init(field: NetworkField, message: String) {
    self.field = field
    self.message = message
  }
}

public struct NetworkCreateFailure: Error, Equatable {
  public let fields: [NetworkFieldError]
}

public enum IPFamily: Sendable, Equatable { case ipv4, ipv6 }

public struct NetworkSubnet: Sendable, Equatable {
  public let cidr: String
  public let family: IPFamily
}

/// The initializer is `internal` on purpose: `NetworkCreateForm.validate` is the only source outside
/// `ColimaCore`, so an unchecked name or subnet can never reach a create request.
public struct ValidatedNetworkCreate: Sendable, Equatable {
  public let name: String
  public let subnet: NetworkSubnet?
  public var driver: String { "bridge" }

  init(name: String, subnet: NetworkSubnet?) {
    self.name = name
    self.subnet = subnet
  }
}

public struct NetworkCreateForm: Sendable, Equatable {
  public var name: String
  public var subnet: String

  public init(name: String, subnet: String) {
    self.name = name
    self.subnet = subnet
  }

  public func validate(
    existingNames: some Sequence<String>
  ) -> Result<ValidatedNetworkCreate, NetworkCreateFailure> {
    var errors: [NetworkFieldError] = []

    let name = self.name.trimmingWhitespace()
    if name.isEmpty {
      errors.append(NetworkFieldError(field: .name, message: String(localized: "Enter a network name.", bundle: #bundle)))
    } else if existingNames.contains(name) {
      errors.append(NetworkFieldError(field: .name, message: String(localized: "A network named “\(name)” already exists.", bundle: #bundle)))
    }

    let subnetText = subnet.trimmingWhitespace()
    var parsedSubnet: NetworkSubnet?
    if !subnetText.isEmpty {
      parsedSubnet = Self.parseCIDR(subnetText)
      if parsedSubnet == nil {
        errors.append(
          NetworkFieldError(
            field: .subnet,
            message: String(localized: "Enter the subnet as 172.28.0.0/16 (IPv4, prefix length 0-32) or fd00::/64 (IPv6, 0-128).", bundle: #bundle)
          ))
      }
    }

    guard errors.isEmpty else { return .failure(NetworkCreateFailure(fields: errors)) }
    return .success(ValidatedNetworkCreate(name: name, subnet: parsedSubnet))
  }

  private static func parseCIDR(_ text: String) -> NetworkSubnet? {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let address = String(parts[0])
    let prefix = parts[1]
    // ASCII digits only: `Int(_:)` would also accept a sign, and `Character.isNumber` non-ASCII digits.
    guard (1...3).contains(prefix.count), prefix.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
      let length = Int(prefix)
    else { return nil }

    if isIPv4(address) {
      return length <= 32 ? NetworkSubnet(cidr: text, family: .ipv4) : nil
    }
    if isIPv6(address) {
      return length <= 128 ? NetworkSubnet(cidr: text, family: .ipv6) : nil
    }
    return nil
  }

  private static func isIPv4(_ text: String) -> Bool {
    var storage = in_addr()
    return inet_pton(AF_INET, text, &storage) == 1
  }

  /// Darwin's `inet_pton` tolerates a `%zone` suffix, which has no place in a subnet.
  private static func isIPv6(_ text: String) -> Bool {
    guard !text.contains("%") else { return false }
    var storage = in6_addr()
    return inet_pton(AF_INET6, text, &storage) == 1
  }
}

extension String {
  fileprivate func trimmingWhitespace() -> String {
    let start = firstIndex { !$0.isWhitespace } ?? endIndex
    let end = lastIndex { !$0.isWhitespace }.map { index(after: $0) } ?? startIndex
    return start < end ? String(self[start..<end]) : ""
  }
}
