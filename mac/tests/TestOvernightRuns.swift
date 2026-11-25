import Foundation

@main
struct TestOvernightRuns {
    static func main() throws {
        let decoder = MailJSON.decoder
        let oldJob = try decoder.decode(JarvisJob.self, from: Data(#"""
        {"id":"2026-11-22-0615-1111","status":"done","result":"Read https://example.org/report."}
        """#.utf8))
        let legacy = OvernightRun.legacy(oldJob)
        precondition(legacy.status == "done" && legacy.fromJobList)
        let plan = try decoder.decode(OvernightRun.self, from: Data(#"""
        {"id":"plan-a","title":"Plan overnight tasks","status":"done","created_at":"","updated_at":"",
         "kind":"intake","run_at":"2026-11-25T09:00:00Z","children":[
         {"id":"task-a","title":"Research internships","status":"scheduled","created_at":"","updated_at":"",
          "parent_id":"plan-a","run_at":"2026-11-25T09:00:00Z"}]}
        """#.utf8))
        precondition(plan.statusLabel == "Plan ready" && plan.children?.first?.parentId == plan.id)
        precondition(plan.children?.first?.runAt == plan.runAt && plan.children?.first?.statusLabel == "Scheduled")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let iso = ISO8601DateFormatter()
        let beforeOne = iso.date(from: "2026-11-24T08:59:00Z")!
        let afterOne = iso.date(from: "2026-11-24T09:01:00Z")!
        precondition(iso.string(from: OvernightIntake.nextStart(after: beforeOne, calendar: calendar)) == "2026-11-24T09:00:00Z")
        precondition(iso.string(from: OvernightIntake.nextStart(after: afterOne, calendar: calendar)) == "2026-11-25T09:00:00Z")
        precondition(legacy.sources?.first?.url == "https://example.org/report")
        let page = try decoder.decode(OvernightRunPage.self, from: Data(#"""
        {"runs":[{"id":"run-a","title":"Task","status":"done","created_at":"2026-11-22","updated_at":"2026-11-23"}],"next_cursor":"run-a"}
        """#.utf8))
        precondition(page.runs.count == 1 && page.nextCursor == "run-a" && !page.legacy)
        let run = try decoder.decode(OvernightRun.self, from: Data(#"""
        {"id":"run-a","title":"Task","status":"done","created_at":"","updated_at":"",
         "markdown":"[Source](notes/one.md)","sources":[],"files":[
           {"id":"a","label":"Source","path":"notes/one.md"},
           {"id":"b","label":"Draft","path":"files/tailored résumé.docx"}
         ]}
        """#.utf8))
        let source = run.linkedFile("notes/one.md#section", from: nil)
        precondition(source?.id == "a")
        precondition(run.linkedFile("../files/tailored%20r%C3%A9sum%C3%A9.docx", from: source)?.id == "b")
        for link in ["/notes/one.md", "../notes/one.md", "file:///notes/one.md", "//external/notes/one.md", "missing.md"] {
            precondition(run.linkedFile(link, from: nil) == nil)
        }
        for key in ["../file", ".", "bad?key", "", "a\\b"] { precondition(!OvernightRun.validID(key)) }
        precondition(OvernightRun.validID("2026-11-22-0615-1111"))
        precondition(OvernightRun.webLink("https://example.org") != nil)
        precondition(OvernightRun.webLink("file:///tmp/f") == nil)
        print("Overnight run compatibility and file-link checks passed.")
    }
}
