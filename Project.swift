import ProjectDescription

let deploymentTarget: DeploymentTargets = .macOS("26.0")

let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual",
    // Without a Developer ID there's no notarization to need it, and its library validation would refuse
    // Sparkle.framework, which keeps Sparkle's own signature.
    "ENABLE_HARDENED_RUNTIME": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    // Release builds get 0.1.<commit count> and <commit count> from scripts/release.sh.
    "MARKETING_VERSION": "0.1.0",
    "CURRENT_PROJECT_VERSION": "1",
]

let project = Project(
    name: "DevInbox",
    options: .options(
        automaticSchemesOptions: .disabled,
        developmentRegion: "en"
    ),
    packages: [
        // Exact, because Package.resolved isn't tracked and scripts/release.sh signs with this version's tools.
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.10.0")),
    ],
    settings: .settings(base: baseSettings),
    targets: [
        .target(
            name: "DevInbox",
            destinations: .macOS,
            product: .app,
            bundleId: "eu.forml.DevInbox",
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "DevInbox",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSUIElement": true,
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSHumanReadableCopyright": "© 2026 Yasin",
                // Each release uploads an appcast with only itself; GitHub redirects to the newest one.
                "SUFeedURL": "https://github.com/YYYasin19/DevInbox/releases/latest/download/appcast.xml",
                "SUPublicEDKey": "97vnyhTpuqH0dBGJrPObGgHApSblTLc0Hamof/e+nbg=",
                "SUVerifyUpdateBeforeExtraction": true,
                "SUEnableAutomaticChecks": true,
                "SUAutomaticallyUpdate": true,
                "SUScheduledCheckInterval": 3600,
            ]),
            sources: ["DevInbox/Sources/**"],
            resources: ["DevInbox/Resources/**"],
            dependencies: [.package(product: "Sparkle")]
        ),
        .target(
            name: "DevInboxTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "eu.forml.DevInboxTests",
            deploymentTargets: deploymentTarget,
            infoPlist: .default,
            sources: ["DevInbox/Tests/**/*.swift"],
            resources: ["DevInbox/Tests/Fixtures/**"],
            dependencies: [.target(name: "DevInbox")]
        ),
    ],
    schemes: [
        .scheme(
            name: "DevInbox",
            shared: true,
            buildAction: .buildAction(targets: ["DevInbox"]),
            testAction: .targets(["DevInboxTests"]),
            runAction: .runAction(executable: "DevInbox")
        ),
    ]
)
