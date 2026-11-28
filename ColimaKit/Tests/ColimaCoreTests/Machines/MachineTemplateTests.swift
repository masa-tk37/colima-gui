import Foundation
import Testing

@testable import ColimaCore

@Suite("MachineTemplate")
struct MachineTemplateTests {
  private static func listedTemplateIDs() throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/limactl-list-templates", withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  @Test func linuxTemplatesKeepOnlyAllowListedDistributionsOfThisMacListing() throws {
    let ids = MachineTemplate.linuxTemplates(from: try Self.listedTemplateIDs()).map(\.id)
    #expect(
      ids == [
        "almalinux", "almalinux-10", "almalinux-8", "almalinux-9",
        "alpine", "alpine-3.21", "alpine-3.22", "alpine-3.23", "alpine-3.24",
        "archlinux",
        "centos-stream", "centos-stream-10", "centos-stream-9",
        "debian", "debian-11", "debian-12", "debian-13",
        "fedora", "fedora-41", "fedora-42", "fedora-43", "fedora-44", "fedora-45",
        "opensuse", "opensuse-leap", "opensuse-leap-15", "opensuse-leap-16",
        "oraclelinux", "oraclelinux-10", "oraclelinux-8", "oraclelinux-9",
        "rocky", "rocky-10", "rocky-8", "rocky-9",
        "ubuntu", "ubuntu-20.04", "ubuntu-22.04", "ubuntu-24.04", "ubuntu-24.10", "ubuntu-25.04", "ubuntu-25.10",
        "ubuntu-26.04", "ubuntu-26.10",
      ])
  }

  @Test(arguments: [
    "docker", "docker-rootful", "k8s", "k3s", "k0s", "macos", "macos-15", "windows", "windows-11", "freebsd",
    "freebsd-15", "podman", "podman-rootful", "alpine-iso", "ubuntu-lts", "default", "apptainer", "buildkit",
    "faasd", "homebrew-linux", "homebrew-macos", "linuxbrew",
    "experimental/debian-sid", "experimental/fedora-rawhide", "experimental/ubuntu-next", "experimental/gentoo",
    "experimental/opensuse-tumbleweed", "experimental/wsl2",
  ])
  func listedNonDistributionTemplatesAreExcluded(id: String) throws {
    #expect(try Self.listedTemplateIDs().contains(id))
    #expect(MachineTemplate(id: id) == nil)
    #expect(MachineTemplate.linuxTemplates(from: [id]).isEmpty)
  }

  @Test func theFixtureHoldsEveryKindOfTemplateTheFilterMustReject() throws {
    let ids = try Self.listedTemplateIDs()
    #expect(ids.contains { $0.hasPrefix("experimental/") })
    #expect(Set(["docker", "k8s", "macos", "windows"]).isSubset(of: ids))
  }

  @Test(arguments: [
    "", "ubuntu-", "ubuntu-24.", "ubuntu-.04", "ubuntu-24..04", "ubuntu-24.04-beta", "ubuntu-lts", "Ubuntu-24.04",
    "UBUNTU", "ubuntu_24.04", "ubuntu 24.04", "ubuntu-２４", "ubuntu-24/04", "debian-sid", "alpine-iso", "opensuse-leap-",
    "opensuse-tumbleweed", "centos-9", "centos", "experimental/ubuntu", "template:ubuntu", "../ubuntu",
    "ubuntu-24.04\n", "x-ubuntu",
  ])
  func idsOutsideTheAllowListAreRejected(id: String) {
    #expect(MachineTemplate(id: id) == nil)
  }

  @Test func versionlessIdFollowsTheLatestVersion() throws {
    let template = try #require(MachineTemplate(id: "debian"))
    #expect(template.distribution == .debian)
    #expect(template.version == nil)
    #expect(template.id == "debian")
  }

  @Test func versionedIdKeepsTheVersionAfterTheFamily() throws {
    let template = try #require(MachineTemplate(id: "ubuntu-24.04"))
    #expect(template.distribution == .ubuntu)
    #expect(template.version == "24.04")
    #expect(template.id == "ubuntu-24.04")
  }

  @Test func familiesWithHyphensKeepTheirOwnNameApartFromTheVersion() throws {
    let centos = try #require(MachineTemplate(id: "centos-stream-10"))
    #expect(centos.distribution == .centosStream)
    #expect(centos.version == "10")
    let leap = try #require(MachineTemplate(id: "opensuse-leap-15"))
    #expect(leap.distribution == .opensuseLeap)
    #expect(leap.version == "15")
    let leapLatest = try #require(MachineTemplate(id: "opensuse-leap"))
    #expect(leapLatest.distribution == .opensuseLeap)
    #expect(leapLatest.version == nil)
  }

  @Test func newVersionsOfAllowListedFamiliesAreAcceptedWithoutChangingTheAllowList() {
    #expect(MachineTemplate(id: "ubuntu-28.04")?.version == "28.04")
    #expect(MachineTemplate.linuxTemplates(from: ["fedora-99", "debian-20"]).map(\.id) == ["fedora-99", "debian-20"])
  }

  @Test func everyDistributionHasAnAllowListedIdThatRoundTrips() {
    for distribution in MachineDistribution.allCases {
      #expect(MachineTemplate(id: distribution.rawValue)?.distribution == distribution)
    }
    #expect(MachineDistribution.allCases.count == 11)
  }

  @Test func displayNamesShowTheVersionOrMarkTheLatestFollowingAlias() throws {
    func name(_ id: String) throws -> String { try #require(MachineTemplate(id: id)).displayName }
    #expect(try name("ubuntu-24.04") == "Ubuntu 24.04")
    #expect(try name("debian") == "Debian (latest)")
    #expect(try name("centos-stream-10") == "CentOS Stream 10")
    #expect(try name("opensuse-leap") == "openSUSE Leap (latest)")
    #expect(try name("oraclelinux-9") == "Oracle Linux 9")
    #expect(try name("almalinux") == "AlmaLinux (latest)")
    #expect(try name("alpine-3.23") == "Alpine Linux 3.23")
    #expect(try name("archlinux") == "Arch Linux (latest)")
    #expect(try name("rocky-9") == "Rocky Linux 9")
    #expect(try name("fedora-44") == "Fedora 44")
    #expect(try name("opensuse") == "openSUSE (latest)")
  }

  @Test func linuxTemplatesPreservesTheOrderOfTheListing() {
    #expect(MachineTemplate.linuxTemplates(from: ["ubuntu", "docker", "debian-12", "alpine"]).map(\.id) == ["ubuntu", "debian-12", "alpine"])
  }

  @Test func emptyListingYieldsNoTemplates() {
    #expect(MachineTemplate.linuxTemplates(from: []).isEmpty)
  }
}
