import SwiftUI
import WebKit

@main
struct ChepushkaLiveApp: App {
    var body: some Scene {
        WindowGroup {
            LiveBrowser()
                .ignoresSafeArea(edges: [.bottom])
                .background(Color(red: 0.047, green: 0.071, blue: 0.067).ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
    }
}

struct LiveBrowser: UIViewRepresentable {
    private static let homepage = URL(string: "https://live.chepushkavpn.fun/")!

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        view.load(URLRequest(url: Self.homepage))
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

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            webView.loadHTMLString("""
                <!doctype html><html lang="ru"><meta charset="utf-8">
                <meta name="viewport" content="width=device-width,initial-scale=1">
                <body style="background:#0c1211;color:#f2f6f3;font:17px system-ui;padding:32px">
                <h1>Не удалось открыть Чепушка Live</h1>
                <p>Проверьте подключение к интернету.</p>
                <a style="color:#cafa75" href="https://live.chepushkavpn.fun/">Повторить</a>
                </body></html>
                """, baseURL: nil)
        }
    }
}
