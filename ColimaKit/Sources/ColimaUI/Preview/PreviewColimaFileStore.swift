#if DEBUG
  import ColimaCore
  import Synchronization

  final class PreviewColimaFileStore: ColimaFileStore {
    struct Config: Sendable {
      var profile: Result<ProfileSettings?, ColimaFileError> = .success(
        ProfileSettings(
          resources: VMResourceSettings(cpus: 2, memoryGiB: 2, diskGiB: 100), vmType: .vz)
      )
      var instanceVMType: Result<VMType?, ColimaFileError> = .success(.vz)
      var writeFailure: ColimaFileError?
    }

    private let state = Mutex(Config())

    func configure(_ body: (inout Config) -> Void) {
      state.withLock { body(&$0) }
    }

    func readProfileSettings() throws(ColimaFileError) -> ProfileSettings? {
      try state.withLock { $0.profile }.get()
    }

    func writeProfileSettings(_ settings: VMResourceSettings) throws(ColimaFileError) {
      let failure = state.withLock { config -> ColimaFileError? in
        if let failure = config.writeFailure { return failure }
        let vmType = (try? config.profile.get())??.vmType
        config.profile = .success(ProfileSettings(resources: settings, vmType: vmType))
        return nil
      }
      if let failure { throw failure }
    }

    func readInstanceVMType() throws(ColimaFileError) -> VMType? {
      try state.withLock { $0.instanceVMType }.get()
    }
  }
#endif
