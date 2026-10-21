import SwiftUI

/// The durable routing log, newest first, with the full record for the selected
/// turn. Fields the app does not interpret are shown verbatim rather than hidden.
package struct RequestsPane: View {
    @Bindable var monitor: RoutingMonitor

    package var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PaneHeader(eyebrow: "Routing atlas", title: "Requests") {
                if !monitor.sessions.isEmpty || monitor.isRouting {
                    SessionPicker(
                        sessions: monitor.sessions, selection: $monitor.selectedSessionID,
                        activeSessionIDs: monitor.activeSessionIDs
                    )
                }
                RouterSegments(
                    values: RoutingMonitor.RequestFilter.allCases,
                    label: \.label,
                    selection: $monitor.filter
                )
                Text("\(monitor.filteredRecords.count) in \(monitor.recordScopeName)")
                    .font(RouterTheme.mono(10))
                    .foregroundStyle(RouterTheme.ink3)
            }

            if let reason = monitor.emptyReason {
                StatsPanel(title: "Routed turns", note: "durable log") {
                    StatsEmptyState(message: reason, systemImage: "list.bullet.rectangle")
                }
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    logPanel
                        .frame(maxWidth: .infinity)
                    detailPanel
                        .frame(width: 320)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Log

    private var logPanel: some View {
        StatsPanel(
            title: "Routed turns",
            note: monitor.selectedSession == nil
                ? "newest first · durable log"
                : "newest first · this session's whole history"
        ) {
            VStack(spacing: 0) {
                header
                if monitor.filteredRecords.isEmpty {
                    StatsEmptyState(
                        message: monitor.selectedSession == nil
                            ? "No turns match this filter in the \(monitor.range.name)."
                            : "No turns match this filter in \(monitor.recordScopeName).",
                        systemImage: "line.3.horizontal.decrease"
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(monitor.filteredRecords) { record in
                                RouterDivider(color: Color(hex: 0xE0F0E8, opacity: 0.045))
                                row(record)
                            }
                        }
                    }
                    .frame(minHeight: 320, maxHeight: .infinity)
                }
            }
        }
    }

    /// Switchyard records an origin only for a client that sends the header, so
    /// the column appears only once something in view actually has one — a
    /// single-client setup keeps the width for the role and model names.
    private var showsOrigin: Bool {
        monitor.filteredRecords.contains { $0.origin != nil }
    }

    private var header: some View {
        HStack(spacing: 8) {
            headerCell("Time", width: 74, alignment: .leading)
            headerCell("Role", width: nil, alignment: .leading)
            if showsOrigin {
                headerCell("Origin", width: 84, alignment: .leading)
            }
            headerCell("Model", width: 132, alignment: .leading)
            headerCell("Prompt", width: 70, alignment: .trailing)
            headerCell("Cached", width: 70, alignment: .trailing)
            headerCell("Output", width: 62, alignment: .trailing)
        }
        .padding(.bottom, 5)
    }

    private func headerCell(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(text.uppercased())
            .font(RouterTheme.mono(9.5, .medium))
            .tracking(0.85)
            .foregroundStyle(RouterTheme.ink3)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func row(_ record: RoutingLogRecord) -> some View {
        let isSelected = monitor.selectedRecord?.id == record.id
        return Button {
            monitor.selectedRecordID = record.id
        } label: {
            HStack(spacing: 8) {
                Text(record.timestamp?.formatted(date: .omitted, time: .standard) ?? "—")
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink3)
                    .frame(width: 74, alignment: .leading)
                Text(monitor.role(for: record) ?? "—")
                    .font(RouterTheme.sans(11.5))
                    .foregroundStyle(record.isClassifier ? RouterTheme.ink3 : RouterTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsOrigin {
                    Text(record.origin ?? "—")
                        .font(RouterTheme.mono(10.5))
                        .foregroundStyle(RouterTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 84, alignment: .leading)
                }
                Text(record.model ?? "—")
                    .font(RouterTheme.mono(10.5))
                    .foregroundStyle(RouterTheme.ink2)
                    .frame(width: 132, alignment: .leading)
                tokenCell(record.tokens.prompt, width: 70)
                tokenCell(record.tokens.cached, width: 70)
                tokenCell(record.tokens.completion, width: 62)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                isSelected ? RouterTheme.accent.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func tokenCell(_ value: Int, width: CGFloat) -> some View {
        Text(value == 0 ? "—" : value.formatted(.number.notation(.compactName)))
            .font(RouterTheme.mono(10.5))
            .foregroundStyle(value == 0 ? RouterTheme.ink3 : RouterTheme.ink2)
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let record = monitor.selectedRecord {
            StatsPanel(
                title: "Selected turn",
                note: record.timestamp?.formatted(date: .omitted, time: .standard) ?? "—"
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    detailRow("session", monitor.sessionName(for: record) ?? "—")
                    if monitor.sessionName(for: record) != record.sessionID {
                        detailRow("session id", record.sessionID ?? "—")
                    }
                    detailRow("route", record.route ?? "—")
                    detailRow("algorithm", record.algorithm ?? "—")
                    detailRow("role", monitor.role(for: record) ?? "—")
                    detailRow("task", record.task ?? "—")
                    detailRow("origin", record.origin ?? "—")
                    detailRow("model", record.model ?? "—")
                    detailRow("prompt tokens", record.tokens.prompt.formatted())
                    detailRow("cached tokens", record.tokens.cached.formatted())
                    detailRow("output tokens", record.tokens.completion.formatted())
                    detailRow("reasoning tokens", record.tokens.reasoning.formatted())
                    detailRow("total tokens", record.tokens.total.formatted())
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.fields) { field in
                            HStack(alignment: .top, spacing: 8) {
                                Text(field.name)
                                    .font(RouterTheme.mono(9.5))
                                    .foregroundStyle(RouterTheme.ink3)
                                    .frame(width: 118, alignment: .leading)
                                Text(field.value)
                                    .font(RouterTheme.mono(9.5))
                                    .foregroundStyle(RouterTheme.ink2)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Full log record · \(record.fields.count) fields")
                        .font(RouterTheme.sans(11))
                        .foregroundStyle(RouterTheme.ink2)
                }
                .padding(.top, 4)

                Text(
                    """
                    Prompts and source code pass through the local proxy to the upstream \
                    endpoint. switchyard-desktop shows only what Switchyard recorded: the model that \
                    served the turn and its token usage. Latency and error counts live in the \
                    proxy's own counters, on the Statistics pane.
                    """
                )
                .font(RouterTheme.sans(10.5))
                .foregroundStyle(RouterTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
        } else {
            StatsPanel(title: "Selected turn") {
                StatsEmptyState(
                    message: "Select a routed turn to see its full log record.",
                    systemImage: "hand.tap"
                )
            }
        }
    }

    private func detailRow(_ key: String, _ value: String, tint: Color = RouterTheme.ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(RouterTheme.mono(9.5))
                .foregroundStyle(RouterTheme.ink3)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(RouterTheme.mono(10.5, .medium))
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
