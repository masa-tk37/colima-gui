import Testing

@testable import ColimaCore

@MainActor
struct ContainerOperationSlotsTests {
  private let web = ContainerID(rawValue: "web")
  private let db = ContainerID(rawValue: "db")

  @Test func reserveTakesAFreeSlot() {
    let slots = ContainerOperationSlots()
    #expect(slots.isBusy(web) == false)
    #expect(slots.reserve(web))
    #expect(slots.isBusy(web))
    #expect(slots.busyIDs == [web])
  }

  @Test func reservingAnOccupiedSlotIsRejectedAndKeepsTheOwner() {
    let slots = ContainerOperationSlots()
    #expect(slots.reserve(web))
    #expect(slots.reserve(web) == false)
    #expect(slots.isBusy(web))
  }

  @Test func releaseFreesTheSlotForTheNextOperation() {
    let slots = ContainerOperationSlots()
    _ = slots.reserve(web)
    slots.release(web)
    #expect(slots.isBusy(web) == false)
    #expect(slots.reserve(web))
  }

  @Test func slotsAreIndependentPerContainer() {
    let slots = ContainerOperationSlots()
    #expect(slots.reserve(web))
    #expect(slots.reserve(db))
    slots.release(web)
    #expect(slots.isBusy(db))
    #expect(slots.isBusy(web) == false)
  }

  @Test func releasingAFreeSlotChangesNothing() {
    let slots = ContainerOperationSlots()
    _ = slots.reserve(db)
    slots.release(web)
    #expect(slots.busyIDs == [db])
  }

  @Test func containerAndNetworkStoresShareOneInstance() {
    let shared = ContainerOperationSlots()
    let containerSide = shared
    let networkSide = shared
    #expect(containerSide.reserve(web))
    #expect(networkSide.reserve(web) == false)
    containerSide.release(web)
    #expect(networkSide.reserve(web))
  }
}
