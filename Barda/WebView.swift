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
        /// Un pilote par imprimante déjà utilisée. Celui par défaut est créé tout
        /// de suite : iOS demande l'autorisation Bluetooth au lancement, comme avant.
        private var printers: [String: LabelPrinter] = [:]
        weak var webView: WKWebView?
        var reloadToken = -1

        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            _ = driver(for: Printers.defaultID)
        }

        private func driver(for id: String) -> LabelPrinter? {
            if let existing = printers[id] { return existing }
            guard let made = Printers.make(id) else { return nil }
            printers[id] = made
            return made
        }

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
                let printerID = body["printer"] as? String ?? Printers.defaultID
                guard let printer = driver(for: printerID) else {
                    reply(id, ok: false, message: Printers.Failure.unknown(printerID).localizedDescription)
                    return
                }
                guard let base64 = body["raster"] as? String,
                      let raster = Data(base64Encoded: base64),
                      let rows = body["rows"] as? Int else {
                    reply(id, ok: false, message: "étiquette illisible")
                    return
                }
                // Une trame faite pour une autre tête sortirait déformée : on refuse.
                let bytesPerRow = body["bytesPerRow"] as? Int ?? printer.bytesPerRow
                guard bytesPerRow == printer.bytesPerRow, raster.count == rows * printer.bytesPerRow else {
                    reply(id, ok: false, message: Printers.Failure.badRaster(printer.name).localizedDescription)
                    return
                }
                let copies = body["copies"] as? Int ?? 1
                let density = UInt8(clamping: body["density"] as? Int ?? 2)

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
                printers.values.forEach { $0.disconnect() }
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
