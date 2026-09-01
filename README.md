# barda-ios — la coquille native

Une app iPhone de quatre fichiers, qui n'a qu'une raison d'exister : **Safari n'expose pas
Web Bluetooth**. Elle affiche [Barda](../barda) dans un `WKWebView` et lui prête un pilote
CoreBluetooth pour l'étiqueteuse Fichero D11s.

Rien de l'interface n'est réécrit ici. Le site continue d'être mis à jour par un `git push`
sur le repo web — l'app, elle, ne bouge que si le protocole d'impression change.

| Fichier | Rôle |
|---|---|
| `BardaApp.swift` | point d'entrée SwiftUI |
| `ContentView.swift` | la vue web, plus un écran d'erreur qui permet de changer l'adresse |
| `WebView.swift` | `WKWebView` + le pont JS ⇄ Swift + l'autorisation caméra |
| `Printer.swift` | le protocole D11s en CoreBluetooth |

## Le pont

La page appelle :

```js
window.webkit.messageHandlers.barda.postMessage({
  id, action: "print", rows, raster /* base64, 1 bit/px, 12 octets par ligne */, copies, density
})
```

Swift répond par `window.__bardaReply(id, ok, message)`. Côté web, tout est encapsulé dans
`src/lib/native.ts` : `hasNativePrinter()` décide quel bouton d'impression afficher.

Le rendu de l'étiquette reste **entièrement côté web** — Swift ne reçoit qu'une trame déjà
encodée, et ne fait que la découper au MTU et l'envoyer. C'est ce qui garde l'app stable
pendant que le site évolue.

## Adresse du serveur

`https://barda.example.com` par défaut, mémorisée dans les réglages de l'app. Si le chargement
échoue, un écran propose d'en saisir une autre — pratique pour viser le Mac en développement
(`http://192.168.1.x:3210`, autorisé par `NSAllowsLocalNetworking` dans `Info.plist`).

## Prérequis Xcode ⚠️

Xcode 26.6 embarque le **SDK iOS 26.5**, mais la plateforme iOS correspondante n'est pas
installée sur ce Mac : seuls les runtimes de simulateur 26.4 et 18.2 sont présents. Conséquence
mesurée le 2026-09-01 :

- `xcodebuild -showdestinations` ne propose **aucun** simulateur ;
- l'iPhone de test (iOS 26.5) est listé comme *ineligible*, « iOS 26.5 is not installed » ;
- la compilation du code réussit (`BUILD SUCCEEDED` pour `-sdk iphoneos`), seul `actool` refuse
  de compiler le catalogue d'images faute de runtime à la bonne version.

Autrement dit : **le code est bon, c'est l'installation de Xcode qui est incomplète.** À corriger
une fois, par Xcode ▸ Settings ▸ Components, ou :

```
xcodebuild -downloadPlatform iOS
```

C'est plusieurs gigaoctets. Il faut de toute façon cette plateforme pour installer quoi que ce
soit sur l'iPhone.

## Installer sur le téléphone

Une fois la plateforme installée : ouvrir `Barda.xcodeproj`, onglet *Signing & Capabilities*,
équipe `ABCDE12345`, brancher l'iPhone, Run.

⚠️ **Durée de validité** : avec un compte Apple Developer **payant**, le profil vaut un an —
l'app survit à l'absence de 4-5 mois. Avec un compte **gratuit**, il expire au bout de **7 jours**
et l'app cesse de s'ouvrir. À vérifier avant de partir.
