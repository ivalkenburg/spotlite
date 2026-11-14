import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin diagnostics")
struct PluginDiagnosticsTests {
    /// A one-script plugin in a scratch folder, removed by the caller.
    private func plugin(_ script: String, settings: String = "[]") throws -> InstalledPlugin {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spotlite-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"id":"demo","name":"Demo","executable":"run.sh","settings":\#(settings),"commands":[{"id":"main","title":"Demo","action":{"type":"run"}}]}"#
            .write(to: directory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("run.sh")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return PluginStore.load(directory)
    }

    private func report(_ script: String, environment: [String: String] = ["PATH": "/usr/bin:/bin"]) async throws -> PluginRunReport {
        let plugin = try plugin(script)
        defer { try? FileManager.default.removeItem(at: plugin.directory) }
        return await withCheckedContinuation { continuation in
            PluginRun.startReporting(executable: plugin.executableURL!, arguments: [], environment: environment,
                                     directory: plugin.directory, timeout: 5) { continuation.resume(returning: $0) }
        }
    }

    @Test func tailBufferKeepsTheEnd() {
        var buffer = TailBuffer(limit: 4)
        for chunk in ["ab", "cdef", "ghijklmn", "o"] { buffer.append(Data(chunk.utf8)) }
        #expect(buffer.bytes == Data("lmno".utf8))
        var short = TailBuffer(limit: 4)
        short.append(Data("ab".utf8))
        #expect(short.bytes == Data("ab".utf8))
    }

    @Test func tailTextDropsAHalfCharacter() {
        let cut = Data("é!".utf8).dropFirst()
        #expect(PluginDiagnostics.text(Data(cut)) == "!")
    }

    @Test func summaryLineIsTheLastNonemptyLine() {
        #expect(PluginDiagnostics.summaryLine("Traceback:\n  File x\nValueError: bad\n\n") == "ValueError: bad")
        #expect(PluginDiagnostics.summaryLine("") == "")
        #expect(PluginDiagnostics.summaryLine(String(repeating: "x", count: 300)).count == 201)
    }

    @Test func keepsTheTailOfALongErrorOutput() async throws {
        let report = try await report("head -c 40000 /dev/zero | tr '\\0' x >&2; echo >&2; echo 'final: it broke' >&2; exit 4")
        #expect(report.result == .failure(.failed(status: 4, message: "final: it broke")))
        #expect(report.status == 4)
        #expect(report.errorOutput.count == 16 * 1024)
        #expect(report.errorText.hasSuffix("final: it broke\n"))
        #expect(report.duration > 0)
    }

    @Test func runawayOutputNeverRetainsMoreThanTheLimit() async throws {
        let report = try await report("head -c 6000000 /dev/zero")
        #expect(report.result == .failure(.outputTooLarge))
        #expect(report.output.count == PluginRun.maxOutput)
    }

    @Test func explainsInvalidJSON() async throws {
        let report = try await report(#"echo 'hello {'"#)
        guard case .failure(.invalidOutput(let detail)) = report.result else {
            Issue.record("expected invalid output, got \(report.result)")
            return
        }
        #expect(detail.contains("not valid JSON"))
        #expect(detail.hasSuffix("Output began: hello {\n"))
        #expect(PluginRunError.invalidOutput(detail).message == "The plugin returned invalid JSON")
        #expect(PluginRunError.invalidOutput(detail).detail.contains("Output began: hello {"))
        #expect(report.output == Data("hello {\n".utf8))
    }

    @Test func explainsAMistypedResponse() async throws {
        // Lenient keys are skipped; a response that is JSON but not an object fails.
        let lenient = try await report(#"printf '{"items":[{"title":1}], "copy": 5, "open": [] }'"#)
        #expect((try? lenient.result.get()) != nil)
        let array = try await report("printf '[1,2]'")
        guard case .failure(.invalidOutput(let detail)) = array.result else {
            Issue.record("expected invalid output")
            return
        }
        #expect(detail.contains("Output began: [1,2]"))
    }

    @Test func excerptCutsOnACharacter() {
        let text = String(repeating: "é", count: 150)
        let excerpt = PluginDiagnostics.excerpt(Data(text.utf8), bytes: 201)
        #expect(excerpt == String(repeating: "é", count: 100) + "…")
        #expect(PluginDiagnostics.excerpt(Data("short".utf8), bytes: 200) == "short")
    }

    @Test func recordDescribesARun() {
        let failed = PluginRunReport(result: .failure(.failed(status: 2, message: "boom")), status: 2,
                                     output: Data(String(repeating: "o", count: 1000).utf8),
                                     errorOutput: Data("warning\nboom\n".utf8), duration: 0.0424)
        let record = PluginRunRecord(report: failed, commandID: "switch", action: .search, arguments: ["use", "two words"])
        #expect(record.failed)
        #expect(record.outputExcerpt.count == 401)
        #expect(record.details.hasPrefix("switch · search · use “two words”\nexit 2 · 42 ms\nError: boom\n\nstderr:\nwarning\nboom\n\nstdout:\n"))
        let fine = PluginRunRecord(report: PluginRunReport(result: .success(PluginResponse()), status: 0, duration: 1.5),
                                   commandID: "main", action: .run, arguments: [])
        #expect(!fine.failed)
        #expect(fine.details == "main · run\nexit 0 · 1.50 s")
    }

    @Test func formatsOutputForReading() {
        #expect(PluginDiagnostics.formatted(Data(#"{"b":1,"a":"x/y"}"#.utf8)) == "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
        #expect(PluginDiagnostics.formatted(Data("plain".utf8)) == "plain")
        #expect(PluginDiagnostics.summary(of: PluginResponse()) == "Valid response, nothing to apply")
        let response = try! PluginResponse.decode(Data(#"{"items":[{"title":"a"}],"toast":"t","copy":"c"}"#.utf8))
        #expect(PluginDiagnostics.summary(of: response) == "Valid response: 1 item, toast, copy")
    }

    @Test func namesConfigurationVariables() {
        #expect(PluginEnvironment.variableName(forSetting: "resultLimit") == "SPOTLITE_CONFIG_RESULTLIMIT")
        #expect(PluginEnvironment.variableName(forSetting: "api-key.v2") == "SPOTLITE_CONFIG_API_KEY_V2")
    }

    @Test func exportsScalarSettings() {
        let variables = PluginEnvironment.configurationVariables(
            ids: ["org", "limit", "ratio", "archived", "optional", "api-key", "api_key", "API_KEY2"],
            values: ["org": .string(" acme "), "limit": .number(20), "ratio": .number(0.5),
                     "archived": .boolean(false), "api-key": .string("a"), "api_key": .string("b"),
                     "API_KEY2": .string("c")])
        #expect(variables == [
            "SPOTLITE_CONFIG_ORG": " acme ",
            "SPOTLITE_CONFIG_LIMIT": "20",
            "SPOTLITE_CONFIG_RATIO": "0.5",
            "SPOTLITE_CONFIG_ARCHIVED": "false",
            // api-key and api_key collide, so neither is exported; the JSON has both.
            "SPOTLITE_CONFIG_API_KEY2": "c",
        ])
    }

    @Test func environmentSaysHowThePluginStarted() throws {
        let plugin = try plugin("true")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }
        let environment = PluginEnvironment.make(
            for: plugin, query: "q", base: ["PATH": "/usr/bin", "SPOTLITE_CONFIG_STALE": "inherited"],
            dataDirectory: plugin.directory, configurationJSON: #"{"org":"acme"}"#,
            configurationVariables: ["SPOTLITE_CONFIG_ORG": "acme"], command: "switch", action: .search,
            appearance: "dark", version: "1.2.3")
        #expect(environment["SPOTLITE_CONFIG"] == #"{"org":"acme"}"#)
        #expect(environment["SPOTLITE_CONFIG_ORG"] == "acme")
        #expect(environment["SPOTLITE_CONFIG_STALE"] == nil)
        #expect(environment["SPOTLITE_COMMAND"] == "switch")
        #expect(environment["SPOTLITE_ACTION"] == "search")
        #expect(environment["SPOTLITE_APPEARANCE"] == "dark")
        #expect(environment["SPOTLITE_VERSION"] == "1.2.3")
    }

    @Test func passesPerFieldValuesToTheProgram() async throws {
        let plugin = try plugin("true")
        defer { try? FileManager.default.removeItem(at: plugin.directory) }
        let environment = PluginEnvironment.make(
            for: plugin, query: "", base: ["PATH": "/usr/bin:/bin"], dataDirectory: plugin.directory,
            configurationVariables: PluginEnvironment.configurationVariables(ids: ["limit"], values: ["limit": .number(3)]),
            command: "main", action: .run)
        let report = try await report(#"printf '{"copy":"%s %s %s"}' "$SPOTLITE_CONFIG_LIMIT" "$SPOTLITE_COMMAND" "$SPOTLITE_ACTION""#,
                                      environment: environment)
        #expect(try report.result.get().copy == "3 main run")
    }

    @Test func actionsThatStartTheExecutable() {
        #expect(PluginRunAction(.search(args: [], debounce: 0, minimumQuery: 0)) == .search)
        #expect(PluginRunAction(.list(args: [])) == .list)
        #expect(PluginRunAction(.run(args: [], keepOpen: true)) == .run)
        #expect(PluginRunAction(.copy("x")) == nil)
    }
}
