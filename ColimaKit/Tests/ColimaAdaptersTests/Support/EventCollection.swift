import ColimaCore

func collectEvents(_ run: VMCommandRun) async -> [ProcessEvent] {
  var events: [ProcessEvent] = []
  for await event in run.events { events.append(event) }
  return events
}
