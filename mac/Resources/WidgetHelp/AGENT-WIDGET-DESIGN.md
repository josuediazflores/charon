# Designing a Charon Overview widget

Start with the question the card should answer. For “How full is the water tank?”, a gauge needs a current volume, a capacity and a unit. Ask for a small sanitized sample if the source format is unclear. A user or an agent can build this widget entirely in Charon.

## Choose a display

- **Number** shows one reading, such as 18.4 °C. **Progress bar** shows work toward a target. **Gauge** shows the current level against a scale. All three accept one finite JSON number. Supply the unit separately and give bars and gauges a positive target.
- **Status** shows a short state such as “Pump running”. Use text or a Boolean. **Trend** shows change over time. Supply an array of 2 to 256 numbers, oldest first.
- **List** shows up to 64 items in order. Supply an array of strings, numbers or Booleans. **Key and value** shows up to 64 named readings. Supply an object whose values are strings, numbers or Booleans.

## Try a working example

Open **Overview → Edit Overview → Add Widget → Custom widget → Gauge → Choose data source**. Select **Paste JSON**, paste the sample and click **Find fields**.

```json
{
  "tank": {
    "liters": 42,
    "history": [36, 39, 42]
  }
}
```

Choose **tank › liters**, then **Preview**. Enter **Tank level** for the title, **80** for the target and **L** for the unit. The gauge should read **42 L** on a scale of **0 to 80 L**. Choose **Add widget → Save**. To chart the same tank, add a second widget using **Trend** and **tank › history**.

**Enter values** supports hand entry. **Paste JSON** saves an editable snapshot of the selected field. For a refreshable reading, select **Connect a JSON URL**, enter a final read-only URL reachable from the Mac, then click **Test URL** and choose the field. The picker follows named object fields and offers whole arrays for lists and trends. Use a stable field name such as `liters` across refreshes. Remote URLs require HTTPS. Local HTTP works for supported private addresses and local hostnames. Keep responses within 512 KiB and credentials out of the URL. If a service requires authentication, an exported sample works with Paste JSON.

## Design the card

Give the card a title that names the measurement. Put the unit beside its value and use a target the user can explain. Reserve color for meaning and include the state in text so the card works without color. Keep the main reading visible at compact width. Use the same title, unit and scale in the preview and the saved card.

For a connected source, distinguish an empty collection, a missing field and a failed request. Show the time of the last successful reading when retaining a value. Replacing a missing reading with zero would make a disconnected tank look empty.

## Add a display or data source in Swift

These files live under `Sources/Console/` in the Mac project. In the public repository, start in `mac/`.

1. **Define the value.** In `CustomWidgetData.swift`, add the display to `CustomWidgetStyle` with a stable raw value and a user-facing title. Reuse a `CustomWidgetValue` case when the data shape fits. Update manual parsing, JSON mapping and snapshot conversion together so the same reading works through all three inputs.
2. **Make it discoverable.** In `CustomWidgetSetup.swift`, add its miniature to `WidgetStyleSample`, provide a manual example and explain which JSON fields fit. Expose the title, unit or target where applicable. Keep the gallery's accessibility identifier pattern `custom.setup.type.<rawValue>`.
3. **Render one card.** Extend `CustomWidgetReading` in `CustomWidgetView.swift`. The builder preview and saved card share it. Use `Panel`, the existing `HT` fonts and colors, and controls from `Sources/Kit/`. Give charts an accessible label and value. Keep numbers, units and status readable at compact width.
4. **Connect a new provider when needed.** If its output already fits the JSON picker, document the field selection. For a new transport, extend `CustomWidgetSource` and `CustomWidgetSpec`, add an explicit test action in setup, and map the response into the same typed value. Follow `CustomEndpointCard` for cancellation, last successful reading, checked time and retry. Preserve explicit refresh in Demo and keep live reads out of the layout editor.
5. **Preserve saved layouts.** Each custom card has an instance ID. `OverviewLayout.swift` stores its options per Mac profile. Encode only active source settings, retain unknown options and allow future unsupported cards to round-trip. Add a display through the existing custom entry so it inherits move, resize, remove and edit.

## Verify

Run the regression checks from the Mac project directory.

```sh
sh tests/run-custom-widget-data.sh
sh tests/run-overview-layout.sh
sh tests/run-overview-feeds.sh
```

Check the new display with manual and JSON data, a missing or incompatible field, and an empty response. In Charon, add two copies, resize one, save, reopen and edit it. Check keyboard navigation and the spoken label and value. For a live source, test a successful refresh, a failed refresh that retains the last reading, and recovery with **Retry**. Update the bundled setup guide when controls or accepted formats change. [Widget setup guide](AGENTS.md)
