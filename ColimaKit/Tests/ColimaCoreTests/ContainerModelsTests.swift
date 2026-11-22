import Testing

@testable import ColimaCore

@Test func runningDockerStateIsRunning() {
  #expect(ContainerState(dockerState: "running") == .running)
  #expect(ContainerState(dockerState: "running").isRunning)
}

@Test(arguments: ["exited", "created", "paused", "restarting", "dead", "Running", ""])
func otherDockerStatesKeepOriginalStringAndAreNotRunning(raw: String) {
  let state = ContainerState(dockerState: raw)
  #expect(state == .other(rawState: raw))
  #expect(state.isRunning == false)
}

@Test func summaryCarriesEveryDisplayedField() {
  let id = ContainerID(rawValue: "abc123")
  let summary = ContainerSummary(
    id: id,
    name: "web",
    image: "nginx:latest",
    state: .running,
    ports: [ContainerPort(ip: "0.0.0.0", privatePort: 80, publicPort: 8080, protocolName: "tcp")],
    labels: ["com.docker.compose.project": "shop"],
    networkNames: ["bridge", "shop_default"]
  )
  #expect(summary.id == id)
  #expect(summary.name == "web")
  #expect(summary.image == "nginx:latest")
  #expect(summary.state.isRunning)
  #expect(summary.ports.first?.publicPort == 8080)
  #expect(summary.labels["com.docker.compose.project"] == "shop")
  #expect(summary.networkNames == ["bridge", "shop_default"])
}

@Test func unpublishedPortHasNoPublicPortOrIP() {
  let port = ContainerPort(ip: nil, privatePort: 5432, publicPort: nil, protocolName: "tcp")
  #expect(port.ip == nil)
  #expect(port.publicPort == nil)
  #expect(port.privatePort == 5432)
}

@Test func detailCarriesTTYRunningAndNetworks() {
  let detail = ContainerDetail(
    id: ContainerID(rawValue: "abc123"),
    hasTTY: true,
    isRunning: false,
    networkNames: ["bridge"]
  )
  #expect(detail.hasTTY)
  #expect(detail.isRunning == false)
  #expect(detail.networkNames == ["bridge"])
}

@Test func containerActionsAreStartStopRestart() {
  #expect(ContainerAction.allCases == [.start, .stop, .restart])
}
