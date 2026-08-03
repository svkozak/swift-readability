import Foundation
import Network
import Testing
import WebKit

@testable import Readability

@Suite("Offline HTML parsing", .serialized)
struct OfflineHTMLParsingTests {
    @Test("The network probe detects an unblocked resource request")
    @MainActor
    func networkProbeDetectsUnblockedRequest() async throws {
        let server = try LoopbackHTTPServer()
        try await server.start()
        defer { server.stop() }

        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(
            #"<img src="\#(server.probeURL.absoluteString)/unblocked">"#,
            baseURL: nil
        )

        for _ in 0..<20 {
            if await server.requestCount > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        webView.stopLoading()
        #expect(await server.requestCount > 0)
    }

    @Test("HTML parsing blocks all network requests")
    @MainActor
    func parseHTMLBlocksNetworkRequests() async throws {
        let server = try LoopbackHTTPServer()
        try await server.start()
        defer { server.stop() }

        let probeURL = server.probeURL.absoluteString
        let articleText = String(
            repeating: "This article contains enough readable text for the parser. ",
            count: 20
        )
        let html = """
            <!doctype html>
            <html>
              <head>
                <title>Offline extraction</title>
                <link rel="stylesheet" href="\(probeURL)/stylesheet">
                <style>
                  @import url("\(probeURL)/import");
                  body { background-image: url("\(probeURL)/style"); }
                </style>
              </head>
              <body background="\(probeURL)/background">
                <article>
                  <h1>Offline extraction</h1>
                  <p>\(articleText)</p>
                  <img src="\(probeURL)/image">
                  <iframe src="\(probeURL)/frame"></iframe>
                </article>
                <script>fetch("\(probeURL)/fetch")</script>
              </body>
            </html>
            """

        let result = try await Readability().parse(
            html: html,
            options: .init(charThreshold: 20),
            baseURL: nil
        )

        #expect(result.title == "Offline extraction")
        #expect(result.textContent.contains("enough readable text"))

        try await Task.sleep(for: .milliseconds(300))
        #expect(await server.requestCount == 0)
    }
}

private actor RequestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let counter = RequestCounter()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "swift-readability.offline-test-server")

    var probeURL: URL {
        guard let port = listener.port,
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)")
        else {
            preconditionFailure("The test server does not have a valid port")
        }
        return url
    }

    var requestCount: Int {
        get async { await counter.value }
    }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [counter, queue] connection in
            Task { await counter.increment() }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { _, _, _, _ in
                let response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
                connection.send(
                    content: response,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }
}
