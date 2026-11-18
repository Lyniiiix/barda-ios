import SwiftUI

/// L'adresse chargée au premier lancement : `BARDA_DEFAULT_URL`, posée au build par
/// `Barda.xcconfig` (la démo publique) ou par ton `Local.xcconfig` (ton instance).
private let defaultURL: String = {
    let v = Bundle.main.object(forInfoDictionaryKey: "BardaDefaultURL") as? String ?? ""
    return v.hasPrefix("http") ? v : "https://showcase-barda.can-ali.fr"
}()

/// Le fond de la Suite : nuit en sombre, gris très clair en clair, comme la page.
private let fond = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(red: 0.043, green: 0.067, blue: 0.125, alpha: 1)
    : UIColor(red: 0.957, green: 0.965, blue: 0.980, alpha: 1) })

struct ContentView: View {
    @AppStorage("baseURL") private var baseURL = defaultURL
    @State private var loadError: String?
    @State private var toast: String?
    @State private var editingURL = false
    @State private var draftURL = ""
    @State private var reloadToken = 0

    private var url: URL { URL(string: baseURL) ?? URL(string: defaultURL)! }

    var body: some View {
        ZStack(alignment: .bottom) {
            fond.ignoresSafeArea()

            WebView(url: url, loadError: $loadError, toast: $toast, reloadToken: reloadToken)
                .ignoresSafeArea(.container, edges: .bottom)

            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }

            if let loadError {
                VStack(spacing: 16) {
                    Text("Barda est injoignable").font(.headline)
                    Text(loadError).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(baseURL).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("Changer l'adresse") { draftURL = baseURL; editingURL = true }
                            .buttonStyle(.bordered)
                        Button("Réessayer") { reloadToken += 1 }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fond)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .alert("Adresse de Barda", isPresented: $editingURL) {
            TextField("https://…", text: $draftURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Annuler", role: .cancel) { }
            Button("Charger") {
                baseURL = draftURL.trimmingCharacters(in: .whitespaces)
                loadError = nil
                reloadToken += 1
            }
        } message: {
            Text("Par défaut \(defaultURL). En développement, l'adresse du Mac sur le réseau local convient aussi.")
        }
    }
}
