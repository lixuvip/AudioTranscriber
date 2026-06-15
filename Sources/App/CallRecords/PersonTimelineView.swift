import SwiftUI

struct PersonTimelineView: View {
    @ObservedObject var store: PersonTimelineStore
    @ObservedObject var runner: PersonOrganizationRunner
    @ObservedObject var settingsManager: SettingsManager
    let pythonPath: String
    let summarizeScriptPath: String
    var onChooseArchive: () -> Void

    var body: some View {
        Group {
            if store.archiveRoot == nil {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if let reason = readOnlyReason {
                        readOnlyBanner(reason: reason)
                    }

                    HSplitView {
                        PersonListPane(store: store)
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                            .accessibilityLabel("人物维护列表")

                        PersonCallsPane(store: store)
                            .frame(minWidth: 420)

                        PersonOrganizationPane(
                            store: store,
                            runner: runner,
                            settingsManager: settingsManager,
                            pythonPath: pythonPath,
                            summarizeScriptPath: summarizeScriptPath
                        )
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
                    }
                }
            }
        }
        .alert(
            "人物时间线",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定") {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "person.2.wave.2")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("选择通话归档目录")
                    .font(.system(size: 17, weight: .semibold))
                Text("选择包含 call_index.json 的归档目录后，可按人物筛选通话并生成整理版本。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button(action: onChooseArchive) {
                Label("选择通话归档目录", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func readOnlyBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text("只读模式")
                .font(.system(size: 12, weight: .semibold))
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var readOnlyReason: String? {
        if case .readOnly(let reason) = store.access {
            return reason
        }
        return nil
    }
}
