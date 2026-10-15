import AppKit
import SyncMacProUI

// Outil d'essai des mises à jour (jamais embarqué dans SyncMacPro) : une app sans agent, d'un autre identifiant, qui
// utilise le vrai `UpdateModel` et le vrai pilote Sparkle. Journal : chemin de la clé `ProbeLog` de son Info.plist.
@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    var model: UpdateModel?
    var last: UpdateState?

    func log(_ text: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let line = "[\(Date())] v\(version) \(text)\n"
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ProbeLog") as? String else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("lancée")
        let model = UpdateModel(driver: SparkleUpdateDriver.makeIfBundled(), defaults: UserDefaults(suiteName: "update-probe") ?? .standard)
        self.model = model
        log(model.isAvailable ? "pilote Sparkle prêt" : "ERREUR pas de pilote")
        model.agentActivity(idle: true)
        model.start()
        model.checkNow()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                if model.state != self.last { self.last = model.state; self.log("état \(model.state)") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.log("fin"); NSApp.terminate(nil) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = ProbeDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
