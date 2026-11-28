#if DEBUG
  import ColimaCore
  import Foundation

  enum PreviewMachineData {
    static let limaHomeUTF8Count = 21
    static let homeDirectory = "/Users/preview"
    static let host = HostResources(cpus: 8, memoryGiB: 32, diskGiB: 500)
    /// Small enough that starting a second 4 GiB machine passes the 75% memory threshold.
    static let constrainedHost = HostResources(cpus: 8, memoryGiB: 8, diskGiB: 500)

    static func name(_ text: String) -> MachineName {
      switch MachineName.parse(text, limaHomeUTF8Count: limaHomeUTF8Count) {
      case .success(let name): return name
      case .failure(let problem):
        preconditionFailure("the preview machine name \(text) is invalid: \(problem)")
      }
    }

    static let running = name("dev")
    static let stopped = name("build")
    static let alpine = name("scratch")
    static let broken = name("legacy")
    static let creating = name("fresh")

    static let templates = ["ubuntu", "debian-12", "alpine", "fedora"].compactMap(MachineTemplate.init(id:))

    static func instance(
      _ name: MachineName, runState: MachineRunState, memoryGiB: Int64 = 4, templateID: String? = "ubuntu"
    ) -> MachineInstance {
      MachineInstance(
        name: name, runState: runState, cpus: 2, memoryBytes: memoryGiB << 30, diskBytes: 100 << 30,
        mounts: [MachineMount(path: homeDirectory, writable: true)], templateID: templateID)
    }

    static func listing(_ machines: [MachineInstance]) -> LimaListing {
      LimaListing(machines: machines, unownedMachineKeys: [])
    }

    static let emptyListing = listing([])
    static let mixedListing = listing([
      instance(running, runState: .running),
      instance(stopped, runState: .stopped, templateID: "debian-12"),
      instance(alpine, runState: .stopped, memoryGiB: 1, templateID: "alpine"),
    ])
    static let brokenListing = listing(
      mixedListing.machines + [
        .broken(name: broken, errors: ["failed to load lima.yaml: yaml: line 12: did not find expected key"])
      ])

    static let limactlSearched = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let listFailureOutput = [
      "time=\"2026-11-28T10:12:03+09:00\" level=fatal msg=\"failed to inspect instances: open /Users/preview/.lima: permission denied\""
    ]
    static let createOutput = [
      "INFO[0000] Terminal is not available, proceeding without opening an editor",
      "INFO[0000] Attempting to download the image  digest=\"sha256:5c1f\" location=\"https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img\"",
      "INFO[0004] Downloaded the image from \"https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img\"",
    ]
    static let createFailureOutput = [
      "INFO[0000] Attempting to download the image  location=\"https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img\"",
      "FATA[0030] failed to download the image: Get \"https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img\": dial tcp: lookup cloud-images.ubuntu.com: no such host",
    ]
    static let startOutput = [
      "INFO[0000] Using the existing instance \"cg-build\"",
      "INFO[0001] [hostagent] Starting VZ (hint: to watch the boot progress, see \"/Users/preview/.lima/cg-build/serial*.log\")",
      "INFO[0009] [hostagent] Waiting for the essential requirement 1 of 3: \"ssh\"",
    ]
    static let startFailureOutput = [
      "INFO[0000] Using the existing instance \"cg-build\"",
      "INFO[0001] [hostagent] Starting VZ",
      "FATA[0012] exiting, status={Running:false Degraded:false Exiting:true Errors:[host agent does not seem to be running]}",
    ]

    // MARK: Fixed values for the confirmation, notice, and shell-failure displays

    static let memoryWarning: MemoryWarning = {
      let warning = MemoryPressureCheck.evaluate(
        defaultVMBytes: nil, otherMachineBytes: [4 << 30], targetBytes: 4 << 30,
        physicalBytes: constrainedHost.memoryBytes)
      guard let warning else { preconditionFailure("the preview memory figures stay under the threshold") }
      return warning
    }()

    static let memoryWarningRequest = ConfirmationRequest(
      intent: .startMachine(stopped, warning: memoryWarning),
      origin: .window,
      title: "Start the machine “build”?",
      message:
        "Starting this machine brings the memory allocated to running VMs to 8 GiB. That is above 6 GiB, 75% of this Mac’s 8 GiB. Other apps and containers may slow down.",
      itemGroups: [],
      confirmLabel: "Start",
      confirmRole: .standard)

    static let deleteRunningRequest = ConfirmationRequest(
      intent: .deleteMachine(running, wasRunning: true),
      title: "Delete the machine “dev”?",
      message:
        "This machine is running. It is force-stopped before it is deleted, and everything inside it is lost. This cannot be undone.",
      item: "dev", confirmLabel: "Delete")

    static let deleteStoppedRequest = ConfirmationRequest(
      intent: .deleteMachine(stopped, wasRunning: false),
      title: "Delete the machine “build”?",
      message: "Everything inside the machine is lost when it is deleted. This cannot be undone.",
      item: "build", confirmLabel: "Delete")

    static let createCancelledNotice = MachineNotice.createCancelled(creating)

    static let shellApplicationNotFound = ShellLaunchFailure(machine: running, error: .applicationNotFound)
    static let shellAutomationDenied = ShellLaunchFailure(machine: running, error: .automationDenied)
    static let shellFailed = ShellLaunchFailure(
      machine: running,
      error: .failed(detail: "LSOpenURLsWithRole() failed for the application /Applications/Ghostty.app with error -10810."))
  }
#endif
