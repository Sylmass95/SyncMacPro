# Vérifications manuelles de l'interface (sous-projet 3a)

À faire avant de publier une version. Les tests automatiques couvrent la logique et le rendu des vues ;
ces vérifications couvrent ce qu'ils ne voient pas (fenêtre réelle, barre de menus, launchd, autorisations macOS).

Préparation : `scripts/make-dev-bundle.sh` (il désenregistre l'ancien agent avant de remplacer le bundle), puis `open ~/Applications/SyncMacPro.app`.
L'agent a besoin de **rsync 3** (`brew install rsync`) : sans lui, macOS utilise `openrsync` et le résumé d'une exécution affiche « 0 fichier(s) » même si les fichiers sont copiés.
Si l'agent ne démarre pas après une reconstruction du bundle : `syncmacpro-ctl agent uninstall` puis `agent install`.
Nettoyage à la fin : `syncmacpro-ctl agent uninstall`, supprimer `~/Applications/SyncMacPro.app` et
`~/Library/Application Support/SyncMacPro`.

## Premier lancement
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
- [ ] Désinstaller l'agent pendant que l'app est ouverte : bandeau « L'agent ne répond pas » avec Installer et Réessayer.

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
