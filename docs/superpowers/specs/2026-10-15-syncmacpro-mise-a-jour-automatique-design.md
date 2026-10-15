# SyncMacPro — sous-projet 8 : mise à jour automatique (Sparkle)

Date : 2026-10-15 · Statut : à valider par l'auteur · Version visée : **1.6.0**

## 1. Objectif

Diffuser SyncMacPro à d'autres personnes sans qu'elles aient à télécharger chaque version : l'app se met à jour seule,
de façon sûre, sans jamais couper une sauvegarde. Sans compte Apple Developer (signature ad hoc conservée).

### Succès
- Une version publiée (étiquette `vX.Y.Z`) arrive seule chez les utilisateurs de la 1.6.0 et plus : téléchargée en
  arrière-plan, installée dès qu'aucune copie ne tourne, app relancée, agent réinscrit, notification « SyncMacPro a été
  mis à jour en X.Y.Z ».
- Une mise à jour falsifiée (archive ou flux modifié, autre clé) est refusée et rien n'est installé.
- Une copie en cours n'est jamais interrompue par une mise à jour.
- L'auteur publie comme aujourd'hui : il pousse une étiquette, le workflow fait le reste.

## 2. Décisions

| Sujet | Décision |
|---|---|
| Mécanisme | **Sparkle 2.10.0** (open source, standard des apps Mac hors App Store), dépendance SwiftPM épinglée (`exact: "2.10.0"`), `Sparkle.framework` embarqué dans `Contents/Frameworks` et signé ad hoc avec le reste. Services XPC de Sparkle retirés (app non sandboxée) |
| Sécurité (essai du 15/10) | **Mode strict obligatoire** : `SUVerifyUpdateBeforeExtraction` et `SURequireSignedFeed` à `YES`, `SUPublicEDKey` (clé publique EdDSA). L'essai a montré qu'en réglages par défaut une archive falsifiée est acceptée entre deux apps ad hoc (repli sur la signature de code), et qu'en mode strict archive et flux falsifiés sont refusés. Un test vérifie ces clés dans l'app assemblée et la construction échoue sans elles |
| Hébergement | Rien de nouveau : le flux `appcast.xml` est joint à chaque release GitHub, à côté du DMG. `SUFeedURL` = `https://github.com/Sylmass95/SyncMacPro/releases/latest/download/appcast.xml`. L'archive de mise à jour est le DMG publié (Sparkle sait l'ouvrir) |
| Publication | Le workflow (étiquette poussée) télécharge les outils de Sparkle 2.10.0 (empreinte SHA-256 vérifiée, comme rsync/rclone), produit `appcast.xml` signé avec la clé privée lue dans le secret `SPARKLE_ED_PRIVATE_KEY`, et le joint à la release. Une seule entrée (la dernière version) avec lien vers les notes de version. Publication refusée si le secret manque ou si le flux produit ne se vérifie pas avec la clé publique du dépôt |
| Clés (choix de l'auteur : il les crée lui-même) | L'auteur lance `generate_keys` (clé privée dans son trousseau), exporte la clé privée vers le secret GitHub (`gh secret set`) puis supprime l'export ; la clé publique est versionnée (`scripts/sparkle-public-key.txt`). Conseil : sauvegarder la clé privée (gestionnaire de mots de passe) — perdue, les installations existantes ne pourraient plus être mises à jour automatiquement |
| Comportement (choix de l'auteur : A) | Par défaut : vérification automatique (une fois par jour au plus, réglage existant), **téléchargement en arrière-plan et installation automatique**. Réglages › Mises à jour : « Vérifier automatiquement », « Installer automatiquement », « Vérifier maintenant ». Installation automatique désactivée : bannière « Mise à jour X.Y.Z prête » avec bouton « Installer et relancer » |
| Pas pendant une copie | Installation seulement quand l'agent est au repos (aucune exécution en cours ou en pause, file d'attente arrêtée ou vide, aucune simulation) ; sinon elle attend et se fait dès le retour au repos. Si l'app est quittée pendant une copie, Sparkle peut remplacer l'app à la fermeture : la **réinscription de l'agent** (qui le redémarre) est alors **reportée** au premier moment où il est au repos — l'agent en cours garde son code jusque-là et termine sa copie |
| Notification | Au premier lancement d'une nouvelle version installée par Sparkle : « SyncMacPro a été mis à jour en X.Y.Z » (avec un lien vers les nouveautés) |
| Fenêtres de Sparkle | Aucune en mode automatique. Les textes visibles sont ceux de l'app (FR/EN) ; les erreurs (flux injoignable, signature refusée, droits) apparaissent dans Réglages › Mises à jour, sans alerte modale |
| Droits | App dans un dossier non modifiable (compte standard) : Sparkle demande le mot de passe administrateur ; refus : message dans Réglages, nouvel essai à la vérification suivante. App lancée depuis le DMG ou translocalisée : pas de mise à jour (le problème d'emplacement existant est signalé) |
| Ancien vérificateur | `UpdateChecker` (API GitHub) remplacé par Sparkle pour la vérification ; `UpdateModel` expose l'état de Sparkle (`idle`, `checking`, `upToDate`, `downloading`, `ready(version)`, `installing`, `failed`) à l'interface existante (Réglages, bannière du tableau de bord) |
| Première fois | La 1.6.0 s'installe à la main (dernière fois) ; les versions ≤ 1.5.0 continuent d'annoncer la nouvelle version par leur vérificateur actuel |
| Hors périmètre | Mises à jour delta, canal bêta, retour à une version précédente, signature Developer ID / notarisation (possible plus tard sans changer la clé EdDSA) |

## 3. Côté app

- `Package.swift` : dépendance `Sparkle` (exact 2.10.0) pour `SyncMacProUI` ; chemin d'exécution `@executable_path/../Frameworks`.
- `SparkleUpdater` (adaptateur derrière un protocole `UpdateDriving`, faux pour les tests) : `SPUUpdater` avec un pilote
  utilisateur silencieux ; délégué : mise à jour trouvée / téléchargée / prête (`immediateInstallationBlock` gardé),
  erreurs ; réglages `automaticallyChecksForUpdates`, `automaticallyDownloadsUpdates`.
- `UpdatePolicy` (logique pure, testée) : installer maintenant ? (prête, installation automatique, agent au repos) ;
  réinscrire l'agent maintenant ? (version changée, agent au repos ou injoignable) ; notifier ? (version précédente
  mémorisée < version actuelle).
- `UpdateModel` : branché sur l'état de l'agent (`AgentModel.status`), déclenche l'installation au retour au repos.
- `AgentInstaller.reRegisterAfterUpdate` : attend le repos de l'agent avant de le réinscrire.
- Réglages › Mises à jour et bannière : nouveaux états et boutons ; textes FR/EN.

## 4. Construction et publication

- `scripts/assemble-app.sh` : copie `Sparkle.framework` (sans ses services XPC), le signe ad hoc avant l'exécutable
  principal ; ajoute à `Info.plist` `SUFeedURL`, `SUPublicEDKey` (lu dans `scripts/sparkle-public-key.txt`),
  `SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`, `SUEnableAutomaticChecks`, `SUAllowsAutomaticUpdates`.
  Échec si la clé publique manque.
- `scripts/vendor.lock` : outils de Sparkle 2.10.0 (empreinte). `scripts/make-appcast.sh` : flux signé à partir du DMG
  (taille, version, signature EdDSA, lien de téléchargement de la release, notes), puis vérification.
- `release.yml` : étape « Flux de mise à jour » dans le job de publication, `appcast.xml` joint à la release.
- `THIRD_PARTY_NOTICES.md` : licence de Sparkle (MIT et dépendances).

## 5. Tests

- Logique : `UpdatePolicy` (repos de l'agent, installation automatique ou non, report de la réinscription, notification),
  `UpdateModel` avec un faux pilote (états, erreurs, bouton « Installer et relancer »), textes FR/EN, rendus.
- Construction : l'app assemblée contient `Sparkle.framework` signé, les clés strictes et la clé publique ;
  `codesign --verify --deep --strict` ; app universelle.
- Flux : `make-appcast.sh` sur un DMG d'essai avec une clé d'essai → flux qui se vérifie ; modifié → refus.
- Réel, local (app d'essai d'un autre identifiant, comme l'essai du 15/10) : mise à jour d'un assemblage 1.6.0 vers un
  assemblage plus récent par le DMG et le flux produits par les scripts du dépôt ; DMG falsifié refusé.
- Réel, de bout en bout : 1.6.0 installée à la main chez l'auteur, puis publication d'une 1.6.1 → mise à jour seule,
  agent réinscrit, copie en cours non interrompue (copie longue lancée avant la publication).

## 6. Risques

| Risque | Parade |
|---|---|
| Réglages par défaut de Sparkle insuffisants en ad hoc | Mode strict imposé et testé dans l'app assemblée |
| Clé privée perdue ou divulguée | Créée et gardée par l'auteur seul, sauvegarde conseillée ; divulguée : nouvelle clé = une installation manuelle pour tous |
| Agent coupé par la réinscription en pleine copie | Réinscription reportée au repos de l'agent |
| Redirections de GitHub (`latest/download`) | Vérifié pendant l'essai de bout en bout ; repli : URL de flux versionnée par la page de la release |
| Avertissement Gatekeeper « développeur non identifié » à la première installation | Inchangé (sans compte Apple) ; Sparkle retire la quarantaine des versions suivantes |
| Accès complet au disque à réautoriser après mise à jour (signature ad hoc qui change) | À vérifier pendant l'essai de bout en bout et à documenter dans le Lisez-moi ; ne concerne que les dossiers protégés |
