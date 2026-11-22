import Foundation

@main
struct TestOverviewLayout {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "check-empty" {
            let defaults = UserDefaults(suiteName: args[2])!
            check(OverviewLayoutStore(key: args[3], defaults: defaults).load().entries.isEmpty,
                  "a saved empty layout must survive a separate process")
            return
        }

        let initial = OverviewLayout.standard
        check(initial.entries.map(\.id) == ["identity", "date", "pihole", "nodes", "stillness",
                                             "commits", "camera", "blocking", "artwork", "status"],
              "first launch preserves the original reading order")
        check(initial.entries.map(\.span) == [12, 12, 4, 4, 4, 7, 5, 5, 7, 12], "large spans")
        check(initial.entries.map(\.spanMd) == [12, 12, 6, 6, 12, 12, 12, 12, 12, 12], "medium spans")

        let suite = "CharonOverviewTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let demoKey = OverviewLayoutStore.profileKey(isDemo: true, collectorURL: nil)
        let demo = OverviewLayoutStore(key: demoKey, defaults: defaults)
        check(demo.load() == initial && defaults.object(forKey: demoKey) == nil, "missing profile")
        var draft = demo.load()
        draft.remove("nodes")
        draft.remove("nonexistent")
        check(draft.availableWidgets == [.nodes, .weather, .quakes, .metric, .progress, .custom],
              "offer removed original widgets and every repeatable widget")
        draft.add(.nodes)
        draft.add(.nodes)
        check(draft.entries.count == 10 && draft.entries.last?.widget == .nodes, "single instance")
        draft.move("nodes", to: -4)
        draft.move("nodes", to: 3)
        check(draft == initial, "moving forward uses the final destination index")
        draft.move("pihole", to: 99)
        draft.resize("pihole", to: .wide)
        check(draft.entries.last?.span == 8 && draft.entries.last?.spanMd == 12, "wide span")
        draft.resize("pihole", to: .full)
        check(draft.entries.last?.span == 12, "full span")
        draft.resize("camera", to: .compact)
        check(draft.entries.first(where: { $0.widget == .camera })?.spanMd == 6, "compact span")
        check(demo.load() == initial, "editing a draft leaves saved layout intact")
        demo.save(draft)
        check(demo.load() == draft, "save and reload preserve the draft")

        func liveKey(_ address: String) -> String {
            OverviewLayoutStore.profileKey(isDemo: false, collectorURL: URL(string: address))
        }
        let live = liveKey("HTTPS://EXAMPLE.invalid:443/base///")
        check(live == liveKey("https://login:secret@example.invalid/base?key=secret#fragment"),
              "canonical profile ignores credentials, query, fragment, default ports and trailing slashes")
        check(!live.contains("example") && !live.contains("secret") && !live.contains("base"), "hashed key")
        check(live != demoKey && live != liveKey("https://example.invalid")
              && live != liveKey("https://example.invalid:8080/base")
              && live != liveKey("https://other.invalid/base"), "distinct collector profiles")
        check(demoKey == OverviewLayoutStore.profileKey(isDemo: true, collectorURL: URL(string: "https://example.invalid")),
              "unused live URL cannot change the demo profile")
        check(OverviewLayoutStore(key: live, defaults: defaults).load() == initial, "demo changes are isolated")

        let future = Data(#"{"version":2,"futureRoot":{"enabled":true},"widgets":[{"id":"new-card","type":"forecast","size":{"rows":3,"width":"tall"},"options":{"region":"test","buckets":[1,2]}},{"id":"nodes","type":"nodes","size":"wide","futureSetting":"keep"}]}"#.utf8)
        defaults.set(future, forKey: demoKey)
        var recovered = demo.load()
        check(recovered.entries.count == 2 && recovered.entries.first?.widget == nil, "unknown widget remains visible")
        check(recovered.entries.first?.size == .standard, "unknown size uses a safe display span")
        recovered.move("new-card", to: 1)
        recovered.resize("nodes", to: .full)
        demo.save(recovered)
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: demoKey)!) as! [String: Any]
        let widgets = saved["widgets"] as! [[String: Any]]
        check(saved["version"] as? Int == 2 && (saved["futureRoot"] as? [String: Bool]) == ["enabled": true],
              "compatible future document metadata survives")
        check(widgets[0]["futureSetting"] as? String == "keep" && widgets[0]["size"] as? String == "full",
              "known widgets keep future fields while edited")
        let original = try JSONSerialization.jsonObject(with: future) as! [String: Any]
        let originalFuture = (original["widgets"] as! [[String: Any]])[0]
        check(NSDictionary(dictionary: widgets[1]).isEqual(to: originalFuture), "preserve complete unknown entry")

        var flexible = initial
        var weather = OverviewWidgetConfig()
        check(flexible.add(.weather, configuration: weather) == nil, "a forecast requires a chosen location")
        flexible.add(.weather)
        check(flexible == initial, "the singleton API cannot bypass location setup")
        weather.place = " Monterey Bay "
        weather.latitude = 36.6
        weather.longitude = -121.9
        let coastal = flexible.add(.weather, configuration: weather)!
        var inlandConfig = weather
        inlandConfig.place = "Fresno"
        inlandConfig.latitude = 36.74
        inlandConfig.longitude = -119.78
        let inland = flexible.add(.weather, configuration: inlandConfig)!
        check(coastal != inland && flexible.availableWidgets.contains(.weather), "independent forecast instances")
        weather.celsius = true
        check(flexible.configure(coastal, configuration: weather), "edit forecast")
        flexible.resize(coastal, to: .wide)
        flexible.move(inland, to: 0)
        demo.save(flexible)
        flexible = demo.load()
        let coast = flexible.entries.first { $0.id == coastal }!
        check(coast.configuration.place == "Monterey Bay" && coast.configuration.celsius && coast.size == .wide,
              "identity, size, units and location survive")
        check(flexible.entries.first?.id == inland && flexible.entries.first?.configuration == inlandConfig,
              "updating one forecast preserves the other and its position")
        var quakes = weather
        quakes.radiusKm = 25
        quakes.minimumMagnitude = 3
        let quakeID = flexible.add(.quakes, configuration: quakes)!
        quakes.radiusKm = .nan
        check(!flexible.configure(quakeID, configuration: quakes), "invalid radius cannot replace a saved config")
        quakes.radiusKm = 2
        quakes.minimumMagnitude = 11
        check(flexible.add(.quakes, configuration: quakes) == nil, "validate earthquake threshold")
        quakes.minimumMagnitude = 2
        quakes.longitude = -181
        check(flexible.add(.quakes, configuration: quakes) == nil, "validate both coordinates")
        quakes.longitude = 0
        quakes.latitude = .nan
        check(flexible.add(.weather, configuration: quakes) == nil, "NaN is not a latitude")

        for metric in OverviewMetric.allCases {
            var config = OverviewWidgetConfig()
            config.metric = metric
            let id = flexible.add(.metric, configuration: config)!
            check(flexible.entries.first(where: { $0.id == id })?.configuration.metric == metric,
                  "available metric \(metric.rawValue)")
        }
        var progress = OverviewWidgetConfig()
        progress.title = "Backups"
        progress.unit = "GB"
        progress.current = 124
        let goal = flexible.add(.progress, configuration: progress)!
        check(flexible.entries.last?.configuration.current == 124, "a goal can exceed its target")
        progress.target = 0
        check(!flexible.configure(goal, configuration: progress), "reject zero target")
        progress.target = 100
        progress.current = .infinity
        check(!flexible.configure(goal, configuration: progress), "reject nonfinite amounts")
        progress.current = -1
        check(!flexible.configure(goal, configuration: progress), "reject negative progress")
        progress.progressSource = .nodes
        check(flexible.configure(goal, configuration: progress), "source-bound goal uses collector values")
        demo.save(flexible)
        let restored = demo.load()
        check(restored == flexible, "the complete mixed layout round trips")
        let progressEntry = restored.entries.first { $0.id == goal }!
        check(progressEntry.configuration.unit == "" && progressEntry.configuration.current == 0,
              "switching source clears inactive manual fields")
        flexible.remove(coastal)
        check(flexible.entries.contains { $0.id == inland }, "removal uses the instance ID")

        var custom = CustomWidgetSpec()
        custom.style = .number
        custom.title = "Sensor"
        custom.manualInput = "21"
        check(flexible.add(.custom, configuration: .init()) == nil, "custom widgets require a spec")
        let sensor = flexible.add(.custom, configuration: .init(custom: custom))!
        var other = custom
        other.style = .list
        other.title = "Shopping"
        other.manualInput = "Milk\nBread"
        let shopping = flexible.add(.custom, configuration: .init(custom: other))!
        check(sensor != shopping, "custom widgets have independent instance IDs")
        custom.source = .endpoint
        custom.endpoint = "https://example.invalid/room"
        custom.pointer = "/sensor/temp"
        check(flexible.configure(sensor, configuration: .init(custom: custom)), "switch to a mapped endpoint")
        flexible.resize(sensor, to: .wide)
        flexible.move(shopping, to: 0)
        demo.save(flexible)
        let cards = demo.load()
        let reading = cards.entries.first { $0.id == sensor }!
        check(reading.size == .wide && reading.configuration.custom?.pointer == "/sensor/temp", "mapping and size survive")
        check(cards.entries.first?.id == shopping && cards.entries.first?.configuration.custom?.manualInput == other.manualInput,
              "reordering and editing leave the second custom widget intact")
        var customDoc = try JSONSerialization.jsonObject(with: defaults.data(forKey: demoKey)!) as! [String: Any]
        var customEntries = customDoc["widgets"] as! [[String: Any]]
        let index = customEntries.firstIndex { $0["id"] as? String == sensor }!
        var sourceOptions = customEntries[index]["options"] as! [String: Any]
        check(sourceOptions["manualInput"] == nil, "saved endpoint excludes obsolete manual payload")
        sourceOptions["futureHint"] = "preserve"
        customEntries[index]["options"] = sourceOptions
        var futureStyle = sourceOptions
        futureStyle["style"] = "future-viz"
        customEntries.append(["id": "future-style", "type": "custom", "options": futureStyle])
        customDoc["widgets"] = customEntries
        defaults.set(try JSONSerialization.data(withJSONObject: customDoc), forKey: demoKey)
        var customFuture = demo.load()
        check(customFuture.entries.last?.widget == nil, "unknown displays stay recoverable")
        custom.title = "Room sensor"
        check(customFuture.configure(sensor, configuration: .init(custom: custom)), "rename a mapped custom widget")
        demo.save(customFuture)
        let preserved = try JSONSerialization.jsonObject(with: defaults.data(forKey: demoKey)!) as! [String: Any]
        let savedEntries = preserved["widgets"] as! [[String: Any]]
        check((savedEntries[index]["options"] as? [String: Any])?["futureHint"] as? String == "preserve",
              "edits retain unknown source settings")
        check(NSDictionary(dictionary: savedEntries.last!).isEqual(to: customEntries.last!),
              "future custom styles round trip without modification")

        let compatible = Data(#"{"version":4,"widgets":[{"id":"w","type":"weather","options":{"place":"Sample","latitude":35,"longitude":-120,"celsius":false,"providerOptions":{"model":"v3"}},"extension":[1,2]},{"id":"m","type":"metric","options":{"metric":"unknown-v3","title":"Test"}}]}"#.utf8)
        defaults.set(compatible, forKey: demoKey)
        var newer = demo.load()
        check(newer.entries.first?.widget == .weather && newer.entries.last?.widget == nil,
              "unrecognized source keeps a recoverable placeholder instead of showing a different reading")
        var existing = newer.entries[0].configuration
        existing.celsius = true
        check(newer.configure("w", configuration: existing), "editable future metadata")
        demo.save(newer)
        let compatibleDoc = try JSONSerialization.jsonObject(with: defaults.data(forKey: demoKey)!) as! [String: Any]
        let compatibleEntries = compatibleDoc["widgets"] as! [[String: Any]]
        let options = compatibleEntries[0]["options"] as! [String: Any]
        check(options["celsius"] as? Bool == true && (options["providerOptions"] as? [String: String])?["model"] == "v3"
              && compatibleEntries[0]["extension"] as? [Int] == [1,2], "unknown fields survive a config edit")
        let knownSource = compatibleEntries[1]["options"] as! [String: Any]
        check(knownSource["metric"] as? String == "unknown-v3", "unsupported metric options survive save")

        for invalid in ["{bad", "{}", #"{"version":1,"widgets":"broken"}"#,
                        #"{"version":1,"widgets":[null,{}]}"#] {
            let data = Data(invalid.utf8)
            defaults.set(data, forKey: demoKey)
            check(demo.load() == initial, "invalid layout recovers to defaults")
            check(defaults.data(forKey: demoKey) == data, "reading invalid data does not write preferences")
        }
        defaults.set(Data(#"{"version":1,"widgets":[{"id":"nodes"},null,{"id":"nodes"},{"id":"pihole"}]}"#.utf8),
                     forKey: demoKey)
        check(demo.load().entries.map(\.id) == ["nodes", "pihole"], "recover valid unique entries")
        var empty = initial
        for entry in initial.entries { empty.remove(entry.id) }
        demo.save(empty)
        check(demo.load().entries.isEmpty, "saved empty differs from missing preference")
        defaults.synchronize() // publish this disposable suite before opening a second test process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = ["check-empty", suite, demoKey]
        try process.run()
        process.waitUntilExit()
        check(process.terminationStatus == 0, "layout was reloaded by another process")
        demo.save(.standard)
        check(demo.load() == initial, "save the restored original layout")
        print("Overview layout and profile persistence checks passed.")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
