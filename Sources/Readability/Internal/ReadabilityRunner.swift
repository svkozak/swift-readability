import ReadabilityCore
import SwiftUI
import WebKit

/// A runner class responsible for processing HTML content and producing a `ReadabilityResult`.
/// This class uses a WKWebView to load HTML and execute JavaScript for parsing.
@MainActor
final class ReadabilityRunner {
    private static let networkBlockerIdentifier = "swift-readability.block-all-network-v1"
    private static let networkBlockerSource = """
        [
          {
            "trigger": { "url-filter": ".*" },
            "action": { "type": "block" }
          }
        ]
        """
    private static var networkBlocker: WKContentRuleList?

    private let webView: WKWebView
    private var isNetworkBlockerInstalled = false

    // The message handler that listens for events from the injected JavaScript.
    private weak var messageHandler: ReadabilityMessageHandler<EmptyContentGenerator>?
    // The script loader for fetching JavaScript resources from the bundle.
    private let scriptLoader = ScriptLoader(bundle: .module)

    private let encoder = JSONEncoder()

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let messageHandler = ReadabilityMessageHandler(
            mode: .generateReadabilityResult,
            readerContentGenerator: EmptyContentGenerator()
        )

        configuration.userContentController.add(messageHandler, name: "readabilityMessageHandler")

        self.messageHandler = messageHandler
        webView = WKWebView(frame: .zero, configuration: configuration)
    }

    func parseHTML(
        _ html: String,
        options: Readability.Options?,
        baseURL: URL? = nil
    ) async throws -> ReadabilityResult {
        try await installNetworkBlocker()

        let shouldSanitize = options?.shouldSanitize ?? false
        let script =
            try await scriptLoader
            .load(shouldSanitize ? .readabilitySanitized : .readabilityBasic)
            .replacingOccurrences(
                of: "__READABILITY_OPTION__",
                with: generateJSONOptions(options: options)
            )

        let endScript = WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )

        webView.configuration.userContentController.addUserScript(endScript)
        webView.loadHTMLString(html, baseURL: baseURL)

        do {
            let result = try await withCheckedThrowingContinuation { [weak self] continuation in
                self?.messageHandler?.subscribeEvent { event in
                    switch event {
                    case let .contentParsed(readabilityResult):
                        continuation.resume(returning: readabilityResult)
                        self?.messageHandler?.subscribeEvent(nil)
                    case let .availabilityChanged(availability):
                        if availability == .unavailable {
                            continuation.resume(throwing: Error.readerIsUnavailable)
                            self?.messageHandler?.subscribeEvent(nil)
                        }
                    default:
                        break
                    }
                }
            }
            webView.stopLoading()
            return result
        } catch {
            webView.stopLoading()
            throw error
        }
    }

    private func installNetworkBlocker() async throws {
        guard !isNetworkBlockerInstalled else { return }

        let blocker: WKContentRuleList
        if let networkBlocker = Self.networkBlocker {
            blocker = networkBlocker
        } else {
            guard
                let compiledBlocker = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: Self.networkBlockerIdentifier,
                    encodedContentRuleList: Self.networkBlockerSource
                )
            else {
                throw Error.networkBlockerUnavailable
            }
            blocker = compiledBlocker
            Self.networkBlocker = blocker
        }

        webView.configuration.userContentController.add(blocker)
        isNetworkBlockerInstalled = true
    }
}

extension ReadabilityRunner {
    private func generateJSONOptions(options: Readability.Options?) throws -> String {
        if let options = options {
            let data = try encoder.encode(options)
            return String(data: data, encoding: .utf8) ?? "{}"
        } else {
            return "{}"
        }
    }
}

extension ReadabilityRunner {
    /// Errors that can occur during HTML parsing.
    enum Error: Swift.Error {
        /// Indicates that the reader became unavailable during parsing.
        case readerIsUnavailable
        /// Indicates that WebKit could not create the rule that blocks network requests.
        case networkBlockerUnavailable
    }
}

/// A placeholder content generator that conforms to `ReaderContentGeneratable` and does not generate any content.
private struct EmptyContentGenerator: ReaderContentGeneratable {
    func generate(_: ReadabilityResult, initialStyle _: ReaderStyle) async -> String? {
        nil
    }
}
