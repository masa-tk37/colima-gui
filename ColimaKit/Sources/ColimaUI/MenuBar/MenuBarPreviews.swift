#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct IconPreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost {
        await VMControllerPreviews.make(scenario)
      } content: { scene in
        MenuBarIcon(state: scene.controller.displayState)
          .font(.largeTitle)
      }
      .padding(24)
    }
  }

  private struct MenuPreview: View {
    let scenario: VMControllerPreviews.Scenario

    var body: some View {
      PreviewHost {
        await VMControllerPreviews.make(scenario)
      } content: { scene in
        MenuBarContentView(controller: scene.controller, openMainWindow: {})
      }
    }
  }

  #Preview("Icon: running") {
    IconPreview(scenario: .running)
  }

  #Preview("Icon: stopped") {
    IconPreview(scenario: .stopped)
  }

  #Preview("Icon: starting") {
    IconPreview(scenario: .starting)
  }

  #Preview("Icon: stopping") {
    IconPreview(scenario: .stopping)
  }

  #Preview("Menu: running") {
    MenuPreview(scenario: .running)
  }

  #Preview("Menu: stopped") {
    MenuPreview(scenario: .stopped)
  }

  #Preview("Menu: broken") {
    MenuPreview(scenario: .broken)
  }

  #Preview("Menu: not created") {
    MenuPreview(scenario: .absent)
  }

  #Preview("Menu: unknown state") {
    MenuPreview(scenario: .unknown)
  }

  #Preview("Menu: Colima not detected") {
    MenuPreview(scenario: .colimaMissing)
  }

  #Preview("Menu: starting") {
    MenuPreview(scenario: .starting)
  }

  #Preview("Menu: stopping") {
    MenuPreview(scenario: .stopping)
  }

  #Preview("Menu: last failure") {
    MenuPreview(scenario: .startFailed)
  }

  #Preview("Menu: data disk remains") {
    MenuPreview(scenario: .dataDiskMayRemain)
  }

  #Preview("Menu: abort available") {
    MenuPreview(scenario: .startingAbortable)
  }

  #Preview("Menu: stop confirmation (from menu bar)") {
    MenuPreview(scenario: .pendingStopFromMenuBar)
  }
#endif
