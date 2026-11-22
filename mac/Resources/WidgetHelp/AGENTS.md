# Helping with Charon Overview widgets

When someone asks for setup help, identify what they want to measure and where the value comes from. Use the widget named in their request if it fits. Ask only for missing details, then give the exact clicks and field values. Keep credentials in Charon.

For agents designing a card or adding a new Swift display, see the [widget design guide](AGENT-WIDGET-DESIGN.md). A [public copy](https://github.com/josuediazflores/charon/blob/main/mac/Resources/WidgetHelp/AGENT-WIDGET-DESIGN.md) is available when working from copied setup instructions.

## Setup workflow

Open **Overview → Edit Overview → Add Widget**. Pick a card under **Presets**, complete its form and click **Add**. Click **Save** in Overview to keep it. To change a card, use **Edit Overview → Setup** on that card, then **Apply → Save**. Each configurable widget supports multiple copies. **Restore a widget** brings back a removed built-in card.

Layouts are local to this Mac and separate for Demo and each collector connection. Check **Settings → Connection** if the user sees sample data or a different layout.

## Custom widget

Choose **Custom widget**, pick a display, then click **Choose data source**. All seven displays support your own data.

- **Number**, **Progress bar** and **Gauge** take one number. Give a bar or gauge a positive target to set its scale.
- **Status** shows a short label. **Trend** plots a sequence of numbers in the order supplied.
- **List** shows items on separate lines. **Key and value** shows named readings such as temperature and humidity.

Choose how to supply the values:

- **Enter values** accepts a number, a status, comma-separated trend samples, one list item per line, or one `key=value` pair per line. To update a saved value, open the card’s **Setup** in Edit Overview.
- **Paste JSON** imports a snapshot. Paste the response, click **Find fields** and select the field you want. Charon saves that value as an editable manual card. The source document stays out of the layout.
- **Connect a JSON URL** links a read-only feed. Enter the final URL, click **Test URL**, then select a compatible **Data field**. For example, a Pi returning `{"room":{"temperature":21.5,"history":[20,21,21.5]}}` can power a Number from `room.temperature` or a Trend from `room.history`. Respond with an array of samples for a trend. Charon stores the selected path and asks for that same field on later reads.

Click **Preview**, name the widget, set its unit or target if applicable, then click **Add widget → Save**. While editing, **Apply → Save** replaces the existing configuration. The preview uses the mapped value and the same card renderer as Overview.

A URL must work from the user's Mac without cookies, a token or custom headers. Use HTTPS for remote sources. Plain HTTP also works for supported local addresses, including a Pi on a private IPv4 address or a `.local` hostname. Enter a URL free of secrets. Responses are limited to 512 KiB. A saved Live card reads when first shown while active and on **Refresh**. In Demo, **Test URL** and **Refresh** are explicit reads. If the field changes shape, **Setup → Test URL** lets the user choose it again.

For agent assistance, ask for a small sanitized example of the JSON and which reading the user wants. Identify the display, source mode and field to select. If the API requires credentials, suggest importing a sanitized snapshot or connecting a keyless endpoint the user already controls. **Copy setup request** includes instructions and the display/source choice, and omits the address and entered values.

## Presets

- **Weather forecast** shows five hourly periods from the U.S. National Weather Service. Ask for the town and temperature unit. In Live mode, type the town, click **Find** and select an Apple Maps result. Alternatively, choose **Enter coordinates** and supply a name, latitude and longitude. NWS receives the selected coordinates. Demo uses a sample location.
- **Recent earthquakes** shows up to five recorded USGS events from the past 24 hours. Choose a center the same way, then set **Radius (km)** and **Minimum magnitude**. Charon filters reports locally. If the user wants a warning before shaking starts, explain that this card shows events already reported.
- **Metric with sparkline** provides a **Reading** picker with **Connected nodes**, **Pi-hole block rate**, **Requests blocked today**, **Collector load (1 min)** and **Collector temperature**. The display name is optional. Keep Overview open for two fresh readings to start the trend.
- **Progress bar** offers **Connected nodes**, **Pi-hole block rate** and **Manual goal** under **Measure**. For a 2 TB backup with 0.5 TB copied, choose **Manual goal**, name it “Backup”, enter `0.5` for **Current**, `2` for **Target** and `TB` for **Unit**. After saving, use **Update** on the card to record progress.

## Troubleshooting

If **Add** is disabled, check the form message. A place search requires selecting a result. A manual goal needs a name, a nonnegative current value and a positive target. For a live feed, leave the editor with **Save**, check the **Checked** time and use **Refresh** or **Retry**. For missing collector readings, check the source in **Hardware**.

If a preset lacks the requested reading, use **Custom widget** for manual, pasted or keyless JSON data. For backup progress, identify the completed amount, target and unit before choosing a progress bar.
