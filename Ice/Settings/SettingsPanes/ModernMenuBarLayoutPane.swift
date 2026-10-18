//
//  ModernMenuBarLayoutPane.swift
//  Ice
//

import SwiftUI
import UniformTypeIdentifiers

/// macOS 27 editor: item identities and app icons do not depend on CGWindowID capture.
struct ModernMenuBarLayoutPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: ModernMenuBarManager
    @State private var search = ""
    @State private var hasAccessibilityPermission = AXHelpers.isProcessTrusted()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Arrange your menu bar items").font(.title2)
                Text("Drag within a section to reorder items, or into another section to choose when they appear.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Label("All items are temporarily revealed", systemImage: "eye")
                        .font(.headline)
                    Text("Assignments save immediately. To see your saved hiding behavior, switch to General or close Settings. Returning here reveals all items again without changing their sections.")
                        .font(.callout)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                TextField("Find an app or menu bar item", text: $search)
                    .textFieldStyle(.roundedBorder)
                Text("App icons identify items when individual menu bar previews are unavailable. Icons from the same app hide together. Wi-Fi, Battery and other supported system controls can be hidden separately.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("User hides together with optional Control Center extras such as AirDrop and Focus. macOS hides this group whenever any items are hidden; reveal all sections to restore it. Control Center itself stays visible.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = manager.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if manager.isMoving {
                    ProgressView("Moving item in the menu bar…")
                }
                accessDiagnostic
                ForEach(ModernMenuBarLayout.Section.allCases, id: \.self) { section in
                    sectionView(section)
                }
                Button("Retry Access and Refresh") {
                    Task {
                        guard await appState.retryPermissionSetup() else { return }
                        await manager.refresh()
                    }
                }
                    .disabled(manager.isRefreshing || manager.isMoving)
            }
            .padding(20)
        }
        .onAppear {
            appState.permissions.recheckPermissions()
            manager.beginEditing()
        }
        .onReceive(appState.permissions.accessibility.$hasPermission) { granted in
            hasAccessibilityPermission = granted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.permissions.recheckPermissions()
        }
        .onDisappear { manager.endEditing() }
        .onReceive(appState.navigationState.$isSettingsPresented) { visible in
            if visible { manager.beginEditing() } else { manager.endEditing() }
        }
    }

    @ViewBuilder
    private var accessDiagnostic: some View {
        switch MenuBarAccessDiagnostic.select(
            isTrusted: hasAccessibilityPermission,
            hasItems: !manager.items.isEmpty,
            isRefreshing: manager.isRefreshing
        ) {
        case .accessibilityDenied:
            VStack(alignment: .leading, spacing: 8) {
                Text(MenuBarAccessDiagnostic.repairGuidance(appPath: Bundle.main.bundlePath))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Open Accessibility Settings") {
                    appState.permissions.accessibility.openSettings()
                }
            }
        case .reading:
            Text("Reading menu bar items…").foregroundStyle(.secondary)
        case .noItems:
            Text("Accessibility access is granted, but no menu bar items could be read. Make sure the menu bar is visible, then retry.")
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func sectionView(_ section: ModernMenuBarLayout.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(section.title) Section").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(manager.items(in: section).filter(matchesSearch)) { item in
                    tile(item)
                        .onDrag { NSItemProvider(object: item.id.rawValue as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            acceptDrop(providers) { source in
                                Task { await manager.move(source.id, before: item.id) }
                            }
                        }
                }
                if manager.items(in: section).filter(matchesSearch).isEmpty {
                    Text(search.isEmpty ? "Drop items here" : "No matches")
                        .foregroundStyle(.secondary).frame(minHeight: 60)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            .onDrop(of: [.text], isTargeted: nil) { providers in
                acceptDrop(providers) { manager.assign($0, to: section) }
            }
        }
    }

    private func tile(_ item: ModernMenuBarItem) -> some View {
        VStack(spacing: 5) {
            if let symbol = item.id.displaySymbol {
                Image(systemName: symbol).font(.title2).foregroundStyle(.blue).frame(height: 26)
            } else if let icon = appIcon(for: item) {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 26, height: 26)
            } else {
                Image(systemName: "menubar.rectangle").font(.title2).frame(height: 26)
            }
            Text(item.id.systemDisplayName ?? item.appName ?? item.id.title)
                .font(.caption).lineLimit(2).multilineTextAlignment(.center)
            Menu("Move to…") {
                ForEach(ModernMenuBarLayout.Section.allCases, id: \.self) { section in
                    Button(section.title) { manager.assign(item, to: section) }
                        .disabled(section != .visible && !manager.canAssign(item))
                }
            }
            .font(.caption2)
            if !manager.canAssign(item) {
                Text("Managed by macOS").font(.caption2).foregroundStyle(.secondary)
            }
            if item.id.isUserSwitcher {
                Text("Hides with system extras").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8).frame(maxWidth: .infinity, minHeight: 64)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .help("\(item.appName ?? item.id.bundleID) — \(item.id.title)")
        .accessibilityLabel(item.id.systemDisplayName ?? item.appName ?? item.id.title)
        .contextMenu {
            ForEach(ModernMenuBarLayout.Section.allCases, id: \.self) { section in
                Button("Move to \(section.title)") { manager.assign(item, to: section) }
                    .disabled(section != .visible && !manager.canAssign(item))
            }
        }
    }

    private func appIcon(for item: ModernMenuBarItem) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: item.pid)?.icon { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.id.bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func matchesSearch(_ item: ModernMenuBarItem) -> Bool {
        search.isEmpty || "\(item.id.systemDisplayName ?? "") \(item.appName ?? "") \(item.id.title) \(item.id.bundleID)".localizedCaseInsensitiveContains(search)
    }

    private func acceptDrop(_ providers: [NSItemProvider], action: @escaping @MainActor (ModernMenuBarItem) -> Void) -> Bool {
        guard !manager.isMoving, let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String else { return }
            Task { @MainActor in
                guard let item = manager.items.first(where: { $0.id.rawValue == raw }) else { return }
                action(item)
            }
        }
        return true
    }
}
