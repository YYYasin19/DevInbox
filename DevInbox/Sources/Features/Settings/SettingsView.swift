import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section {
                if let session = model.session {
                    HStack(spacing: 10) {
                        AvatarView(url: session.viewer.avatarURL, size: 32)
                        VStack(alignment: .leading) {
                            Text(session.viewer.name ?? session.viewer.login)
                            Text("@\(session.viewer.login) · via GitHub CLI").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reload Login") { model.connect() }
                            .tooltip("Pick up a new GitHub CLI login, e.g. after `gh auth switch`")
                    }
                    LabeledContent("Organization access") {
                        Link("Manage on GitHub…", destination: GitHubCLI.connectionsURL)
                    }
                    .tooltip("Organizations that restrict OAuth apps need to approve the GitHub CLI before their repositories show up.")
                } else {
                    Text("Not connected. DevInbox uses your GitHub CLI login (`gh auth login`).")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("To use a different account, run `gh auth switch`, then click Reload Login.")
            }

            Section {
                // Only user changes register; reverting after a failure must not trigger another attempt.
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
                Picker("Inbox grouping", selection: $settings.inboxGrouping) {
                    ForEach(AppSettings.InboxGrouping.allCases) { Text($0.label).tag($0) }
                }
                Picker("Date format", selection: $settings.dateFormat) {
                    ForEach(DateFormat.allCases) { Text($0.label).tag($0) }
                }
                .tooltip("How dates older than four weeks and exact times in tooltips are written")
            } header: {
                Text("General")
            }

            Section {
                Toggle("Show counts", isOn: $settings.showUnreadCount)
                    .tooltip("Notifications you haven't opened yet and waiting reviews in a pill, instead of just the icon")
                Toggle("Red dot for new review requests", isOn: $settings.showsReviewDot)
                    .tooltip("The dot shows until you open a review request or its notification")
                LabeledContent("Open DevInbox") {
                    ShortcutRecorder(shortcut: $settings.openPanelShortcut, isRecording: $model.isRecordingShortcut)
                }
                .tooltip("Opens the panel from any app, even when the menu bar has no room for DevInbox")
                if model.isShortcutTaken, !model.isRecordingShortcut {
                    Text("Another app already uses this shortcut. Record a different one.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Snoozed and dismissed reviews don't count.")
            }

            Section {
                ForEach(NotificationReason.bannerCandidates, id: \.rawValue) { reason in
                    Toggle(title(for: reason), isOn: Binding(
                        get: { settings.bannerReasons.contains(reason) },
                        set: { enabled in
                            if enabled { settings.bannerReasons.insert(reason) } else { settings.bannerReasons.remove(reason) }
                        }
                    ))
                    .tooltip(reason.explanation)
                }
                Button("Open macOS Notification Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
                .tooltip("Choose how DevInbox banners look, or turn them off, in System Settings")
            } header: {
                Text("Banners")
            } footer: {
                Text("Show a macOS notification for new activity with these reasons. Snoozed threads stay quiet.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .tooltipHost()
    }

    /// Banner settings name the threads, since "Author" or "State change" alone don't say much here.
    private func title(for reason: NotificationReason) -> String {
        switch reason {
        case .author: "Your pull requests and issues"
        case .comment: "Threads you commented on"
        case .stateChange: "Threads you closed or reopened"
        case .ciActivity: "Your workflow runs"
        case .approvalRequested: "Deployment approvals"
        case .subscribed: "Watched repositories"
        default: reason.label
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
