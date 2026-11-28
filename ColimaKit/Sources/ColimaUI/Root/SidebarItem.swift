import SwiftUI

public enum SidebarItem: Hashable, CaseIterable, Sendable {
  case overview
  case settings
  case containers
  case images
  case volumes
  case networks
  case machines

  enum Group: CaseIterable {
    case vm
    case docker
    case linuxMachines

    var title: LocalizedStringResource {
      switch self {
      case .vm: LocalizedStringResource("VM", bundle: #bundle)
      case .docker: LocalizedStringResource("Docker", bundle: #bundle)
      case .linuxMachines: LocalizedStringResource("Linux machines", bundle: #bundle)
      }
    }

    var items: [SidebarItem] {
      SidebarItem.allCases.filter { $0.group == self }
    }
  }

  var group: Group {
    switch self {
    case .overview, .settings: .vm
    case .containers, .images, .volumes, .networks: .docker
    case .machines: .linuxMachines
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .overview: LocalizedStringResource("Overview", bundle: #bundle)
    case .settings: LocalizedStringResource("VM settings", bundle: #bundle)
    case .containers: LocalizedStringResource("Containers", bundle: #bundle)
    case .images: LocalizedStringResource("Images", bundle: #bundle)
    case .volumes: LocalizedStringResource("Volumes", bundle: #bundle)
    case .networks: LocalizedStringResource("Networks", bundle: #bundle)
    case .machines: LocalizedStringResource("Machines", bundle: #bundle)
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "desktopcomputer"
    case .settings: "gearshape"
    case .containers: "shippingbox"
    case .images: "square.stack.3d.up"
    case .volumes: "externaldrive"
    case .networks: "network"
    case .machines: "server.rack"
    }
  }

  var shortcutKey: KeyEquivalent {
    let index = Self.allCases.firstIndex(of: self) ?? 0
    return KeyEquivalent(Character(String(index + 1)))
  }
}
