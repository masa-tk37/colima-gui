import Testing

@testable import ColimaCore

@Suite("HostResources")
struct HostResourcesTests {
  @Test func gibInitializerStoresTheByteCount() {
    let host = HostResources(cpus: 8, memoryGiB: 16, diskGiB: 460)

    #expect(host.memoryBytes == 17_179_869_184)
    #expect(host.memoryGiB == 16)
  }

  @Test func bytesInitializerReportsGiBTruncated() {
    let host = HostResources(cpus: 8, memoryBytes: 17_179_869_184 + 1_073_741_823, diskGiB: 460)

    #expect(host.memoryGiB == 16)
    #expect(host.memoryBytes == 17_179_869_184 + 1_073_741_823)
  }

  @Test func bothInitializersAreEqualForTheSameWholeGiB() {
    let fromGiB = HostResources(cpus: 8, memoryGiB: 16, diskGiB: 460)
    let fromBytes = HostResources(cpus: 8, memoryBytes: 16 << 30, diskGiB: 460)

    #expect(fromGiB == fromBytes)
    #expect(fromGiB != HostResources(cpus: 8, memoryGiB: 17, diskGiB: 460))
  }

  @Test func floorsApplyToBothInitializers() {
    let fromGiB = HostResources(cpus: 0, memoryGiB: 0, diskGiB: -3)
    let fromBytes = HostResources(cpus: 0, memoryBytes: 0, diskGiB: -3)

    #expect(fromGiB == HostResources(cpus: 1, memoryGiB: 1, diskGiB: 1))
    #expect(fromBytes == fromGiB)
    #expect(fromBytes.memoryBytes == 1 << 30)
    #expect(fromBytes.memoryGiB == 1)
  }

  @Test func belowOneGiBIsRaisedToOneGiB() {
    let host = HostResources(cpus: 1, memoryBytes: (1 << 30) - 1, diskGiB: 1)

    #expect(host.memoryBytes == 1 << 30)
    #expect(host.memoryGiB == 1)
  }

  @Test func currentHostIsBuiltFromPhysicalMemoryBytes() {
    let current = HostResources.current

    #expect(current.memoryBytes >= 1 << 30)
    #expect(current.memoryGiB == Int(current.memoryBytes >> 30))
  }
}
