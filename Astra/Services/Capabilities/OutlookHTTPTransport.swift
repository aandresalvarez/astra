import Foundation

protocol OutlookHTTPTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

enum OutlookHTTPFailure: LocalizedError {
    case invalidResponse, responseTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Microsoft returned an unexpected response."
        case .responseTooLarge: "Microsoft's response exceeds ASTRA's response size limit."
        }
    }
}

private final class OutlookRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Reads complete, bounded responses. No cookies, shared cache, redirects or
/// partial success when the response exceeds the limit.
struct URLSessionOutlookHTTPTransport: OutlookHTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.timeoutIntervalForRequest = 30
        copy.timeoutIntervalForResource = 30
        copy.httpCookieStorage = nil
        copy.httpShouldSetCookies = false
        copy.urlCache = nil
        self.configuration = copy
    }
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard maximumBytes > 0, maximumBytes <= 8 * 1_024 * 1_024 else { throw OutlookHTTPFailure.responseTooLarge }
        let session = URLSession(configuration: configuration, delegate: OutlookRedirectRefusal(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw OutlookHTTPFailure.invalidResponse }
        guard response.expectedContentLength <= Int64(maximumBytes) else { bytes.task.cancel(); throw OutlookHTTPFailure.responseTooLarge }
        var body = Data()
        body.reserveCapacity(min(maximumBytes, 65_536))
        for try await byte in bytes {
            guard body.count < maximumBytes else { bytes.task.cancel(); throw OutlookHTTPFailure.responseTooLarge }
            body.append(byte)
        }
        try Task.checkCancellation()
        return (body, http)
    }
}
