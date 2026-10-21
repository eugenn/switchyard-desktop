import Foundation
import Testing
@testable import SwitchyardDesktopKit

@Test func diagnosticRedactorRemovesCredentialsAndApiKeyLikeValues() {
    let diagnostic = """
        Authorization: Bearer authorization-secret
        Cookie: session=cookie-secret
        x-api-key=header-key-secret
        OPENAI_API_KEY=environment-key-secret
        access_token="access-token-secret"
        upstream rejected sk-proj-1234567890abcdefghijklmnop
        opaque value abcdefghijklmnopqrstuvwxyz0123456789ABCD
        """

    let redacted = DiagnosticRedactor.redact(diagnostic)

    for secret in [
        "authorization-secret",
        "cookie-secret",
        "header-key-secret",
        "environment-key-secret",
        "access-token-secret",
        "sk-proj-1234567890abcdefghijklmnop",
        "abcdefghijklmnopqrstuvwxyz0123456789ABCD",
    ] {
        #expect(!redacted.contains(secret))
    }
    #expect(redacted.contains(DiagnosticRedactor.placeholder))
}

@Test func diagnosticRedactorDropsDiagnosticsContainingRequestOrSourceFields() {
    for diagnostic in [
        #"{"prompt":"do not retain this prompt"}"#,
        #"request_body={"messages":[{"content":"private request"}]}"#,
        #"source_code="private source code""#,
        #"body: {"input":"private input"}"#,
    ] {
        #expect(
            DiagnosticRedactor.redact(diagnostic)
                == DiagnosticRedactor.requestContentPlaceholder
        )
    }
}

@Test func diagnosticRedactorKeepsOrdinaryOperationalErrorsUseful() {
    let diagnostic = "error: failed to bind 127.0.0.1:4100"
    #expect(DiagnosticRedactor.redact(diagnostic) == diagnostic)
}

@Test func dryRunFailureDoesNotExposeSubprocessCredentials() throws {
    let directory = try diagnosticDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binary = try diagnosticScript(
        in: directory,
        output: "Authorization: Bearer dry-run-secret"
    )

    do {
        try SwitchyardConfigWriter.validate(
            configPath: directory.appendingPathComponent("routes.toml"),
            binaryPath: binary
        )
        Issue.record("Expected the diagnostic script to fail.")
    } catch {
        #expect(!error.localizedDescription.contains("dry-run-secret"))
        #expect(error.localizedDescription.contains(DiagnosticRedactor.placeholder))
    }
}

private func diagnosticDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func diagnosticScript(in directory: URL, output: String) throws -> URL {
    let script = directory.appendingPathComponent("diagnostic-server.sh")
    let escapedOutput = output.replacingOccurrences(of: "'", with: "'\\''")
    try "#!/bin/sh\nprintf '%s\\n' '\(escapedOutput)'\nexit 1\n"
        .write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

/// The reason an upstream gave is the whole point of keeping its output: a
/// rejection reduced to its type and parameter explains nothing.
@Test func diagnosticRedactorKeepsAnUpstreamErrorMessage() {
    let diagnostic =
        #"{"error": {"message": "No tool call found for function call output with call_id call_x1.", "type": "invalid_request_error", "param": "input", "code": null}}"#

    #expect(DiagnosticRedactor.redact(diagnostic) == diagnostic)
}

/// The two narrowed names still carry a request or a listing under their own
/// carrier, and that is what the pattern matches on.
@Test func diagnosticRedactorStillDropsAMessageCarryingRequestContent() {
    for diagnostic in [
        #"{"message": {"role": "user", "content": "private request"}}"#,
        #"{"messages": [{"role": "user", "text": "private request"}]}"#,
        #"{"code": {"content": "private source code"}}"#,
        #"source_code="private source code""#,
    ] {
        #expect(
            DiagnosticRedactor.redact(diagnostic)
                == DiagnosticRedactor.requestContentPlaceholder
        )
    }
}
