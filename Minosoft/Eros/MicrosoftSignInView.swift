import SwiftUI
import UIKit

/// The device-code sheet: Microsoft prints a short code, the player confirms
/// it in the browser, and the app picks up the tokens that follow.
struct MicrosoftSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var accounts = AccountStore.shared

    @State private var deviceCode: AuthDeviceCode?
    @State private var failure: String?
    @State private var copied = false
    @State private var isRunning = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let deviceCode {
                    Text("Enter this code at \(host(of: deviceCode))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(deviceCode.userCode)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = deviceCode.userCode
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            openURL(deviceCode.verificationURI)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ProgressView("Waiting for you to finish signing in…")
                        .padding(.top, 8)
                } else if failure == nil {
                    ProgressView("Contacting Microsoft…")
                }

                if let message = failure {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Try again") {
                        failure = nil
                        copied = false
                        deviceCode = nil
                        attempt += 1
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .navigationTitle("Microsoft sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: attempt) {
                await signIn()
            }
        }
    }

    private func host(of code: AuthDeviceCode) -> String {
        code.verificationURI.host ?? "microsoft.com/link"
    }

    private func signIn() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            let account = try await MicrosoftAuth.signIn { code in
                Task { @MainActor in
                    deviceCode = code
                }
            }
            accounts.update(account)
            dismiss()
        } catch is CancellationError {
            // The sheet went away while the code was still waiting.
        } catch {
            failure = error.localizedDescription
        }
    }
}
