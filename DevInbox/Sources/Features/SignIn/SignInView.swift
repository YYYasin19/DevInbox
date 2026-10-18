import SwiftUI

/// Shown until DevInbox can borrow the GitHub CLI's login.
struct SignInView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            IconView(icon: .inbox, size: 44)
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("DevInbox").font(.title.bold())
                Text("GitHub notifications, reviews and your pull requests.")
                    .foregroundStyle(.secondary)
            }

            switch model.auth {
            case .checking, .signedIn:
                ProgressView("Looking for your GitHub CLI login…").controlSize(.small)
            case .signedOut(let reason):
                SignInInstructions(reason: reason, model: model)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Quit DevInbox") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .tooltip("Quit DevInbox")
                    .font(.caption)
            }
            .padding(12)
        }
    }

}

struct SignInInstructions: View {
    let reason: GitHubCLI.TokenError
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            switch reason {
            case .notInstalled:
                Text("DevInbox uses the login of the GitHub CLI. Install it and log in:")
                    .multilineTextAlignment(.center)
                CommandRow(command: GitHubCLI.installCommand, model: model)
                CommandRow(command: GitHubCLI.loginCommand, model: model)
            case .notLoggedIn:
                Text("DevInbox uses the login of the GitHub CLI. Log in once in Terminal:")
                    .multilineTextAlignment(.center)
                CommandRow(command: GitHubCLI.loginCommand, model: model)
            case .failed(let message):
                Text(LocalizedStringKey(message))
                    .foregroundStyle(Tone.failure.foreground)
                    .multilineTextAlignment(.center)
            }

            Button("Check Again") { model.connect() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .tooltip("Read the GitHub CLI's login again")
        }
        .padding(.horizontal, 32)
    }
}

private struct CommandRow: View {
    let command: String
    let model: AppModel

    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            // Fixed width, and back to "Copy" after a moment, so the button never jumps.
            Button {
                model.copyToPasteboard(command)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                HStack(spacing: 4) {
                    IconView(icon: copied ? .check : .copy, size: 12)
                    Text(copied ? "Copied" : "Copy")
                }
                    .frame(minWidth: 64)
            }
            .controlSize(.small)
            .focusable(false)
            .tooltip("Copy the command, then paste it into Terminal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Fill.hover))
        .frame(maxWidth: 300)
    }
}
