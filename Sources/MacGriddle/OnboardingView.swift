// Sources/MacGriddle/OnboardingView.swift
//
// One SwiftUI view switching on OnboardingStage, per
// composition-root-wiring-fixups.md §3. Kept deliberately plain — no
// custom styling beyond what's needed to read clearly during onboarding.

import SwiftUI

import Permissions

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch viewModel.stage {
            case .welcome:
                welcomeContent
            case .requestingAccessibility:
                permissionContent(
                    title: "Accessibility Access",
                    message: "MacGriddle needs Accessibility access so it can see and move other apps' windows.",
                    buttonTitle: "Grant Accessibility Access…",
                    requestAction: viewModel.requestAccessibility,
                    openSettingsAction: viewModel.openAccessibilitySettings
                )
            case .requestingInputMonitoring:
                permissionContent(
                    title: "Input Monitoring Access",
                    message: "MacGriddle needs Input Monitoring access so it can notice when you hold Option while dragging.",
                    buttonTitle: "Grant Input Monitoring Access…",
                    requestAction: viewModel.requestInputMonitoring,
                    openSettingsAction: viewModel.openInputMonitoringSettings
                )
            case .readyToUse:
                readyContent
            case .degraded(let missing):
                degradedContent(missing: missing)
            }
        }
        .padding(32)
        .frame(minWidth: 440, minHeight: 300, alignment: .topLeading)
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Welcome to MacGriddle")
                .font(.title2).bold()
            Text("MacGriddle needs two separate permissions to work: Accessibility, so it can see and "
                 + "move other apps' windows, and Input Monitoring, so it can notice when you hold "
                 + "Option while dragging.")
                .foregroundStyle(.secondary)
            Button("Get Started") {
                viewModel.start()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("You're All Set")
                .font(.title2).bold()
            Text("Both permissions are granted. MacGriddle is now running from the menu bar.")
                .foregroundStyle(.secondary)
        }
    }

    private func permissionContent(
        title: String,
        message: String,
        buttonTitle: String,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2).bold()
            Text(message)
                .foregroundStyle(.secondary)
            permissionRow(
                buttonTitle: buttonTitle,
                requestAction: requestAction,
                openSettingsAction: openSettingsAction
            )
        }
    }

    private func degradedContent(missing: MissingPermission) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("MacGriddle Needs Attention")
                .font(.title2).bold()
            Text("MacGriddle lost access to a permission it needs — its grid gesture won't work until "
                 + "you re-grant it.")
                .foregroundStyle(.secondary)

            if missing == .accessibility || missing == .both {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility Access").font(.headline)
                    permissionRow(
                        buttonTitle: "Grant Accessibility Access…",
                        requestAction: viewModel.requestAccessibility,
                        openSettingsAction: viewModel.openAccessibilitySettings
                    )
                }
            }

            if missing == .inputMonitoring || missing == .both {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input Monitoring Access").font(.headline)
                    permissionRow(
                        buttonTitle: "Grant Input Monitoring Access…",
                        requestAction: viewModel.requestInputMonitoring,
                        openSettingsAction: viewModel.openInputMonitoringSettings
                    )
                }
            }
        }
    }

    private func permissionRow(
        buttonTitle: String,
        requestAction: @escaping () -> Void,
        openSettingsAction: @escaping () -> Void
    ) -> some View {
        HStack {
            Button(buttonTitle, action: requestAction)
            Button("Open System Settings", action: openSettingsAction)
                .buttonStyle(.link)
        }
    }
}
