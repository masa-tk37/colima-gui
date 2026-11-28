import ColimaCore
import SwiftUI
import UniformTypeIdentifiers

/// Goes inside a `Form`.
struct TerminalSettingsSection: View {
  let model: TerminalModel
  @State private var presentation: TerminalSettingsPresentation
  @State private var choosingApplication = false

  init(model: TerminalModel, presentation: TerminalSettingsPresentation = TerminalSettingsPresentation()) {
    self.model = model
    _presentation = State(initialValue: presentation)
  }

  var body: some View {
    Section {
      Picker(LocalizedStringResource("Terminal for machine shells", bundle: #bundle), selection: optionBinding) {
        Text("Terminal", bundle: #bundle).tag(TerminalSettingsPresentation.Option.terminal)
        Text("Ghostty", bundle: #bundle).tag(TerminalSettingsPresentation.Option.ghostty)
        Text("Other…", bundle: #bundle).tag(TerminalSettingsPresentation.Option.other)
      }
      if let name = TerminalSettingsPresentation.customApplicationName(for: model.choice) {
        LabeledContent(LocalizedStringResource("Application", bundle: #bundle)) {
          HStack(spacing: 8) {
            Text(verbatim: name)
            Button(LocalizedStringResource("Choose…", bundle: #bundle)) { chooseApplication() }
          }
        }
      }
      if presentation.rejectedSelection {
        notice(
          Text("That item is not an application. The terminal was not changed.", bundle: #bundle),
          systemImage: "xmark.octagon")
      }
      if let missing = TerminalSettingsPresentation.missing(choice: model.choice, availability: model.availability) {
        notice(Text(verbatim: missingMessage(missing)), systemImage: "exclamationmark.triangle")
      }
    } header: {
      Text("Terminal", bundle: #bundle)
    } footer: {
      Text("Opening a shell in a machine uses this app.", bundle: #bundle)
    }
    .task { await model.refreshAvailability() }
    .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.application]) { result in
      guard case .success(let url) = result else { return }
      Task { presentation.apply(await model.selectCustomApplication(at: url)) }
    }
  }

  private var optionBinding: Binding<TerminalSettingsPresentation.Option> {
    Binding(
      get: { TerminalSettingsPresentation.option(for: model.choice) },
      set: { option in
        switch option {
        case .terminal: choose(.terminal)
        case .ghostty: choose(.ghostty)
        case .other:
          if TerminalSettingsPresentation.option(for: model.choice) != .other { chooseApplication() }
        }
      })
  }

  private func choose(_ choice: TerminalChoice) {
    presentation.clearRejection()
    Task { await model.select(choice) }
  }

  private func chooseApplication() {
    presentation.clearRejection()
    choosingApplication = true
  }

  private func notice(_ text: Text, systemImage: String) -> some View {
    Label {
      text
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func missingMessage(_ missing: TerminalSettingsPresentation.Missing) -> String {
    switch missing {
    case .terminal: String(localized: "Terminal was not found on this Mac.", bundle: #bundle)
    case .ghostty: String(localized: "Ghostty was not found on this Mac.", bundle: #bundle)
    case .custom(let name): String(localized: "\(name) was not found on this Mac.", bundle: #bundle)
    }
  }
}

#if DEBUG
  @MainActor
  private enum TerminalSettingsPreviewScenario {
    case terminal, ghostty, custom, rejected, terminalNotFound, ghosttyNotFound, customNotFound

    private static let warp = CustomTerminalApp(
      path: "/Applications/Warp.app", bundleIdentifier: "dev.warp.Warp", displayName: "Warp")

    func make() async -> (TerminalModel, TerminalSettingsPresentation) {
      let scene = await TerminalModelPreviews.make(self == .terminalNotFound ? .terminalNotFound : .available)
      let model = scene.model
      var presentation = TerminalSettingsPresentation()
      let someApp = URL(fileURLWithPath: "/Applications/Warp.app")
      switch self {
      case .terminal, .terminalNotFound:
        break
      case .ghostty:
        await model.select(.ghostty)
      case .custom:
        scene.launcher.configure { $0.customApplication = Self.warp }
        _ = await model.selectCustomApplication(at: someApp)
      case .rejected:
        presentation.apply(await model.selectCustomApplication(at: URL(fileURLWithPath: "/Users/preview/notes.txt")))
      case .ghosttyNotFound:
        scene.launcher.configure { $0.availability = .notFound }
        await model.select(.ghostty)
      case .customNotFound:
        scene.launcher.configure {
          $0.customApplication = Self.warp
          $0.availability = .notFound
        }
        _ = await model.selectCustomApplication(at: someApp)
      }
      return (model, presentation)
    }
  }

  private struct TerminalSettingsPreview: View {
    let scenario: TerminalSettingsPreviewScenario

    var body: some View {
      PreviewHost({ await scenario.make() }) { model, presentation in
        Form {
          TerminalSettingsSection(model: model, presentation: presentation)
        }
        .formStyle(.grouped)
        .frame(width: 460)
      }
    }
  }

  #Preview("Terminal") {
    TerminalSettingsPreview(scenario: .terminal)
  }

  #Preview("Ghostty") {
    TerminalSettingsPreview(scenario: .ghostty)
  }

  #Preview("Other application") {
    TerminalSettingsPreview(scenario: .custom)
  }

  #Preview("Not an application") {
    TerminalSettingsPreview(scenario: .rejected)
  }

  #Preview("Terminal not found") {
    TerminalSettingsPreview(scenario: .terminalNotFound)
  }

  #Preview("Ghostty not found") {
    TerminalSettingsPreview(scenario: .ghosttyNotFound)
  }

  #Preview("Other application not found") {
    TerminalSettingsPreview(scenario: .customNotFound)
  }
#endif
