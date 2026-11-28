import ColimaCore
import Foundation

struct MachineBannersPresentation: Equatable {
  let notice: MachineNoticeBanner?
  let shellFailure: ShellFailureBanner?

  @MainActor
  init(controller: MachineController, terminal: TerminalModel) {
    notice = controller.notice.map(MachineNoticeBanner.init)
    shellFailure = terminal.lastLaunchFailure.map(ShellFailureBanner.init)
  }
}

struct MachineNoticeBanner: Equatable {
  let message: String

  init(_ notice: MachineNotice) {
    switch notice {
    case .editSaved(let name):
      message = String(
        localized: "Saved the changes to “\(name.rawValue)”. They take effect the next time it starts.", bundle: #bundle)
    case .createCancelled(let name):
      message = String(localized: "Cancelled creating “\(name.rawValue)”.", bundle: #bundle)
    }
  }
}

struct ShellFailureBanner: Equatable {
  let id: UUID
  let title: String
  let message: String
  let detail: String?
  let offersSettings: Bool

  init(_ failure: ShellLaunchFailure) {
    id = failure.id
    title = String(localized: "Couldn't open a shell in “\(failure.machine.rawValue)”", bundle: #bundle)
    switch failure.error {
    case .applicationNotFound:
      message = String(
        localized: "The terminal app was not found. Choose an installed terminal in Settings.", bundle: #bundle)
      detail = nil
      offersSettings = true
    case .automationDenied:
      message = String(
        localized:
          "macOS denied this app permission to control the terminal. Allow it in System Settings › Privacy & Security › Automation, then try again.",
        bundle: #bundle)
      detail = nil
      offersSettings = false
    case .failed(let text):
      message = String(localized: "The terminal app could not open the shell.", bundle: #bundle)
      detail = text.isEmpty ? nil : text
      offersSettings = false
    }
  }
}
