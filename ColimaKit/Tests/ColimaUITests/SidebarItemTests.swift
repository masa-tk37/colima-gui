import SwiftUI
import Testing

@testable import ColimaUI

@Suite(.timeLimit(.minutes(1)))
struct SidebarItemTests {
  @Test func existingItemsKeepTheirShortcutsAndMachinesIsSeventh() {
    let keys = SidebarItem.allCases.map { String($0.shortcutKey.character) }
    #expect(keys == ["1", "2", "3", "4", "5", "6", "7"])
    #expect(SidebarItem.allCases.prefix(6) == [.overview, .settings, .containers, .images, .volumes, .networks])
    #expect(SidebarItem.machines.shortcutKey == KeyEquivalent("7"))
    #expect(SidebarItem.overview.shortcutKey == KeyEquivalent("1"))
    #expect(SidebarItem.networks.shortcutKey == KeyEquivalent("6"))
  }

  @Test func machinesFormTheLastGroupAfterDocker() {
    #expect(SidebarItem.Group.allCases.count == 3)
    #expect(SidebarItem.Group.allCases.last?.items == [.machines])
    #expect(SidebarItem.machines.group == SidebarItem.Group.allCases.last)
    #expect(SidebarItem.Group.docker.items == [.containers, .images, .volumes, .networks])
    #expect(SidebarItem.Group.vm.items == [.overview, .settings])
  }

  @Test func everyItemBelongsToExactlyOneGroup() {
    let grouped = SidebarItem.Group.allCases.flatMap(\.items)
    #expect(grouped.count == SidebarItem.allCases.count)
    #expect(Set(grouped) == Set(SidebarItem.allCases))
  }
}
