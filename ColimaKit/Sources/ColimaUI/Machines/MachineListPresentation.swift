import ColimaCore
import Foundation

struct MachineListPresentation: Equatable {
  enum Screen: Equatable {
    case loading
    case limactlMissing(searched: [String])
    case noMachines
    case readFailedWithoutList
    case table
  }

  struct ReadFailure: Equatable {
    let summary: String?
    let output: [String]
  }

  enum Detail: Equatable {
    case none
    case operations(MachineName)
    case brokenErrors(MachineName, [String])
  }

  let screen: Screen
  let readFailure: ReadFailure?
  let rows: [MachineRow]
  let canCreate: Bool

  @MainActor
  init(controller: MachineController) {
    self.init(
      toolchain: controller.toolchain, listing: controller.listing, listError: controller.listError,
      rows: controller.rows())
  }

  init(toolchain: LimaToolchain?, listing: LimaListing?, listError: LimaCLIError?, rows: [MachineRow]) {
    self.rows = rows
    if case .found? = toolchain { canCreate = true } else { canCreate = false }
    if case .missing(let searched)? = toolchain {
      screen = .limactlMissing(searched: searched)
      readFailure = nil
      return
    }
    readFailure = listError.flatMap(Self.readFailure)
    if !rows.isEmpty {
      screen = .table
    } else if listing != nil {
      screen = .noMachines
    } else {
      screen = readFailure == nil ? .loading : .readFailedWithoutList
    }
  }

  private static func readFailure(of error: LimaCLIError) -> ReadFailure? {
    switch error {
    case .limactlMissing:
      ReadFailure(summary: String(localized: "limactl was not found. Install Lima, then try again.", bundle: #bundle), output: [])
    case .launchFailed(let reason):
      ReadFailure(summary: nil, output: [reason])
    case .nonZeroExit(let code, let output):
      ReadFailure(summary: MachineFailureCause.exited(code: code).message, output: output)
    case .cancelled:
      nil
    }
  }

  // MARK: Selection

  static func selectedRow(_ selection: MachineKey?, in rows: [MachineRow]) -> MachineRow? {
    guard let selection else { return nil }
    return rows.first { $0.id == selection }
  }

  static func selection(_ selection: MachineKey?, afterRows old: [MachineRow], become new: [MachineRow]) -> MachineKey? {
    let known = Set(old.map(\.id))
    if let created = new.first(where: { $0.display == .creating && !known.contains($0.id) }) {
      return created.id
    }
    return selectedRow(selection, in: new)?.id
  }

  static func detail(for row: MachineRow?, operationsAreEmpty: Bool) -> Detail {
    guard let row else { return .none }
    if case .broken(let errors) = row.display, operationsAreEmpty {
      return .brokenErrors(row.name, errors)
    }
    return .operations(row.name)
  }
}

struct MachineStatePresentation: Equatable {
  enum Tone: Equatable {
    case running, stopped, transitional, attention
  }

  let label: String
  let tone: Tone

  var symbol: String {
    switch tone {
    case .running, .stopped: "circle.fill"
    case .transitional: "circle.dotted"
    case .attention: "exclamationmark.triangle.fill"
    }
  }

  init(_ state: MachineDisplayState) {
    switch state {
    case .running:
      label = String(localized: "Running", bundle: #bundle)
      tone = .running
    case .stopped:
      label = String(localized: "Stopped", bundle: #bundle)
      tone = .stopped
    case .creating:
      label = String(localized: "Creating", bundle: #bundle)
      tone = .transitional
    case .starting:
      label = String(localized: "Starting", bundle: #bundle)
      tone = .transitional
    case .stopping:
      label = String(localized: "Stopping", bundle: #bundle)
      tone = .transitional
    case .deleting:
      label = String(localized: "Deleting", bundle: #bundle)
      tone = .transitional
    case .saving:
      label = String(localized: "Saving", bundle: #bundle)
      tone = .transitional
    case .broken:
      label = String(localized: "Broken", bundle: #bundle)
      tone = .attention
    case .other(let rawStatus):
      label = rawStatus
      tone = .attention
    }
  }
}

struct MachineRowCells: Equatable {
  static let placeholder = "—"

  let name: String
  let state: MachineStatePresentation
  let distribution: String
  let cpu: String
  let memory: String
  let disk: String

  init(row: MachineRow) {
    name = row.name.rawValue
    state = MachineStatePresentation(row.display)
    distribution = row.distribution ?? Self.placeholder
    let instance = row.instance
    cpu = instance.map { $0.cpus > 0 ? String($0.cpus) : Self.placeholder } ?? Self.placeholder
    memory = Self.gibibytes(instance?.memoryBytes ?? 0)
    disk = Self.gibibytes(instance?.diskBytes ?? 0)
  }

  static func gibibytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return placeholder }
    let value = (Double(bytes) / Double(1 << 30)).formatted(.number.precision(.fractionLength(0...1)))
    return "\(value) GiB"
  }
}
