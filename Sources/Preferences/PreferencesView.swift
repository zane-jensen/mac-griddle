import SwiftUI

/// The tabbed settings surface (Grid / Appearance / Behavior / About), with
/// a persistent "Restore Defaults" button pinned below the tabs so it's
/// reachable regardless of which tab is selected. Internal — the only
/// thing outside this target that ever needs to exist is a way to *show*
/// this view in a window, which is `PreferencesWindowController`'s job.
struct PreferencesView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GridSettingsTab()
                    .tabItem { Label("Grid", systemImage: "grid") }

                AppearanceSettingsTab()
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }

                BehaviorSettingsTab()
                    .tabItem { Label("Behavior", systemImage: "gearshape") }

                AboutTab()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .environmentObject(settings)
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    settings.resetToDefaults()
                }
                .padding(12)
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 420)
    }
}

// Tab subviews all read the store via @EnvironmentObject, injected once at
// the TabView level above rather than threaded through every subview's
// initializer.

private struct GridSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Stepper(value: $settings.gridColumns, in: SettingsStore.dimensionRange) {
                LabeledContent("Columns", value: "\(settings.gridColumns)")
            }
            Stepper(value: $settings.gridRows, in: SettingsStore.dimensionRange) {
                LabeledContent("Rows", value: "\(settings.gridRows)")
            }
        }
    }
}

private struct AppearanceSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            ColorPicker("Grid line color", selection: $settings.cellStrokeColor)
            ColorPicker("Selection fill color", selection: $settings.selectionFillColor)
            ColorPicker("Selection border color", selection: $settings.selectionStrokeColor)

            VStack(alignment: .leading) {
                Slider(
                    value: $settings.overlayOpacity,
                    in: SettingsStore.opacityRange
                ) {
                    Text("Overlay opacity")
                } minimumValueLabel: {
                    Text("Dim")
                } maximumValueLabel: {
                    Text("Solid")
                }
            }
        }
    }
}

private struct BehaviorSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Resize live while dragging", isOn: $settings.liveResizeEnabled)
            Text("Off by default: the window stays put until you release the mouse, then "
                 + "snaps once. Some apps (Electron/Chromium: VS Code, Slack, Discord) redraw "
                 + "poorly under continuous live resizing.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Launch MacGriddle at login", isOn: $settings.launchAtLoginEnabled)
        }
    }
}

private struct AboutTab: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Form {
            LabeledContent("Panic hotkey", value: settings.panicHotkeyDisplayString)
            Text("Force-resets the drag gesture if it ever gets stuck (e.g. a missed "
                 + "mouse-up event). Not yet configurable — a natural candidate for a "
                 + "future release.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
