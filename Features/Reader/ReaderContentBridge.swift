import Combine
import Foundation
import WebKit

struct ReaderScrollPosition: Equatable {
    /// Index of the paragraph at the top of the viewport (the last paragraph when scrolled to the bottom).
    let paragraphIndex: Int
    let totalParagraphs: Int

    /// Parses the "index:total" payload posted by the reader's scroll listener.
    init?(message: String) {
        let parts = message.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 0, parts[1] > 0 else { return nil }
        paragraphIndex = min(parts[0], parts[1] - 1)
        totalParagraphs = parts[1]
    }

    var percent: Int { min(max(Int((Double(paragraphIndex + 1) / Double(totalParagraphs) * 100).rounded()), 0), 100) }
}

struct TTSSourcePosition: Equatable {
    let paragraphIndex: Int
    let offset: Int
}

@MainActor
final class ReaderContentBridge: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var isReady = false
    @Published private(set) var isFollowing = true
    let paragraphScrollPublisher = PassthroughSubject<ReaderScrollPosition, Never>()
    let wordTapPublisher = PassthroughSubject<TTSSourcePosition, Never>()
    /// A color was chosen from the native selection menu.
    let highlightRequestPublisher = PassthroughSubject<ReaderHighlightRequest, Never>()
    private var activeWord: TTSWordTiming?
    private var activeIndex: Int?
    private var speechMode = false
    private var controlsVisible = true

    func setWebView(_ webView: WKWebView) { self.webView = webView; isReady = false }
    func contentDidChange() { isReady = false }
    func contentDidFinishLoad() {
        isReady = true
        setSpeechMode(speechMode)
        setControlsVisible(controlsVisible)
        if let activeWord { setActiveWord(activeWord) }
        else if let activeIndex { setActiveIndex(activeIndex) }
    }
    func receive(_ name: String, body: Any) -> Bool {
        if name == "ttsWordTap", let value = body as? [String: Any],
           let paragraph = value["paragraphIndex"] as? Int, let offset = value["offset"] as? Int {
            wordTapPublisher.send(.init(paragraphIndex: paragraph, offset: offset)); return true
        }
        if name == "ttsFollowChanged", let following = body as? Bool { isFollowing = following; return true }
        if name == "readerHighlightRequest" {
            if let json = body as? String, let data = json.data(using: .utf8),
               let request = try? JSONDecoder().decode(ReaderHighlightRequest.self, from: data) {
                highlightRequestPublisher.send(request)
            }
            return true
        }
        return false
    }
    func onParagraphScroll(_ message: String) {
        if let position = ReaderScrollPosition(message: message) { paragraphScrollPublisher.send(position) }
    }
    func scrollToParagraph(_ index: Int) { evaluate("window.scrollToParagraph && window.scrollToParagraph(\(index))") }
    func prepareTTS() { evaluate("window.prepareTTS && window.prepareTTS()") }
    func fetchTTSBlocks() async -> [String] {
        guard isReady, let webView else { return [] }
        return (try? await webView.evaluateJavaScript("window.getTTSBlocks && window.getTTSBlocks()")) as? [String] ?? []
    }
    func setSpeechMode(_ active: Bool) { speechMode = active; if !active { activeWord = nil; activeIndex = nil }; evaluate("window.setTTSSpeechMode && window.setTTSSpeechMode(\(active ? "true" : "false"))") }
    func setControlsVisible(_ visible: Bool) { controlsVisible = visible; evaluate("window.setTTSControlsVisible && window.setTTSControlsVisible(\(visible ? "true" : "false"))") }
    func setActiveWord(_ word: TTSWordTiming?) {
        guard speechMode else { clearActive(); return }
        activeWord = word
        guard let word else { clearActive(); return }
        guard isReady, let data = try? JSONEncoder().encode(word), let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.setTTSActiveWord && window.setTTSActiveWord(\(json))")
    }
    func resumeFollowing() {
        isFollowing = true
        evaluate("window.resumeTTSFollow && window.resumeTTSFollow()")
    }
    func setActiveIndex(_ index: Int?) {
        activeIndex = index
        guard isReady, let index else { return }
        evaluate("window.setTTSActiveIndex && window.setTTSActiveIndex(\(index))")
    }
    func clearActive() {
        activeIndex = nil; activeWord = nil
        evaluate("window.clearTTSActive && window.clearTTSActive()")
    }

    // MARK: Highlights

    func applyHighlights(_ highlights: [ReaderStoredHighlight]) {
        guard isReady,
              let data = try? JSONEncoder().encode(highlights),
              let json = String(data: data, encoding: .utf8),
              let literal = javaScriptLiteral(json) else { return }
        evaluate("window.lnrApplyHighlights && window.lnrApplyHighlights(\(literal))")
    }

    func flashParagraph(_ index: Int) {
        evaluate("window.lnrFlashParagraph && window.lnrFlashParagraph(\(index))")
    }

    private func javaScriptLiteral(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func evaluate(_ script: String) { guard isReady else { return }; webView?.evaluateJavaScript(script) }
}
