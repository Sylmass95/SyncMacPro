# Mise à jour automatique (Sparkle) — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SyncMacPro 1.6.0 se met à jour seule, de façon sûre (Sparkle en mode strict), sans jamais couper une copie.

**Architecture:** Sparkle 2.10.0 par SwiftPM, embarqué et signé ad hoc par `assemble-app.sh`. Un pilote utilisateur
silencieux (`SparkleUpdateDriver`) remplace les fenêtres de Sparkle et alimente `UpdateModel` ; `UpdatePolicy` (pure)
décide quand installer et quand réinscrire l'agent. Le workflow de publication produit un `appcast.xml` signé
(modèle + `sign_update`) joint à la release.

**Tech Stack:** Swift 5.9 (CI : Swift 5.10, SDK macOS 14), SwiftUI, Sparkle 2.10.0, bash, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-15-syncmacpro-mise-a-jour-automatique-design.md`

## Global Constraints

- Sparkle épinglé `exact: "2.10.0"` ; outils de Sparkle par `vendor.lock` (URL + SHA-256).
- `Info.plist` : `SUVerifyUpdateBeforeExtraction` = YES, `SURequireSignedFeed` = YES, `SUPublicEDKey`, `SUFeedURL` =
  `https://github.com/Sylmass95/SyncMacPro/releases/latest/download/appcast.xml`, `SUEnableAutomaticChecks` = YES.
- Aucune fenêtre de Sparkle ; textes FR/EN de l'app.
- Installation seulement agent au repos ; réinscription de l'agent seulement au repos (ou agent injoignable).
- Clé privée jamais manipulée par l'agent de développement : l'auteur la crée et la range (secret `SPARKLE_ED_PRIVATE_KEY`).
- Swift 5.10 : pas de `var` capturée dans une closure `@Sendable` / `Task`.
- Ne jamais ouvrir une app d'essai avec l'identifiant `com.sylvain.syncmacpro` (elle désenregistrerait l'agent installé).

## Review Focus

- Pas de flux (pas encore de `appcast.xml`, 404) ou réseau coupé : état « à jour » ou erreur discrète, aucune alerte.
- App lancée hors bundle (`swift run`, « dev ») : aucun Sparkle démarré, réglages affichés sans plantage.
- Agent injoignable pendant l'attente du repos : l'installation n'est pas bloquée indéfiniment (injoignable = au repos).
- Installation automatique désactivée puis réactivée avec une mise à jour prête : elle part au repos suivant.
- Mise à jour prête puis copie lancée avant l'installation : l'installation attend la fin de la copie.

---

### Task 1: Sparkle dans le paquet et dans l'app assemblée

**Files:** Modify `Package.swift`, `scripts/assemble-app.sh`, `THIRD_PARTY_NOTICES.md`. Create `Tests/SyncKitTests/AppBundleSparkleTests.swift`.

**Interfaces:** Produces : app assemblée avec `Contents/Frameworks/Sparkle.framework` (sans `XPCServices`), rpath
`@executable_path/../Frameworks`, clés `SU*` ; variable `SPARKLE_PUBLIC_KEY` (sinon `scripts/sparkle-public-key.txt`),
`SPARKLE_FEED_URL` (essais seulement).

- [ ] Test (RED) `AppBundleSparkleTests` (IntegrationTestCase) : lance `scripts/assemble-app.sh <bin de swift test> <sandbox>/SyncMacPro.app 9.9.9 1` avec `SPARKLE_PUBLIC_KEY=dGVzdA==` ; vérifie : framework présent, `XPCServices` absent, `otool -l` contient `@executable_path/../Frameworks`, `Info.plist` (PlistBuddy) a les 5 clés de Global Constraints, `codesign --verify --deep --strict` réussit ; sans clé (variable vide, fichier absent dans une copie du dépôt) → code ≠ 0 avec « clé publique ».
- [ ] `Package.swift` : `dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")]` après `products` ; `SyncMacProUI` dépend de `.product(name: "Sparkle", package: "Sparkle")`. `Package.resolved` versionné.
- [ ] `assemble-app.sh` : clé publique (variable puis fichier, sinon échec) ; `cp -R "$BIN/Sparkle.framework" Contents/Frameworks/`, `rm -rf …/Versions/B/XPCServices` ; `install_name_tool -add_rpath @executable_path/../Frameworks` sur l'exécutable `SyncMacPro` ; clés `SU*` dans `Info.plist` ; `codesign --force --deep --sign -` du framework avant les exécutables.
- [ ] Notices : licence de Sparkle (MIT + bsdiff, ed25519). Tests verts ; commit.

### Task 2: Outils de Sparkle et flux signé

**Files:** Modify `scripts/vendor.lock`. Create `scripts/fetch-sparkle-tools.sh`, `scripts/make-appcast.sh`, `Tests/SyncKitTests/AppcastScriptTests.swift`.

**Interfaces:** `scripts/fetch-sparkle-tools.sh [DOSSIER]` (défaut `.build/sparkle-tools`) → `bin/sign_update`, `bin/generate_keys`.
`scripts/make-appcast.sh DMG CLÉ_PRIVÉE_FICHIER SORTIE.xml` : lit `CFBundleVersion` / `CFBundleShortVersionString` de
l'app du DMG, écrit le flux (une entrée, enclosure `https://github.com/Sylmass95/SyncMacPro/releases/download/v<ver>/<dmg>`,
`length`, `sparkle:edSignature`, `minimumSystemVersion` 14.0, lien de la release), le signe (`sign_update`), puis le
vérifie, ainsi que la signature du DMG (`sign_update --verify`) ; code ≠ 0 sinon.

- [ ] Test (RED) `AppcastScriptTests` (saute si les outils manquent hors CI ; `CI` défini → échec) : DMG d'essai (app factice `CFBundleVersion` 42, `1.6.0`), clé CryptoKit (`Curve25519.Signing.PrivateKey`, base64 de `rawRepresentation`) ; flux produit : version 42, `1.6.0`, URL attendue, longueur exacte, signature EdDSA valide (vérifiée en CryptoKit avec la clé publique), signature du flux présente ; DMG modifié après coup → `sign_update --verify` échoue ; clé absente → échec du script.
- [ ] `vendor.lock` : `SPARKLE_VERSION=2.10.0`, URL de `Sparkle-2.10.0.tar.xz`, SHA-256. Scripts ; tests verts ; commit.

### Task 3: Publication

Dépend de la clé publique de l'auteur (`scripts/sparkle-public-key.txt`) : sans elle, le job DMG des PR (qui reconstruit
l'app quand `scripts/**` change) échouerait. Demandée à l'auteur dès la fin de la tâche 2.

**Files:** Modify `.github/workflows/release.yml`, `.github/workflows/ci.yml`, `scripts/make-release.sh`. Test : `Tests/SyncKitTests/ReleaseWorkflowTests.swift`.

- [ ] Test (RED) : `release.yml` — le job de publication tourne sur macOS, appelle `fetch-sparkle-tools.sh` et `make-appcast.sh` avec le secret `SPARKLE_ED_PRIVATE_KEY` écrit dans un fichier temporaire (`umask 077`, supprimé), joint `appcast.xml` à `gh release create`, s'arrête si le secret est vide ; `ci.yml` récupère les outils avant les tests ; `make-release.sh` refuse de construire sans `scripts/sparkle-public-key.txt`.
- [ ] Modifications ; tests verts ; commit.

### Task 4: Politique et modèle de mise à jour

**Files:** Create `Sources/SyncMacProUI/Updates/UpdatePolicy.swift`, `UpdateDriving.swift`. Modify `UpdateModel.swift`, `Sources/SyncMacProUI/Agent/AgentInstaller.swift`. Tests : `Tests/SyncMacProUITests/UpdatePolicyTests.swift`, `UpdateModelSparkleTests.swift`.

**Interfaces:**
- `public enum UpdateEvent: Equatable, Sendable { case checking, upToDate, downloading(String), ready(String), installing, failed(String) }`
- `@MainActor public protocol UpdateDriving: AnyObject { var onEvent: ((UpdateEvent) -> Void)? { get set }; var automaticallyChecks: Bool { get set }; func start(); func checkNow(); func installNow() }`
- `UpdatePolicy.agentIsIdle(connected: Bool, status: AgentStatus?) -> Bool` (injoignable → vrai ; tâche `running`/`paused`/`queued` ou file lancée non vide → faux) ; `shouldInstall(ready: Bool, autoInstall: Bool, idle: Bool) -> Bool` ; `shouldNotifyUpdated(previous: String?, current: String) -> Bool`.
- `UpdateState` : `idle, checking, upToDate, downloading(String), ready(String), installing, failed(String)` ; `UpdateModel(driver: UpdateDriving?, defaults:)` : `automatic` (clé `checkUpdates`), `autoInstall` (clé `installUpdates`, défaut vrai), `checkNow()`, `installNow()`, `agentActivity(idle: Bool)`, `isAvailable` (driver ≠ nil).
- `AgentInstaller.reRegisterAfterUpdate(…, isIdle: @escaping () async -> Bool)` : attend le repos (essai toutes les 30 s) avant de réinscrire.

- [ ] Tests (RED) : politique (cas du Review Focus inclus) ; modèle avec `FakeUpdateDriver` (événements → états, prête + auto + repos → `installNow` une fois, prête + copie en cours → rien puis repos → installe, auto désactivée → bannière puis bouton, réactivée → installe au repos, sans driver → `isAvailable` faux) ; réinscription : agent occupé → attend, repos → réinscrit.
- [ ] Implémentation ; `UpdateChecker` (API GitHub) et ses tests supprimés : Sparkle vérifie à sa place (les ≤ 1.5.0 gardent leur propre vérificateur, qui annonce la 1.6.0) ; tests verts ; commit.

### Task 5: Pilote Sparkle silencieux et branchement dans l'app

**Files:** Create `Sources/SyncMacProUI/Updates/SparkleUpdateDriver.swift`. Modify `Sources/SyncMacPro/SyncMacProApp.swift`. Test : `Tests/SyncMacProUITests/SparkleDriverTests.swift`.

**Interfaces:** `SparkleUpdateDriver: NSObject, UpdateDriving, SPUUserDriver` ; `static func makeIfBundled(bundle: Bundle = .main) -> SparkleUpdateDriver?` (nil hors `.app` ou sans `SUFeedURL`). Réponses : mise à jour trouvée → `.install` ; prête → réponse gardée, `installNow()` l'appelle avec `.install` ; erreurs → `failed(message)` + acquittement ; pas de mise à jour → `upToDate` ; demande d'autorisation → réponse avec `automaticallyChecks`.

- [ ] Tests (RED) : appels directs des méthodes `SPUUserDriver` sur un pilote non démarré → événements attendus, `installNow` appelle la réponse gardée une seule fois ; `makeIfBundled` nil pour un bundle de test.
- [ ] App : `UpdateModel(driver: SparkleUpdateDriver.makeIfBundled())`, démarrage au lancement ; boucle (30 s) `updates.agentActivity(idle: UpdatePolicy.agentIsIdle(…))` ; `reRegisterAfterUpdate(isIdle:)` ; notification « mis à jour » (`UserNotifier`) au premier lancement d'une version plus récente. Tests verts ; commit.

### Task 6: Interface

**Files:** Modify `SettingsView.swift`, `DashboardView.swift`, `RootView.swift`, `Localizable.strings` (fr, en). Test : `Tests/SyncMacProUITests/UpdateUITests.swift`.

- [ ] Tests (RED) : textes d'état (FR/EN) pour chaque `UpdateState` ; Réglages : deux bascules, « Vérifier maintenant », « Installer et relancer » quand prête ; bannière : « prête » (bouton) si auto désactivée, « s'installera à la fin des copies » si auto et copie en cours ; rendus clair/sombre ; chaînes complètes.
- [ ] Implémentation ; tests verts ; commit.

### Task 7: Version 1.6.0, documentation, essais réels

- [ ] `VERSION` 1.6.0 ; notes de version ; README (publication, clé, sauvegarde de la clé) ; `dmg-readme.txt` (mises à jour automatiques).
- [ ] Essai réel local (app d'essai d'un autre identifiant, pilote Sparkle de l'essai du 15/10) : DMG et flux produits par `make-appcast.sh` d'un assemblage plus récent, servis en local → mise à jour ; DMG modifié → refus.
- [ ] Suite complète verte ; commit. Ensuite (avec l'accord de l'auteur) : clé créée par l'auteur, publication 1.6.0, installation manuelle, publication 1.6.1 → mise à jour seule, copie longue non interrompue.
