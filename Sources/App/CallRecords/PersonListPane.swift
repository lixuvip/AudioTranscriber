import Foundation
import SwiftUI

struct PersonListPane: View {
    @ObservedObject var store: PersonTimelineStore

    @State private var activeSheet: PersonMaintenanceSheet?
    @State private var pendingDeletePerson: PersonRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            if store.people.isEmpty && store.unassignedPhoneNumbers.isEmpty {
                emptyState
            } else {
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
        }
        .sheet(item: $activeSheet) { sheet in
            sheetView(sheet)
        }
        .alert(
            "删除人物",
            isPresented: Binding(
                get: { pendingDeletePerson != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDeletePerson = nil
                    }
                }
            )
        ) {
            Button("删除", role: .destructive) {
                guard let person = pendingDeletePerson else { return }
                if performStoreAction({
                    try store.deletePersonKeepingPhonesUnassigned(person.id)
                }) {
                    pendingDeletePerson = nil
                }
            }
            Button("取消", role: .cancel) {
                pendingDeletePerson = nil
            }
        } message: {
            if let person = pendingDeletePerson {
                Text("删除 \(personName(person)) 后，其号码会恢复为未归档号码。")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("人物")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
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

                    Button("删除人物", role: .destructive) {
                        pendingDeletePerson = selectedPerson
                    }
                    .disabled(isReadOnly || selectedPerson == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help(isReadOnly ? "只读模式下无法维护人物" : "人物维护")
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
                onContinue: { candidates in
                    openMergeSheet(for: candidates)
                },
                onCancel: { activeSheet = nil }
            )

        case .merge(let draft):
            PersonMergeSheet(
                candidates: draft.candidates,
                callCounts: callCounts(for: draft.candidates),
                targetPersonID: draft.targetPersonID,
                displayName: draft.displayName,
                onConfirm: { personIDs, targetID, displayName in
                    if performStoreAction({
                        try store.mergePeople(
                            personIDs: personIDs,
                            targetID: targetID,
                            displayName: displayName
                        )
                    }) {
                        activeSheet = nil
                    }
                },
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

private enum PersonMaintenanceSheet: Identifiable {
    case create
    case rename(PersonRecord)
    case assign(PersonRecord, preselectedPhone: String?)
    case chooseMerge
    case merge(MergeDraft)
    case split(PersonRecord)
    case revert

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let person):
            return "rename-\(person.id)"
        case .assign(let person, let phone):
            return "assign-\(person.id)-\(phone ?? "manual")"
        case .chooseMerge:
            return "choose-merge"
        case .merge(let draft):
            return "merge-\(draft.id)"
        case .split(let person):
            return "split-\(person.id)"
        case .revert:
            return "revert"
        }
    }
}

private struct MergeDraft: Identifiable {
    let id: String
    let candidates: [PersonRecord]
    let targetPersonID: String
    let displayName: String

    init(
        candidates: [PersonRecord],
        targetPersonID: String,
        displayName: String
    ) {
        self.candidates = uniquePeople(candidates)
        self.targetPersonID = targetPersonID
        self.displayName = displayName
        id = self.candidates.map(\.id).joined(separator: "|")
            + "|target:\(targetPersonID)"
    }
}

private struct PersonCreateSheet: View {
    @State private var displayName = ""
    @State private var phoneText = ""
    var onSave: (_ displayName: String, _ phones: [String]) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                title: "新建人物",
                detail: "可先创建空人物，也可以同时输入一个或多个未归档号码。"
            )

            VStack(alignment: .leading, spacing: 10) {
                labeledField("名称") {
                    TextField("人物名称", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField("号码") {
                    TextField("可选，换行或逗号分隔", text: $phoneText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }
            }

            footer(
                hint: "新建后会自动选中该人物。",
                cancelTitle: "取消",
                confirmTitle: "新建",
                canConfirm: !trimmedDisplayName.isEmpty,
                onCancel: onCancel,
                onConfirm: {
                    onSave(trimmedDisplayName, parsedPhoneList(phoneText))
                }
            )
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PersonRenameSheet: View {
    let person: PersonRecord
    @State private var displayName: String
    var onSave: (_ displayName: String) -> Void
    var onCancel: () -> Void

    init(
        person: PersonRecord,
        onSave: @escaping (_ displayName: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.person = person
        self.onSave = onSave
        self.onCancel = onCancel
        _displayName = State(initialValue: person.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(title: "重命名人物", detail: personName(person))

            labeledField("新名称") {
                TextField("人物名称", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            footer(
                hint: "只修改人物显示名称，不改动号码和通话选择。",
                cancelTitle: "取消",
                confirmTitle: "保存",
                canConfirm: !trimmedDisplayName.isEmpty,
                onCancel: onCancel,
                onConfirm: {
                    onSave(trimmedDisplayName)
                }
            )
        }
        .padding(20)
        .frame(minWidth: 400)
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PersonAssignPhonesSheet: View {
    let person: PersonRecord
    let unassignedPhones: [String]
    @State private var selectedPhones: Set<String>
    @State private var manualPhoneText = ""
    var onSave: (_ phones: [String]) -> Void
    var onCancel: () -> Void

    init(
        person: PersonRecord,
        unassignedPhones: [String],
        preselectedPhone: String?,
        onSave: @escaping (_ phones: [String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.person = person
        self.unassignedPhones = unassignedPhones
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedPhones = State(initialValue: preselectedPhone.map { Set([$0]) } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                title: "分配号码",
                detail: "分配给 \(personName(person))"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("未归档号码")
                    .font(.system(size: 12, weight: .semibold))
                phoneSelectionList(
                    phones: unassignedPhones,
                    selectedPhones: $selectedPhones,
                    emptyText: "暂无未归档号码，可手动输入号码。"
                )

                labeledField("手动输入") {
                    TextField("换行或逗号分隔", text: $manualPhoneText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                }
            }

            footer(
                hint: "\(phonesToAssign.count) 个号码将被分配",
                cancelTitle: "取消",
                confirmTitle: "分配",
                canConfirm: !phonesToAssign.isEmpty,
                onCancel: onCancel,
                onConfirm: {
                    onSave(phonesToAssign)
                }
            )
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }

    private var phonesToAssign: [String] {
        uniqueStrings(
            unassignedPhones.filter { selectedPhones.contains($0) }
                + parsedPhoneList(manualPhoneText)
        )
    }
}

private struct PersonManualMergeSelectionSheet: View {
    let people: [PersonRecord]
    let callCounts: [String: Int]
    @State private var selectedIDs: Set<String>
    var onContinue: (_ candidates: [PersonRecord]) -> Void
    var onCancel: () -> Void

    init(
        people: [PersonRecord],
        selectedPersonID: String?,
        callCounts: [String: Int],
        onContinue: @escaping (_ candidates: [PersonRecord]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.people = people
        self.callCounts = callCounts
        self.onContinue = onContinue
        self.onCancel = onCancel
        if let selectedPersonID {
            _selectedIDs = State(initialValue: Set([selectedPersonID]))
        } else {
            _selectedIDs = State(initialValue: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                title: "选择合并人物",
                detail: "至少选择两个人物，下一步再确认目标人物和合并后名称。"
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(people) { person in
                        Button {
                            toggle(person.id)
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: selectedIDs.contains(person.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedIDs.contains(person.id) ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(personName(person))
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(person.phoneNumbers.count) 个号码 · \(callCounts[person.id, default: 0]) 通")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedIDs.contains(person.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 360)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }

            footer(
                hint: selectedIDs.count < 2 ? "至少选择两个人物" : "已选择 \(selectedIDs.count) 个人物",
                cancelTitle: "取消",
                confirmTitle: "下一步",
                canConfirm: selectedIDs.count >= 2,
                onCancel: onCancel,
                onConfirm: {
                    onContinue(people.filter { selectedIDs.contains($0.id) })
                }
            )
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 480)
    }

    private func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

private struct PersonSplitSheet: View {
    let person: PersonRecord
    @State private var selectedPhones: Set<String> = []
    @State private var destination: SplitDestination = .unassigned
    @State private var newDisplayName = ""
    var onSplit: (_ phones: [String], _ newDisplayName: String?) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                title: "拆分号码",
                detail: "从 \(personName(person)) 中拆出一个或多个号码。"
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("选择号码")
                    .font(.system(size: 12, weight: .semibold))
                phoneSelectionList(
                    phones: person.phoneNumbers,
                    selectedPhones: $selectedPhones,
                    emptyText: "当前人物没有可拆分号码。"
                )

                Picker("拆分方式", selection: $destination) {
                    ForEach(SplitDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .pickerStyle(.segmented)

                if destination == .newPerson {
                    labeledField("新人物名称") {
                        TextField("人物名称", text: $newDisplayName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            footer(
                hint: splitHint,
                cancelTitle: "取消",
                confirmTitle: "拆分",
                canConfirm: canSplit,
                onCancel: onCancel,
                onConfirm: {
                    onSplit(
                        phonesToSplit,
                        destination == .newPerson ? trimmedNewDisplayName : nil
                    )
                }
            )
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }

    private var phonesToSplit: [String] {
        person.phoneNumbers.filter { selectedPhones.contains($0) }
    }

    private var trimmedNewDisplayName: String {
        newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSplit: Bool {
        !phonesToSplit.isEmpty
            && (destination == .unassigned || !trimmedNewDisplayName.isEmpty)
    }

    private var splitHint: String {
        if phonesToSplit.isEmpty {
            return "请选择至少一个号码"
        }
        if destination == .newPerson && trimmedNewDisplayName.isEmpty {
            return "创建新人物需要输入名称"
        }
        return "\(phonesToSplit.count) 个号码将被拆出"
    }
}

private enum SplitDestination: String, CaseIterable, Identifiable {
    case unassigned
    case newPerson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unassigned:
            return "恢复为未归档号码"
        case .newPerson:
            return "创建新人物"
        }
    }
}

private struct PersonRevertMergeSheet: View {
    let records: [PersonMergeRecord]
    @State private var selectedRecordID: String?
    @State private var pendingRecord: PersonMergeRecord?
    var onRevert: (_ mergeID: String) -> Void
    var onCancel: () -> Void

    init(
        records: [PersonMergeRecord],
        onRevert: @escaping (_ mergeID: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.records = records
        self.onRevert = onRevert
        self.onCancel = onCancel
        _selectedRecordID = State(initialValue: records.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                title: "撤销合并",
                detail: "只显示尚未撤销的合并记录，按时间倒序排列。"
            )

            if records.isEmpty {
                Text("没有可撤销的合并记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(records) { record in
                                recordButton(record)
                            }
                        }
                    }
                    .frame(width: 190)
                    .frame(minHeight: 260)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.quaternary, lineWidth: 1)
                    }

                    Divider()

                    ScrollView {
                        if let selectedRecord {
                            mergeRecordDetail(selectedRecord)
                        }
                    }
                    .frame(minWidth: 300, minHeight: 260)
                }
            }

            HStack {
                Text(selectedRecord == nil ? "请选择一条合并记录" : "撤销会恢复合并前的人物和号码映射")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button("撤销所选合并", role: .destructive) {
                    pendingRecord = selectedRecord
                }
                .disabled(selectedRecord == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 430)
        .alert(
            "确认撤销合并",
            isPresented: Binding(
                get: { pendingRecord != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRecord = nil
                    }
                }
            )
        ) {
            Button("撤销合并", role: .destructive) {
                if let pendingRecord {
                    onRevert(pendingRecord.id)
                }
                pendingRecord = nil
            }
            Button("取消", role: .cancel) {
                pendingRecord = nil
            }
        } message: {
            if let pendingRecord {
                Text("将恢复 \(pendingRecord.beforePeople.count) 个合并前人物。")
            }
        }
    }

    private var selectedRecord: PersonMergeRecord? {
        records.first { $0.id == selectedRecordID }
    }

    private func recordButton(_ record: PersonMergeRecord) -> some View {
        Button {
            selectedRecordID = record.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: record.createdAt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(record.beforePeople.count) 个人物")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selectedRecordID == record.id ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private func mergeRecordDetail(_ record: PersonMergeRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("合并目标")
                    .font(.system(size: 12, weight: .semibold))
                Text(shortID(record.targetPersonID))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("将恢复的人物映射")
                    .font(.system(size: 12, weight: .semibold))

                ForEach(record.beforePeople) { person in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(personName(person))
                            .font(.system(size: 12, weight: .medium))
                        Text(person.phoneNumbers.isEmpty ? "无号码" : person.phoneNumbers.joined(separator: "、"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

private func sheetHeader(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
        Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func labeledField<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        content()
    }
}

private func footer(
    hint: String,
    cancelTitle: String,
    confirmTitle: String,
    canConfirm: Bool,
    onCancel: @escaping () -> Void,
    onConfirm: @escaping () -> Void
) -> some View {
    HStack {
        Text(hint)
            .font(.system(size: 11))
            .foregroundStyle(canConfirm ? Color.secondary : Color.orange)
        Spacer()
        Button(cancelTitle, action: onCancel)
        Button(confirmTitle, action: onConfirm)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm)
    }
}

private func phoneSelectionList(
    phones: [String],
    selectedPhones: Binding<Set<String>>,
    emptyText: String
) -> some View {
    Group {
        if phones.isEmpty {
            Text(emptyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(phones, id: \.self) { phone in
                        Button {
                            if selectedPhones.wrappedValue.contains(phone) {
                                selectedPhones.wrappedValue.remove(phone)
                            } else {
                                selectedPhones.wrappedValue.insert(phone)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedPhones.wrappedValue.contains(phone) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedPhones.wrappedValue.contains(phone) ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                Text(phone)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedPhones.wrappedValue.contains(phone) ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                    }
                }
            }
        }
    }
    .frame(minHeight: 120, maxHeight: 180)
    .overlay {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.quaternary, lineWidth: 1)
    }
}

private func personName(_ person: PersonRecord) -> String {
    let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "未命名人物" : name
}

private func parsedPhoneList(_ text: String) -> [String] {
    uniqueStrings(
        text.split { separator in
            separator == ","
                || separator == "，"
                || separator == ";"
                || separator == "；"
                || separator.isWhitespace
                || separator.isNewline
        }
        .map(String.init)
    )
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { seen.insert($0).inserted }
}

private func uniquePeople(_ people: [PersonRecord]) -> [PersonRecord] {
    var seen = Set<String>()
    return people.filter { seen.insert($0.id).inserted }
}

private func shortID(_ id: String) -> String {
    String(id.prefix(8))
}
