import SwiftUI

struct ContentView: View {
    @AppStorage("baseURL") private var baseURL = "https://barda.example.com"
    @State private var loadError: String?
    @State private var toast: String?
    @State private var editingURL = false
    @State private var draftURL = ""
    @State private var reloadToken = 0

    private var url: URL { URL(string: baseURL) ?? URL(string: "https://barda.example.com")! }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(red: 0.06, green: 0.07, blue: 0.08).ignoresSafeArea()

            WebView(url: url, loadError: $loadError, toast: $toast, reloadToken: reloadToken)
                .ignoresSafeArea(.container, edges: .bottom)

            if let toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 28)
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
                .background(Color(red: 0.06, green: 0.07, blue: 0.08))
            }
        }
        .preferredColorScheme(.dark)
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
            Text("Par défaut https://barda.example.com. En développement, l'adresse du Mac sur le réseau local convient aussi.")
        }
    }
}
