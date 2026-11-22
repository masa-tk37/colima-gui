# Project Conventions

- Before adding a file or an import across `ColimaKit` targets, read `.kiro/steering/tech.md` and `structure.md`: they hold the architecture, target dependency rules, and the test and build commands.
- When creating or updating the Xcode project (`ColimaGUI.xcodeproj/project.xcproj`), `ColimaKit/Package.swift`, or any build setting, use the current Xcode's recommended values and template defaults. Deviate only where `.kiro/specs/colima-gui/design.md` requires it, and record each deviation here:
  - `ENABLE_APP_SANDBOX = NO`: the app runs `/opt/homebrew/bin/colima` and connects to `~/.colima/default/docker.sock`.
  - `SWIFT_VERSION = 6.0` (ColimaGUI and ColimaGUIAgent): the design relies on Swift 6 strict concurrency checking (the Xcode 27.2 templates set 5.0).
  - ColimaGUIAgent has no man-page copy phase: the Command Line Tool template adds an empty one, and the agent ships no man page.
  - ColimaGUI `INFOPLIST_KEY_LSUIElement = YES`: the app shows a Dock icon only while a regular window is open, and a login-item launch starts in the menu bar only.
  - ColimaGUIAgent `PRODUCT_BUNDLE_IDENTIFIER = cc.tk37.ColimaGUI.agent`, `GENERATE_INFOPLIST_FILE = YES`, `CREATE_INFOPLIST_SECTION_IN_BINARY = YES`: the embedded Info.plist fixes the agent's code-signing identifier, which the app's XPC peer requirement names.
  - ColimaGUIAgent `SKIP_INSTALL = YES`: the tool ships only inside the app bundle.
  - ColimaGUI depends on ColimaGUIAgent and has two copy phases: the agent into `Contents/MacOS` (code sign on copy) and `LaunchAgents/cc.tk37.ColimaGUI.agent.plist` into `Contents/Library/LaunchAgents`, where `SMAppService.agent(plistName:)` looks for it.

# Localization

- When a package view passes a user-facing string, use `Text("…", bundle: #bundle)` or `LocalizedStringResource("…", bundle: #bundle)`: a bare literal is looked up in the app's main bundle and loses its translation.
- When you add or change a user-facing string, run `ColimaKit/Scripts/sync-string-catalogs.sh`, then add the Japanese translation: neither SwiftPM nor xcodebuild writes new keys into the catalogs, and `LocalizationCatalogTests` fails on a missing translation.
