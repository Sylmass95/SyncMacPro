# Vérifications manuelles de l'interface (sous-projet 3a)

À faire avant de publier une version. Les tests automatiques couvrent la logique et le rendu des vues ;
ces vérifications couvrent ce qu'ils ne voient pas (fenêtre réelle, barre de menus, launchd, autorisations macOS).

Préparation : `scripts/make-dev-bundle.sh` (il désenregistre l'ancien agent avant de remplacer le bundle), puis `open ~/Applications/SyncMacPro.app`.
L'agent a besoin de **rsync 3** (`brew install rsync`) : sans lui, macOS utilise `openrsync` et le résumé d'une exécution affiche « 0 fichier(s) » même si les fichiers sont copiés.
Si l'agent ne démarre pas après une reconstruction du bundle : `syncmacpro-ctl agent uninstall` puis `agent install`.
Nettoyage à la fin : `syncmacpro-ctl agent uninstall`, supprimer `~/Applications/SyncMacPro.app` et
`~/Library/Application Support/SyncMacPro`.

## Premier lancement
- [ ] Copier l'app sur un autre Mac (ou masquer le dossier `.build`) : elle se lance et affiche ses textes (ressources lues dans `Contents/Resources`).
- [ ] Quitter l'app fenêtre fermée, la relancer : l'icône de la barre de menus est vivante même si la fenêtre ne s'ouvre pas.
- [ ] Sans agent installé : l'écran d'accueil s'affiche avec « Installer l'agent ».
- [ ] Cliquer sur Installer : si macOS demande une autorisation, l'écran explique où la donner et ouvre Réglages Système ; après autorisation, le tableau de bord apparaît seul.
- [ ] Sans aucune tâche : le message « Aucune tâche » indique la commande `syncmacpro-ctl add`.

## Tableau de bord
- [ ] Ajouter une tâche (`syncmacpro-ctl add --name Test --source ~/Desktop/a --dest ~/Desktop/b --every 1`) : la carte apparaît sans recharger.
- [ ] Pendant une copie volumineuse : barre de progression, fichier en cours, débit, temps restant, qui avancent en direct.
- [ ] Pause / Reprendre / Arrêter sur la carte ; Lancer sur une tâche au repos.
- [ ] Pause globale : les copies se figent, l'en-tête indique « En pause globale » ; quitter l'app, relancer : la pause est toujours là.
- [ ] Fermer la fenêtre : l'app reste dans la barre de menus ; cliquer sur l'icône du Dock rouvre la fenêtre.
- [ ] Mode miroir avec trop de suppressions : la carte indique le blocage et propose « Valider les suppressions ».

## Barre de menus
- [ ] L'icône change : repos, pourcentage pendant une copie, pause, erreur, déconnecté.
- [ ] Le panneau liste les copies actives, les prochaines exécutions, la pause globale, Ouvrir, Quitter.
- [ ] Quitter ne coupe pas l'agent (`pgrep -f syncmacpro-agent`).

## Connexion
- [ ] Tuer l'agent (`kill -KILL "$(launchctl print gui/$(id -u)/com.sylvain.syncmacpro.agent | awk '/^\tpid = /{print $3}')"`) : l'interface affiche « Reconnexion… », puis se rétablit seule en une quinzaine de secondes.
- [ ] Désinstaller l'agent pendant que l'app est ouverte : après une quinzaine de secondes de « Reconnexion… », l'app propose Installer (accueil) ou Réessayer.

## Historique
- [ ] Les exécutions terminées apparaissent ; les filtres (tâche, état, période, recherche) fonctionnent ; les flèches haut / bas déplacent la sélection ; le détail montre le message d'un échec.

## Réglages
- [ ] Apparence : Automatique, Clair, Sombre s'appliquent tout de suite à la fenêtre et au panneau.
- [ ] « Ouvrir à la connexion » s'active et se désactive (vérifier dans Réglages Système › Éléments de connexion).
- [ ] Installer / désinstaller l'agent ; « Afficher le dossier des données » ouvre le Finder.

## Langues
- [ ] Système en français puis en anglais : aucun texte brut du type « ⚠︎clé » nulle part.

## Accessibilité
- [ ] VoiceOver annonce le nom, l'état et le pourcentage d'une carte ; ⌘, ouvre les Réglages.

## Tâches et éditeur (3b)
- [ ] Nouvelle tâche : choisir la source et la destination avec « Choisir… » ; un dossier d'un volume réseau monté est reconnu.
- [ ] Une destination dans la source est refusée dès l'étape 1, avec le message.
- [ ] Les cartes de mode montrent l'avertissement des modes qui suppriment.
- [ ] Planification : « Prochaine exécution » change en direct.
- [ ] Résumé : la phrase est juste ; Simuler annonce les fichiers et les suppressions ; Annuler la simulation fonctionne.
- [ ] Enregistrer : la tâche apparaît au tableau de bord et dans Tâches ; un refus de l'agent reste affiché dans l'éditeur.
- [ ] Activer / désactiver, modifier, dupliquer, supprimer (confirmation) depuis l'écran Tâches.
- [ ] Modèles depuis le tableau de bord vide et depuis Tâches.
- [ ] Historique : « Voir le journal » montre les lignes du moteur ; Copier fonctionne ; une exécution antérieure à 3b affiche « Aucun journal ».

## Copie (3c)
- [ ] Naviguer : double-clic sur un dossier, barre de chemin, dossier parent, emplacements, disques, favoris (étoile).
- [ ] Fichiers cachés : bouton œil. Fenêtre étroite : les noms restent lisibles (les dates se masquent).
- [ ] Choisir plusieurs fichiers (⌘, ⇧) : la barre d'état affiche le nombre, la taille (calcul en cours, puis total) et la place libre.
- [ ] Copier → confirmation → Simuler → Lancer : la carte « Copie manuelle » apparaît au tableau de bord, puis l'exécution dans l'historique avec son journal.
- [ ] Synchroniser un dossier dont la destination a des fichiers en trop : la simulation annonce les suppressions ; « accepter les suppressions » permet de lancer malgré le garde-fou.
- [ ] Glisser un fichier d'un panneau à l'autre ; déposer des fichiers du Finder (de deux dossiers différents : deux copies).
- [ ] Copier un dossier dans un de ses sous-dossiers, ou synchroniser le dossier personnel vers le Bureau : refus clair, Simuler et Lancer désactivés.
- [ ] Dossier sans droits de lecture : message dans le panneau.
- [ ] Démonter un disque affiché puis Actualiser : le panneau remonte et le signale.
- [ ] Agent arrêté : boutons désactivés avec la raison.
- [ ] Enregistrer comme tâche : l'éditeur s'ouvre avec source, destination et éléments choisis.

## Connexions (4)
- [ ] Google Drive avec son propre identifiant : guide, console, connexion dans le navigateur, test réussi ; une tâche vers Drive avec un dossier choisi s'exécute.
- [ ] Google Drive avec l'identifiant partagé : avertissement, connexion, test.
- [ ] Dropbox et OneDrive (choix du lecteur posé tel que rclone le formule).
- [ ] S3 : bonnes clés → test réussi ; mauvaises clés → échec clair (« InvalidAccessKeyId… »), « Corriger » revient aux réglages.
- [ ] Annuler pendant l'attente du navigateur : la connexion n'apparaît pas.
- [ ] Reconnecter une connexion Drive (jeton expiré ou révoqué).
- [ ] Supprimer une connexion utilisée par une tâche : refus avec le nom de la tâche.
- [ ] Éditeur : choisir une connexion, parcourir ses dossiers, « Ajouter une connexion… » la sélectionne à la fermeture de l'assistant.
- [ ] Les connexions créées avec rclone en ligne de commande apparaissent et sont utilisables.

## Distribution (5)
- [ ] Sur un Mac sans Homebrew : ouvrir le DMG, glisser l'app dans Applications, l'ouvrir après l'autorisation Gatekeeper.
- [ ] Ouvrir l'app directement depuis le DMG : l'accueil demande de la déplacer dans Applications.
- [ ] L'accueil installe l'agent ; `syncmacpro-ctl doctor` montre rsync et rclone **du bundle**.
- [ ] Une copie vers un dossier et une connexion Google Drive fonctionnent sans rien installer.
- [ ] Mac Intel (ou Rosetta) : l'app et l'agent démarrent.
- [ ] Réglages › À propos : version, Vérifier maintenant (« à jour » ou nouvelle version), Licences ouvre le fichier.
- [ ] Une publication plus récente sur GitHub fait apparaître le bandeau au tableau de bord.

## Thème verre (1.1)
- [ ] Réglages › Apparence › Style : passer de « Verre intense » à « Verre léger » s'applique tout de suite à la fenêtre et aux feuilles ouvertes ensuite.
- [ ] Clair, sombre et automatique : textes lisibles partout (tableau de bord, éditeur, historique, copie, connexions, réglages).
- [ ] Réglages Système › Accessibilité › Affichage › « Réduire la transparence » : panneaux opaques, sans halo.
- [ ] Barre de menus : barres de progression du même style.
