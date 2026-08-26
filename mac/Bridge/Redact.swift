import Foundation

/* The home directory, out of everything this program says.
 *
 * Section 8: every line on the Mac that could carry a path has the home
 * directory redacted. Errors from Foundation, from the helper and from the
 * collector all quote paths, and a log is a file somebody else may end up
 * reading -- so the substitution happens on the way into the log rather than
 * at each of the forty places a path could come from.
 *
 * Message bodies are not redacted here because they are never given to this
 * function: nothing in the Bridge logs a body at all.
 */
func redact(_ text: String) -> String {
    var out = text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path,
                                        with: "~")
    out = out.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    // And the general case, for a path belonging to some other account that
    // arrived in an error string: the account name is the part worth losing.
    out = out.replacingOccurrences(of: "/Users/[^/\\s\"']+",
                                   with: "~",
                                   options: .regularExpression)
    return out
}

extension Error {
    /// What this error is called, with nothing of the disk in it.
    var redacted: String { redact(String(describing: self)) }
}
