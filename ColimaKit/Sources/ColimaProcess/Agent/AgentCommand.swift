import ColimaCore
import Foundation

package enum AgentTarget: Sendable, Hashable {
  case colima
  case machine(MachineKey)
}

package enum AgentCommand: Sendable, Equatable {
  case colima(VMCommand)
  case machine(MachineCommand)

  package var target: AgentTarget {
    switch self {
    case .colima: .colima
    case .machine(let command): .machine(command.name.key)
    }
  }
}

package struct AgentRunSummary: Sendable, Equatable, Codable {
  package let runID: UUID
  package let command: AgentCommand

  package init(runID: UUID, command: AgentCommand) {
    self.runID = runID
    self.command = command
  }
}

extension AgentCommand: Codable {
  private enum CodingKeys: String, CodingKey {
    case target, command
  }

  private enum Kind: String, Codable {
    case colima, machine
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .target) {
    case .colima: self = .colima(try container.decode(VMCommand.self, forKey: .command))
    case .machine: self = .machine(try container.decode(MachineCommand.self, forKey: .command))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .colima(let command):
      try container.encode(Kind.colima, forKey: .target)
      try container.encode(command, forKey: .command)
    case .machine(let command):
      try container.encode(Kind.machine, forKey: .target)
      try container.encode(command, forKey: .command)
    }
  }
}
