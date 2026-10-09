import SwiftUI

/// Modal form for adding a remote dev box. One required field — the SSH target —
/// with everything else left to the user's ~/.ssh/config (ADR-0001).
struct RemoteSettingsWindow: View {
    let relay: RelayConnection
    var onSaved: () -> Void = {}

    @State private var target = ""
    @State private var label = ""
    @State private var password = ""
    @State private var herdrPath = ""
    @State private var testState: TestState = .idle
    @Environment(\.dismiss) private var dismiss

    enum TestState: Equatable {
        case idle
        case running
        case ok(Int)
        case authFailed
        case timeout
        case binaryNotFound(String)
        case sshpassMissing
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Remote").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("SSH Target").font(.caption).foregroundStyle(.secondary)
                TextField("tanglei@example.com or a Host alias", text: $target)
                    .textFieldStyle(.roundedBorder)
                Text("Anything your terminal's `ssh <target>` does — ProxyCommand, keys, config — works here too.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Display Name (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("Work laptop", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Password (optional)").font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $password).textFieldStyle(.roundedBorder)
                Text("Leave empty for key auth. Requires `brew install sshpass` when set.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Remote herdr Path (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("herdr", text: $herdrPath).textFieldStyle(.roundedBorder)
                Text("Full path when herdr is off the non-interactive shell PATH, e.g. /home/me/.local/bin/herdr.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Button("Test Connection") {
                    testState = .running
                    let t = target, hp = herdrPath
                    DispatchQueue.global(qos: .userInitiated).async {
                        // The password goes to the Keychain first so the probe uses it.
                        if !password.isEmpty { KeychainHelper.setPassword(password, for: t) }
                        let result = relay.testConnection(t, herdrPath: hp)
                        DispatchQueue.main.async {
                            switch result {
                            case .ok(let n): testState = .ok(n)
                            case .authFailed: testState = .authFailed
                            case .timeout: testState = .timeout
                            case .binaryNotFound(let b): testState = .binaryNotFound(b)
                            case .sshpassMissing: testState = .sshpassMissing
                            case .failed(let m): testState = .failed(m)
                            }
                        }
                    }
                }
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || testState == .running)

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    relay.addRemote(
                        target.trimmingCharacters(in: .whitespaces),
                        password: password.isEmpty ? nil : password,
                        label: label,
                        herdrPath: herdrPath
                    )
                    onSaved()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }

            testResultView
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            Text("Testing…").font(.caption).foregroundStyle(.secondary)
        case .ok(let n):
            Text("Connected — \(n) agent\(n == 1 ? "" : "s") found").font(.caption).foregroundStyle(.green)
        case .authFailed:
            Text("Auth failed. Run `ssh \(target)` once in a terminal, or set a password (needs sshpass).").font(.caption).foregroundStyle(.red)
        case .timeout:
            Text("Timed out. Check the host and any ProxyCommand in ~/.ssh/config.").font(.caption).foregroundStyle(.red)
        case .binaryNotFound(let bin):
            Text("Connected, but `\(bin)` not found on the remote. Set the full path above.").font(.caption).foregroundStyle(.orange)
        case .sshpassMissing:
            Text("Password set but sshpass is missing: brew install sshpass").font(.caption).foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red)
        }
    }
}
