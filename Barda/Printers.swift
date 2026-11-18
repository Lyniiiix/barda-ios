import Foundation

/// Une étiqueteuse que l'app sait piloter.
///
/// Le rendu de l'étiquette reste entièrement côté web : un pilote ne reçoit
/// qu'une trame déjà encodée (1 bit par point, `bytesPerRow` octets par ligne)
/// et ne fait que la transmettre. Ajouter une imprimante, c'est écrire une
/// classe conforme à ce protocole et l'inscrire dans `Printers.catalog`.
protocol LabelPrinter: AnyObject {
    /// Même identifiant que `src/lib/printers/models.ts` côté web.
    var id: String { get }
    var name: String { get }
    /// Octets attendus par ligne de trame : une trame d'une autre largeur est refusée.
    var bytesPerRow: Int { get }

    func print(rows: Int, raster: Data, copies: Int, density: UInt8,
               progress: @escaping (String) -> Void,
               completion: @escaping (Result<Void, Error>) -> Void)
    func disconnect()
}

/// Le registre des pilotes, par identifiant.
enum Printers {
    /// Imprimante supposée quand la page n'en nomme aucune (versions du site
    /// antérieures au champ `printer`).
    static let defaultID = "fichero-d11s"

    private static let catalog: [String: () -> LabelPrinter] = [
        "fichero-d11s": { FicheroD11s() },
    ]

    static var knownIDs: [String] { catalog.keys.sorted() }

    static func make(_ id: String) -> LabelPrinter? { catalog[id]?() }

    enum Failure: LocalizedError {
        case unknown(String)
        case badRaster(String)

        var errorDescription: String? {
            switch self {
            case .unknown(let id):
                return "Imprimante « \(id) » inconnue de cette version de l'app. Mets Barda à jour sur l'iPhone."
            case .badRaster(let name):
                return "Étiquette illisible pour la \(name) : la trame n'a pas la largeur de sa tête."
            }
        }
    }
}
