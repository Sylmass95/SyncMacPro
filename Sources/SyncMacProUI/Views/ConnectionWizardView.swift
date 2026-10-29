import AppKit
import SwiftUI
import SyncKit

/// Une question de rclone posée telle quelle : choix parmi les exemples, ou champ libre (secret si besoin).
@MainActor
struct WizardQuestionView: View {
    let question: RemoteQuestion
    @Binding var answer: String
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.help.isEmpty ? question.option : question.help).fixedSize(horizontal: false, vertical: true)
            if question.exclusive && !question.choices.isEmpty {
                Picker("", selection: $answer) {
                    ForEach(question.choices, id: \.value) { choice in
                        Text(choice.help.isEmpty ? choice.value : choice.help).tag(choice.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            } else if question.isPassword {
                SecureField(question.option, text: $answer).textFieldStyle(.roundedBorder)
            } else {
                TextField(question.option, text: $answer).textFieldStyle(.roundedBorder)
                if !question.choices.isEmpty {
                    Text(localizer.format("wizard.question.examples", question.choices.prefix(5).map(\.value).joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Le contenu de l'étape courante, sans défilement ni boutons (rendu par les tests).
@MainActor
struct WizardStepContent: View {
    @Bindable var wizard: WizardModel
    let localizer: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch wizard.step {
            case .service: services
            case .prepare: prepare
            case .name: nameStep
            case .connect: connect
            case .test: test
            case .done: done
            }
            if let error = wizard.error {
                Label(error, systemImage: "xmark.circle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var serviceName: String { localizer.text(wizard.service.nameKey) }

    private var services: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizer.text("wizard.service.title")).font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(CloudService.allCases) { service in
                    Button { wizard.choose(service) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: service.symbol).font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(localizer.text(service.nameKey)).font(.headline)
                                Text(localizer.text("wizard.service.\(service.rawValue).help"))
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var prepare: some View {
        Text(serviceName).font(.title3.bold())
        switch wizard.service {
        case .drive:
            Picker("", selection: $wizard.ownClient) {
                Text(localizer.text("wizard.drive.own")).tag(true)
                Text(localizer.text("wizard.drive.shared")).tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if wizard.ownClient {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(1...5, id: \.self) { index in
                        Text(localizer.text("wizard.drive.step\(index)")).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout)
                Button(localizer.text("wizard.drive.console")) { NSWorkspace.shared.open(ConnectionWizardView.googleConsoleURL) }
                TextField(localizer.text("wizard.drive.clientID"), text: $wizard.clientID).textFieldStyle(.roundedBorder)
                SecureField(localizer.text("wizard.drive.clientSecret"), text: $wizard.clientSecret).textFieldStyle(.roundedBorder)
            } else {
                Label(localizer.text("wizard.drive.shared.warning"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        case .s3:
            Picker(localizer.text("wizard.s3.provider"), selection: $wizard.s3Provider) {
                ForEach(S3Provider.allCases) { provider in
                    Text(localizer.text("wizard.s3.provider.\(provider.rawValue)")).tag(provider)
                }
            }
            TextField(localizer.text("wizard.s3.accessKey"), text: $wizard.accessKey).textFieldStyle(.roundedBorder)
            SecureField(localizer.text("wizard.s3.secretKey"), text: $wizard.secretKey).textFieldStyle(.roundedBorder)
            TextField(localizer.text("wizard.s3.region"), text: $wizard.region).textFieldStyle(.roundedBorder)
            if wizard.s3Provider.needsEndpoint {
                TextField(localizer.text("wizard.s3.endpoint"), text: $wizard.endpoint).textFieldStyle(.roundedBorder)
            }
        case .smb:
            Text(localizer.text("wizard.smb.help")).font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField(localizer.text("wizard.smb.host"), text: $wizard.smbHost).textFieldStyle(.roundedBorder)
            TextField(localizer.text("wizard.smb.user"), text: $wizard.smbUser).textFieldStyle(.roundedBorder)
            SecureField(localizer.text("wizard.smb.password"), text: $wizard.smbPassword).textFieldStyle(.roundedBorder)
        case .dropbox, .onedrive:
            Text(localizer.format("wizard.browser.help", serviceName)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var nameStep: some View {
        Text(localizer.text("wizard.name.title")).font(.title3.bold())
        TextField(localizer.text("wizard.name.placeholder"), text: $wizard.name).textFieldStyle(.roundedBorder)
        Text(localizer.text("wizard.name.help")).font(.caption).foregroundStyle(.secondary)
        if let problem = wizard.nameProblem {
            Text(localizer.text("wizard.name.problem.\(Self.key(problem))")).font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder private var connect: some View {
        Text(localizer.format(wizard.reconnecting ? "wizard.connect.reconnect" : "wizard.connect.title", wizard.name))
            .font(.title3.bold())
        if wizard.waitingForBrowser {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("wizard.connect.browser")) }
        } else if let question = wizard.question {
            WizardQuestionView(question: question, answer: $wizard.answer, localizer: localizer)
        } else if wizard.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("wizard.connect.working")) }
        } else {
            Text(localizer.text(wizard.service.usesBrowser ? "wizard.connect.help.browser" : "wizard.connect.help.keys"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var test: some View {
        Text(localizer.text("wizard.test.title")).font(.title3.bold())
        if let result = wizard.testResult, !result.ok {
            Label(localizer.format("connections.failed", result.message ?? ""), systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            Text(localizer.text("wizard.test.fixHelp")).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(localizer.text("connections.testing")) }
        }
    }

    @ViewBuilder private var done: some View {
        Label(localizer.format("wizard.done.title", wizard.name), systemImage: "checkmark.seal.fill")
            .font(.title3.bold()).foregroundStyle(.green)
        Text(localizer.text("wizard.done.body")).fixedSize(horizontal: false, vertical: true)
    }

    static func key(_ problem: RemoteNameProblem) -> String {
        switch problem {
        case .empty: return "empty"
        case .invalidCharacters: return "characters"
        case .badStart: return "start"
        case .badEnd: return "end"
        case .taken: return "taken"
        }
    }
}

/// La feuille de l'assistant : contenu de l'étape et boutons (Annuler, Précédent, Suivant / Se connecter / Terminé).
@MainActor
struct ConnectionWizardView: View {
    @Bindable var wizard: WizardModel
    let localizer: Localizer
    let onClose: () -> Void

    static let googleConsoleURL = URL(string: "https://console.cloud.google.com/apis/credentials")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView { WizardStepContent(wizard: wizard, localizer: localizer).padding(.bottom, 8) }
            HStack {
                Button(localizer.text("confirm.cancel"), role: .cancel) {
                    Task {
                        if wizard.busy || wizard.question != nil { await wizard.cancel() }
                        onClose()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(wizard.step == .done)
                if [.prepare, .name].contains(wizard.step) || (wizard.step == .connect && !wizard.busy && wizard.question == nil && !wizard.reconnecting) {
                    Button(localizer.text("editor.back")) { wizard.back() }
                }
                Spacer()
                primary
            }
        }
        .padding(20)
        .frame(width: 580, height: 480)
        .background(GlassBackdrop())
        .glassThemed()
    }

    @ViewBuilder private var primary: some View {
        switch wizard.step {
        case .service: EmptyView()
        case .prepare, .name:
            Button(localizer.text("editor.next")) { wizard.next() }.keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true)).disabled(!wizard.canContinue)
        case .connect:
            if wizard.question != nil {
                Button(localizer.text("wizard.question.continue")) { Task { await wizard.submitAnswer() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true)).disabled(!wizard.canContinue)
            } else {
                Button(localizer.text(wizard.service.usesBrowser ? "wizard.connect.go.browser" : "wizard.connect.go.keys")) {
                    Task { await wizard.connect() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true)).disabled(wizard.busy)
            }
        case .test:
            if let result = wizard.testResult, !result.ok {
                Button(localizer.text("wizard.test.keep")) { wizard.keepAnyway() }
                Button(localizer.text("wizard.test.fix")) { Task { await wizard.fix() } }.keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true))
            }
        case .done:
            Button(localizer.text("wizard.done.close")) { onClose() }.keyboardShortcut(.defaultAction).buttonStyle(GlassButtonStyle(prominent: true))
        }
    }
}
