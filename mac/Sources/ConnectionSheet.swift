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

    private var candidate: Connection {
        Connection(mode: mode, baseURL: baseURL, token: token)
    }

    private var canConnect: Bool { candidate.url?.host != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connection")
                .font(FocusInk.heading(20))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)

            ScrollView {
                form.padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: mode == .demo ? 96 : 252)
            Divider()
            HStack {
                if mode == .live {
                    Button("Test connection") { Task { await test() } }
                        .disabled(probing || !canConnect)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.apply(candidate)
                    dismiss()
                }
                .disabled(mode == .live && !canConnect)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
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

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Connection mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(Face.body)

            Note(text: mode == .demo
                 ? "Explore Charon with sample data on this Mac."
                 : "Read data and run actions through your collector.",
                 top: 10)

            if mode == .live {
                field("Collector address", text: $baseURL, secure: false)
                    .padding(.top, 10)

                field("Collector token", text: $token, secure: true)
                    .padding(.top, 8)

                Note(text: TokenStore.keychainRefused
                     ? "Keychain is unavailable. Credentials last for this session."
                     : "Credentials are stored in Keychain.")

                if let probe {
                    Text(probe).font(.callout).foregroundStyle(HT.inkMid)
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.medium)).foregroundStyle(M.inkMid)
            Group {
                if secure {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .accessibilityLabel(label)
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
        guard canConnect, let url = candidate.url else {
            probe = "Enter a valid collector address."
            return
        }
        let client = LiveClient(baseURL: url, token: token)
        probing = true
        probe = "Testing connection…"
        let result = await client.probe()
        probing = false
        switch result {
        case .ok: probe = "Connected to the collector."
        case .unauthorized: probe = "The collector refused the token."
        case .unreachable(let why): probe = "unreachable · \(why)"
        }
    }
}
