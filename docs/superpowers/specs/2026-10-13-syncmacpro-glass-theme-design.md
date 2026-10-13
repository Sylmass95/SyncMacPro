# SyncMacPro — refonte visuelle : thème verre

Date : 2026-10-13 · Statut : rédigé en autonomie après choix de l'auteur sur maquettes (A par défaut, sélecteur A ↔ C)

## 1. Objectif

Donner à SyncMacPro l'apparence de Rsync-GUI remis au goût du jour : fond aux dégradés colorés, panneaux en verre
dépoli, boutons et barres de progression en dégradé lumineux, en clair comme en sombre. Rien ne change au fonctionnement.

## 2. Décisions prises

| Sujet | Décision |
|---|---|
| Styles | Deux styles de verre : **Intense** (maquette A, par défaut) et **Léger** (maquette C). Réglages › Apparence : « Style » à côté de Automatique / Clair / Sombre (qui reste) |
| Technique | SwiftUI natif : dégradés linéaires et radiaux pour le fond, `.ultraThinMaterial` + voile blanc ou gris pour le verre, bordure fine claire, reflet en haut, ombre douce. Aucune vue web |
| Valeurs | Centralisées dans `GlassTheme(style:scheme:)` (couleurs, opacités, flou, halo) : une seule source, testée |
| Composants | `GlassBackdrop` (fond), modificateur `glassCard()`, `GlassButtonStyle` (principal en dégradé avec halo, secondaire en verre), `GlowProgressBar` (dégradé + halo) |
| Écrans | Fond verre sur toutes les vues de détail (tableau de bord, tâches, copie, historique, connexions, réglages) et sur les feuilles (éditeur, assistant, confirmation, journal) ; cartes, bandeaux, lignes de connexion, cartes de mode, panneaux de copie et barres de progression (y compris barre de menus) passent au verre. La barre latérale garde le matériau système de macOS (elle laisse déjà voir le bureau) |
| Lisibilité | Les listes denses (historique, fichiers) gardent un fond de verre plus opaque ; contrastes vérifiés sur captures en clair et en sombre |
| Accessibilité | « Réduire la transparence » de macOS : le verre devient opaque (fond uni de la carte) et le halo disparaît |
| Version | 1.1.0 ; la publication reste une décision de l'auteur |
| Hors périmètre | Icônes personnalisées des écrans, animations nouvelles, refonte de la mise en page |

## 3. Tests
- `GlassTheme` : valeurs par style et par apparence (Intense plus marqué que Léger, sombre plus foncé, halo absent en transparence réduite).
- Rendus : tableau de bord, carte de tâche, bandeau, connexions, assistant, confirmation de copie — dans les deux styles, en clair et en sombre (PNG relus).
- Réel : captures de la fenêtre de l'app dans les deux styles et les deux apparences.
