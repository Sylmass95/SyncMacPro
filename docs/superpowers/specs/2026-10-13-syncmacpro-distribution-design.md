# SyncMacPro — sous-projet 5 : distribution

Date : 2026-10-13 · Statut : rédigé en autonomie (à la demande de l'auteur) · Complète le §9 et les risques 5 du §10 de `2026-10-12-syncmacpro-design.md`

## 1. Objectif

Livrer SyncMacPro comme une app que l'on installe sans terminal ni Homebrew : un **DMG** qui contient l'app avec **rsync et rclone embarqués** (binaires universels Apple Silicon + Intel), signée **ad hoc** (décision de l'auteur : pas de compte Apple Developer), avec les licences des programmes embarqués, une vérification des mises à jour et une documentation d'installation.

### Succès
- Sur un Mac sans Homebrew, ouvrir le DMG, glisser l'app dans Applications, l'ouvrir (après l'autorisation Gatekeeper expliquée) : l'agent s'installe, une copie vers un dossier et une connexion Google Drive fonctionnent.
- Une version se publie en poussant une étiquette `vX.Y.Z` : le CI construit le DMG à partir de sources dont les empreintes sont vérifiées, et le joint à la publication GitHub avec le code source de rsync.
- L'app signale qu'une nouvelle version existe, sans rien installer seule.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Signature | **Ad hoc** (décision de l'auteur). Avertissement Gatekeeper au premier lancement : le README et le DMG expliquent « Réglages Système › Confidentialité et sécurité › Ouvrir quand même » (macOS 15+) ou clic droit › Ouvrir (macOS 14), et la commande `xattr -dr com.apple.quarantine` |
| rsync embarqué | **3.5.1** compilé depuis l'archive officielle (download.samba.org), empreinte SHA-256 épinglée, **universel** (`-arch arm64 -arch x86_64`), uniquement les bibliothèques système (options : sans xxhash, zstd, lz4, openssl, md2man, idn ; popt et zlib inclus), cible macOS 14 |
| rclone embarqué | **1.75.1**, binaires officiels osx-arm64 et osx-amd64 (downloads.rclone.org), empreintes épinglées (identiques au `SHA256SUMS` officiel), réunis par `lipo` |
| Épinglage | `scripts/vendor.lock` (versions, adresses, empreintes) ; toute empreinte différente arrête la construction. Cache dans `.build/vendor` |
| Recherche des binaires | Variable d'environnement, puis **le dossier `Contents/Resources/bin` du bundle** (trouvé depuis l'exécutable : app, agent ou `ctl`), puis Homebrew et `/usr/bin` (rsync 3 exigé) |
| App universelle | `swift build -c release --arch arm64 --arch x86_64` ; même assemblage pour le bundle de développement et la version publiée (`scripts/assemble-app.sh`) |
| Version | Fichier `VERSION` (première version publiée : **1.0.0**) ; `CFBundleVersion` = nombre de commits ; affichée dans Réglages › À propos et par `syncmacpro-ctl version` |
| Icône | Générée par un script Swift (CoreGraphics) puis `iconutil`, à la construction ; pas d'image binaire dans le dépôt |
| Licences | `THIRD_PARTY_NOTICES.md` (rsync GPL v3, rclone MIT, avec adresse du code source) copié dans l'app avec les textes `COPYING` ; Réglages › À propos › « Licences » l'ouvre. L'archive source de rsync est jointe à chaque publication (obligation de la GPL) |
| Mises à jour | **Vérification seulement** : au plus une fois par jour (et sur demande), l'app lit la dernière publication GitHub (`api.github.com/repos/Sylmass95/SyncMacPro/releases/latest`), compare les versions et affiche un bandeau « Version X disponible » avec un lien vers la page de téléchargement. Réglage « Vérifier les mises à jour » (activé par défaut). Aucune installation automatique (Sparkle exigerait une infrastructure de signature : hors périmètre) |
| Emplacement | Une app lancée depuis le DMG ou translocalisée par Gatekeeper ne peut pas installer son agent de façon durable : l'accueil le détecte et demande de la déplacer dans Applications |
| Publication | Workflow `release.yml` : sur étiquette `v*`, construit et publie (DMG + source rsync) ; lancé à la main (`workflow_dispatch`), construit seulement et garde le DMG comme artefact. Pousser l'étiquette reste une décision de l'auteur |
| Diagnostic | `syncmacpro-ctl doctor` : chemins et versions de rsync et rclone retenus, version de l'app, état de l'agent |
| Hors périmètre | Notarisation, Sparkle, cask Homebrew (après une première publication), App Store |

## 3. Côté code

- `BinaryLocator.embeddedDirectory(executable:)` : `…/X.app/Contents/MacOS/prog` → `…/X.app/Contents/Resources/bin` s'il existe ; l'agent, `ctl` et l'app l'utilisent.
- `SemanticVersion` (lecture `v1.2.3`, `1.2`, comparaison) ; `UpdateChecker` (récupération injectable, intervalle d'un jour mémorisé, résultat `upToDate`, `available(version, url)`, `failed`).
- `InstallLocation.problem(bundlePath:)` : `translocated` (chemin contenant `/AppTranslocation/`), `diskImage` (sous `/Volumes/`), `nil` sinon.
- Réglages › À propos : version, Vérifier maintenant, réglage de vérification automatique, Licences, Code source.
- Bandeau de mise à jour au tableau de bord.
- `ctl version`, `ctl doctor`.

## 4. Scripts

- `scripts/vendor.lock` et `scripts/fetch-vendor.sh` (téléchargement avec reprises, vérification, compilation de rsync, `lipo` de rclone, licences).
- `scripts/make-icon.swift`.
- `scripts/assemble-app.sh BIN_DIR APP [--vendor DIR]` (Info.plist, plist de l'agent, ressources, binaires, licences, icône, signature ad hoc de l'intérieur vers l'extérieur).
- `scripts/make-dev-bundle.sh` (utilise l'assemblage ; embarque les binaires s'ils sont en cache) et `scripts/make-release.sh` (universel, binaires obligatoires, DMG avec lien Applications et « Lisez-moi »).

## 5. Erreurs
- Empreinte différente ou téléchargement impossible : la construction s'arrête avec un message clair (jamais de binaire non vérifié).
- Binaire embarqué absent ou abîmé : retour à Homebrew, sinon le message existant (« rsync 3 est introuvable… »).
- Vérification de mise à jour sans réseau ou limitée par GitHub : rien n'est affiché, nouvel essai le lendemain ; « Vérifier maintenant » montre l'erreur.

## 6. Tests
- `BinaryLocator` (dossier embarqué trouvé depuis l'exécutable, ordre de recherche), `SemanticVersion`, `UpdateChecker` (réponse GitHub réelle capturée, intervalle, erreur), `InstallLocation`, parseur `ctl` (`version`, `doctor`), rendu de Réglages › À propos et du bandeau.
- CI : `bash -n` des scripts ; le workflow de publication est vérifié par un lancement manuel.
- Réel : construire le DMG, le monter, vérifier les architectures et les signatures, lancer `ctl doctor` depuis l'app copiée (binaires embarqués retenus sans Homebrew dans le PATH), copier un dossier avec le rsync embarqué.

## 7. Risques
| Risque | Parade |
|---|---|
| Gatekeeper bloque une app ad hoc | Explications dans le README et le DMG ; commande `xattr` |
| Taille (rclone universel ≈ 175 Mo) | DMG compressé ; acceptable pour une app de synchronisation |
| Site de rsync indisponible (erreurs 504 constatées) | Reprises ; cache local ; empreinte épinglée |
| GPL de rsync | Avis de licence, texte complet, archive source jointe à chaque publication, script de construction public |
| Agent ad hoc sans identifiant d'équipe : pas d'exigence de signature côté XPC | Inchangé depuis le sous-projet 2 (agent de l'utilisateur, même session) ; noté |
