import ColimaCore
import Foundation

struct MachineEditFormPresentation: Equatable {
  enum Content: Equatable {
    case form
    case stopFirst
  }

  private enum Attempt: Equatable {
    case none
    case invalid(MachineValidationFailure, submitted: MachineEditInput)
  }

  var input: MachineEditInput
  private var attempt = Attempt.none
  /// Set once a save has started, so the form stays up while the sheet closes and a second submit does nothing.
  private(set) var saveStarted = false

  init(instance: MachineInstance) {
    input = MachineEditInput(
      cpus: String(instance.cpus), memoryGiB: Self.gibText(bytes: instance.memoryBytes),
      diskGiB: String(Self.wholeGiB(roundingUp: instance.diskBytes)), mounts: instance.mounts)
  }

  static func content(canEdit: Bool, saveStarted: Bool = false) -> Content {
    canEdit || saveStarted ? .form : .stopFirst
  }

  var canSave: Bool { !saveStarted }

  // MARK: Shares

  mutating func addMounts(_ paths: [String]) {
    for path in paths where !input.mounts.contains(where: { $0.path == path }) {
      input.mounts.append(MachineMount(path: path, writable: false))
    }
  }

  mutating func addMounts(folders: [URL]) {
    addMounts(folders.map(Self.path(of:)))
  }

  /// A folder URL from the chooser ends in a slash, which would keep a listed folder from matching itself.
  static func path(of folder: URL) -> String {
    let path = folder.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  mutating func removeMount(at index: Int) {
    guard input.mounts.indices.contains(index) else { return }
    input.mounts.remove(at: index)
  }

  mutating func setWritable(_ writable: Bool, at index: Int) {
    guard input.mounts.indices.contains(index) else { return }
    let current = input.mounts[index]
    input.mounts[index] = MachineMount(path: current.path, writable: writable, mountPoint: current.mountPoint)
  }

  // MARK: Outcomes

  @discardableResult
  mutating func apply(_ outcome: MachineEditOutcome, submitted: MachineEditInput) -> Bool {
    switch outcome {
    case .started:
      attempt = .none
      saveStarted = true
      return true
    case .invalid(let failure):
      attempt = .invalid(failure, submitted: submitted)
    case .busy, .mustStopFirst:
      attempt = .none
    }
    return false
  }

  func errors(for field: MachineField) -> [String] {
    guard case .invalid(let failure, let submitted) = attempt, isUnchanged(field, since: submitted) else { return [] }
    return failure.fields.filter { $0.field == field }.map(\.message)
  }

  private func isUnchanged(_ field: MachineField, since submitted: MachineEditInput) -> Bool {
    switch field {
    case .cpu: input.cpus == submitted.cpus
    case .memory: input.memoryGiB == submitted.memoryGiB
    case .disk: input.diskGiB == submitted.diskGiB
    case .mount(let index):
      input.mounts.indices.contains(index) && submitted.mounts.indices.contains(index)
        && input.mounts[index].path == submitted.mounts[index].path
    case .name, .template: false
    }
  }

  // MARK: Initial values

  private static let bytesPerGiB: Int64 = 1 << 30

  private static func wholeGiB(roundingUp bytes: Int64) -> Int {
    Int((bytes + bytesPerGiB - 1) / bytesPerGiB)
  }

  private static func gibText(bytes: Int64) -> String {
    var text = String(format: "%.3f", Double(bytes) / Double(bytesPerGiB))
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
  }
}
