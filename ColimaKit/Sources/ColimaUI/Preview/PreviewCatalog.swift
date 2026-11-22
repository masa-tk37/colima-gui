#if DEBUG
  import ColimaCore
  import SwiftUI

  private struct PreviewStateSummary: View {
    let title: String
    let lines: [String]

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line).font(.system(.caption, design: .monospaced))
        }
      }
      .padding()
      .frame(minWidth: 420, alignment: .leading)
    }
  }

  @MainActor
  private func describe(_ controller: VMController) -> [String] {
    var lines = [
      "observation: \(controller.observation)", "displayState: \(controller.displayState)",
    ]
    lines.append("dockerAvailability: \(controller.dockerAvailability)")
    if let operation = controller.activeOperation {
      let silence =
        operation.lastOutputAt.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "never"
      lines.append(
        "operation: \(operation.kind) \(operation.stage), started \(Int(Date().timeIntervalSince(operation.startedAt))) s ago"
      )
      lines.append("last output: \(silence), \(controller.latestRecord?.lines.count ?? 0) lines")
      lines.append("abort available: \(operation.isAbortAvailable(at: Date()))")
    }
    if let failure = controller.lastFailure {
      lines.append(
        "lastFailure: \(failure.kind) \(failure.stage) \(failure.cause), \(failure.outputTail.count) lines kept"
      )
    }
    lines.append("dataDiskMayRemain: \(controller.dataDiskMayRemain)")
    if let request = controller.pendingConfirmation {
      lines.append("pending confirmation: \(request.title) (origin \(request.origin))")
    }
    return lines
  }

  #Preview("VM running") {
    PreviewHost {
      await VMControllerPreviews.make(.running)
    } content: { scene in
      PreviewStateSummary(title: "VM running", lines: describe(scene.controller))
    }
  }

  #Preview("VM operation in progress (abort available)") {
    PreviewHost {
      await VMControllerPreviews.make(.startingAbortable)
    } content: { scene in
      PreviewStateSummary(title: "VM operation in progress (abort available)", lines: describe(scene.controller))
    }
  }

  #Preview("VM failure (retained)") {
    PreviewHost {
      await VMControllerPreviews.make(.startFailed)
    } content: { scene in
      PreviewStateSummary(title: "VM failure (retained)", lines: describe(scene.controller))
    }
  }

  #Preview("VM data disk remains") {
    PreviewHost {
      await VMControllerPreviews.make(.dataDiskMayRemain)
    } content: { scene in
      PreviewStateSummary(title: "VM data disk remains", lines: describe(scene.controller))
    }
  }

  #Preview("Confirmation request (menu bar)") {
    PreviewHost {
      await ConfirmationPreviews.make(.stopFromMenuBar)
    } content: { scene in
      PreviewStateSummary(
        title: "Confirmation request (menu bar)",
        lines: [scene.request.map { "\($0.title) / origin \($0.origin)" } ?? "none"])
    }
  }

  #Preview("Usage (series with gaps)") {
    PreviewHost {
      await VMUsageMonitorPreviews.make(.runningWithGaps)
    } content: { scene in
      let points = scene.monitor.cpu.points
      PreviewStateSummary(
        title: "Usage (series with gaps)",
        lines: [
          "state: \(scene.monitor.state)",
          "cpu points: \(points.count), gaps: \(points.count { $0.value == nil })",
        ])
    }
  }

  #Preview("Containers (three Compose states)") {
    PreviewHost {
      await ContainerStorePreviews.make(.listed)
    } content: { scene in
      let groups = scene.store.groups
      PreviewStateSummary(
        title: "Containers (three Compose states)",
        lines: groups.projects.map {
          "\($0.name): \($0.state), \($0.runningCount)/\($0.containers.count) running"
        }
          + ["Unlabeled: \(groups.ungrouped.count)"])
    }
  }

  #Preview("Logs (following)") {
    PreviewHost {
      await LogSessionPreviews.make(.following)
    } content: { scene in
      PreviewStateSummary(
        title: "Logs (following)",
        lines: [
          "state: \(scene.session.state)", "lines: \(scene.session.lines.count)",
          "stderr lines: \(scene.session.lines.count { $0.stream == .stderr })",
        ])
    }
  }

  #Preview("Network detail") {
    PreviewHost {
      await NetworkStorePreviews.make(.detailSelected)
    } content: { scene in
      PreviewStateSummary(
        title: "Network detail",
        lines: (scene.store.detail.value?.containers ?? []).map {
          "\($0.name) \($0.ipv4Address ?? "-")"
        })
    }
  }
#endif
