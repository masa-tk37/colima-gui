import Testing

@testable import ColimaCore

@Test func containerIDsFromTheSameStringAreEqualAndHashEqually() {
  let a = ContainerID(rawValue: "abc123")
  let b = ContainerID(rawValue: "abc123")
  #expect(a == b)
  #expect(a.hashValue == b.hashValue)
  #expect(Set([a, b]).count == 1)
  #expect(a != ContainerID(rawValue: "abc124"))
}

@Test func networkIDsFromTheSameStringAreEqualAndHashEqually() {
  let a = NetworkID(rawValue: "net1")
  let b = NetworkID(rawValue: "net1")
  #expect(a == b)
  #expect(a.hashValue == b.hashValue)
  #expect(Set([a, b]).count == 1)
  #expect(a != NetworkID(rawValue: "net2"))
}

@Test func idsExposeTheirStringForm() {
  #expect(ContainerID(rawValue: "abc123").rawValue == "abc123")
  #expect(ContainerID(rawValue: "abc123").description == "abc123")
  #expect(NetworkID(rawValue: "net1").rawValue == "net1")
  #expect(NetworkID(rawValue: "net1").description == "net1")
  #expect("\(ContainerID(rawValue: "abc123"))" == "abc123")
}

@Test func containerAndNetworkIDsAreDistinctTypesEvenForTheSameString() {
  #expect(ObjectIdentifier(ContainerID.self) != ObjectIdentifier(NetworkID.self))
  #expect(AnyHashable(ContainerID(rawValue: "x")) != AnyHashable(NetworkID(rawValue: "x")))
}

@Test func idsCanCrossConcurrencyBoundaries() async {
  let id = ContainerID(rawValue: "abc123")
  let netID = NetworkID(rawValue: "net1")
  let result = await Task.detached { (id.rawValue, netID.rawValue) }.value
  #expect(result == ("abc123", "net1"))
}
