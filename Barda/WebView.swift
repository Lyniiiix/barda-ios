import SwiftUI
import WebKit

/// La coquille : l'app web telle quelle, plus un pont d'impression.
///
/// Rien de l'interface n'est réécrit ici. Le natif n'apporte que ce que Safari
/// refuse — le Bluetooth — et le site continue d'être mis à jour par un simple
/// `git push`, sans repasser par l'App Store.
struct WebView: UIViewRepresentable {
    let url: URL
    @Binding var loadError: String?
    @Binding var toast: String?
    let reloadToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "barda")
        // Le site teste `window.__bardaNative` pour proposer l'impression directe.
        controller.addUserScript(WKUserScript(
            source: "window.__bardaNative = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true                       // scanner sans plein écran
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()                          // la session survit au redémarrage

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullToRefresh(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh

        context.coordinator.webView = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.reloadToken != reloadToken || web.url == nil {
            context.coordinator.reloadToken = reloadToken
            web.load(URLRequest(url: url))
        }
    }

    // MARK: - Coordinateur

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let parent: WebView
        private let printer = Printer()
        weak var webView: WKWebView?
        var reloadToken = -1

        init(_ parent: WebView) { self.parent = parent }

        @objc func pullToRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        // MARK: chargement

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            parent.loadError = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error, webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error, webView)
        }

        private func fail(_ error: Error, _ webView: WKWebView) {
            webView.scrollView.refreshControl?.endRefreshing()
            let ns = error as NSError
            guard ns.code != NSURLErrorCancelled else { return }
            parent.loadError = ns.localizedDescription
        }

        // La caméra du scanner passe par getUserMedia : sans cette autorisation
        // explicite, WKWebView refuse par défaut et le scan reste noir.
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == parent.url.host ? .grant : .deny)
        }

        // MARK: pont

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let id = body["id"] as? String else { return }

            switch body["action"] as? String {
            case "print":
                guard let base64 = body["raster"] as? String,
                      let raster = Data(base64Encoded: base64),
                      let rows = body["rows"] as? Int else {
                    reply(id, ok: false, message: "étiquette illisible")
                    return
                }
                let copies = body["copies"] as? Int ?? 1
                let density = UInt8(body["density"] as? Int ?? 2)

                printer.print(rows: rows, raster: raster, copies: copies, density: density) { [weak self] step in
                    DispatchQueue.main.async { self?.parent.toast = step }
                } completion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.parent.toast = nil
                        switch result {
                        case .success:
                            self?.reply(id, ok: true, message: "Imprimé")
                        case .failure(let error):
                            self?.reply(id, ok: false, message: error.localizedDescription)
                        }
                    }
                }

            case "disconnect":
                printer.disconnect()
                reply(id, ok: true, message: "déconnecté")

            default:
                reply(id, ok: false, message: "action inconnue")
            }
        }

        private func reply(_ id: String, ok: Bool, message: String) {
            let escaped = message.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
            webView?.evaluateJavaScript(
                "window.__bardaReply && window.__bardaReply(\"\(id)\", \(ok), \"\(escaped)\")")
        }
    }
}
