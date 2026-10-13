# Règles de confidentialité de SyncMacPro

*Dernière mise à jour : 13 octobre 2026* — [English version below](#privacy-policy)

SyncMacPro est une application macOS gratuite et open source (licence MIT) qui copie et synchronise vos fichiers entre
dossiers, disques, NAS et services en ligne, à l'aide de rsync et de rclone. Elle fonctionne entièrement sur votre Mac.

## Ce que SyncMacPro collecte

**Rien.** SyncMacPro n'a pas de serveur, pas de compte, pas de statistiques d'usage, pas de publicité et ne transmet
aucune donnée personnelle à l'auteur ni à un tiers.

## Données stockées sur votre Mac

- Vos tâches, l'historique des exécutions et leurs journaux, dans `~/Library/Application Support/SyncMacPro/`.
- Les connexions aux services en ligne (Google Drive, Dropbox, OneDrive, S3…), y compris les jetons d'accès et les clés,
  dans le fichier de configuration de rclone (`~/.config/rclone/rclone.conf`), lisible par votre seul compte macOS.

Ces données ne quittent jamais votre Mac, sauf pour les échanges décrits ci-dessous.

## Échanges avec des services

- **Les services que vous connectez** (par exemple Google Drive) : vos fichiers sont lus et écrits directement entre
  votre Mac et le service, selon les tâches que vous créez. L'autorisation est donnée dans votre navigateur, sur la page
  du service. Aucun intermédiaire ne voit vos fichiers ni vos jetons.
- **Vérification des mises à jour** : au plus une fois par jour (désactivable dans Réglages › À propos), l'app lit la
  dernière publication sur l'API de GitHub (`api.github.com`). Cette requête n'envoie aucune donnée vous concernant ; comme
  toute requête web, elle révèle à GitHub votre adresse IP et la version de l'app et de macOS (en-tête standard).

## Données Google (Google Drive)

Lorsque vous connectez Google Drive, SyncMacPro (par rclone) demande l'accès à votre Drive pour copier, synchroniser,
archiver et vérifier les fichiers que **vous** désignez dans vos tâches. Ces données servent uniquement à ces opérations,
ne sont jamais transférées à un tiers, jamais utilisées à des fins publicitaires ni pour entraîner des modèles, et ne
sont lues par personne d'autre que vous. L'utilisation et le transfert des informations reçues des API Google respectent
les [règles relatives aux données utilisateur des services d'API Google](https://developers.google.com/terms/api-services-user-data-policy),
y compris les exigences d'utilisation limitée (*Limited Use*).

## Supprimer vos données

- Supprimez une connexion dans l'écran **Connexions** (ou `syncmacpro-ctl remote delete NOM`) : les jetons sont effacés
  de la configuration de rclone.
- Révoquez l'accès côté Google sur https://myaccount.google.com/permissions.
- Supprimez `~/Library/Application Support/SyncMacPro/` pour effacer tâches et historique.

## Contact

Questions ou signalements : https://github.com/Sylmass95/SyncMacPro/issues

---

# Privacy policy

*Last updated: October 13, 2026*

SyncMacPro is a free, open-source (MIT) macOS app that copies and syncs your files between folders, disks, NAS and online
services using rsync and rclone. It runs entirely on your Mac.

## What SyncMacPro collects

**Nothing.** SyncMacPro has no server, no account, no usage analytics and no advertising, and sends no personal data to
the author or to any third party.

## Data stored on your Mac

- Your tasks, run history and logs, in `~/Library/Application Support/SyncMacPro/`.
- Connections to online services (Google Drive, Dropbox, OneDrive, S3…), including access tokens and keys, in rclone's
  configuration file (`~/.config/rclone/rclone.conf`), readable only by your macOS account.

This data never leaves your Mac, except for the exchanges described below.

## Exchanges with services

- **Services you connect** (for example Google Drive): your files are read and written directly between your Mac and the
  service, according to the tasks you create. You grant access in your browser, on the service's own page. No
  intermediary sees your files or tokens.
- **Update check**: at most once a day (can be turned off in Settings › About), the app reads the latest release from
  GitHub's API (`api.github.com`). This request sends no data about you; like any web request, it reveals your IP address
  and the app and macOS versions (standard header) to GitHub.

## Google user data (Google Drive)

When you connect Google Drive, SyncMacPro (through rclone) requests access to your Drive to copy, sync, archive and
verify the files **you** select in your tasks. This data is used only for those operations, is never transferred to third
parties, never used for advertising or to train models, and is not read by anyone but you. SyncMacPro's use and transfer
of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the
Limited Use requirements.

## Deleting your data

- Delete a connection in the **Connections** screen (or `syncmacpro-ctl remote delete NAME`): its tokens are removed from
  rclone's configuration.
- Revoke access on Google's side at https://myaccount.google.com/permissions.
- Delete `~/Library/Application Support/SyncMacPro/` to erase tasks and history.

## Contact

Questions or reports: https://github.com/Sylmass95/SyncMacPro/issues
