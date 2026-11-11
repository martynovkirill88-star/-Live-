import SwiftUI
import WebKit

@main
struct ChepushkaLiveApp: App {
    var body: some Scene {
        WindowGroup {
            LiveScreen()
                .ignoresSafeArea(edges: [.bottom])
                .background(Color(red: 0.047, green: 0.071, blue: 0.067).ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
    }
}

private struct LiveScreen: View {
    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = UUID()

    var body: some View {
        ZStack {
            LiveBrowser { result in
                loading = false
                failure = result
            }
            .id(attempt)
            if loading || failure != nil {
                VStack(spacing: 16) {
                    Text("Чепушка Live").font(.title.bold())
                    if let failure {
                        Text(failure).multilineTextAlignment(.center)
                        Button("Повторить") {
                            loading = true
                            self.failure = nil
                            attempt = UUID()
                        }
                        .buttonStyle(.borderedProminent)
                        Link("Открыть в Safari", destination: LiveBrowser.homepage)
                    } else {
                        ProgressView("Загружаем видео…")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.047, green: 0.071, blue: 0.067))
            }
        }
    }
}

private struct LiveBrowser: UIViewRepresentable {
    let onReady: (String?) -> Void
    static let homepage = URL(string: "https://live.chepushkavpn.fun/")!

    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        if let file = Bundle.main.url(forResource: "mobile", withExtension: "js"),
           let script = try? String(contentsOf: file, encoding: .utf8) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.047, green: 0.071, blue: 0.067, alpha: 1)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.open(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let scheme = url.scheme else {
                decisionHandler(.cancel)
                return
            }
            if ["https", "http", "about", "blob"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if action.navigationType == .linkActivated { UIApplication.shared.open(url) }
            }
        }

        private let onReady: (String?) -> Void
        private var startup: Task<Void, Never>?


        init(onReady: @escaping (String?) -> Void) {
            self.onReady = onReady
        }

        func open(_ view: WKWebView) {
            let request = URLRequest(url: LiveBrowser.homepage,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 20)
            view.load(request)
            startup = Task { @MainActor [weak self, weak view] in
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled, let self, let view else { return }
                    let script = """
                        (() => {
                            const root = document.querySelector('main#app');
                            return !!root && !root.querySelector(':scope > .loading')
                                && root.getBoundingClientRect().height > 0
                                && root.innerText.trim().length > 0;
                        })()
                        """
                    if (try? await view.evaluateJavaScript(script)) as? Bool == true {

                        self.onReady(nil)
                        return
                    }
                }
                self?.fail("Каталог не загрузился за 24 секунды.")
            }
        }

        private func fail(_ message: String) {
            startup?.cancel()
            onReady(message)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled else { return }
            fail("Не удалось подключиться к Чепушка Live. Код ошибки: \(code).")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            self.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail("Страница закрылась из-за сбоя WebKit. Откройте её снова.")
        }
    }
}
