// 设定核查页：排查角色认知冲突、档案过长、缺少依据的记录与久未回收的伏笔，并支持一键整理。

import Foundation
import SwiftUI

struct DreamingAuditView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var report: DreamingAuditReport?
    @State private var isAuditing = false
    @State private var auditTrigger = 0
    @State private var errorMessage: String?

    var body: some View {
        List {
            actionSection
            if let report {
                findingsSection(report)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("设定核查")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(session.narrativeRevision)-\(auditTrigger)") {
            await runAudit()
        }
        .narrativeErrorAlert($errorMessage, title: "检查失败")
    }

    private var cleanableFindings: [DreamingFinding] {
        guard let report else { return [] }
        return report.findings.filter { $0.kind != .ungroundedFact }
    }

    private var actionSection: some View {
        Section {
            Button {
                auditTrigger &+= 1
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text(isAuditing ? "正在核查设定与伏笔…" : "重新核查")
                    if isAuditing {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isAuditing)

            if let report {
                Text(report.summary)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)

                if !cleanableFindings.isEmpty {
                    Button("一键整理（\(cleanableFindings.count) 项）") {
                        applyCleanup(findings: cleanableFindings)
                    }
                    .disabled(isAuditing)
                }
            }
        } header: {
            AppSectionHeader(title: "核查与整理")
        }
    }

    private func findingsSection(_ report: DreamingAuditReport) -> some View {
        Section {
            if report.findings.isEmpty {
                Text("未发现设定冲突、档案冗余或久未回收的伏笔。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.findings) { finding in
                    findingRow(finding)
                }
            }
        } header: {
            AppSectionHeader(title: "待处理项（\(report.findings.count)）")
        }
    }

    private func findingRow(_ finding: DreamingFinding) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                StatusPill(
                    text: severityLabel(finding.severity),
                    tone: severityTone(finding.severity)
                )
                StatusPill(text: kindLabel(finding.kind), tone: .neutral)
                Spacer(minLength: 0)
            }

            Text(finding.title)
                .font(Theme.labelEmphasis)
                .foregroundStyle(.primary)

            Text(finding.detail)
                .font(Theme.labelSmall)
                .foregroundStyle(.secondary)

            if let quote = finding.anchor?.quote, !quote.isEmpty {
                Text("依据：「\(quote)」")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }

            Text("建议：\(finding.suggestedAction)")
                .font(Theme.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func runAudit() async {
        guard !isAuditing else { return }
        isAuditing = true
        defer { isAuditing = false }
        do {
            report = try await ConsistencyCheckWorkflow.runOfflineDreamingAsync(
                session: session,
                store: store
            )
        } catch {
            guard !Task.isCancelled, !error.isLLMCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyCleanup(findings: [DreamingFinding]) {
        do {
            let cleaned = try ConsistencyCheckWorkflow.applyDreamingCleanup(
                findings: findings,
                session: session,
                store: store
            )
            store.toast = cleaned > 0 ? "已整理 \(cleaned) 项" : "没有可自动整理的内容"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func severityLabel(_ severity: DreamingIssueSeverity) -> String {
        switch severity {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    private func severityTone(_ severity: DreamingIssueSeverity) -> AppTone {
        switch severity {
        case .high: return .danger
        case .medium: return .warning
        case .low: return .neutral
        }
    }

    private func kindLabel(_ kind: DreamingIssueKind) -> String {
        switch kind {
        case .staleBelief: return "认知冲突"
        case .entityPageBloat: return "档案过长"
        case .overdueThread: return "久未回收"
        case .ungroundedFact: return "缺少依据"
        }
    }
}
