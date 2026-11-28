import ColimaCore
import Foundation

struct MachineCreateFormPresentation: Equatable {
  enum Templates: Equatable {
    case loading
    case loaded([MachineTemplate])
    case failed(LimaCLIError)
  }

  private enum Attempt: Equatable {
    case none
    case invalid(MachineValidationFailure, submitted: MachineFormInput)
    case busy(submitted: MachineFormInput)
  }

  private(set) var templates = Templates.loading
  var input = MachineFormInput.defaults(firstTemplateID: nil)
  var isSubmitting = false
  private var attempt = Attempt.none

  var offeredTemplates: [MachineTemplate] {
    if case .loaded(let templates) = templates { templates } else { [] }
  }

  var hasNoTemplates: Bool {
    if case .loaded(let templates) = templates { templates.isEmpty } else { false }
  }

  var canSubmit: Bool { !offeredTemplates.isEmpty && !isSubmitting }

  var loadFailureMessage: String? {
    guard case .failed(let error) = templates else { return nil }
    switch error {
    case .limactlMissing:
      return String(localized: "limactl was not found. Install Lima, then try again.", bundle: #bundle)
    case .launchFailed(let reason):
      return reason
    case .nonZeroExit(_, let output):
      return output.joined(separator: "\n")
    case .cancelled:
      return String(localized: "Loading the distributions was cancelled.", bundle: #bundle)
    }
  }

  mutating func load(_ result: Result<[MachineTemplate], LimaCLIError>) {
    switch result {
    case .failure(let error):
      templates = .failed(error)
    case .success(let offered):
      templates = .loaded(offered)
      if !offered.contains(where: { $0.id == input.templateID }) {
        input.templateID = Self.defaultTemplateID(in: offered)
      }
    }
  }

  static func defaultTemplateID(in templates: [MachineTemplate]) -> String? {
    templates.first { $0.id == "ubuntu" }?.id ?? templates.first?.id
  }

  @discardableResult
  mutating func apply(_ outcome: MachineCreateOutcome, submitted: MachineFormInput) -> Bool {
    switch outcome {
    case .started:
      attempt = .none
      return true
    case .invalid(let failure):
      attempt = .invalid(failure, submitted: submitted)
    case .busy:
      attempt = .busy(submitted: submitted)
    }
    return false
  }

  func errors(for field: MachineField) -> [String] {
    guard case .invalid(let failure, let submitted) = attempt, value(of: field, in: input) == value(of: field, in: submitted)
    else { return [] }
    return failure.fields.filter { $0.field == field }.map(\.message)
  }

  var showsBusy: Bool {
    guard case .busy(let submitted) = attempt else { return false }
    return submitted.name == input.name
  }

  private func value(of field: MachineField, in input: MachineFormInput) -> String? {
    switch field {
    case .name: input.name
    case .template: input.templateID
    case .cpu: input.cpus
    case .memory: input.memoryGiB
    case .disk: input.diskGiB
    case .mount: nil
    }
  }
}
