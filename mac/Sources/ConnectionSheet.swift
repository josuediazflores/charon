import SwiftUI

/* Where this copy of the app is pointed.
 *
 * Demo is the default and is openable anywhere: of everything in this app, a
 * write that reached a real mailbox from a fixture is the one with consequences
 * that cannot be taken back.
 *
 * The token goes to the Keychain and never to preferences. Where the Keychain
 * refuses the process -- an ad-hoc signed sandboxed build has no team prefix on
 * its access group -- the sheet says so rather than pretending it was saved.
 */

struct ConnectionSheet: View {

    let model: MailModel

    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .demo
    @State private var baseURL = Connection.defaultBase
    @State private var token = ""
    @State private var probe: String?
    @State private var probing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon(name: .gear, size: 14).foregroundStyle(M.inkMid)
                Text("CONNECTION")
                    .font(Face.body).tracking(1.1).foregroundStyle(M.inkMid)
                Spacer(minLength: 8)
                IconKey(icon: .close, label: "close") { dismiss() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            Hairline()

            VStack(alignment: .leading, spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .font(Face.body)

                Note(text: mode == .demo
                     ? "A fixture mailbox in this process. Nothing reaches a network."
                     : "The collector on the tailnet. Every request carries the token.",
                     top: 10)

                LabelledRule(text: "collector")

                field("address", text: $baseURL, secure: false)
                    .padding(.top, 10)
                    .disabled(mode == .demo)
                    .opacity(mode == .demo ? 0.5 : 1)

                field("token", text: $token, secure: true)
                    .padding(.top, 8)
                    .disabled(mode == .demo)
                    .opacity(mode == .demo ? 0.5 : 1)

                Note(text: TokenStore.keychainRefused
                     ? "the Keychain refused this build · the token is held for this "
                        + "session only and is never written to preferences"
                     : "stored in the Keychain · never in preferences")

                HStack(spacing: 8) {
                    KeyButton("Test", disabled: mode == .demo || probing) {
                        Task { await test() }
                    }
                    if let probe {
                        Text(probe)
                            .font(Face.body).foregroundStyle(M.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                LabelledRule(text: "behaviour")

                Note(text: "row note on · summary open · after archive: next message. "
                     + "Fixed in this version.", top: 10)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    KeyButton("Cancel", variant: .quiet) { dismiss() }
                    KeyButton("Use this") {
                        model.apply(Connection(mode: mode, baseURL: baseURL, token: token))
                        dismiss()
                    }
                }
                .padding(.top, 18)
            }
            .padding(14)
        }
        .frame(width: 440)
        .background(M.surface)
        .preferredColorScheme(.dark)
        .onAppear {
            mode = model.connection.mode
            baseURL = model.connection.baseURL
            token = model.connection.token
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(Face.body).tracking(0.66).foregroundStyle(M.inkDim)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Face.body)
            .foregroundStyle(M.inkBright)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: M.r, style: .continuous).fill(M.ground))
            .overlay(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .strokeBorder(M.line, lineWidth: 1))
        }
    }

    private func test() async {
        guard let url = Connection(mode: mode, baseURL: baseURL, token: token).url else {
            probe = "not an address"
            return
        }
        probing = true
        probe = "asking..."
        let result = await LiveClient(baseURL: url, token: token).probe()
        probing = false
        switch result {
        case .ok: probe = "ok · the collector answered"
        case .unauthorized: probe = "401 · the token was refused"
        case .unreachable(let why): probe = "unreachable · \(why)"
        }
    }
}
