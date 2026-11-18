<p align="center">
  <img src="Barda/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="88" height="88" alt="">
</p>

<h1 align="center">barda-ios</h1>

<p align="center">
  La coquille iPhone de <a href="https://github.com/Lyniiiix/barda">Barda</a> : le site, plus le Bluetooth que Safari refuse.
</p>

Une app de quelques fichiers, qui n'a qu'une raison d'exister : **Safari n'expose pas Web
Bluetooth**. Elle affiche Barda dans un `WKWebView` et lui prête un pilote CoreBluetooth pour
l'étiqueteuse.

Rien de l'interface n'est réécrit ici. Le site se met à jour de son côté ; l'app, elle, ne bouge
que si un protocole d'impression change.

| Fichier | Rôle |
|---|---|
| `BardaApp.swift` | point d'entrée SwiftUI |
| `ContentView.swift` | la vue web, plus un écran d'erreur qui permet de changer l'adresse |
| `WebView.swift` | `WKWebView`, le pont JS ⇄ Swift et l'autorisation caméra |
| `Printers.swift` | le protocole `LabelPrinter` et le registre des imprimantes |
| `FicheroD11s.swift` | le protocole de la Fichero D11s en CoreBluetooth |

## Imprimantes

| Imprimante | Identifiant |
|---|---|
| **Fichero D11s** | `fichero-d11s` |

Pour en ajouter une : une classe conforme à `LabelPrinter` dans `Barda/<Modele>.swift`, avec le
même `id` et le même `bytesPerRow` que le modèle déclaré côté web, puis une entrée dans
`Printers.catalog`. Le guide complet est dans le README de
[Barda](https://github.com/Lyniiiix/barda#ajouter-une-imprimante).

## Le pont

La page appelle :

```js
window.webkit.messageHandlers.barda.postMessage({
  id, action: "print", printer: "fichero-d11s",
  rows, bytesPerRow, raster /* base64, 1 bit/px */, copies, density
})
```

Swift répond par `window.__bardaReply(id, ok, message)`. Sans champ `printer`, c'est la D11s ; un
identifiant inconnu reçoit une erreur claire. Côté web, tout est dans `src/lib/printers/native.ts`.

Le rendu de l'étiquette reste **entièrement côté web** : Swift ne reçoit qu'une trame déjà
encodée, la découpe au MTU et l'envoie. C'est ce qui garde l'app stable pendant que le site évolue.

## Installer sur ton iPhone

1. Copie `Local.xcconfig.example` en `Local.xcconfig` (ignoré par git) et remplis-le :
   - `DEVELOPMENT_TEAM` : ton équipe Apple Developer ;
   - `PRODUCT_BUNDLE_IDENTIFIER` : un identifiant à toi, en domaine inversé ;
   - `BARDA_DEFAULT_URL` : l'adresse de ton instance Barda.
2. Ouvre `Barda.xcodeproj`, branche l'iPhone, Run.

Sans `Local.xcconfig`, l'app vise la démo publique, et l'adresse se change dans l'app si le
chargement échoue. En développement, l'adresse du Mac sur le réseau local
(`http://192.168.1.x:3210`) est acceptée grâce à `NSAllowsLocalNetworking`.

⚠️ **Durée de validité.** Avec un compte Apple Developer **payant**, le profil vaut un an. Avec un
compte **gratuit**, il expire au bout de **7 jours** et l'app cesse de s'ouvrir : à savoir avant
de partir loin longtemps.

⚠️ **Plateforme iOS dans Xcode.** Si Xcode liste ton iPhone comme *ineligible* (« iOS 26.x is not
installed »), il manque la plateforme correspondante : Xcode ▸ Settings ▸ Components, ou
`xcodebuild -downloadPlatform iOS` (plusieurs gigaoctets).

## Licence

[MIT](LICENSE). Protocole de la D11s d'après
[0xmh/fichero-printer](https://github.com/0xmh/fichero-printer) (MIT). Conçu par
[can.sys](https://can-ali.fr).
