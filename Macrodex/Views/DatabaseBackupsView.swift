import SwiftUI

struct DatabaseBackupsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var overview = DatabaseBackupOverview()
    @State private var isWorking = false
    @State private var message: String?
    @State private var restoreTarget: DatabaseBackupSummary?
    @State private var deleteTarget: DatabaseBackupSummary?
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            statusSection
            actionsSection
            backupsSection
        }
        .navigationTitle("Database Backups")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(MacrodexTheme.backgroundGradient.ignoresSafeArea())
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
        .confirmationDialog("Restore backup?", isPresented: restoreBinding, titleVisibility: .visible) {
            Button("Restore Backup", role: .destructive) {
                Task { await restoreSelectedBackup() }
            }
            Button("Cancel", role: .cancel) {
                restoreTarget = nil
            }
        } message: {
            Text("Macrodex will create a safety backup first, then replace the current database.")
        }
        .confirmationDialog("Delete backup?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) {
                Task { await deleteSelectedBackup() }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This removes the local backup files for the selected point in time.")
        }
        .confirmationDialog("Reset database?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
            Button("Reset Database", role: .destructive) {
                Task { await resetDatabase() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Macrodex will create a backup first, then replace the current database with an empty one.")
        }
    }

    private var statusSection: some View {
        Section {
            SettingsInfoRow(title: "Last Backup", value: lastBackupText, systemImage: "clock.arrow.circlepath")
            SettingsInfoRow(title: "Storage Used", value: ByteCountFormatter.string(fromByteCount: overview.storageBytes, countStyle: .file), systemImage: "externaldrive")
            SettingsInfoRow(title: "Status", value: overview.status, systemImage: "checkmark.circle")

            Toggle(isOn: automaticBinding) {
                Label("Automatic Backups", systemImage: "arrow.triangle.2.circlepath")
                    .macrodexFont(.subheadline)
                    .foregroundColor(MacrodexTheme.textPrimary)
            }
            .tint(MacrodexTheme.accent)
            .listRowBackground(MacrodexTheme.surface.opacity(0.6))

        } header: {
            Text("Database")
                .foregroundColor(MacrodexTheme.textSecondary)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await createBackup() }
            } label: {
                actionLabel("Create Backup Now", systemImage: "plus.circle")
            }
            .disabled(isWorking)
            .listRowBackground(MacrodexTheme.surface.opacity(0.6))

            Button {
                Task { await createIncrementalBackup() }
            } label: {
                actionLabel("Save Incremental Backup", systemImage: "plus.square.on.square")
            }
            .disabled(isWorking)
            .listRowBackground(MacrodexTheme.surface.opacity(0.6))

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                actionLabel("Reset Database", systemImage: "trash")
                    .foregroundColor(MacrodexTheme.danger)
            }
            .disabled(isWorking)
            .listRowBackground(MacrodexTheme.surface.opacity(0.6))

            if isWorking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working...")
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }
                .listRowBackground(MacrodexTheme.surface.opacity(0.6))
            }

            if let message {
                Text(message)
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textSecondary)
                    .listRowBackground(MacrodexTheme.surface.opacity(0.6))
            }
        } header: {
            Text("Actions")
                .foregroundColor(MacrodexTheme.textSecondary)
        }
    }

    private var backupsSection: some View {
        Section {
            if overview.backups.isEmpty {
                Text("No backups yet.")
                    .macrodexFont(.caption)
                    .foregroundColor(MacrodexTheme.textMuted)
                    .listRowBackground(MacrodexTheme.surface.opacity(0.6))
            } else {
                ForEach(overview.backups) { backup in
                    backupRow(backup)
                }
            }
        } header: {
            Text("Backups")
                .foregroundColor(MacrodexTheme.textSecondary)
        }
    }

    private func backupRow(_ backup: DatabaseBackupSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundColor(MacrodexTheme.textPrimary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(backup.displayName)
                        .macrodexFont(.subheadline, weight: .semibold)
                        .foregroundColor(MacrodexTheme.textPrimary)
                    Text(backupSubtitle(backup))
                        .macrodexFont(.caption)
                        .foregroundColor(MacrodexTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Restore") {
                        restoreTarget = backup
                    }
                    Button("Delete", role: .destructive) {
                        deleteTarget = backup
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(MacrodexTheme.textPrimary)
                }
            }
        }
        .listRowBackground(MacrodexTheme.surface.opacity(0.6))
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
            Text(title)
                .macrodexFont(.subheadline)
            Spacer()
        }
        .foregroundColor(MacrodexTheme.textPrimary)
    }

    private var lastBackupText: String {
        guard let date = overview.lastBackupDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var automaticBinding: Binding<Bool> {
        Binding {
            overview.automaticBackupsEnabled
        } set: { value in
            overview.automaticBackupsEnabled = value
            Task {
                await DatabaseBackupManager.shared.setAutomaticBackupsEnabled(value)
                await refresh()
            }
        }
    }

    private var restoreBinding: Binding<Bool> {
        Binding {
            restoreTarget != nil
        } set: { showing in
            if !showing { restoreTarget = nil }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding {
            deleteTarget != nil
        } set: { showing in
            if !showing { deleteTarget = nil }
        }
    }

    private func backupSubtitle(_ backup: DatabaseBackupSummary) -> String {
        let size = ByteCountFormatter.string(fromByteCount: backup.totalByteCount, countStyle: .file)
        let deltaText = backup.deltas.isEmpty ? "base only" : "\(backup.deltas.count) incremental"
        return "\(size) - \(deltaText) - local"
    }

    private func refresh() async {
        overview = await DatabaseBackupManager.shared.overview()
    }

    private func run(_ body: @escaping () async throws -> String) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            message = try await body()
            await refresh()
        } catch {
            message = error.localizedDescription
            await refresh()
        }
    }

    private func createBackup() async {
        await run {
            let backup = try await DatabaseBackupManager.shared.createBackup(reason: "Manual")
            return "Created backup from \(backup.displayName)."
        }
    }

    private func createIncrementalBackup() async {
        await run {
            let backup = try await DatabaseBackupManager.shared.createIncrementalBackup(reason: "Manual incremental")
            return "Saved backup chain with \(backup.deltas.count) incremental file(s)."
        }
    }

    private func restoreSelectedBackup() async {
        guard let restoreTarget else { return }
        self.restoreTarget = nil
        await run {
            try await DatabaseBackupManager.shared.restoreBackup(id: restoreTarget.id)
            try await appModel.restartLocalServer()
            await appModel.refreshSnapshot()
            return "Restored \(restoreTarget.displayName)."
        }
    }

    private func deleteSelectedBackup() async {
        guard let deleteTarget else { return }
        self.deleteTarget = nil
        await run {
            try await DatabaseBackupManager.shared.deleteBackup(id: deleteTarget.id)
            return "Deleted \(deleteTarget.displayName)."
        }
    }

    private func resetDatabase() async {
        await run {
            let backup = try await DatabaseBackupManager.shared.resetDatabase()
            try await appModel.restartLocalServer()
            await appModel.refreshSnapshot()
            return "Database reset. Safety backup: \(backup.displayName)."
        }
    }
}
