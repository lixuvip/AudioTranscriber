import SwiftUI

struct PersonMergeSheet: View {
    let candidates: [PersonRecord]
    let callCounts: [String: Int]
    @State var targetPersonID: String
    @State var displayName: String
    var onConfirm: (_ personIDs: [String], _ targetID: String, _ displayName: String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("合并人物")
                    .font(.system(size: 17, weight: .semibold))
                Text("确认后会把下列人物的号码合并到目标人物，并保留可撤销记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { person in
                        candidateRow(person)
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 280)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("合并到", selection: $targetPersonID) {
                    ForEach(candidates) { person in
                        Text(personName(person)).tag(person.id)
                    }
                }
                .pickerStyle(.menu)

                TextField("合并后名称", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(canConfirm ? Color.secondary : Color.orange)
                Spacer()
                Button("取消", action: onCancel)
                Button("确认合并") {
                    onConfirm(
                        uniqueCandidateIDs,
                        targetPersonID,
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 430)
    }

    private func candidateRow(_ person: PersonRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: person.id == targetPersonID ? "target" : "person.crop.circle")
                    .foregroundStyle(person.id == targetPersonID ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(personName(person))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(callCounts[person.id, default: 0]) 通")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text(phoneText(for: person))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(person.id == targetPersonID ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
    }

    private var canConfirm: Bool {
        candidates.count >= 2
            && candidates.contains { $0.id == targetPersonID }
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String {
        if candidates.count < 2 {
            return "至少选择两个人物"
        }
        if !candidates.contains(where: { $0.id == targetPersonID }) {
            return "请选择合并目标"
        }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请输入合并后名称"
        }
        return "\(candidates.count) 个人物将被合并"
    }

    private var uniqueCandidateIDs: [String] {
        var seen = Set<String>()
        return candidates.map(\.id).filter { seen.insert($0).inserted }
    }

    private func personName(_ person: PersonRecord) -> String {
        let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未命名人物" : name
    }

    private func phoneText(for person: PersonRecord) -> String {
        if person.phoneNumbers.isEmpty {
            return "无号码"
        }
        return person.phoneNumbers.joined(separator: "、")
    }
}
