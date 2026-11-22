import Synchronization

@testable import ColimaCore

final class InMemoryColimaFileStore: ColimaFileStore {
  enum Call: Equatable {
    case readProfileSettings
    case writeProfileSettings(VMResourceSettings)
    case readInstanceVMType
  }

  struct Config: Sendable {
    var profile: Result<ProfileSettings?, ColimaFileError> = .success(nil)
    var instanceVMType: Result<VMType?, ColimaFileError> = .success(nil)
    var writeFailure: ColimaFileError?
  }

  private struct State {
    var config = Config()
    var calls: [Call] = []
    var written: [VMResourceSettings] = []
  }

  private let state = Mutex(State())

  func configure(_ body: (inout Config) -> Void) {
    state.withLock { body(&$0.config) }
  }

  var calls: [Call] { state.withLock { $0.calls } }

  var writtenSettings: [VMResourceSettings] { state.withLock { $0.written } }

  func readProfileSettings() throws(ColimaFileError) -> ProfileSettings? {
    let result = state.withLock { state in
      state.calls.append(.readProfileSettings)
      return state.config.profile
    }
    return try result.get()
  }

  func writeProfileSettings(_ settings: VMResourceSettings) throws(ColimaFileError) {
    let failure = state.withLock { state -> ColimaFileError? in
      state.calls.append(.writeProfileSettings(settings))
      state.written.append(settings)
      if let failure = state.config.writeFailure { return failure }
      let vmType = (try? state.config.profile.get())??.vmType
      state.config.profile = .success(ProfileSettings(resources: settings, vmType: vmType))
      return nil
    }
    if let failure { throw failure }
  }

  func readInstanceVMType() throws(ColimaFileError) -> VMType? {
    let result = state.withLock { state in
      state.calls.append(.readInstanceVMType)
      return state.config.instanceVMType
    }
    return try result.get()
  }
}
