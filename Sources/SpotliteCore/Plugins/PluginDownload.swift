import Foundation

/// Limits transfers as bytes arrive, including responses without Content-Length.
/// Large archives spool to disk; small API responses stay in bounded memory.
public enum PluginDownload {
    public static func data(for request: URLRequest, limit: Int,
                            configuration: URLSessionConfiguration = .ephemeral) async throws -> (Data, HTTPURLResponse) {
        let result = try await transfer(request, limit: limit, toFile: false, configuration: configuration)
        return (result.data, result.response)
    }

    public static func file(for request: URLRequest, limit: Int,
                            directory: URL = FileManager.default.temporaryDirectory,
                            configuration: URLSessionConfiguration = .ephemeral) async throws -> (URL, HTTPURLResponse) {
        let result = try await transfer(request, limit: limit, toFile: true, directory: directory, configuration: configuration)
        guard let url = result.file else { throw PluginError.failed("Download did not create a file.") }
        return (url, result.response)
    }

    private static func transfer(_ request: URLRequest, limit: Int, toFile: Bool,
                                 directory: URL = FileManager.default.temporaryDirectory,
                                 configuration: URLSessionConfiguration) async throws -> Transfer.Result {
        let transfer = Transfer(limit: limit, toFile: toFile, directory: directory)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start(request, configuration: configuration, continuation: $0) }
        } onCancel: { transfer.cancel() }
    }

    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        struct Result: Sendable {
            let data: Data
            let file: URL?
            let response: HTTPURLResponse
        }
        private let limit: Int
        private let toFile: Bool
        private let directory: URL
        private let lock = NSLock()
        private var cancelled = false
        private var received = 0
        private var data = Data()
        private var file: URL?
        private var handle: FileHandle?
        private var response: HTTPURLResponse?
        private var session: URLSession?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<Result, Error>?

        init(limit: Int, toFile: Bool, directory: URL) { self.limit = limit; self.toFile = toFile; self.directory = directory }

        func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                   continuation: CheckedContinuation<Result, Error>) {
            lock.lock()
            self.continuation = continuation
            guard !cancelled, limit > 0 else {
                lock.unlock()
                finish(error: cancelled ? CancellationError() : PluginError.invalid("Download limit must be positive."))
                return
            }
            do {
                if toFile {
                    let url = directory.appendingPathComponent("Spotlite-download-\(UUID().uuidString)")
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw PluginError.failed("Cannot create download file.") }
                    file = url
                    handle = try FileHandle(forWritingTo: url)
                }
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            } catch {
                lock.unlock()
                finish(error: error)
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = task
            lock.unlock()
            task?.cancel()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                finish(error: PluginError.failed("The server did not return HTTP."))
                return
            }
            guard response.expectedContentLength <= Int64(limit) else {
                completionHandler(.cancel)
                finish(error: tooLarge)
                return
            }
            lock.lock()
            self.response = http
            let active = continuation != nil && !cancelled
            lock.unlock()
            completionHandler(active ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
            lock.lock()
            guard continuation != nil, !cancelled else { lock.unlock(); return }
            guard bytes.count <= limit - received else {
                lock.unlock()
                dataTask.cancel()
                finish(error: tooLarge)
                return
            }
            received += bytes.count
            do {
                if let handle { try handle.write(contentsOf: bytes) }
                else { data.append(bytes) }
                lock.unlock()
            } catch {
                lock.unlock()
                dataTask.cancel()
                finish(error: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error: error) }

        private var tooLarge: PluginError { .failed("Download exceeds the \(limit)-byte limit.") }

        private func finish(error: Error?) {
            lock.lock()
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            let result: Swift.Result<Result, Error>
            do {
                try handle?.close()
                if cancelled { throw CancellationError() }
                if let error { throw error }
                guard let response else { throw PluginError.failed("Download ended without a response.") }
                result = .success(Result(data: data, file: file, response: response))
            } catch { result = .failure(error) }
            if case .failure = result, let file { try? FileManager.default.removeItem(at: file) }
            handle = nil; file = nil; data = Data()
            let session = session
            self.session = nil; task = nil
            lock.unlock()
            session?.invalidateAndCancel()
            continuation.resume(with: result)
        }
    }
}
