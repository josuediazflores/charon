import Foundation

/* ── Earth's land mask ─────────────────────────────────────────────────
   256x128 equirectangular, one bit per cell -- ported verbatim from the
   design system's globe land mask.

   Rasterised there from Natural Earth's 110m land polygons (ne_110m_land),
   which are explicitly public domain: no attribution required, and none of the
   copyleft that porting an existing ASCII-globe implementation would have
   carried in. This is geography, not somebody's texture.

   Packed to bits and base64'd: 32,768 cells would be 32 KB as characters and
   are 5.5 KB this way.
*/

enum LandMask {

    static let width = 256
    static let height = 128

    private static let base64 =
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP//w" +
        "Cf/wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA7//3/////8AAAAAAAQAAAAOAAAAAAAAAAAAAAA" +
        "AAAAD//wf////+AAAPyAAAAAAAA+AAAAAAAAAAAAAAAAAMCwH4//////wAAAeYAAAAAAAAEAAAAA" +
        "AAAAAAAAAAB4IB7/A/////+AAAAAAAAAAYAAAPYAAAAAAAAAAAAAAA/42/4AA////8AAAAAAAADw" +
        "AAH//4AAfsAAAAAAAAAA+AAPAAAA////gAAAAAAAA4AAL///AAAAAAAAAAAAAAHv+ej+wAB///0A" +
        "AAAAAAAGAHR/////8B8AAACAAMAAAI/8HH/4AB///wAAAABYAAMB///////7//EAAQAP//C9R/9u" +
        "GH8Ab//+AAAAB/4AABj//////////9h8wD/////+HDecDwA//+AAAAAf//GN/3f////////////8" +
        "D/////////gP8D//AAAAAD//+L//5////////////xh/////////0B8gH/AA/AAA/j+P////////" +
        "////////AAP///////8eD8Af4ADwAAH+//////////////////4AH////////AwDAA/AAAAAD/n/" +
        "/////////////////wA////////4AHgAB8AAAAAP8f///////////////i/gAAfsD/////gAfgAA" +
        "AAAAAA/4D//////////////8MAAAAOAD/////AB/4AAAAAAMDPB/////////////8ABgAAABoAB/" +
        "////AD/wAAAAAAwCcf/////////////gAfAAAAwAAD/////gf/gAAAAABgLB/////////////4AB" +
        "4AAAAAAAH/////j//gAAAABzA9//////////////lAHAAAAAAAAP/////P//AAAAAGef////////" +
        "///////8AYAAAAAAAAf///////4AAAAAB7////////////////QBAAAAAAAAB///////gYAAAAAA" +
        "f///////////////9AAAAAAAAAABf/////7DwAAAAAf////////////////0AAAAAAAAAAD/////" +
        "/8CAAAAAA////+///////////+QAAAAAAAAAAP//////+AAAAAAB///4n8P/////////wAAAAAAA" +
        "AAAA//////9AAAAAAAH/n/Afj/////////+EAAAAAAAAAAH//////AAAAAAAf8DP8AfH////////" +
        "/gwAAAAAAAAAAP/////4AAAAAAA/wmPxx+f////////wAAAAAAAAAAAA/////+AAAAAAAD8CEx//" +
        "5///////+eAIAAAAAAAAAAD/////4AAAAAAAfwARn//j///////wYBgAAAAAAAAAAH/////AAAAA" +
        "AAA+ACEf//P///////4wMAAAAAAAAAAAP////8AAAAAAAAD/AAA/////////+DBwAAAAAAAAAAA/" +
        "////gAAAAAAAH/4AAD/////////4BoAAAAAAAAAAAAf///8AAAAAAAA//wAAf/////////wOAAAA" +
        "AAAAAAAABf///AAAAAAAAH//48B//////////gAAAAAAAAAAAAAA//8cAAAAAAAAf///////////" +
        "///8AAAAAAAAAAAAAAD/8AYAAAAAAAD//////8////////4AAAAAAAAAAAAAA3/gBgAAAAAAAf//" +
        "//9/5////////AAAAAAAAAAAAAAAv+ACAAAAAAAD/////z/4f//////4AAAAAAAAAAAAAACf4ACA" +
        "AAAAAAf/////n/kA//////IAAAAAAAAAAAAAAA/AAAAAAAAAD/////+P/8B/////5AAAAAAAAAAA" +
        "AAAAB+ABgAAAAAAP/////8//wH/+f/8AAAAAAAAAAAAAAAAH4MBgAAAAAA//////z/+AD/w/8gAA" +
        "AAAAAAAAAAAAAAPxwA4AAAAAD//////n/4AP8B/mAAAAAAAAAAAAAAAAAP+AAAAAAAAP/////+P+" +
        "AA/gH/ACAAAAAAAAAAAAAAAAP4AAAAAAAA//////8/gAD8AX+AIAAAAAAAAAAAAAAAAD+AAAAAAA" +
        "D//////54AAHgAP8AAAAAAAAAAAAAAAAAAB4AAAAAAAP//////2AAAeAAvwAAAAAAAAAAAAAAAAA" +
        "ADAAAAAAAA///////gAAA4ACfAAAAAAAAAAAAAAAAAAAGD+4AAAAA//////+8AADgAIwAQAAAAAA" +
        "AAAAAAAAAAANv/gAAAAD///////wAANAAgABQAAAAAAAAAAAAAAAAAL//AAAAAH//////+AAAEAA" +
        "AAHAAAAAAAAAAAAAAAAAAH/+AAAAAP//////4AAAQAGAEIAAAAAAAAAAAAAAAAAAf//gAAAAMg//" +
        "///AAAAADYAwAAAAAAAAAAAAAAAAAAB///AAAAAAAf///8AAAAAGwHAAAAAAAAAAAAAAAAAAAP//" +
        "8AAAAAAB////AAAAAANB8AAAAAAAAAAAAAAAAAAB///wAAAAAAH///4AAAAAA4P3gAAAAAAAAAAA" +
        "AAAAAAH///gAAAAAA////AAAAAABw/ECAAAAAAAAAAAAAAAAA////wAAAAAB///4AAAAAADD5gNg" +
        "AAAAAAAAAAAAAAAB////8AAAAAD///AAAAAAAGBmA/wAAAAAAAAAAAAAAAP////8AAAAAP//8AAA" +
        "AAAAIAUAfwAAAAAAAAAAAAAAA/////4AAAAAf//wAAAAAAAYAAE/ggAAAAAAAAAAAAAB/////gAA" +
        "AAB///AAAAAAAAOAAD+AAAAAAAAAAAAAAAD////+AAAAAH//8AAAAAAAAACABMAgAAAAAAAAAAAA" +
        "AH////wAAAAAP//4AAAAAAAAAAAAAAAAAAAAAAAAAAAAf///+AAAAAA///gAAAAAAAAAAgQAAAAA" +
        "AAAAAAAAAAA////wAAAAAH//+BAAAAAAAAAHhAAAAAAAAAAAAAAAAD////AAAAAAf//4MAAAAAAA" +
        "AG8GAAIAAAAAAAAAAAAAD///8AAAAAD///DgAAAAAAAA/84AAAAAAAAAAAAAAAAH///wAAAAAP//" +
        "4eAAAAAAAAH/7wAAAgAAAAAAAAAAAAP///AAAAAAf/+B4AAAAAAAA///AAAAAAAAAAAAAAAAA///" +
        "4AAAAAB//4HgAAAAAAAP///AAAAAAAAAAAAAAAAD///gAAAAAD//gcAAAAAAAD///8ACAAAAAAAA" +
        "AAAAAAP//4AAAAAAP/+BwAAAAAAAf///4AAAAAAAAAAAAAAAA//8AAAAAAA//4HAAAAAAAB////w" +
        "AAAAAAAAAAAAAAAD//gAAAAAAB/+AAAAAAAAAH////gAAAAAAAAAAAAAAAP/+AAAAAAAH/4AAAAA" +
        "AAAAf///+AAAAAAAAAAAAAAAB//4AAAAAAAP/gAAAAAAAAA////4AAAAAAAAAAAAAAAH//AAAAAA" +
        "AA/8AAAAAAAAAD////gAAAAAAAAAAAAAAAf/4AAAAAAAB/gAAAAAAAAAP/P/+AAAAAAAAAAAAAAA" +
        "B//gAAAAAAAH8AAAAAAAAAA/AP/wAAAAAAAAAAAAAAAH/cAAAAAAAAIAAAAAAAAAADgAv+AAAAAA" +
        "AAAAAAAAAA/+AAAAAAAAAAAAAAAAAAAAAAAf4AAQAAAAAAAAAAAAD/4AAAAAAAAAAAAAAAAAAAAA" +
        "AA/gAAgAAAAAAAAAAAAP/AAAAAAAAAAAAAAAAAAAAAAAAAAADgAAAAAAAAAAAA/wAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAMAAAAAAAAAAAAH8AAAAAAAAAAAAAAAAAAAAAAAAGAADAAAAAAAAAAAAAfwAAA" +
        "AAAAAAAAAAAAAAAAAAAAAIAAYAAAAAAAAAAAAB/AAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAA" +
        "AAAAHwAAAAAAAAAAAAAAAAAAAAAAAAAAA4AAAAAAAAAAAAAfgAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAD+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPwAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAeBgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4AAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAABgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAAAAAAAAAAAAAPgAACAOPh/4AAAAAAAAAAAAAA" +
        "AAAAgAAAAAAAAAAAAP//gH///////4AAAAAAAAAAAAAAAAfgAAAAAAAAAAHv//+B/////////4AA" +
        "AAAAAAAAAAAABvAAAAAAED///////4///////////wAAAAAAAAAA8AAE+AAAAAH/////////////" +
        "////////gAAAAAABYAH//9/4AAAAD/////////////////////4AAAAAH////////8AAAAAf////" +
        "////////////////+AAAAAH////////sAAAAD//////////////////////wAAAA/////////+AA" +
        "AwH///////////////////////gAAAYD////////gAAPgR//////////////////////4AAAAAH/" +
        "///////8ODgA///////////////////////AAAAAH//////////4P///////////////////////" +
        "//AAAAAf/////////////////////////////////////wD/+AA/////////////////////////" +
        "////////////////////////////////////////////////////////////////////////////" +
        "/////////////////////////////////////////////////////////////////w=="

    /// Decoded once, on first ask. 4 KB, so there is nothing to be clever about.
    private static let bits: [UInt8] = {
        guard let data = Data(base64Encoded: base64) else {
            return [UInt8](repeating: 0, count: width * height / 8)
        }
        return [UInt8](data)
    }()

    /// Sample by latitude/longitude in radians. Longitude wraps; latitude
    /// clamps, so the poles stay solid instead of tearing.
    static func isLand(_ latRad: Double, _ lonRad: Double) -> Bool {
        var u = (lonRad / (2 * Double.pi) + 0.5).truncatingRemainder(dividingBy: 1)
        if u < 0 { u += 1 }
        let v = 0.5 - latRad / Double.pi
        let c = min(width - 1, max(0, Int((u * Double(width)).rounded(.down))))
        let r = min(height - 1, max(0, Int((v * Double(height)).rounded(.down))))
        let i = r * width + c
        let byte = i >> 3
        guard byte < bits.count else { return false }
        return (bits[byte] & (0x80 >> UInt8(i & 7))) != 0
    }
}
