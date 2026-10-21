import Foundation
import Observation

/// Backs the statistics window: which pane is showing, and the live data it
/// reads from the running proxy and its durable routing log.
///
/// Polling runs only while the window is on screen, and every read is
/// loopback-local: the proxy's own `/v1/stats` on the app's configured port and
/// the JSONL log the app asked it to write.
@MainActor
@Observable
package final class RoutingMonitor {
    package enum Pane: String, CaseIterable, Identifiable {
        case statistics, requests, overview

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .overview: "Overview"
            case .statistics: "Statistics"
            case .requests: "Requests"
            }
        }

        package var symbol: String {
            switch self {
            case .overview: "waveform.path.ecg"
            case .statistics: "chart.bar"
            case .requests: "list.bullet"
            }
        }
    }

    /// The log distinguishes a served turn from a judge call and nothing else,
    /// so these are the only filters it can honestly offer.
    package enum RequestFilter: String, CaseIterable, Identifiable {
        case all, routed, classifier

        package var id: String { rawValue }

        package var label: String {
            switch self {
            case .all: "All"
            case .routed: "Routed"
            case .classifier: "Classifier"
            }
        }
    }

    package var pane: Pane = .statistics
    package var range: MetricsRange = .sixHours
    package var selectedModelID: String?
    /// The client conversation the user picked. Nil lets the flow map follow
    /// the newest one and the request list show every conversation.
    package var selectedSessionID: String?
    package var filter: RequestFilter = .all
    package var selectedRecordID: Int?

    package private(set) var stats: RoutingStats?
    package private(set) var statsError: String?
    /// The log's tail narrowed to the current routing run, so every pane
    /// describes the run the user just started rather than the log's history.
    package private(set) var records: [RoutingLogRecord] = [] {
        didSet { recordsRevision &+= 1 }
    }
    /// When the run the window describes began: the active route, or the last
    /// one after it stopped. Nil until a route has run, which shows the whole log.
    package private(set) var runStart: Date?
    /// A new run has no conversation yet. The first one it routes is picked
    /// for the user, once, and a choice of their own ends the wait.
    package private(set) var awaitsFirstSession = false
    /// The log's tail as read, before it is narrowed to the run.
    @ObservationIgnored private var logRecords: [RoutingLogRecord] = []
    package private(set) var lastRefresh: Date?
    package private(set) var isRefreshing = false
    /// Conversation id to the name Codex shows for it, refreshed with the log.
    package private(set) var sessionNames: [String: String] = [:]
    package private(set) var contextWindows: [String: Int] = [:]
    package private(set) var routeContextWindows: [String: Int] = [:]
    /// LiteLLM's price map: the last download, or the bundled copy until one
    /// arrives. Read on the first refresh and re-downloaded at most daily.
    package private(set) var prices: ModelPriceTable = .empty

    package let model: WizardModel
    private let statsClient: SwitchyardStatsClient
    private let logReader: RoutingLogReader
    private let sessionNameReader: CodexSessionNameReader
    private let modelContextReader: CodexModelContextReader
    private let sessionContextReader: CodexSessionContextReader
    private let priceReader: ModelPriceReader
    @ObservationIgnored private var pricesLoaded = false
    /// Compared instead of the table itself, which holds thousands of entries.
    @ObservationIgnored private var pricesRevision = 0
    @ObservationIgnored private var priceDownload: Task<Void, Never>?
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var isWindowVisible = true
    private var recordsRevision = 0
    /// Bumped on every beat of the recalculation signal, so the session cost
    /// is worked out afresh from the log read on that same beat.
    private var costRevision = 0
    /// When the session cost was last recalculated on a beat.
    package private(set) var lastCostRecalculation: Date?
    package let recalculationSignal: RecalculationSignal
    private let createdAt = Date()

    /// Each point in the routed-turns sparkline represents five minutes.
    /// The history picker is intentionally absent from Statistics, so the
    /// default six-hour range renders as 72 equally sized intervals.
    private static let routedTurnsBucketDuration: TimeInterval = 5 * 60

    /// Fixed cache slots retain only the current UI selections. Their keys read
    /// observable inputs even on a hit, so SwiftUI keeps tracking future edits.
    private struct SummaryKey: Equatable {
        package let revision: Int
        package let now: Date
        package let range: MetricsRange
        package let assignments: [String: String]
        package var modelID: String?
        package var sessionID: String?
        package var span: DateInterval?
        package var bucketCount = 12
    }

    private struct Cached<Value> {
        package let key: SummaryKey
        package let value: Value
    }

    @ObservationIgnored private var metricsCache: Cached<RoutingMetrics>?
    @ObservationIgnored private var activityCache: Cached<RoutingMetrics>?
    @ObservationIgnored private var selectedModelCache: Cached<RoutingMetrics>?
    @ObservationIgnored private var costCache: (
        revision: Int, costRevision: Int, sessionID: String?, now: Date, pricesRevision: Int,
        aliases: [String: String], value: TokenCostEstimate
    )?
    @ObservationIgnored private var sessionsCache: (revision: Int, names: [String: String], value: [RoutingSession])?
    @ObservationIgnored private var contextCache: (
        revision: Int, sessionID: String, windows: [String: Int], sessionWindow: Int?, routeWindow: Int?,
        value: [String: ModelContextUsage]
    )?

    package init(
        model: WizardModel,
        statsClient: SwitchyardStatsClient = SwitchyardStatsClient(),
        logReader: RoutingLogReader = RoutingLogReader(),
        sessionNameReader: CodexSessionNameReader = CodexSessionNameReader(),
        modelContextReader: CodexModelContextReader? = nil,
        sessionContextReader: CodexSessionContextReader? = nil,
        priceReader: ModelPriceReader = ModelPriceReader(),
        pollInterval: Duration = .seconds(3),
        recalculationSignal: RecalculationSignal? = nil
    ) {
        self.model = model
        self.statsClient = statsClient
        self.logReader = logReader
        self.sessionNameReader = sessionNameReader
        self.modelContextReader = modelContextReader ?? CodexModelContextReader(configPath: model.codexConfigPath)
        self.sessionContextReader = sessionContextReader
            ?? CodexSessionContextReader(configPath: model.codexConfigPath)
        self.priceReader = priceReader
        self.pollInterval = pollInterval
        self.recalculationSignal = recalculationSignal ?? model.recalculationSignal
        // Held weakly by the signal: the subscription ends with this monitor.
        self.recalculationSignal.subscribe(self) { [weak self] in
            await self?.recalculate()
        }
    }

    // MARK: - Derived state

    package var isRouting: Bool { model.processManager.status.isRunning }

    package var metrics: RoutingMetrics {
        cachedMetrics(range: range, assignments: assignments, cache: &metricsCache)
    }

    /// The conversations the log has seen, newest activity first, under the
    /// names Codex gives them.
    package var sessions: [RoutingSession] {
        let names = sessionNames
        if let cached = sessionsCache, cached.revision == recordsRevision, cached.names == names {
            return cached.value
        }
        let value = RoutingSession.sessions(from: records, names: names)
        sessionsCache = (recordsRevision, names, value)
        return value
    }

    /// The conversation the flow map is narrowed to. A selection that has aged
    /// out of the log's tail reads as no selection rather than as an empty map.
    package var selectedSession: RoutingSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    /// The conversation the flow map shows: the one the user picked, or the
    /// newest one. The map always describes a single conversation, so its
    /// context gauges and cost belong to it.
    package var flowSession: RoutingSession? {
        selectedSession ?? sessions.first
    }

    /// The flow map's window is its session's own lifetime, so its shares
    /// cover every turn it routed rather than the last 15 minutes of it. A log
    /// with no session ids at all falls back to a fixed recent window.
    package var activityMetrics: RoutingMetrics {
        return cachedMetrics(
            range: .fifteenMinutes, assignments: assignments,
            session: flowSession, cache: &activityCache
        )
    }

    /// Conversations that routed a call in the last 15 minutes: the ones the
    /// user is working in now, marked live in the session picker. A record
    /// with no timestamp counts, exactly as `RoutingMetrics` counts it.
    package var activeSessionIDs: Set<String> {
        let now = lastRefresh ?? createdAt
        let start = now.addingTimeInterval(-MetricsRange.fifteenMinutes.duration)
        let futureLimit = now.addingTimeInterval(60)
        var ids: Set<String> = []
        for record in records {
            if let timestamp = record.timestamp, timestamp < start || timestamp > futureLimit { continue }
            guard let id = record.sessionID, !id.isEmpty else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// The conversation the context gauges describe: the flow map's own.
    package var contextSession: RoutingSession? { flowSession }

    /// What the flow map's conversation would cost at API list prices, judge
    /// calls included. Without session ids, the map's recent window instead.
    package var sessionCost: TokenCostEstimate {
        let session = flowSession
        let now = lastRefresh ?? createdAt
        let aliases = liteLLMAliases
        // Read on a hit too, so SwiftUI redraws once the table has loaded.
        let prices = self.prices
        let costRevision = self.costRevision
        if let cached = costCache, cached.revision == recordsRevision, cached.costRevision == costRevision,
           cached.sessionID == session?.id, cached.now == now, cached.pricesRevision == pricesRevision,
           cached.aliases == aliases {
            return cached.value
        }
        let selected: [RoutingLogRecord]
        if let session {
            selected = records.filter { $0.sessionID == session.id }
        } else {
            let start = now.addingTimeInterval(-MetricsRange.fifteenMinutes.duration)
            selected = records.filter { record in record.timestamp.map { $0 >= start } ?? true }
        }
        let value = TokenCostEstimate.estimate(records: selected, prices: prices, aliases: aliases)
        costCache = (recordsRevision, costRevision, session?.id, now, pricesRevision, aliases, value)
        return value
    }

    /// A LiteLLM name the app publishes for a model it serves under another
    /// id, so the judge's own name is priced as the model behind it.
    private var liteLLMAliases: [String: String] {
        var aliases: [String: String] = [:]
        for model in model.profile.managedLiteLLMModels ?? [] where model.name != model.upstreamModel {
            aliases[model.name] = model.upstreamModel
        }
        return aliases
    }

    package var sessionContextUsage: [String: ModelContextUsage] {
        guard let sessionID = contextSession?.id else { return [:] }
        let windows = contextWindows
        // Routing empties Codex's account catalog, so a model the catalog does
        // not name still has the window Codex holds the conversation to.
        let sessionWindow = sessionContextReader.contextWindow(sessionID: sessionID)
        let routeWindow = sessionRouteContextWindow
        if let cached = contextCache, cached.revision == recordsRevision,
           cached.sessionID == sessionID, cached.windows == windows,
           cached.sessionWindow == sessionWindow, cached.routeWindow == routeWindow { return cached.value }
        let value = ModelContextUsage.latest(
            records: records, sessionID: sessionID, contextWindows: windows,
            sessionWindow: sessionWindow, routeWindow: routeWindow)
        contextCache = (recordsRevision, sessionID, windows, sessionWindow, routeWindow, value)
        return value
    }

    /// The route's current declaration is not the capacity of each model.
    package var sessionRouteContextWindow: Int? {
        guard let sessionID = contextSession?.id,
              let route = records.first(where: { $0.sessionID == sessionID && !$0.isClassifier })?.route else {
            return nil
        }
        return routeContextWindows[route]
    }

    /// The selected model's own history, for the activity chart.
    package var selectedModelMetrics: RoutingMetrics {
        let bucketCount = max(Int((range.duration / Self.routedTurnsBucketDuration).rounded(.up)), 1)
        return cachedMetrics(
            range: range, assignments: [:], modelID: selectedModelID,
            bucketCount: bucketCount, cache: &selectedModelCache
        )
    }

    private func cachedMetrics(
        range: MetricsRange, assignments: [String: String], modelID: String? = nil,
        session: RoutingSession? = nil, bucketCount: Int = 12, cache: inout Cached<RoutingMetrics>?
    ) -> RoutingMetrics {
        let key = SummaryKey(
            revision: recordsRevision, now: lastRefresh ?? createdAt, range: range,
            assignments: assignments, modelID: modelID, sessionID: session?.id,
            span: session?.span, bucketCount: bucketCount
        )
        if let cached = cache, cached.key == key { return cached.value }
        var selected = records
        if let session { selected = selected.filter { $0.sessionID == session.id } }
        if let modelID { selected = selected.filter { $0.modelIdentity == modelID } }
        let value = RoutingMetrics.compute(
            records: selected, range: range, assignments: assignments, now: key.now,
            bucketCount: bucketCount, span: session?.span
        )
        cache = Cached(key: key, value: value)
        return value
    }

    /// Per-model latency the proxy measured, narrowed to the model filter.
    package var selectedLatencies: [RoutingStats.ModelUsage] {
        (stats?.models ?? []).filter {
            $0.latency != nil && (selectedModelID == nil || $0.id == selectedModelID)
        }
    }

    /// Judge calls the proxy attempted and how many of them failed. A failing
    /// judge is invisible in the served-turn counters: the route simply serves
    /// its default target on every turn.
    package var classifierFailure: String? {
        guard let stats, stats.classifierErrors > 0 else { return nil }
        return "\(stats.classifierErrors) of \(stats.classifierRequests) classifier calls failed"
    }

    /// Every model the window knows about, in a stable order: a lane keeps its
    /// colour when the flow map is narrowed to one session. Read from the range
    /// summary alone, which always covers at least the flow map's own window.
    package var modelIDs: [String] {
        var seen = Set<String>()
        let configured = model.profile.tiers.compactMap(\.assignedModel).filter { seen.insert($0).inserted }
        let observed = Set(metrics.shares.map(\.id))
        return configured + observed.subtracting(seen).sorted()
    }

    /// Whether the selected algorithm makes a judge call at all, so the flow map
    /// can keep the classifier leg visible before the first one is logged.
    package var usesClassifier: Bool { model.profile.algorithm?.requiresJudge ?? false }

    /// The model the judge call is configured to ask, when the profile names one.
    package var classifierModelID: String? { model.profile.classifierModel }

    /// Model id to the role it serves, so an idle assignment still gets a row.
    package var assignments: [String: String] {
        var map: [String: String] = [:]
        for tier in model.profile.tiers {
            guard let assigned = tier.assignedModel else { continue }
            map[assigned] = tier.displayName
        }
        return map
    }

    /// Model id to the role it serves on the flow map: the role's own name and
    /// the effort it asks for, so the map can ladder its rows by how hard the
    /// work is rather than by how much of it arrived.
    package var flowRoles: [String: FlowRole] {
        var map: [String: FlowRole] = [:]
        for tier in model.profile.tiers {
            guard let assigned = tier.assignedModel else { continue }
            let role = model.profile.role(of: tier)
            let candidate = FlowRole(name: role?.displayName ?? tier.displayName, effort: role?.effort)
            // Several targets may share one model, and the map draws one row
            // for it, so the heaviest of them decides where that row sits.
            if let existing = map[assigned], existing.rank >= candidate.rank { continue }
            map[assigned] = candidate
        }
        return map
    }

    /// The role a record was served under: the judge call is named as such, and
    /// a served turn takes the role its model is assigned to, since Switchyard
    /// leaves `tier` empty for it.
    package func role(for record: RoutingLogRecord) -> String? {
        if record.isClassifier { return "classifier" }
        if let tier = record.tier, !tier.isEmpty { return roleName(for: tier) }
        return record.model.flatMap { assignments[$0] }
    }

    /// The log records Switchyard's own target key (`quick_fixes`), so show the
    /// role name the user typed whenever the two still line up.
    package func roleName(for target: String?) -> String? {
        guard let target else { return nil }
        let names = model.profile.targetNames
        guard let index = names.firstIndex(of: target),
              model.profile.tiers.indices.contains(index) else {
            return target
        }
        return model.profile.tiers[index].displayName
    }

    /// The log list, newest first. A picked session replaces the trailing
    /// window with that conversation itself, so its older turns stay reachable
    /// instead of falling out of the range the user last chose.
    package var filteredRecords: [RoutingLogRecord] {
        let session = selectedSession
        let windowStart = (lastRefresh ?? createdAt).addingTimeInterval(-range.duration)
        return records.filter { record in
            if let session {
                if record.sessionID != session.id { return false }
            } else if let timestamp = record.timestamp, timestamp < windowStart {
                return false
            }
            switch filter {
            case .all: return true
            case .routed: return !record.isClassifier
            case .classifier: return record.isClassifier
            }
        }
    }

    /// The name Codex gives a record's conversation, or its raw id when there
    /// is none to show.
    package func sessionName(for record: RoutingLogRecord) -> String? {
        guard let id = record.sessionID, !id.isEmpty else { return nil }
        return sessionNames[id] ?? id
    }

    /// What the Requests list is currently showing, for its own header.
    package var recordScopeName: String {
        selectedSession?.scopeName ?? "the \(range.name)"
    }

    package var selectedRecord: RoutingLogRecord? {
        let filtered = filteredRecords
        guard let selectedRecordID else { return filtered.first }
        return filtered.first { $0.id == selectedRecordID } ?? filtered.first
    }

    /// Why a pane has nothing to show yet, if that is the case.
    package var emptyReason: String? {
        if !isRouting && records.isEmpty {
            return "Routing is off. Start routing in the setup window, then send a Codex request."
        }
        if records.isEmpty {
            return logReader.logExists
                ? "No routed turns yet. The log fills as Codex sends requests through the proxy."
                : "The routing log appears once the proxy has started and served its first turn."
        }
        return nil
    }

    package var uptime: String? {
        guard let started = model.routingStartedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(started))
        guard seconds >= 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    // MARK: - Prices

    private func setPrices(_ table: ModelPriceTable) {
        pricesRevision &+= 1
        prices = table
    }

    /// One download at a time, and none while the cached map is under a day old.
    private func refreshPricesIfStale() {
        guard priceDownload == nil, priceReader.needsDownload() else { return }
        let reader = priceReader
        priceDownload = Task { [weak self] in
            let downloaded = await reader.downloadPrices()
            guard let self else { return }
            if let downloaded { self.setPrices(downloaded) }
            // A failed download waits an hour rather than retrying on every poll.
            try? await Task.sleep(for: downloaded == nil ? .seconds(3_600) : .zero)
            self.priceDownload = nil
        }
    }

    // MARK: - Routing run

    /// A record written this long before the run began still belongs to it:
    /// the log keeps whole seconds, and the run's own clock does not.
    private static let runStartTolerance: TimeInterval = 1

    /// Narrows the window to the route that is running now. A route that
    /// started since the last call empties every pane and forgets the picked
    /// session and request, which belonged to the run before it.
    package func followRoutingRun() {
        followRun(startedAt: model.routingStartedAt)
    }

    /// `startedAt` is the active route's start, or nil when none is running.
    func followRun(startedAt: Date?) {
        if let started = startedAt, started != runStart {
            runStart = started
            selectedSessionID = nil
            selectedRecordID = nil
            awaitsFirstSession = true
        }
        let scoped: [RoutingLogRecord]
        if let runStart {
            let start = runStart.addingTimeInterval(-Self.runStartTolerance)
            // A record without a time cannot be placed in the run, so it is left out.
            scoped = logRecords.filter { record in record.timestamp.map { $0 >= start } ?? false }
        } else {
            scoped = logRecords
        }
        if records != scoped { records = scoped }
    }

    /// Picks the run's first conversation, preferring one that is live now.
    private func pickFirstSessionIfAwaited() {
        guard awaitsFirstSession else { return }
        if selectedSessionID != nil {
            awaitsFirstSession = false
            return
        }
        let sessions = sessions
        let live = activeSessionIDs
        guard let first = sessions.first(where: { live.contains($0.id) }) ?? sessions.first else { return }
        selectedSessionID = first.id
        awaitsFirstSession = false
    }

    // MARK: - Polling

    package func beginPolling() {
        guard isWindowVisible, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // One immediate read of the Codex selection: a window opened after a
            // drift happened in the background should say so at once.
            await self?.model.refreshCodexSelection()
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    package func endPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    package func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        if visible {
            beginPolling()
        } else {
            endPolling()
        }
    }

    /// One beat of the recalculation signal while the router runs: the
    /// statistics are refreshed and the session cost is recalculated from that
    /// same read, whether or not a window is polling at the time.
    func recalculate() async {
        guard isRouting else { return }
        await refresh()
        costRevision &+= 1
        lastCostRecalculation = Date()
    }

    /// Codex opens a throwaway thread of its own, with its own `session_id`, to
    /// title every new conversation, and that thread is routed like any other
    /// turn. It is not a conversation the user started: it makes a single call
    /// and, unlike a real conversation, never gets a rollout on disk. Only Codex
    /// threads are judged this way; other clients never have a rollout at all.
    nonisolated package static func droppingHousekeepingThreads(
        from records: [RoutingLogRecord], hasRollout: (String) -> Bool
    ) -> [RoutingLogRecord] {
        var servedTurns: [String: Int] = [:]
        for record in records where record.origin == codexOrigin && !record.isClassifier {
            if let id = record.sessionID, !id.isEmpty { servedTurns[id, default: 0] += 1 }
        }
        // A conversation whose rollout is not written yet has more than one turn
        // within moments, so a single turn is what marks the naming thread.
        let housekeeping = Set(servedTurns.filter { $0.value <= 1 && !hasRollout($0.key) }.keys)
        guard !housekeeping.isEmpty else { return records }
        return records.filter { record in
            guard record.origin == codexOrigin, let id = record.sessionID else { return true }
            return !housekeeping.contains(id)
        }
    }

    private nonisolated static let codexOrigin = "codex-cli"

    package func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let reader = logReader
        let nameReader = sessionNameReader
        let contextReader = modelContextReader
        let rolloutReader = sessionContextReader
        let configPath = model.routingConfigPath
        let priceReader = pricesLoaded ? nil : self.priceReader
        let (recent, names, windows, configuredWindows, loadedPrices) = await Task.detached(priority: .utility) {
            (Self.droppingHousekeepingThreads(
                from: reader.recentRecords(),
                hasRollout: { rolloutReader.hasRollout(sessionID: $0) }),
             nameReader.names(), contextReader.contextWindows(),
             SwitchyardRouteContext.configuredWindows(at: configPath), priceReader?.localPrices())
        }.value
        guard !Task.isCancelled else { return }
        if let loadedPrices {
            pricesLoaded = true
            setPrices(loadedPrices)
        }
        refreshPricesIfStale()
        logRecords = recent
        followRoutingRun()
        if sessionNames != names { sessionNames = names }
        pickFirstSessionIfAwaited()
        if contextWindows != windows { contextWindows = windows }

        guard case .running(_, let port) = model.processManager.status else {
            routeContextWindows = configuredWindows
            stats = nil
            statsError = nil
            lastRefresh = Date()
            return
        }

        async let advertisedWindows = try? statsClient.routeContextWindows(host: model.processManager.host, port: port)
        do {
            stats = try await statsClient.stats(host: model.processManager.host, port: port)
            statsError = nil
        } catch {
            stats = nil
            statsError = error.localizedDescription
        }
        routeContextWindows = await advertisedWindows ?? [:]
        lastRefresh = Date()
    }
}
