import Testing

@testable import ColimaCore

private func errors(
  name: String = "net1", subnet: String = "", existing: [String] = []
) -> [NetworkFieldError] {
  switch NetworkCreateForm(name: name, subnet: subnet).validate(existingNames: existing) {
  case .success: []
  case .failure(let failure): failure.fields
  }
}

private func validated(name: String, subnet: String = "", existing: [String] = []) throws
  -> ValidatedNetworkCreate
{
  try NetworkCreateForm(name: name, subnet: subnet).validate(existingNames: existing).get()
}

@Test func emptyNameIsRejectedOnTheNameField() {
  #expect(errors(name: "").map(\.field) == [.name])
  #expect(errors(name: "   ").map(\.field) == [.name])
}

@Test func existingNameIsRejectedByExactMatch() {
  #expect(errors(name: "bridge", existing: ["bridge", "other"]).map(\.field) == [.name])
  #expect(errors(name: "Bridge", existing: ["bridge"]).isEmpty)
  #expect(errors(name: "bridge2", existing: ["bridge"]).isEmpty)
}

@Test(arguments: [
  "10.0.0.0/33", "10.0.0.0", "10.0.0.0/", "/24", "10.0.0/24", "10.0.0.256/24", "10.0.0.0.0/24",
  "10.0.0.0/-1", "10.0.0.0/+8", "10.0.0.0/2 4", "10.0.0.0/8/8", "10.0.0.0/٢٤", "a.b.c.d/8",
  "fd00::/129", "fd00::", "fd00::/", "fd00:::1/64", "fd00::g/64", "fe80::1%eth0/64",
  "1:2:3:4:5:6:7:8:9/64",
  "not-a-cidr", "/",
])
func malformedSubnetIsRejectedOnTheSubnetField(subnet: String) {
  #expect(errors(subnet: subnet).map(\.field) == [.subnet])
}

@Test(arguments: [
  "10.0.0.0/0", "10.0.0.0/32", "172.20.0.0/16", "192.168.1.0/24", "fd00::/0", "fd00::/128",
  "fd00::/64",
  "2001:db8::/32", "::1/128", "::/0", "1:2:3:4:5:6:7:8/64", "::ffff:10.0.0.1/96",
])
func wellFormedSubnetIsAccepted(subnet: String) {
  #expect(errors(subnet: subnet).isEmpty)
}

@Test func blankSubnetMeansNoSubnet() throws {
  #expect(try validated(name: "n", subnet: "").subnet == nil)
  #expect(try validated(name: "n", subnet: "  ").subnet == nil)
}

@Test func errorsAreReportedPerFieldTogether() {
  let result = errors(name: "", subnet: "10.0.0.0/33")
  #expect(Set(result.map(\.field)) == [.name, .subnet])
  #expect(result.allSatisfy { !$0.message.isEmpty })
}

@Test func validatedValueCarriesNameSubnetFamilyAndFixedDriver() throws {
  let v4 = try validated(name: "  app-net ", subnet: " 172.28.0.0/16 ")
  #expect(v4.name == "app-net")
  #expect(v4.subnet == NetworkSubnet(cidr: "172.28.0.0/16", family: .ipv4))
  #expect(v4.driver == "bridge")

  let v6 = try validated(name: "n6", subnet: "fd00:1::/64")
  #expect(v6.subnet == NetworkSubnet(cidr: "fd00:1::/64", family: .ipv6))
}
