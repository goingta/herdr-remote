import SwiftUI

struct SettingsView: View {
    @Environment(RelayConnection.self) private var relay
    @Environment(\.dismiss) private var dismiss
    @State private var manualHost = relay.hostAddress
    @State private var manualToken = relay.token

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle().fill(relay.isConnected ? .green : .red).frame(width: 8, height: 8)
                            Text(relay.isConnected ? "Connected" : "Disconnected")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !relay.hostAddress.isEmpty {
                        HStack {
                            Text("Host")
                            Spacer()
                            Text(relay.hostAddress).foregroundStyle(.secondary).font(.caption)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Section("Manual Connect") {
                    TextField("wss://xxx.trycloudflare.com", text: $manualHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Token (if relay requires one)", text: $manualToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect") {
                        relay.token = manualToken
                        relay.connect(to: manualHost)
                    }
                    .disabled(manualHost.isEmpty)
                }
                Section("Discovery") {
                    Button("Scan for relay (Bonjour)") {
                        relay.startBrowsing()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
