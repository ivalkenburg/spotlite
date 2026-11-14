import Foundation
import Testing
@testable import SpotliteCore

@Suite("Plugin git processes")
struct PluginGitRunTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func drainsBothPipesWhileRunningAndBoundsDiagnostics() async throws {
        let result = try await PluginGitRun.run(shell, arguments: ["-c", """
            head -c 262144 /dev/zero | tr '\\0' o
            head -c 262144 /dev/zero | tr '\\0' e >&2
            printf '\\nlast error\\n' >&2
            exit 7
            """], timeout: 5)
        #expect(result.code == 7)
        #expect(result.output == String(repeating: "o", count: 4096))
        #expect(result.error == "last error")
    }

    @Test func reportsLaunchFailure() async {
        await #expect(throws: PluginInstallError.download("Couldn’t start git.")) {
            try await PluginGitRun.run(URL(fileURLWithPath: "/missing/git"), arguments: [], timeout: 1)
        }
    }

    @Test func cancellationBeforeStartingDoesNotLaunchTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PluginGitRun.run(shell, arguments: ["-c", "touch \"$1\"", "git", marker.path], timeout: 5)
        }
        await #expect(throws: PluginInstallError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: [false, true])
    func stopsProcessesThatIgnoreTermination(cancel: Bool) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            try await PluginGitRun.run(shell, arguments: ["-c", """
                trap '' TERM
                echo $$ > "$1"
                while :; do /bin/sleep 1; done
                """, "git", marker.path], timeout: cancel ? 5 : 0.2)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        if cancel { task.cancel() }
        let expected: PluginInstallError = cancel ? .cancelled : .download("git took too long.")
        await #expect(throws: expected) { try await task.value }
        // SIGTERM was deliberately ignored; escalation must stop the process too.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
