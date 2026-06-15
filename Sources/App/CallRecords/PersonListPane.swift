import SwiftUI

struct PersonListPane: View {
    @ObservedObject var store: PersonTimelineStore

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
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("人物")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("新建人物") {}
                        .disabled(true)
                    Button("重命名") {}
                        .disabled(true)
                    Button("分配号码") {}
                        .disabled(true)
                    Divider()
                    Button("合并人物") {}
                        .disabled(true)
                    Button("拆分号码") {}
                        .disabled(true)
                    Button("撤销合并") {}
                        .disabled(true)
                    Divider()
                    Button("删除人物", role: .destructive) {}
                        .disabled(true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("人物维护入口将在后续任务接入")
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
                    Text(person.displayName.isEmpty ? "未命名人物" : person.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(personDetail(for: person, isSelected: isSelected))
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
            Button("分配给当前人物") {}
                .disabled(true)
        }
    }

    private func personDetail(for person: PersonRecord, isSelected: Bool) -> String {
        let phoneCount = "\(person.phoneNumbers.count) 个号码"
        guard isSelected else {
            let phones = person.phoneNumbers.prefix(2).joined(separator: "、")
            return phones.isEmpty ? phoneCount : "\(phoneCount) · \(phones)"
        }

        let callCount = "\(store.calls.count) 通"
        if let latestCall = store.calls.map(\.entry.callDate).max() {
            return "\(phoneCount) · \(callCount) · 最近 \(Self.shortDateFormatter.string(from: latestCall))"
        }
        return "\(phoneCount) · \(callCount)"
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
