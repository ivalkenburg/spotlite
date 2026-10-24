import Foundation
import Testing
@testable import SpotliteCore

private final class PluginDownloadProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "plugins.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let declared = url.path == "/declared"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: declared ? ["Content-Length": "1000000"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path == "/success" {
            client?.urlProtocol(self, didLoad: Data("plugin data".utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else if !declared { sendChunk(0) }
    }
    private func sendChunk(_ index: Int) {
        lock.lock(); let active = !stopped; lock.unlock()
        guard active else { return }
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 512))
        if index >= 999 { client?.urlProtocolDidFinishLoading(self) }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { [self] in sendChunk(index + 1) } }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

@Suite("Bounded plugin downloads")
struct PluginDownloadTests {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginDownloadProtocol.self]
        return configuration
    }
    private func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://plugins.test/" + path)!) }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpotliteDownloadTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func boundedResponsesReturnTheirDataAndStatus() async throws {
        let (data, response) = try await PluginDownload.data(for: request("success"), limit: 1024, configuration: configuration())
        #expect(String(decoding: data, as: UTF8.self) == "plugin data")
        #expect(response.statusCode == 200)
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (file, _) = try await PluginDownload.file(for: request("success"), limit: 1024, directory: root, configuration: configuration())
        #expect(try Data(contentsOf: file) == data)
    }

    @Test(arguments: ["declared", "stream"])
    func oversizedResponsesStopAndRemovePartialFiles(_ path: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await PluginDownload.file(for: request(path), limit: 1024, directory: root, configuration: configuration())
            Issue.record("Oversized response succeeded.")
        } catch { #expect(error.localizedDescription.contains("1024-byte limit")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: (any Error).self) {
            try await PluginDownload.data(for: request(path), limit: 1024, configuration: configuration())
        }
    }

    @Test func cancellationRemovesThePartialDownload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await PluginDownload.file(for: request("stream"), limit: 1024 * 1024,
                                          directory: root, configuration: configuration())
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled download succeeded.") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
