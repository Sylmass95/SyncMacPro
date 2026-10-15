import XCTest
import SwiftUI
import SyncKit
@testable import SyncMacProUI

/// Disque amovible côté app (1.4.0) : éditeur, cartes, miniature, barre de menus.
@MainActor
final class RemovableDriveUITests: XCTestCase {
    let external = VolumeInfo(uuid: "AAAA-1111", name: "Extreme Pro", rootPath: "/Volumes/Extreme Pro",
                              isInternal: false, isNetwork: false, isEjectable: true)
    let fr = Localizer(language: "fr")
    let en = Localizer(language: "en")

    func backupTask(eject: RemovableDrive.Eject = .button) -> SyncTask {
        var task = SyncTask(name: "Sauvegarde", source: .local(path: "/Users/moi/Photos"),
                            destination: .local(path: "/Volumes/Extreme Pro/Sauvegardes"), schedule: .manual)
        task.removableDrive = RemovableDrive(volumeUUID: "AAAA-1111", volumeName: "Extreme Pro", relativePath: "Sauvegardes",
                                             trigger: .atMostEveryDays(7), resumeWindowDays: 3, eject: eject)
        return task
    }

    func draftOnDrive() -> TaskDraft {
        var draft = TaskDraft()
        draft.source = SideDraft(kind: .folder, path: "/Users/moi/Photos")
        draft.destination = SideDraft(kind: .folder, path: "/Volumes/Extreme Pro/Sauvegardes/Photos")
        return draft
    }

    // MARK: brouillon

    func testExternalVolumeOffersTheSectionUnlinked() throws {
        var draft = draftOnDrive()
        draft.refreshRemovable { _ in self.external }
        let removable = try XCTUnwrap(draft.removable)
        XCTAssertFalse(removable.linked, "pas de changement de comportement sans l'accord de l'utilisateur")
        XCTAssertEqual(removable.volumeName, "Extreme Pro")
        XCTAssertEqual(removable.volumeUUID, "AAAA-1111")
        XCTAssertEqual(removable.relativePath, "Sauvegardes/Photos")
        XCTAssertNil(draft.task(resolver: .localOnly).removableDrive)
    }

    func testLinkedDraftBecomesARemovableDrive() throws {
        var draft = draftOnDrive()
        draft.refreshRemovable { _ in self.external }
        draft.removable?.linked = true
        draft.removable?.everyConnection = false
        draft.removable?.everyDays = 10
        draft.removable?.resumeWindowDays = 5
        draft.removable?.eject = .automatic
        let drive = try XCTUnwrap(draft.task(resolver: .localOnly).removableDrive)
        XCTAssertEqual(drive, RemovableDrive(volumeUUID: "AAAA-1111", volumeName: "Extreme Pro", relativePath: "Sauvegardes/Photos",
                                             trigger: .atMostEveryDays(10), resumeWindowDays: 5, eject: .automatic))
    }

    func testExistingTaskRoundTripsAndSurvivesAnUnpluggedDrive() {
        let task = backupTask()
        var draft = TaskDraft(task: task)
        XCTAssertEqual(draft.removable?.linked, true)
        draft.refreshRemovable { _ in nil }   // disque débranché : le chemin n'existe pas, le lien reste
        XCTAssertEqual(draft.task(resolver: .localOnly).removableDrive, task.removableDrive)
    }

    // Ouvrir l'éditeur ne relie jamais la tâche à un autre disque du même nom (ni ne retire le lien) en silence.
    func testOpeningTheEditorKeepsTheLinkedDrive() {
        let task = backupTask()
        var draft = TaskDraft(task: task)
        var other = external
        other.uuid = "BBBB-2222"
        draft.refreshRemovable(adopting: false) { _ in other }
        XCTAssertEqual(draft.task(resolver: .localOnly).removableDrive, task.removableDrive)
        draft.refreshRemovable(adopting: false) { _ in VolumeInfo(uuid: "X", name: "Macintosh HD", rootPath: "/", isInternal: true, isNetwork: false) }
        XCTAssertEqual(draft.task(resolver: .localOnly).removableDrive, task.removableDrive, "dossier fantôme sur le disque interne")
        draft.refreshRemovable { _ in other }   // l'utilisateur a choisi un dossier sur l'autre disque
        XCTAssertEqual(draft.removable?.volumeUUID, "BBBB-2222")
    }

    // 1.5.0 : un dossier pas encore créé sur le disque propose quand même la section (volume du premier parent existant).
    func testFolderNotYetCreatedOnTheDriveOffersTheSection() throws {
        var draft = TaskDraft()
        draft.destination = SideDraft(kind: .folder, path: "/Volumes/Extreme Pro/Nouveau/Photos")
        draft.refreshRemovable { path in path == "/Volumes/Extreme Pro" ? self.external : nil }
        let removable = try XCTUnwrap(draft.removable)
        XCTAssertEqual(removable.relativePath, "Nouveau/Photos")
        // Disque absent : « /Volumes » est sur le disque interne, ce n'est pas une raison de retirer la section.
        var unplugged = TaskDraft(task: backupTask())
        unplugged.refreshRemovable { path in
            path == "/Volumes" ? VolumeInfo(uuid: "X", name: "Macintosh HD", rootPath: "/", isInternal: true, isNetwork: false) : nil
        }
        XCTAssertEqual(unplugged.task(resolver: .localOnly).removableDrive, backupTask().removableDrive)
    }

    // 1.5.0 : sauvegarde en pause dont le disque est revenu (la reprise attend une condition).
    func testSuspendedLineWhenTheDriveIsBack() {
        let now = Date(timeIntervalSince1970: 100_000)
        let back = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .waiting(reason: "branchement secteur requis"),
                                 driveSuspendedSince: now.addingTimeInterval(-3_600), driveMounted: true)
        XCTAssertEqual(DrivePresentation(localizer: fr, now: now).line(info: back, task: backupTask()),
                       "En pause sur « Extreme Pro » (branché) : reprise en attente (branchement secteur requis)")
        XCTAssertEqual(DrivePresentation(localizer: en, now: now).line(info: back, task: backupTask()),
                       "Paused on “Extreme Pro” (connected): resume waiting (branchement secteur requis)")
    }

    func testInternalNetworkOrCloudDestinationHasNoSection() {
        var draft = draftOnDrive()
        draft.refreshRemovable { _ in VolumeInfo(uuid: "X", name: "Macintosh HD", rootPath: "/", isInternal: true, isNetwork: false) }
        XCTAssertNil(draft.removable)
        draft.refreshRemovable { _ in VolumeInfo(uuid: "Y", name: "nas", rootPath: "/Volumes/nas", isInternal: false, isNetwork: true) }
        XCTAssertNil(draft.removable)
        var cloud = TaskDraft(task: backupTask())
        cloud.destination = SideDraft(kind: .cloud, path: "Sauvegardes", remote: "drive")
        cloud.refreshRemovable { _ in self.external }
        XCTAssertNil(cloud.removable)
        XCTAssertNil(cloud.task(resolver: .localOnly).removableDrive)
    }

    func testVolumeWithoutIdentifierCannotBeLinked() {
        var draft = draftOnDrive()
        var noUUID = external
        noUUID.uuid = nil
        draft.refreshRemovable { _ in noUUID }
        XCTAssertNotNil(draft.removable, "la section explique pourquoi")
        draft.removable?.linked = true
        XCTAssertNil(draft.task(resolver: .localOnly).removableDrive)
    }

    // MARK: cartes

    func testSuspendedTaskOffersAbandon() {
        let info = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .waiting(reason: "disque débranché depuis 2 h"),
                                 driveSuspendedSince: Date(), driveMounted: false)
        let actions = TaskCard.availableActions(info: info, task: backupTask(), driveMounted: false)
        XCTAssertTrue(actions.contains(.abandon))
        XCTAssertFalse(actions.contains(.eject))
    }

    func testIdleTaskWithButtonEjectAndMountedDriveOffersEject() {
        let info = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .idle, driveMounted: true)
        XCTAssertTrue(TaskCard.availableActions(info: info, task: backupTask(), driveMounted: true).contains(.eject))
        XCTAssertFalse(TaskCard.availableActions(info: info, task: backupTask(eject: .automatic), driveMounted: true).contains(.eject))
        XCTAssertFalse(TaskCard.availableActions(info: info, task: backupTask(), driveMounted: false).contains(.eject))
    }

    func testDriveLines() {
        let now = Date(timeIntervalSince1970: 100_000)
        let text = DrivePresentation(localizer: fr, now: now)
        let suspended = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .waiting(reason: ""),
                                      driveSuspendedSince: now.addingTimeInterval(-2 * 3_600), driveMounted: false)
        XCTAssertEqual(text.line(info: suspended, task: backupTask()), "En pause : disque « Extreme Pro » débranché depuis 2 h")
        let unplugged = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .idle, driveMounted: false)
        XCTAssertEqual(text.line(info: unplugged, task: backupTask()),
                       "Disque « Extreme Pro » débranché : la sauvegarde partira au branchement")
        let plugged = AgentTaskInfo(id: UUID(), name: "Sauvegarde", state: .idle, driveMounted: true)
        XCTAssertEqual(text.line(info: plugged, task: backupTask()), "Disque « Extreme Pro » branché")
        XCTAssertNil(text.line(info: plugged, task: SyncTask(name: "t", source: .local(path: "/a"), destination: .local(path: "/b"))))
        let english = DrivePresentation(localizer: en, now: now)
        XCTAssertEqual(english.line(info: suspended, task: backupTask()), "Paused: drive “Extreme Pro” unplugged for 2 h")
        XCTAssertEqual(english.elapsed(since: now.addingTimeInterval(-3 * 86_400)), "3 d")
        XCTAssertEqual(text.elapsed(since: now.addingTimeInterval(-3 * 86_400)), "3 j")
        XCTAssertEqual(text.elapsed(since: now.addingTimeInterval(-30)), "1 min")
    }

    func testMiniAndMenuBarListDrivesNeedingAttention() {
        let suspendedID = UUID(), ejectableID = UUID(), quietID = UUID()
        var suspendedTask = backupTask(); suspendedTask.id = suspendedID
        var ejectable = backupTask(); ejectable.id = ejectableID
        var quiet = backupTask(eject: .never); quiet.id = quietID
        let status = makeStatus([
            AgentTaskInfo(id: suspendedID, name: "A", state: .waiting(reason: ""), driveSuspendedSince: Date(), driveMounted: false),
            AgentTaskInfo(id: ejectableID, name: "B", state: .idle, driveMounted: true),
            AgentTaskInfo(id: quietID, name: "C", state: .idle, driveMounted: true),
        ])
        let model = AgentModel.preview(status: status, tasks: [suspendedTask, ejectable, quiet])
        XCTAssertEqual(DrivePresentation.attentionIDs(status: model.status, tasks: model.tasks), [suspendedID, ejectableID])
    }

    func testAbandonAndEjectAreSentToTheAgent() async {
        let agent = FakeAgent()
        let model = AgentModel(agent: agent, sleeper: ManualSleeper())
        let id = UUID()
        await model.abandonSuspended(id)
        await model.ejectDrive(id)
        XCTAssertEqual(agent.performed, [.abandonSuspended(id), .ejectDrive(id)])
        model.shutdown()
    }

    // MARK: rendus

    func testRenders() throws {
        let task = backupTask()
        let info = AgentTaskInfo(id: task.id, name: "Sauvegarde", state: .waiting(reason: "disque débranché depuis 2 h"),
                                 driveSuspendedSince: UIFixtures.now.addingTimeInterval(-7_200), driveMounted: false)
        for scheme in [ColorScheme.light, .dark] {
            let card = TaskCard(info: info, task: task, progress: nil, busy: false, text: UIFixtures.french, actions: TaskCardActions())
            assertNotBlank(try render(card.glassThemed(), name: "card-drive-suspended", size: CGSize(width: 380, height: 260), scheme: scheme))
            var draft = TaskDraft(task: task)
            draft.refreshRemovable { _ in self.external }
            let step = EditorStepContent(
                draft: .constant(draft), step: .schedule,
                text: TaskSummaryText(localizer: fr, now: UIFixtures.now),
                resolver: .localOnly, simulation: .idle, saveError: nil, offline: false,
                onSimulate: {}, onCancelSimulation: {}
            ).padding(20)
            assertNotBlank(try render(step.glassThemed(), name: "editor-drive", size: CGSize(width: 700, height: 620), scheme: scheme))
            let model = AgentModel.preview(status: makeStatus([info]), tasks: [task])
            assertNotBlank(try render(MenuBarPanel(model: model, text: UIFixtures.french, onOpen: {}, onQuit: {}).glassThemed(),
                                      name: "menubar-drive", size: CGSize(width: 320, height: 420), scheme: scheme))
        }
    }

    func testStrings() {
        for key in ["editor.drive.title", "editor.drive.link", "editor.drive.trigger.every", "editor.drive.eject.automatic",
                    "card.drive.suspended", "card.drive.mounted", "card.drive.unplugged", "menubar.drives",
                    "editor.drive.nouuid", "editor.drive.noschedule", "card.schedule.drive"] {
            XCTAssertNotEqual(fr.text(key), key, key)
            XCTAssertNotEqual(en.text(key), key, key)
            XCTAssertNotEqual(fr.text(key), en.text(key), key)
        }
    }
}
