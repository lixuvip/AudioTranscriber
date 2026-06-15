import SwiftUI

struct PersonListPane: View {
    @ObservedObject var store: PersonTimelineStore

    @State private var activeSheet: PersonMaintenanceSheet?
    @State private var pendingDeletePerson: PersonRecord?
    @State private var showingDeleteConfirmation = false
    @State private var clearDeletePendingOnDismiss = true

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            if store.people.isEmpty && store.unassignedPhoneNumbers.isEmpty {
                emptyState
            } else {
                peopleList
            }
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
        }
        .alert(
            "删除人物",
            isPresented: Binding(
                get: { showingDeleteConfirmation },
                set: handleDeleteConfirmationPresentation
            )
        ) {
            if let person = pendingDeletePerson {
                Button("删除", role: .destructive) {
                    confirmDelete(person)
                }
            }
            Button("取消", role: .cancel, action: cancelDelete)
        } message: {
            if let person = pendingDeletePerson {
                Text("删除 \(personName(person)) 后，其号码会恢复为未归档号码。")
            }
        }
    }

    private var peopleList: some View {
        List {
            Section("人物") {
                if store.filteredPeople.isEmpty {
                    Text("未找到匹配人物")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.filteredPeople) { person in
                        personRow(person)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 4,
                                    leading: 8,
                                    bottom: 4,
                                    trailing: 8
                                )
                            )
                    }
                }
            }

            if !store.mergeSuggestions.isEmpty {
                Section("可能是同一人") {
                    ForEach(store.mergeSuggestions.indices, id: \.self) { index in
                        suggestionRow(store.mergeSuggestions[index])
                            .listRowInsets(
                                EdgeInsets(
                                    top: 4,
                                    leading: 8,
                                    bottom: 4,
                                    trailing: 8
                                )
                            )
                    }
                }
            }

            if !store.unassignedPhoneNumbers.isEmpty {
                Section("未归档号码") {
                    ForEach(store.unassignedPhoneNumbers, id: \.self) { phone in
                        unassignedPhoneRow(phone)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 4,
                                    leading: 8,
                                    bottom: 4,
                                    trailing: 8
                                )
                            )
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("人物")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                maintenanceMenu
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索姓名或号码", text: $store.searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var maintenanceMenu: some View {
        Menu {
            Button("新建人物") {
                activeSheet = .create
            }
            .disabled(isReadOnly)

            Button("重命名") {
                if let selectedPerson {
                    activeSheet = .rename(selectedPerson)
                }
            }
            .disabled(isReadOnly || selectedPerson == nil)

            Button("分配号码") {
                if let selectedPerson {
                    activeSheet = .assign(selectedPerson, preselectedPhone: nil)
                }
            }
            .disabled(isReadOnly || selectedPerson == nil)

            Divider()

            Button("合并人物") {
                activeSheet = .chooseMerge
            }
            .disabled(isReadOnly || store.people.count < 2)

            Button("拆分号码") {
                if let selectedPerson {
                    activeSheet = .split(selectedPerson)
                }
            }
            .disabled(
                isReadOnly
                    || selectedPerson == nil
                    || selectedPerson?.phoneNumbers.isEmpty == true
            )

            Button("撤销合并") {
                activeSheet = .revert
            }
            .disabled(isReadOnly || store.activeMergeRecords.isEmpty)

            Divider()

            Button("删除人物", role: .destructive, action: beginDelete)
                .disabled(isReadOnly || selectedPerson == nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help(isReadOnly ? "只读模式下无法维护人物" : "人物维护")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("暂无人物")
                .font(.system(size: 13, weight: .semibold))
            Text("归档索引载入后会在这里显示人物和未归档号码。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 180)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func personRow(_ person: PersonRecord) -> some View {
        let isSelected = store.selectedPersonID == person.id
        return Button {
            store.selectPerson(person.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(personName(person))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(personDetail(for: person))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
    }

    private func suggestionRow(_ people: [PersonRecord]) -> some View {
        Button {
            openMergeSheet(for: people)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.2.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestionTitle(for: people))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(people.count) 个人物 · \(people.flatMap(\.phoneNumbers).count) 个号码")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    private func unassignedPhoneRow(_ phone: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "phone.badge.questionmark")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(phone)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contextMenu {
            Button("分配给当前人物") {
                if let selectedPerson {
                    _ = performStoreAction {
                        try store.assignUnassignedPhones([phone], to: selectedPerson.id)
                    }
                }
            }
            .disabled(isReadOnly || selectedPerson == nil)

            Button("打开分配面板") {
                if let selectedPerson {
                    activeSheet = .assign(selectedPerson, preselectedPhone: phone)
                }
            }
            .disabled(isReadOnly || selectedPerson == nil)
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: PersonMaintenanceSheet) -> some View {
        switch sheet {
        case .create:
            PersonCreateSheet(
                onSave: { displayName, phones in
                    if performStoreAction({
                        try store.createPerson(displayName: displayName, phones: phones)
                    }) {
                        activeSheet = nil
                    }
                },
                onCancel: { activeSheet = nil }
            )

        case .rename(let person):
            PersonRenameSheet(
                person: person,
                onSave: { displayName in
                    if performStoreAction({
                        try store.renamePerson(person.id, displayName: displayName)
                    }) {
                        activeSheet = nil
                    }
                },
                onCancel: { activeSheet = nil }
            )

        case .assign(let person, let preselectedPhone):
            PersonAssignPhonesSheet(
                person: person,
                unassignedPhones: store.unassignedPhoneNumbers,
                preselectedPhone: preselectedPhone,
                onSave: { phones in
                    if performStoreAction({
                        try store.assignUnassignedPhones(phones, to: person.id)
                    }) {
                        activeSheet = nil
                    }
                },
                onCancel: { activeSheet = nil }
            )

        case .chooseMerge:
            PersonManualMergeSelectionSheet(
                people: store.people,
                selectedPersonID: store.selectedPersonID,
                callCounts: callCounts(for: store.people),
                onContinue: openMergeSheet,
                onCancel: { activeSheet = nil }
            )

        case .merge(let draft):
            PersonMergeSheet(
                candidates: draft.candidates,
                callCounts: callCounts(for: draft.candidates),
                targetPersonID: draft.targetPersonID,
                displayName: draft.displayName,
                onConfirm: mergePeople,
                onCancel: { activeSheet = nil }
            )

        case .split(let person):
            PersonSplitSheet(
                person: person,
                onSplit: { phones, newDisplayName in
                    if performStoreAction({
                        try store.splitPhones(
                            personID: person.id,
                            phones: phones,
                            newDisplayName: newDisplayName
                        )
                    }) {
                        activeSheet = nil
                    }
                },
                onCancel: { activeSheet = nil }
            )

        case .revert:
            PersonRevertMergeSheet(
                records: store.activeMergeRecords,
                onRevert: { mergeID in
                    if performStoreAction({
                        try store.revertMerge(mergeID)
                    }) {
                        activeSheet = nil
                    }
                },
                onCancel: { activeSheet = nil }
            )
        }
    }

    private var selectedPerson: PersonRecord? {
        store.selectedPerson
    }

    private var isReadOnly: Bool {
        if case .readOnly = store.access {
            return true
        }
        return false
    }

    private func beginDelete() {
        pendingDeletePerson = selectedPerson
        clearDeletePendingOnDismiss = true
        showingDeleteConfirmation = pendingDeletePerson != nil
    }

    private func cancelDelete() {
        clearDeletePendingOnDismiss = true
        pendingDeletePerson = nil
        showingDeleteConfirmation = false
    }

    private func confirmDelete(_ person: PersonRecord) {
        do {
            try store.deletePersonKeepingPhonesUnassigned(person.id)
            cancelDelete()
        } catch {
            clearDeletePendingOnDismiss = false
            showingDeleteConfirmation = false
            pendingDeletePerson = person
            store.present(error)
        }
    }

    private func handleDeleteConfirmationPresentation(_ isPresented: Bool) {
        showingDeleteConfirmation = isPresented
        if !isPresented {
            if clearDeletePendingOnDismiss {
                pendingDeletePerson = nil
            }
            clearDeletePendingOnDismiss = true
        }
    }

    private func openMergeSheet(for people: [PersonRecord]) {
        let uniquePeople = uniquePeople(people)
        guard uniquePeople.count >= 2 else {
            store.present("至少选择两个人物后才能合并")
            return
        }
        let target = uniquePeople.first { $0.id == store.selectedPersonID }
            ?? uniquePeople.first
        guard let target else { return }
        activeSheet = .merge(
            MergeDraft(
                candidates: uniquePeople,
                targetPersonID: target.id,
                displayName: personName(target)
            )
        )
    }

    private func mergePeople(
        personIDs: [String],
        targetID: String,
        displayName: String
    ) {
        if performStoreAction({
            try store.mergePeople(
                personIDs: personIDs,
                targetID: targetID,
                displayName: displayName
            )
        }) {
            activeSheet = nil
        }
    }

    private func personDetail(for person: PersonRecord) -> String {
        let summary = store.callSummary(for: person.id)
        let phoneCount = "\(person.phoneNumbers.count) 个号码"
        let callCount = "\(summary.count) 通"
        if let latestDateText = summary.latestDateText {
            return "\(phoneCount) · \(callCount) · 最近 \(latestDateText)"
        }
        return "\(phoneCount) · \(callCount)"
    }

    private func suggestionTitle(for people: [PersonRecord]) -> String {
        guard let first = people.first else { return "同名人物" }
        return personName(first)
    }

    private func callCounts(for people: [PersonRecord]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: people.map { person in
            (person.id, store.callCount(for: person.id))
        })
    }

    @discardableResult
    private func performStoreAction(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            store.present(error)
            return false
        }
    }
}
