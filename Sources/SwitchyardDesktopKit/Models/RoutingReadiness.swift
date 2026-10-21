import Darwin
import Foundation

/// A prerequisite result shown before Apply. A skipped check is deliberately
/// not considered a pass: the user must resolve the preceding blocker first.
package enum ReadinessStatus: Equatable, Sendable {
    case pending
    case passed(String)
    case failed(String)
    case skipped(String)

    package var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    package var message: String {
        switch self {
        case .pending:
            return "Not checked yet."
        case .passed(let message), .failed(let message), .skipped(let message):
            return message
        }
    }
}

/// All external conditions required before the app writes its own files or
/// starts its managed proxy. Nothing the user owns is written, so the only
/// destination checked here is the generated Codex profile.
package struct RoutingReadiness: Equatable, Sendable {
    package let routingConfigPath: URL
    package let codexProfilePath: URL
    package let resolvedBinaryPath: URL?
    /// Whether the resolved server takes the route `vision` key. False until a
    /// binary resolves, so an unknown server never gets a config it rejects.
    package let serverSupportsVision: Bool
    package let binary: ReadinessStatus
    package let generatedConfig: ReadinessStatus
    package let dryRun: ReadinessStatus
    package let codexProfile: ReadinessStatus
    package let endpoint: ReadinessStatus
    package let upstream: ReadinessStatus

    package init(
        routingConfigPath: URL, codexProfilePath: URL, resolvedBinaryPath: URL?, serverSupportsVision: Bool,
        binary: ReadinessStatus, generatedConfig: ReadinessStatus, dryRun: ReadinessStatus,
        codexProfile: ReadinessStatus, endpoint: ReadinessStatus, upstream: ReadinessStatus
    ) {
        self.routingConfigPath = routingConfigPath
        self.codexProfilePath = codexProfilePath
        self.resolvedBinaryPath = resolvedBinaryPath
        self.serverSupportsVision = serverSupportsVision
        self.binary = binary
        self.generatedConfig = generatedConfig
        self.dryRun = dryRun
        self.codexProfile = codexProfile
        self.endpoint = endpoint
        self.upstream = upstream
    }

    package static func pending(routingConfigPath: URL, codexProfilePath: URL) -> RoutingReadiness {
        RoutingReadiness(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath,
            resolvedBinaryPath: nil,
            serverSupportsVision: false,
            binary: .pending,
            generatedConfig: .pending,
            dryRun: .pending,
            codexProfile: .pending,
            endpoint: .pending,
            upstream: .pending
        )
    }

    package var isReady: Bool {
        [
            binary,
            generatedConfig,
            dryRun,
            codexProfile,
            endpoint,
            upstream,
        ].allSatisfy(\.isPassed)
    }

    package var blockers: [String] {
        [
            binary,
            generatedConfig,
            dryRun,
            codexProfile,
            endpoint,
            upstream,
        ].compactMap { status in
            switch status {
            case .failed(let message):
                return message
            case .skipped(let message):
                return message
            case .pending:
                return "Prerequisites have not been checked yet."
            case .passed:
                return nil
            }
        }
    }

    package var failureDescription: String {
        blockers.joined(separator: "\n")
    }
}

/// Makes preflight testable without starting a proxy or writing a Codex profile.
package protocol RoutingReadinessChecking: Sendable {
    func check(
        profile: RoutingProfile,
        binaryPathOverride: String,
        routingConfigPath: URL,
        codexProfilePath: URL
    ) -> RoutingReadiness
}

/// Default prerequisite checks for a direct-distribution installation.
package struct RoutingReadinessChecker: RoutingReadinessChecking {
    private let liteLLMAvailable: @Sendable () -> Bool
    private let locateBinary: @Sendable (String) -> URL?
    private let portHolder: @Sendable (Int) -> (pid: Int32, path: String?)?

    package init(
        liteLLMAvailable: @escaping @Sendable () -> Bool = { LiteLLMProcessManager.isAvailable },
        binaryLocator: @escaping @Sendable (String) -> URL? = {
            SwitchyardBinaryLocator.locate(explicitPath: $0)
        },
        portHolder: @escaping @Sendable (Int) -> (pid: Int32, path: String?)? = {
            LeftoverProcessReclaimer().holder(ofPort: $0)
        }
    ) {
        self.liteLLMAvailable = liteLLMAvailable
        self.locateBinary = binaryLocator
        self.portHolder = portHolder
    }

    package func check(
        profile: RoutingProfile,
        binaryPathOverride: String,
        routingConfigPath: URL,
        codexProfilePath: URL
    ) -> RoutingReadiness {
        let binary = locateBinary(binaryPathOverride)
        let binaryStatus: ReadinessStatus
        if let binary {
            binaryStatus = .passed("Using \(binary.path).")
        } else {
            binaryStatus = .failed(SwitchyardBinaryLocator.installInstructions)
        }

        // Declared only when every target accepts images; whether the server
        // takes the key at all is settled by the dry-run below.
        let wantsVision = profile.advertisesImageInput

        let generatedConfigStatus: ReadinessStatus
        let renderedConfig: String?
        do {
            renderedConfig = try SwitchyardConfigWriter.render(
                profile: profile, serverSupportsVision: wantsVision
            )
            generatedConfigStatus = .passed("Generated configuration is valid.")
        } catch {
            renderedConfig = nil
            generatedConfigStatus = .failed(error.localizedDescription)
        }

        var supportsVision = false
        let dryRunStatus: ReadinessStatus
        if let binary, let renderedConfig {
            let attempt = dryRun(binaryPath: binary, renderedConfig: renderedConfig)
            if attempt.isPassed {
                supportsVision = wantsVision
                dryRunStatus = attempt
            } else if wantsVision,
                      let withoutVision = try? SwitchyardConfigWriter.render(
                          profile: profile, serverSupportsVision: false
                      ),
                      dryRun(binaryPath: binary, renderedConfig: withoutVision).isPassed {
                // The same file minus the `vision` key is accepted, so this is a
                // switchyard-server build from before that key existed.
                dryRunStatus = .passed(
                    """
                    switchyard-server accepted the generated configuration, without image \
                    input: this build does not take the route `vision` key.
                    """
                )
            } else {
                dryRunStatus = attempt
            }
        } else {
            dryRunStatus = .skipped(
                "Dry-run is waiting for an executable server and a valid routing profile."
            )
        }

        let codexProfileStatus = writableDestinationStatus(
            configPath: codexProfilePath,
            label: "Codex profile"
        )
        let endpointStatus = endpointStatus(host: profile.host, port: profile.port)
        let upstreamStatus: ReadinessStatus
        if profile.algorithm == .noop {
            upstreamStatus = .passed("No-op routing does not call an upstream model.")
        } else if profile.needsManagedLiteLLM {
            if !liteLLMAvailable() {
                upstreamStatus = .failed(AppRuntimeLocator.missingLiteLLMMessage)
            } else if profile.port == LiteLLMProcessManager.port {
                upstreamStatus = .failed("LiteLLM requires port 4101, so Switchyard cannot use it.")
            } else if !Self.isPortAvailable(host: "127.0.0.1", port: LiteLLMProcessManager.port) {
                upstreamStatus = .failed(
                    "LiteLLM requires an available port 4101, separate from Switchyard"
                        + Self.holderSuffix(portHolder(LiteLLMProcessManager.port)) + "."
                )
            } else if profile.usesManagedLiteLLM {
                upstreamStatus = .passed("Bundled LiteLLM is available on port 4101. ChatGPT sign-in is checked at Start.")
            } else if case .failed(let reason) = self.upstreamStatus(profile.upstreamBaseURL) {
                upstreamStatus = .failed(reason)
            } else {
                // Served turns still go direct; only the judge call needs LiteLLM.
                upstreamStatus = .passed(
                    """
                    \(profile.upstreamBaseURL) for routed turns, bundled LiteLLM on port 4101 \
                    for the classifier call. ChatGPT sign-in is checked at Start.
                    """
                )
            }
        } else {
            upstreamStatus = self.upstreamStatus(profile.upstreamBaseURL)
        }

        return RoutingReadiness(
            routingConfigPath: routingConfigPath,
            codexProfilePath: codexProfilePath,
            resolvedBinaryPath: binary,
            serverSupportsVision: supportsVision,
            binary: binaryStatus,
            generatedConfig: generatedConfigStatus,
            dryRun: dryRunStatus,
            codexProfile: codexProfileStatus,
            endpoint: endpointStatus,
            upstream: upstreamStatus
        )
    }

    private func dryRun(binaryPath: URL, renderedConfig: String) -> ReadinessStatus {
        let temporaryConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchyard-desktop-preflight-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: temporaryConfig) }

        do {
            try renderedConfig.write(to: temporaryConfig, atomically: true, encoding: .utf8)
            try SwitchyardConfigWriter.validate(configPath: temporaryConfig, binaryPath: binaryPath)
            return .passed("switchyard-server accepted the generated configuration.")
        } catch {
            return .failed(Self.explained(error, binaryPath: binaryPath))
        }
    }

    /// A server older than the generated file rejects it as an unknown key, and
    /// the raw TOML parse error says nothing about which side is behind. Name
    /// the resolved binary, since a command-line run resolves one from `PATH`
    /// rather than the bundle's own.
    package static func explained(_ error: Error, binaryPath: URL) -> String {
        let message = error.localizedDescription
        guard message.contains("unknown field") else { return message }
        return """
            \(message)

            This switchyard-server is older than the configuration switchyard-desktop generates: \
            it does not know that key yet. Update the server at \(binaryPath.path), or clear \
            the switchyard-server override to use the one bundled with this app.
            """
    }

    private func writableDestinationStatus(configPath: URL, label: String) -> ReadinessStatus {
        let writablePath = nearestExistingParent(of: configPath)
        if FileManager.default.isWritableFile(atPath: writablePath.path) {
            return .passed("\(label) will be written at \(configPath.path).")
        }
        return .failed(
            "\(label) cannot be written at \(configPath.path). Check the directory permissions."
        )
    }

    private func nearestExistingParent(of url: URL) -> URL {
        var candidate = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return candidate
    }

    private func endpointStatus(host: String, port: Int) -> ReadinessStatus {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard RoutingProfile.isLoopbackHost(normalizedHost) else {
            return .failed(
                "The proxy host must be loopback-only (127.0.0.1, localhost, or ::1)."
            )
        }
        guard (1024...65535).contains(port), port != RoutingProfile.reservedPort else {
            return .failed("Choose an available non-reserved port between 1024 and 65535.")
        }
        guard Self.isPortAvailable(host: normalizedHost, port: port) else {
            // Naming the holder is the difference between a dead end and an
            // action: the usual cause is a server this app left behind, which
            // Start reclaims, and the rest is someone else's program.
            return .failed(
                "The local proxy endpoint \(host):\(port) is already in use\(Self.holderSuffix(portHolder(port))). "
                    + "Choose another port."
            )
        }
        return .passed("Local endpoint \(host):\(port) is loopback-only and available.")
    }

    /// " — held by switchyard-server (pid 18590)", or nothing when the holder
    /// cannot be read.
    package static func holderSuffix(_ holder: (pid: Int32, path: String?)?) -> String {
        guard let holder else { return "" }
        let name = holder.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "an unknown process"
        return " — held by \(name) (pid \(holder.pid))"
    }

    private func upstreamStatus(_ rawURL: String) -> ReadinessStatus {
        guard RoutingProfile.isValidUpstreamURL(rawURL) else {
            return .failed(
                "Use an absolute http(s) upstream URL without credentials, query values, or fragments."
            )
        }
        return .passed("Requests will be forwarded to \(rawURL).")
    }

    /// Whether a server could bind this port right now.
    ///
    /// `SO_REUSEADDR` matches how both bundled servers bind: without it a
    /// connection still in TIME_WAIT from the run that just stopped reads as
    /// "port in use", and restarting routing fails for a minute for no reason
    /// a user can see.
    package static func isPortAvailable(host: String, port: Int) -> Bool {
        if host == "::1" {
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            allowAddressReuse(descriptor)

            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else { return false }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        allowAddressReuse(descriptor)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func allowAddressReuse(_ descriptor: Int32) {
        var enabled: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size)
        )
    }
}
