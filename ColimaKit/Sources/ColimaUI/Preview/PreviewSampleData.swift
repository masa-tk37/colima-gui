#if DEBUG
  import ColimaCore
  import Foundation

  enum PreviewSampleData {
    static let created = Date(timeIntervalSince1970: 1_730_000_000)

    // MARK: Containers

    static func containerID(_ name: String) -> ContainerID {
      ContainerID(
        rawValue: "c0ffee"
          + name.unicodeScalars.map { String($0.value, radix: 16) }.joined().prefix(58))
    }

    /// Links the sample containers to the sample images, so the image list shows which ones are in use.
    private static let imageIDs = ["nginx:1.27": "sha256:aa01", "postgres:17": "sha256:aa02"]

    private static func container(
      _ name: String,
      image: String,
      running: Bool,
      project: String? = nil,
      ports: [ContainerPort] = [],
      networks: [String]
    ) -> ContainerSummary {
      ContainerSummary(
        id: containerID(name), name: name, image: image,
        state: running ? .running : .other(rawState: "exited"),
        ports: ports,
        labels: project.map { [ComposeGrouping.projectLabel: $0] } ?? [:],
        networkNames: networks,
        imageID: imageIDs[image] ?? ""
      )
    }

    private static func tcp(_ privatePort: Int, published publicPort: Int?) -> ContainerPort {
      ContainerPort(
        ip: publicPort == nil ? nil : "0.0.0.0", privatePort: privatePort, publicPort: publicPort,
        protocolName: "tcp")
    }

    static let webshopWeb = container(
      "webshop-web-1", image: "nginx:1.27", running: true, project: "webshop",
      ports: [tcp(80, published: 8080)], networks: ["webshop_default"])
    static let webshopAPI = container(
      "webshop-api-1", image: "webshop/api:2.4.1", running: true, project: "webshop",
      ports: [tcp(3000, published: 3000)], networks: ["webshop_default"])
    static let webshopCache = container(
      "webshop-cache-1", image: "redis:7", running: true, project: "webshop",
      ports: [tcp(6379, published: nil)], networks: ["webshop_default"])
    static let analyticsWorker = container(
      "analytics-worker-1", image: "analytics/worker:0.9", running: true, project: "analytics",
      networks: ["analytics_default"])
    static let analyticsDB = container(
      "analytics-db-1", image: "postgres:17", running: false, project: "analytics",
      ports: [tcp(5432, published: nil)], networks: ["analytics_default"])
    static let legacyBatch = container(
      "legacy-batch-1", image: "legacy/batch:1.0", running: false, project: "legacy",
      networks: ["legacy_default"])
    static let legacyCron = container(
      "legacy-cron-1", image: "legacy/cron:1.0", running: false, project: "legacy",
      networks: ["legacy_default"])
    static let scratchPostgres = container(
      "scratch-postgres", image: "postgres:17", running: true,
      ports: [tcp(5432, published: 5432)], networks: ["bridge"])
    static let adminer = container(
      "adminer", image: "adminer:latest", running: false, networks: ["bridge"])

    static let containers: [ContainerSummary] = [
      webshopWeb, webshopAPI, webshopCache, analyticsWorker, analyticsDB, legacyBatch, legacyCron,
      scratchPostgres, adminer,
    ]
    static let unlabeledContainers: [ContainerSummary] = [scratchPostgres, adminer]

    // MARK: Logs

    static func logEntries(count: Int) -> [(stream: LogStreamKind, text: String)] {
      (0..<count).map { index in
        let minute = String(format: "%02d", index % 60)
        if index % 9 == 4 {
          return (
            .stderr,
            "2024/11/01 10:\(minute):12 [warn] upstream response is buffered to a temporary file"
          )
        }
        return (
          .stdout,
          "172.20.0.1 - - [01/Nov/2024:10:\(minute):12 +0000] \"GET /items/\(index) HTTP/1.1\" 200 \(512 + index)"
        )
      }
    }

    static func logChunks(
      _ entries: [(stream: LogStreamKind, text: String)],
      tty: Bool,
      unterminated: (stream: LogStreamKind, text: String)? = nil
    ) -> [[UInt8]] {
      var result = entries.map { entry in
        tty
          ? Array((entry.text + "\n").utf8)
          : PreviewDockerEngine.frame(entry.stream, entry.text + "\n")
      }
      if let unterminated {
        result.append(
          tty
            ? Array(unterminated.text.utf8)
            : PreviewDockerEngine.frame(unterminated.stream, unterminated.text))
      }
      return result
    }

    // MARK: Images

    static let images: [ImageSummary] = [
      ImageSummary(
        id: "sha256:aa01", repoTags: ["nginx:1.27", "nginx:latest"], size: 192_000_000,
        created: created),
      ImageSummary(
        id: "sha256:aa02", repoTags: ["postgres:17"], size: 437_000_000,
        created: created.addingTimeInterval(-86_400 * 12)),
      ImageSummary(
        id: "sha256:aa03", repoTags: ["registry.example.com:5000/webshop/api:2.4.1"],
        size: 288_000_000,
        created: created.addingTimeInterval(-3_600)),
      ImageSummary(
        id: "sha256:aa04", repoTags: [], size: 71_000_000,
        created: created.addingTimeInterval(-86_400 * 90)),
    ]

    // MARK: Volumes

    static let anonymousVolumeName =
      "9b1f5c2d7a8e4f60b3c1d2e4f5a69788c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5"

    static let volumes: [VolumeSummary] = [
      VolumeSummary(name: "webshop_pgdata", driver: "local", createdAt: created, labels: nil),
      VolumeSummary(
        name: "analytics_cache", driver: "local",
        createdAt: created.addingTimeInterval(-86_400 * 3), labels: nil),
      VolumeSummary(
        name: anonymousVolumeName, driver: "local",
        createdAt: created.addingTimeInterval(-86_400 * 30),
        labels: [VolumeSummary.anonymousLabel: ""]),
      VolumeSummary(name: "scratch_data", driver: "local", createdAt: nil, labels: nil),
    ]
    static let unusedVolumes: [VolumeSummary] = volumes.filter { $0.name != "webshop_pgdata" }
    static let volumeSizes: [String: VolumeSize] = [
      "webshop_pgdata": .bytes(1_800_000_000),
      "analytics_cache": .bytes(64_000_000),
      anonymousVolumeName: .bytes(12_000_000),
      "scratch_data": .unknown,
    ]

    // MARK: Networks

    static func networkID(_ name: String) -> NetworkID {
      NetworkID(
        rawValue: "a1b2c3"
          + name.unicodeScalars.map { String($0.value, radix: 16) }.joined().prefix(58))
    }

    private static func network(
      _ name: String, driver: String = "bridge", subnet: String? = nil, gateway: String? = nil
    ) -> NetworkSummary {
      NetworkSummary(
        id: networkID(name), name: name, driver: driver, scope: "local",
        ipam: subnet.map { [IPAMConfig(subnet: $0, gateway: gateway)] } ?? [])
    }

    static let bridge = network("bridge", subnet: "172.17.0.0/16", gateway: "172.17.0.1")
    static let host = network("host", driver: "host")
    static let none = network("none", driver: "null")
    static let webshopDefault = network(
      "webshop_default", subnet: "172.20.0.0/16", gateway: "172.20.0.1")
    static let analyticsDefault = network(
      "analytics_default", subnet: "172.21.0.0/16", gateway: "172.21.0.1")
    static let legacyDefault = network(
      "legacy_default", subnet: "172.22.0.0/16", gateway: "172.22.0.1")
    static let devNet = network("dev-net", subnet: "172.28.0.0/16", gateway: "172.28.0.1")
    static let unusedNetwork = network(
      "old-experiment", subnet: "172.30.0.0/16", gateway: "172.30.0.1")

    static let networks: [NetworkSummary] = [
      bridge, host, none, webshopDefault, analyticsDefault, legacyDefault, devNet, unusedNetwork,
    ]
    /// The networks no running container is connected to; the built-in ones can never be candidates.
    static let unusedNetworks: [NetworkSummary] = [legacyDefault, devNet, unusedNetwork]

    private static func member(_ summary: ContainerSummary, ip: String) -> NetworkContainer {
      NetworkContainer(id: summary.id, name: summary.name, ipv4Address: ip, ipv6Address: nil)
    }

    static let networkDetails: [NetworkID: NetworkDetail] = {
      let details = [
        NetworkDetail(
          id: bridge.id, name: bridge.name,
          containers: [member(scratchPostgres, ip: "172.17.0.2/16")]),
        NetworkDetail(
          id: webshopDefault.id, name: webshopDefault.name,
          containers: [
            member(webshopWeb, ip: "172.20.0.2/16"), member(webshopAPI, ip: "172.20.0.3/16"),
            member(webshopCache, ip: "172.20.0.4/16"),
          ]),
        NetworkDetail(
          id: analyticsDefault.id, name: analyticsDefault.name,
          containers: [member(analyticsWorker, ip: "172.21.0.2/16")]),
        NetworkDetail(id: host.id, name: host.name, containers: []),
        NetworkDetail(id: none.id, name: none.name, containers: []),
        NetworkDetail(id: legacyDefault.id, name: legacyDefault.name, containers: []),
        NetworkDetail(id: devNet.id, name: devNet.name, containers: []),
        NetworkDetail(id: unusedNetwork.id, name: unusedNetwork.name, containers: []),
      ]
      return Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
    }()
  }
#endif
