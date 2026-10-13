# SyncMacPro — thème verre : plan d'implémentation

> **Pour les agents :** SOUS-COMPÉTENCE REQUISE : superpowers:executing-plans (exécution native, en autonomie).

**Objectif :** thème verre (Intense par défaut, Léger au choix) sur toute l'interface. **Spec :** `docs/superpowers/specs/2026-10-13-syncmacpro-glass-theme-design.md`

## Contraintes globales
- SwiftUI natif, macOS 14, mode Swift 5 ; vues `@MainActor` (CI Swift 5.10).
- Une seule source de valeurs : `GlassTheme`. Textes en fr et en (`settings.style*`).
- Suite verte ; PR brouillon poussée après chaque tâche.

## Points de revue
1. Contraste du texte secondaire sur le verre en clair (fond coloré) : lisible.
2. « Réduire la transparence » : pas de verre ni de halo.
3. Listes longues (historique, fichiers) : lisibles et sans ralentissement (pas de flou par ligne).
4. Barre de menus (panneau) : cohérente avec le style choisi.
5. Changement de style dans les Réglages : appliqué tout de suite à toutes les fenêtres.

### Tâche 1 : `GlassStyle`, `GlassTheme` et les composants
Fichiers : `Sources/SyncMacProUI/Theme/GlassTheme.swift`, `Sources/SyncMacProUI/Theme/GlassComponents.swift`, `Tests/SyncMacProUITests/GlassThemeTests.swift`.
- `enum GlassStyle: String, CaseIterable { vivid, soft }` (clé `glassStyle`, défaut `vivid`).
- `struct GlassTheme: Equatable` : `init(style:scheme:reduceTransparency:)` ; `backdropStops: [Color]`, `blobs: [GlassBlob]` (couleur, centre, rayon, opacité), `cardTint: Color`, `cardTintOpacity`, `borderOpacity`, `highlightOpacity`, `shadowOpacity`, `shadowRadius`, `progressGlow`, `buttonGlow`, `usesMaterial` ; environnement `\.glassTheme` ; modificateur `.glassThemed()` qui lit `@AppStorage("glassStyle")`, `colorScheme` et `accessibilityReduceTransparency`.
- `GlassBackdrop`, `.glassCard(cornerRadius:dense:)`, `GlassButtonStyle(prominent:)`, `GlowProgressBar(value:)`.
- Tests : valeurs (Intense > Léger pour halo et opacité des taches colorées ; sombre ≠ clair ; transparence réduite → `usesMaterial == false`, halos à 0) ; rendus des composants dans 2 styles × 2 apparences.

### Tâche 2 : application aux écrans et réglage
Fichiers : `RootView`, `DashboardView`, `TaskCard`, `Components` (Banner), `ConnectionsView`, `ConnectionWizardView`, `CopyView`/`FilePaneView`/`CopyConfirmationView`, `EditorSteps`/`TaskEditorView`, `HistoryView`, `TasksView`, `SettingsView`, `MenuBarViews`, `RunLogSheet`, `SyncMacProApp` ; chaînes `settings.style*` ; rendus existants mis à jour.
- Fond `GlassBackdrop` derrière chaque vue de détail et chaque feuille ; `Form` des Réglages avec `.scrollContentBackground(.hidden)`.
- Cartes et rangées → `.glassCard()` ; barres de progression → `GlowProgressBar` ; Pause globale et boutons principaux des feuilles → `GlassButtonStyle(prominent: true)`.
- Réglages › Apparence : Picker « Style » (Intense / Léger).
- Vérifier : suite verte ; captures réelles de l'app (2 styles × 2 apparences) relues.

### Tâche 3 : version 1.1.0 et docs
`VERSION` → 1.1.0 ; `docs/release-notes.md` ; README (section Interface) ; `docs/manual-checks-ui.md` (thème).
