import SwiftUI
import WebKit

struct MiniGamesView: View {
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color(red: 0.047, green: 0.078, blue: 0.067).ignoresSafeArea()
            MiniGamesBrowser { loadFailed = true }
                .id(attempt)
                .accessibilityHidden(loadFailed)
            if loadFailed {
                VStack(spacing: 12) {
                    Text("Не удалось загрузить игры").font(.headline)
                    Button("Повторить") {
                        loadFailed = false
                        attempt += 1
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Мини-игры")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MiniGamesBrowser: UIViewRepresentable {
    private static let catalog = URL(string: "https://live.chepushkavpn.fun/api/android/mini-games")!
    private static let rules = #"""
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https://live[.]chepushkavpn[.]fun/api/android/mini-games$"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^https://live[.]chepushkavpn[.]fun/api/android/mini-games/[a-f0-9]+/play$"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^https://live[.]chepushkavpn[.]fun/api/android/mini-games/[a-f0-9]+/game$"},"action":{"type":"ignore-previous-rules"}},
      {"trigger":{"url-filter":"^https://live[.]chepushkavpn[.]fun/api/android/mini-games/[a-f0-9]+/cover$"},"action":{"type":"ignore-previous-rules"}}
    ]
    """#
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ChepushkaMiniGames", encodedContentRuleList: Self.rules
        ) { [weak webView] rules, _ in
            DispatchQueue.main.async {
                guard let webView else { return }
                guard let rules else {
                    onFailure()
                    return
                }
                webView.configuration.userContentController.add(rules)
                webView.load(URLRequest(url: Self.catalog))
            }
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFailure: () -> Void

        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme == "https",
                  url.host == "live.chepushkavpn.fun", url.port == nil || url.port == 443,
                  action.request.httpMethod == "GET" else {
                decisionHandler(.cancel)
                return
            }
            let prefix = "/api/android/mini-games"
            let suffix = action.targetFrame?.isMainFrame == true ? "play" : "game"
            let allowed = url.path == prefix ||
                url.path.range(of: "^" + prefix + "/[a-f0-9]{32}/" + suffix + "$",
                               options: .regularExpression) != nil
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            onFailure()
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let status = (response.response as? HTTPURLResponse)?.statusCode,
               !(200..<300).contains(status) {
                onFailure()
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
