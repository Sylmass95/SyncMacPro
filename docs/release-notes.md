SyncMacPro 1.7.5 — une liste plus lisible, colonnes redimensionnables.

**Améliorations (1.7.5)**
- Rien n'est plus coupé dans la liste : les textes passent à la ligne. La progression tient sur trois lignes complètes (« 21 % · 143,57 Go sur 683,59 Go », « 6,0 Mo/s · reste 1 j 21 h 32 », puis le chemin entier du fichier en cours), en caractères plus grands.
- Au-delà d'un jour, le temps restant s'écrit en jours et heures (« 1 j 21 h 32 ») au lieu de « 45:32:38 ».
- Un en-tête au-dessus de la liste nomme les colonnes (N°, Tâche, Horaire, État, Dernière exécution, Actions). On glisse un séparateur pour élargir ou rétrécir une colonne ; un double-clic lui rend sa largeur d'origine ; les largeurs sont retenues.

SyncMacPro 1.7.4 — les mises à jour n'attendent plus la fin des copies.

**Changements (1.7.4)**
- Une mise à jour s'installe et l'agent redémarre tout de suite, même si des copies tournent : avec une copie de plusieurs jours (NAS → Drive), toutes les autres tâches restaient « en attente : départ après le redémarrage de l'agent ». Les copies coupées reprennent juste après le redémarrage, sans recopier ce qui est déjà fait (rsync refait sa comparaison préalable). L'installation automatique reste limitée à la journée (9 h – 19 h par défaut), pour les demandes d'autorisation de macOS.
- Une sauvegarde de disque amovible coupée par un redémarrage de l'agent, ou lancée pendant l'attente d'une mise à jour, repart sans qu'il faille rebrancher le disque.

SyncMacPro 1.7.3 — la progression d'une copie de nouveau lisible.

**Correction (1.7.3)**
- Dans la liste, une copie en cours n'affichait qu'une barre de progression, sans chiffres : une copie déjà bien avancée paraissait à « 0 octet ». La ligne affiche maintenant le pourcentage, le volume copié sur le total, le débit, le temps restant et le fichier en cours (« 33 % · 51,5 Go sur 539 Go · 2,2 Mo/s · reste … »).

SyncMacPro 1.7.2 — copies vers un NAS sans réécriture inutile des dates.

**Corrections (1.7.2)**
- Un partage réseau (QNAP, NAS) garde les dates des fichiers moins finement que le Mac : rsync croyait chaque fichier modifié et réécrivait sa date à chaque passage (15 811 fichiers en 2 h pour 0 octet copié lors d'un essai réel). Une seconde d'écart est maintenant tolérée pour les copies depuis ou vers un partage réseau (`--modify-window=1`).
- Colonne Horaire d'une tâche de disque amovible : « Déclenchée au branchement du disque » (et non un état d'attente).

SyncMacPro 1.7.1 — on voit ce que fait une copie qui se prépare.

**Corrections (1.7.1)**
- Avant de copier, rsync compare la source et la destination (garde-fou contre une source vide) : sur un disque externe ou un NAS, cela peut prendre plusieurs minutes, et la copie semblait ne rien faire. La ligne dit maintenant « Préparation : comparaison avec la destination… », puis « Vérification après la copie… » à la fin.
- Pendant une mise à jour, l'agent encore en ancienne version ne comprend pas un déplacement de ligne ni « Forcer » : au lieu de « Erreur interne de l'agent : requête illisible », le message dit « SyncMacPro termine sa mise à jour : réessayez dans un instant » et la liste reprend aussitôt son ordre réel.

SyncMacPro 1.7.0 — une seule liste, comme SyncBackPro.

**Nouveautés (1.7.0)**
- Le tableau de bord devient une seule liste de tâches en lignes : rang, nom, « source → destination » en clair (Bureau, NAS « … », Disque « … », Drive partagé), horaire, état avec la progression et la raison de l'attente (« même disque que « … » », « en attente d'une place »), dernière exécution, boutons.
- L'ordre de la liste est l'ordre de départ : quand plusieurs copies attendent, la plus haute part en premier. On change l'ordre en glissant les lignes, une ou plusieurs à la fois (sélection avec ⌘ ou ⇧).
- Deux copies en même temps au plus, et jamais deux sur un même disque physique, en source comme en destination : le NAS du travail (ses partages comptent pour un seul disque), le QNAP, chaque disque externe. Le disque interne du Mac et Google Drive ne sont pas limités.
- « Forcer » lance tout de suite, même au-delà de deux copies ou sur un disque occupé ; « Lancer » met la tâche en attente, à son rang.
- Une copie en pause libère sa place et son disque ; sa reprise attend son tour (« Forcer » la reprend tout de suite).
- Une copie ponctuelle (écran Copier) se place en haut de la liste ; « Forcer » la démarre aussitôt.
- Clic sur une tâche : son détail s'ouvre sous la liste — Historique, Réglages (horaire, activation, conditions, déclencheur du disque ; « Modifier… » ouvre l'éditeur complet) et Journal. Les exécutions des copies ponctuelles et des tâches supprimées sont dans la ligne « Autres exécutions ».
- Plus de file d'attente à remplir ni de bouton « Lancer la file », plus d'écran Historique global. Le mode mini et la barre de menus suivent l'ordre de la liste.
- `syncmacpro-ctl` : `queue` affiche la liste dans l'ordre, `queue up|down <tâche>` change le rang, `force <tâche>` lance tout de suite.

SyncMacPro 1.6.9 — une copie en pause ne bloque plus la mise à jour.

**Correction (1.6.9)**
- Après une mise à jour, une copie mise en pause empêchait l'agent de redémarrer : toutes les autres tâches restaient « en attente (mise à jour installée…) » tant qu'on ne la reprenait pas. Maintenant, seules les copies en cours retardent le redémarrage ; une copie en pause est interrompue proprement et reprend après le redémarrage, là où elle en était.

SyncMacPro 1.6.8 — partage réseau perdu pendant une copie.

**Correction (1.6.8)**
- Si le partage du NAS se démonte pendant une copie (coupure du réseau ou du VPN), la copie s'arrête dans les 30 s au lieu de tourner des heures dans le vide (les Go « à copier » augmentaient sans que rien ne soit copié). La tâche passe « en attente : partage injoignable, nouvel essai à HH:MM », remonte le partage dès que le NAS répond et reprend là où elle en était. Ce qui avait déjà été copié reste dans l'historique (exécution interrompue).
- Les dossiers temporaires de Google Drive pour ordinateur (`.tmp.driveupload`, `.tmp.drivedownload`) sont exclus par défaut des nouvelles tâches : dans un dossier synchronisé par Drive, la copie y passait des heures (fichiers en cours d'envoi, gros et changeants).

SyncMacPro 1.6.7 — plus d'échecs en série après une mise à jour.

**Correction (1.6.7)**
- Après une mise à jour installée pendant une copie, l'agent continuait avec l'ancien programme jusqu'à la fin des copies ; macOS ne le reconnaissait plus et toutes ses nouvelles copies échouaient en « Accès refusé » (Bureau, volumes réseau, disques externes), même avec les autorisations cochées. Maintenant, dès que son programme a été remplacé, l'agent ne lance plus rien : les copies en cours finissent normalement, les autres attendent « mise à jour installée : départ après le redémarrage de l'agent », puis l'app le redémarre et elles partent. Une notification le signale.
- L'app redémarre l'agent dès que ses copies en cours sont finies, sans attendre que la file d'attente soit vide (déjà pour la mise à jour vers la 1.6.7). Si l'app n'est pas ouverte, l'agent l'ouvre en arrière-plan pour qu'elle s'en charge.
- Pendant cette courte attente, une copie ponctuelle, une simulation ou la validation d'une suppression sont refusées avec un message clair (elles ne survivraient pas au redémarrage) ; les tâches lancées à la main, elles, partent après le redémarrage.

SyncMacPro 1.6.6 — un seul montage par partage réseau.

**Correction (1.6.6)**
- Deux tâches vers le même NAS qui démarraient ensemble montaient chacune le partage (il apparaissait deux fois, par exemple « Documents » et « Documents-1 »). Le montage se fait maintenant une seule fois : la seconde tâche attend et l'utilise.

SyncMacPro 1.6.5 — partages réseau remontés tout seuls, NAS injoignable sans échec.

**Corrections (1.6.5)**
- Un partage réseau (NAS) qui n'est plus monté est remonté automatiquement avant la copie, avec les identifiants enregistrés dans le trousseau, sans aucune fenêtre.
- NAS éteint, en veille, ou réseau / VPN coupé : la tâche n'échoue plus. Elle passe « en attente : partage « … » injoignable, nouvel essai à HH:MM » et réessaie toutes les 5 minutes, sans notification ni ligne d'échec dans l'historique. Au bout de 12 heures sans réponse, l'échec est enregistré et notifié comme avant.
- Une tâche planifiée dont le partage n'est pas monté démarre quand même à son heure (elle monte le partage), au lieu d'attendre qu'il soit monté à la main.
- Dans la file d'attente, une tâche dont le NAS ne répond pas laisse passer les suivantes. « Arrêter » met fin à l'attente.
- Une sauvegarde d'un NAS vers un disque amovible garde le comportement d'avant : si le NAS ne répond pas au branchement, elle échoue (et repartira au prochain branchement ou à la main).
- L'app pouvait se fermer brutalement quand une copie n'avançait presque plus (durée restante estimée infinie) : la durée s'affiche maintenant « — ».
- Le message d'un partage qui ne répond pas parle du NAS et du réseau, plus seulement d'une autorisation de macOS.

SyncMacPro 1.6.4 — autorisations de macOS redemandées à chaque mise à jour.

**Corrections (1.6.4)**
- Après une mise à jour, macOS ne reconnaissait plus les autorisations de SyncMacPro (Volumes de réseau, Bureau…) même cochées : les copies échouaient en « Accès refusé ». SyncMacPro efface maintenant ses autorisations périmées au moment de redémarrer l'agent, puis l'agent accède aussitôt aux dossiers des tâches : macOS affiche ses demandes, il suffit de cliquer sur « Autoriser ».
- L'installation automatique se fait en journée seulement (de 9 h à 19 h par défaut, réglable dans Réglages › À propos), pour que quelqu'un soit là pour ces demandes.
- « Accès refusé » sur un dossier protégé ou un volume : le message dit quel réglage activer dans Confidentialité et sécurité.

SyncMacPro 1.6.3 — une seule copie à la fois par disque.

**Amélioration (1.6.3)**
- Deux sauvegardes vers le même disque amovible ne tournent plus en même temps : la seconde attend la fin de la première (au branchement, lancée à la main ou depuis la file), et les autres tâches prennent les places libres. Sur un disque dur, deux copies simultanées se ralentissaient l'une l'autre.
- Éjection automatique : elle attend que toutes les sauvegardes prévues sur le disque soient faites.
- Sauvegarde en pause dont le disque est rebranché mais qui attend une place : la carte et `ctl status` disent « disque branché, reprise dès qu'une place se libère » au lieu de « disque débranché ».

SyncMacPro 1.6.2 — autorisations de macOS après une mise à jour.

**Corrections (1.6.2)**
- Après une mise à jour, macOS peut redemander d'autoriser SyncMacPro à accéder à un dossier protégé (Bureau, Documents, disque…). Une copie attendait alors la réponse sans rien dire ; elle s'arrête maintenant au bout de 15 s avec un message qui explique quoi faire, et elle est retentée plus tard.
- La notification « SyncMacPro a été mis à jour » prévient de cette demande d'autorisation.

SyncMacPro 1.6.1 — première mise à jour automatique.

**1.6.1**
- Aucun changement fonctionnel : cette version sert à vérifier la mise à jour automatique depuis la 1.6.0 (téléchargement, attente de la fin des copies, installation, relance).

SyncMacPro 1.6.0 — mises à jour automatiques.

**Nouveau (1.6.0)**
- Mises à jour automatiques : chaque nouvelle version est téléchargée en arrière-plan, vérifiée (signature de l'auteur : une version falsifiée est refusée), puis installée dès qu'aucune copie ne tourne ; l'app se relance et l'annonce. Réglages › À propos : « Installer automatiquement » (désactivé : bouton « Installer et relancer »), « Vérifier maintenant ».
- Une copie en cours n'est jamais coupée par une mise à jour : l'installation attend la fin des copies, et l'agent n'est redémarré qu'au repos.
- Cette version s'installe encore à la main (dernière fois) ; les suivantes arriveront seules.

SyncMacPro 1.5.0 — finitions de la sauvegarde sur disque amovible.

**Corrections (1.5.0)**
- Un redémarrage de l'agent (connexion à la session, mise à jour) ne compte plus comme un nouveau branchement : un disque resté branché n'est pas sauvegardé une fois de plus.
- La simulation d'une tâche liée compare avec le dossier du disque là où il est monté ; disque absent, elle est refusée clairement.
- Supprimer une tâche, ou la délier de son disque, clôt sa sauvegarde en pause (plus de ligne « En pause » qui traîne).
- Disque rebranché mais reprise en attente (secteur requis, plage horaire) : la carte dit ce qu'elle attend au lieu de « débranché ».
- Une seule éjection à la fois ; aucune sauvegarde ne démarre sur un disque en cours d'éjection.
- Agent redémarré pendant une sauvegarde sur disque : pas de nouvel essai fantôme, et la file d'attente passe à la suite.
- Vitesse moyenne d'une sauvegarde reprise calculée sans les pauses ; message exact pour « Abandonner » sans sauvegarde en pause.
- Éditeur : la section « Disque amovible » est proposée même si le dossier n'existe pas encore sur le disque.

**Nouveau (1.4.0)**
- Sauvegarde sur disque externe : une tâche liée à un disque part quand vous le branchez (à chaque fois, ou au plus une fois tous les N jours), se met en pause si vous le débranchez, et reprend au rebranchement ; après plusieurs jours (3 par défaut), une nouvelle sauvegarde repart sur une comparaison complète. Le disque est reconnu par son identifiant, même monté sous un autre nom.
- En fin de sauvegarde : notification, bouton « Éjecter » ou éjection automatique, au choix ; « Abandonner » pour une sauvegarde en pause.
- `syncmacpro-ctl eject <tâche>` et `syncmacpro-ctl abandon <tâche>`.

**Corrections (1.4.0)**
- Une tâche désactivée est retirée de la file et ne peut plus y être mise ; une tâche lancée hors de la file en est retirée.
- Une copie ponctuelle en file n'affiche plus « Lancer » ; le bilan d'une copie terminée reste dans Tâches › Copies jusqu'à ce que vous le fermiez.
- La fin d'une copie vers un service en ligne n'attend plus le comptage des dossiers.
- La vitesse moyenne du bilan ne compte plus le temps passé en pause.
- Le garde-fou des fichiers vides gère les noms qui contiennent « \ ».
- Réglages › Réseau n'envoie plus rien à l'agent à la simple ouverture ; fermer la miniature rouvre la grande fenêtre.
- Au démarrage, la file attend de connaître les connexions avant de répartir les plafonds de débit ; message clair pour un élément absent de la file.

**Nouveau (1.3.0)**
- File d'attente : « Mettre en file » sur une tâche ou une copie, puis « Lancer la file » ; les tâches partent une par une, dans l'ordre que vous choisissez (monter, descendre, retirer). Un échec ne bloque pas la file.
- Progression comme RsyncGUI : fichiers et dossiers faits sur le total, vitesse moyenne, temps écoulé ; le bilan reste affiché sur la carte et dans l'historique.
- Mode miniature (⌥⌘M ou le bouton de la barre d'outils) : une petite fenêtre toujours visible avec les transferts en cours et la file.
- Réglages › Réseau : plafonds de réception et d'envoi internet et du réseau local, en Mbit/s comme speedtest, appliqués aux copies en cours ; les copies d'un même sens se partagent le plafond.
- Garde-fou : un fichier vide à la source ne remplace plus une version non vide à la destination (cas d'un fichier que Drive pour ordinateur n'a pas fini d'envoyer).
- `syncmacpro-ctl queue …` et `syncmacpro-ctl bandwidth …`.

**Corrections (1.3.0)**
- Une tâche manuelle n'affiche plus « Prochaine : Sans échéance ».
- Le nombre d'erreurs ne compte plus plusieurs fois le même incident (une nouvelle tentative de rclone).

**Nouveau (1.2.4)**
- Historique › « Vider… » : vide tout l'historique, ou celui de la tâche choisie dans le filtre, après confirmation. Les journaux correspondants sont supprimés ; une exécution en cours est conservée ; tâches, fichiers et archives ne sont pas touchés. En ligne de commande : `syncmacpro-ctl history [tâche] --clear`.

**Corrections (1.2.3)**
- Après une mise à jour, l'agent d'arrière-plan pouvait encore rester arrêté (launchd refusait le nouvel agent, code 78). L'app attend que macOS ait vraiment retiré l'ancien agent, vérifie que le nouveau tourne, et sinon recommence : plus besoin de le réinstaller à la main.

**Corrections (1.2.2)**
- Une copie sur un disque ou un NAS qui ne répond plus ne reste plus « en cours » pour toujours : sans aucune activité pendant 20 minutes (pauses et veille exclues), elle est arrêtée et retentée plus tard.
- Gros volumes : l'avancement se calcule à coût constant. Une copie d'un million de fichiers ralentissait au fil du temps (jusqu'à freiner rsync) et occupait beaucoup plus de mémoire.
- Les échecs indiquent la vraie cause, expliquée en français (« Plus de place sur le disque de destination », « le disque ou le NAS a peut-être été débranché », « Dossier introuvable »…), au lieu de sa conséquence (« Broken pipe »).
- Synchronisation bidirectionnelle : une nouvelle tâche crée son dossier de destination ; quand bisync exige une réinitialisation (par exemple après un changement de casse seul dans un nom), elle est faite tout de suite, sans rien supprimer (la version remplacée est archivée), au lieu d'un échec et d'un nouvel essai une heure plus tard.
- Une vérification qui n'a pas pu se faire (NAS absent, réseau coupé) est retentée ; seule une vérification qui trouve des différences ne l'est pas.
- Finitions : lecture plus sûre de la version des programmes embarqués, nom de tâche ambigu signalé par `syncmacpro-ctl log`, avertissements de compilation.

**Corrections (1.2.1)**
- Après une mise à jour, l'agent d'arrière-plan pouvait rester arrêté (macOS gardait l'ancien agent, refusé pour sa signature). L'app attend désormais que macOS l'ait retiré avant de le réenregistrer, et répare d'elle-même un agent installé qui ne répond pas.

**Corrections (1.2.0)**
- Synchronisation bidirectionnelle : elle échouait dès que les chemins des deux dossiers étaient longs (au-delà de 255 caractères au total, par exemple un dossier Google Drive pour ordinateur et un NAS).
- Rouvrir l'app depuis le Dock ou le Finder montre de nouveau la fenêtre.
- Une tâche « toutes les N minutes » part à l'heure (elle partait jusqu'à une minute en retard à chaque fois).
- Une vérification qui trouve des différences n'est plus relancée automatiquement toutes les heures.
- L'app ne se fige plus sur un disque réseau lent : les dossiers sont lus en arrière-plan ; un disque démonté est détecté.
- Écran Copie : glisser un élément sélectionné emporte toute la sélection ; un dépôt impossible est expliqué.
- Connexions : annulation fiable, question reposée quand rclone refuse une réponse, vérifications renforcées des noms et des valeurs, assistant plus robuste.
- Messages plus clairs (sans codes de couleur), délai sur la vérification des programmes embarqués, nettoyage des fichiers de travail d'une tâche supprimée, finitions du thème verre, messages de mise à jour traduits.

**Installation** : ouvrez le DMG et glissez SyncMacPro dans Applications (remplace la version précédente ; l'agent est réenregistré automatiquement). L'app est signée « ad hoc » : au premier lancement, autorisez-la dans Réglages Système › Confidentialité et sécurité › « Ouvrir quand même » (macOS 15+) ou par clic droit › Ouvrir (macOS 14). macOS 14 ou plus récent, Apple Silicon et Intel. rsync 3.5.1 et rclone 1.75.1 sont inclus.

**Licences** : SyncMacPro (MIT) ; rsync (GPL v3, archive source jointe à cette publication) ; rclone (MIT).
