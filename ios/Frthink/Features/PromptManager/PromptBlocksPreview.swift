// 提示词块预览：按发送顺序列出装配后的逐字内容。

import SwiftUI

struct PromptBlocksPreviewSheet: View {
    let blocks: [PromptBlock]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if blocks.isEmpty {
                    EmptyStateView(
                        symbol: "text.alignleft",
                        title: "还没有提示词块"
                    )
                } else {
                    blockList
                }
            }
            .groupedPageBackground()
            .navigationTitle("提示词块预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetCloseButton(title: "完成") { dismiss() }
                }
            }
        }
    }

    private var blockList: some View {
        List {
            ForEach(blocks, id: \.key) { block in
                blockSection(block)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func blockSection(_ block: PromptBlock) -> some View {
        Section {
            Text(block.rendered)
                .font(Theme.reply)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            blockHeader(block)
        }
    }

    private func blockHeader(_ block: PromptBlock) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(block.category.rawValue)
                .font(Theme.sectionTitle)
                .foregroundStyle(.secondary)
            if block.locked {
                Image(systemName: "lock.fill")
                    .font(Theme.badge)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已锁定")
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
    }
}
