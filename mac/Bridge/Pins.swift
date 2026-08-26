import Foundation

/* The helper this build will run, and nothing else.
 *
 * imsg is the only thing on this Mac that reads chat.db and the only thing
 * that sends through Messages, so it is pinned by version and by digest: one
 * release asset, one executable, both hashed before anything is run. The
 * directory it lands in is inside the user's own Application Support and is
 * therefore writable by anything the user runs, which is why the executable is
 * hashed again at every spawn and not only at install.
 *
 * Recorded 2026-08-21 from the release asset itself:
 *   curl -L -o imsg-macos.zip \
 *     https://github.com/openclaw/imsg/releases/download/v0.14.1/imsg-macos.zip
 *   shasum -a 256 imsg-macos.zip     # archive, 3 841 443 bytes
 *   ditto -x -k imsg-macos.zip out && shasum -a 256 out/imsg
 */
enum Pins {

    static let version = "0.14.1"

    static let archiveURL = URL(
        string: "https://github.com/openclaw/imsg/releases/download/v0.14.1/imsg-macos.zip")!

    /// SHA-256 of the release asset `imsg-macos.zip` as downloaded.
    static let archiveDigest = "04f82882cf0ef56b9d677b0c1fcd8b7d6fa9b62c51c468c22566ceeac2379864"

    /// SHA-256 of the `imsg` executable inside that archive.
    static let executableDigest = "5377aa4e8ae89a8650ec664af96893aaf3d577a646bb3873871d999960b816c1"

    /// The most that archive may weigh before we stop reading it.
    static let archiveLimit = 64 * 1024 * 1024

    /// imsg's licence, kept beside the binary because a copy of somebody
    /// else's work travels with the terms it was given under.
    static let license = """
        MIT License

        Copyright (c) 2026 Peter Steinberger

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.

        """
}
