import AppKit
import NevermoreCore
import RavenProtocol
import WebKit

/// One player per conversation window. TextKit reserves the space, and an
/// interactive WebKit view moves with that attachment as the transcript reflows.
@MainActor final class InlineYouTubePlayer {
    struct Source: Equatable {
        let messageID: String
        let url: URL
        let video: YouTubeVideo

        init?(messageID: String, raw: String) {
            guard let url = URL(string: raw), let video = YouTubeVideo(url: url) else { return nil }
            self.messageID = messageID
            self.url = url
            self.video = video
        }
    }

    static let command = URL(string: "nevermore-youtube://player")!
    private weak var owner: ConversationWindow?
    private(set) var source: Source?
    private var location: Int?
    private var embed: YouTubeEmbedView?
    private var reveal = false

    init(owner: ConversationWindow) { self.owner = owner }

    func toggle(_ source: Source) {
        let wasOpen = self.source == source
        close()
        if !wasOpen {
            self.source = source
            reveal = true
        }
        owner?.render()
    }

    func close() {
        embed?.close()
        embed = nil
        source = nil
        location = nil
        reveal = false
    }

    func didRender(at location: Int?) {
        guard let location, let owner else { close(); return }
        self.location = location
        if reveal {
            reveal = false
            owner.scrollMessageIntoView(NSRange(location: location, length: 1))
        }
        updatePlacement()
    }

    func updatePlacement() {
        guard let source, let owner, let location, let layout = owner.transcript.layoutManager else { return }
        let frame = AnimatedImageOverlay.attachmentFrame(at: location, layout: layout, origin: owner.transcript.textContainerOrigin)
        guard let frame, frame.width >= YouTubePlayerSpace.minimumSide,
              owner.window?.isVisible == true, owner.window?.isMiniaturized == false,
              frame.intersects(owner.readableTranscriptRect) else {
            embed?.setSuspended(true)
            embed?.isHidden = true
            return
        }

        if let embed {
            if embed.frame != frame { embed.frame = frame }
            embed.isHidden = false
            embed.setSuspended(false)
        } else {
            let view = YouTubeEmbedView(video: source.video, frame: frame)
            embed = view
            owner.transcript.addSubview(view)
            view.load()
        }
    }
}

@MainActor final class YouTubeEmbedView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private let request: URLRequest
    private var suspended = false
    private var initialNavigation: WKNavigation?

    init(video: YouTubeVideo, frame: NSRect) {
        request = Self.request(for: video)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func request(for video: YouTubeVideo) -> URLRequest {
        var request = URLRequest(url: video.embedURL)
        // YouTube's desktop embed contract identifies the app by its bundle
        // ID, independently of the Raven site hosting the conversation.
        let appID = Bundle.main.bundleIdentifier ?? "ch.goodvantage.Nevermore"
        request.setValue("https://\(appID.lowercased())", forHTTPHeaderField: "Referer")
        return request
    }

    func load() { initialNavigation = webView.load(request) }

    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        webView.setAllMediaPlaybackSuspended(value, completionHandler: nil)
    }

    func close() {
        setSuspended(true)
        webView.stopLoading()
        webView.closeAllMediaPresentations(completionHandler: nil)
        removeFromSuperview()
    }

    static func allowsDocument(_ url: URL?, inMainFrame: Bool, embedURL: URL?) -> Bool {
        guard let url else { return false }
        if inMainFrame { return url == embedURL }
        // Limit document navigation inside the player. Media and other
        // subresources still load through the isolated WebKit data store.
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else { return false }
        return ["youtube.com", "youtube-nocookie.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.scheme?.lowercased() == "https" else { return .cancel }
        if let frame = action.targetFrame, Self.allowsDocument(url, inMainFrame: frame.isMainFrame, embedURL: request.url) {
            return .allow
        }
        // Keep the embed in the transcript. Links deliberately followed
        // from its main frame open with the system browser.
        if action.navigationType == .linkActivated, action.sourceFrame.isMainFrame {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard Self.allowsDocument(response.response.url, inMainFrame: response.isForMainFrame, embedURL: request.url) else {
            if response.isForMainFrame { showFailure() }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let navigation, navigation === initialNavigation { showFailure() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if let navigation, navigation === initialNavigation { showFailure() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showFailure() }

    private func showFailure() {
        guard webView.superview != nil else { return }
        webView.removeFromSuperview()
        let label = NSTextField(wrappingLabelWithString: "YouTube couldn’t load here. Use Open on YouTube to watch in your browser.")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

final class YouTubePlayerSpace: TranscriptCardCell {
    nonisolated static let minimumSide: CGFloat = 200

    init() { super.init(maximumWidth: TranscriptMedia.linkCardMaximumWidth, label: "YouTube player") }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        width < Self.minimumSide ? 0 : max(Self.minimumSide, width * 9 / 16)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
}

extension ConversationWindow {
    func youtubeSource(for message: RavenMessage) -> InlineYouTubePlayer.Source? {
        guard let session, isCurrent(session, channelID: message.channelID),
              !session.deletedIDs.contains(message.id), !session.deletedIDs.contains(message.channelID),
              channel?.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true,
              !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: session.revokedChannels, threadParents: session.threadParents),
              message.messageType != "System",
              case .parsed(let document) = session.messageDocument(for: message),
              let raw = SentLinkPreviewPresentation.previewedLink(of: message, in: document) else { return nil }
        return InlineYouTubePlayer.Source(messageID: message.id, raw: raw)
    }

    func youtubeActionTitle(for message: RavenMessage) -> String? {
        guard let source = youtubeSource(for: message) else { return nil }
        return inlineYouTube.source == source ? "Close YouTube Player" : "Play YouTube Inline"
    }

    @objc func toggleSelectedYouTube(_ sender: Any?) {
        guard !isUpdatingTranscript, let message = selectedMessage, let source = youtubeSource(for: message) else { return }
        inlineYouTube.toggle(source)
    }
}

extension TranscriptMedia {
    static func youtubeControls(_ source: InlineYouTubePlayer.Source, expanded: Bool, metrics: TranscriptMetrics) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: TranscriptStyle.secondaryFont(metrics), .nevermoreReadingControl: true]
        let text = NSMutableAttributedString(string: expanded ? "\nClose player" : "\nPlay inline", attributes: base)
        text.addAttribute(.link, value: InlineYouTubePlayer.command, range: NSRange(location: 1, length: text.length - 1))
        if expanded {
            text.append(NSAttributedString(string: " · ", attributes: base))
            let browser = NSMutableAttributedString(string: "Open on YouTube", attributes: base)
            browser.addAttribute(.link, value: source.url, range: NSRange(location: 0, length: browser.length))
            text.append(browser)
        }
        return text
    }

    static func youtubeSpace() -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = YouTubePlayerSpace()
        let text = NSMutableAttributedString(attributedString: line(attachment, attributes: [:], newLine: true, afterText: true))
        text.addAttribute(.nevermoreReadingControl, value: true, range: NSRange(location: 0, length: text.length))
        return text
    }
}
