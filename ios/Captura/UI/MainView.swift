import CapturaCore
import SwiftUI
import UIKit

/// The single screen, like Android's compact home: recording state and control, the
/// Drive link and queue, and the local recordings. Dark from the first frame.
struct MainView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Captura")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.fg)
                    .accessibilityAddTraits(.isHeader)
                RecorderPanel(model: model)
                DrivePanel(model: model)
                RecordingsPanel(rows: model.recordings)
                Text("Los originales se quedan en este iPhone. Captura no transcribe ni ejecuta instrucciones de lo que se graba.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                Task {
                    await model.sceneBecameActive()
                    #if DEBUG
                    await model.runLaunchAutomation(LaunchOptions.current)
                    #endif
                }
            case .background:
                model.sceneEnteredBackground()
            default:
                break
            }
        }
    }
}

// MARK: - Recording

private struct RecorderPanel: View {
    let model: AppModel
    @State private var isBusy = false

    private var recorder: RecorderController { model.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecorderStatusCard(recorder: recorder)

            Text("Avisá a las personas antes de grabar.")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)

            primaryButton

            if recorder.state == .interrupted {
                Button("Reanudar ahora") { run { await model.startRecording() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint("Vuelve a usar el micrófono en un tramo nuevo")
            }

            if recorder.permission == .denied {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Captura no tiene permiso para usar el micrófono.")
                        .foregroundStyle(Theme.error)
                    Button("Abrir Ajustes") { model.openMicrophoneSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityHint("Abre los ajustes de Captura para permitir el micrófono")
                }
            } else if let message = model.recorderMessage {
                Text(message).foregroundStyle(Theme.error)
            }

            if !recorder.recoveredOnLaunch.isEmpty {
                Text(recoveredText(recorder.recoveredOnLaunch.count))
                    .font(.callout)
                    .foregroundStyle(Theme.error)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let active = recorder.state.isRecording || recorder.state == .interrupted
        Button {
            run { await model.toggleRecording() }
        } label: {
            Label(active ? "Detener" : "Grabar", systemImage: active ? "stop.fill" : "mic.fill")
        }
        .buttonStyle(PrimaryButtonStyle(fill: active ? Theme.error : Theme.accent))
        .disabled(isBusy)
        .accessibilityHint(active ? "Detiene la grabación y guarda el audio en el iPhone" : "Empieza a grabar con el micrófono del iPhone")
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }

    private func recoveredText(_ count: Int) -> String {
        count == 1
            ? "Se conservó 1 archivo incompleto de una grabación cortada. No se sube solo."
            : "Se conservaron \(count) archivos incompletos de grabaciones cortadas. No se suben solos."
    }
}

private struct RecorderStatusCard: View {
    let recorder: RecorderController

    var body: some View {
        Group {
            if case .recording = recorder.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = recorder.elapsed(at: context.date)
                    card(
                        title: "Grabando · \(Self.clock(elapsed))",
                        detail: "El audio se guarda en este iPhone en tramos de \(Self.chunkMinutes(recorder.chunkDuration)).",
                        color: Theme.error,
                        spokenTitle: "Grabando, \(Self.spoken(elapsed))"
                    )
                }
            } else {
                switch recorder.state {
                case .interrupted:
                    card(
                        title: RecorderMessages.interruptedTitle,
                        detail: RecorderMessages.interruptedDetail,
                        color: Theme.error
                    )
                case .failed(let message):
                    card(title: "No se está grabando", detail: message, color: Theme.error)
                default:
                    card(title: "Micrófono apagado", detail: "Tocá Grabar para empezar. La grabación siempre se ve acá.", color: Theme.fg)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func card(title: String, detail: String, color: Color, spokenTitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .accessibilityLabel(spokenTitle ?? title)
            Text(detail)
                .font(.callout)
                .foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "es")
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: max(0, seconds.rounded(.down))) ?? clock(seconds)
    }

    static func chunkMinutes(_ duration: TimeInterval) -> String {
        duration >= 60 ? "\(Int(duration / 60)) minutos" : "\(Int(duration)) segundos"
    }
}

// MARK: - Drive

private struct DrivePanel: View {
    let model: AppModel
    @State private var confirmAutomatic = false
    @State private var confirmManual = false
    @State private var confirmUnlink = false
    @State private var copiedFolderID: String?
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Google Drive")
            switch model.auth.status {
            case .notConfigured(let message):
                Text(message)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                Text("Grabar funciona igual; los audios se quedan en el iPhone.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            case .signedOut:
                Text("Drive sin vincular. Grabar funciona sin Google.")
                    .foregroundStyle(Theme.muted)
                Button("Vincular Google Drive") { run { await model.linkDrive() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isBusy || model.auth.isWorking)
                syncControls
            case .signedIn(let email):
                Text("Cuenta: \(email)")
                    .foregroundStyle(Theme.fg)
                    .textSelection(.enabled)
                if model.driveNeedsRelink {
                    Button("Volver a vincular Google Drive") { run { await model.linkDrive() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isBusy || model.auth.isWorking)
                }
                syncControls
                Button("Desvincular") { confirmUnlink = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isBusy || model.auth.isWorking)
                    .accessibilityHint("Deja de subir audios desde este iPhone")
            }
            if let message = model.queueUnavailableMessage {
                Text(message).foregroundStyle(Theme.error)
            }
        }
        .alert("Activar Wi-Fi automático", isPresented: $confirmAutomatic) {
            Button("Activar") { model.setAutomaticSync(true) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Subirá los audios M4A finalizados de Captura a Google Drive, en la cuenta \(model.linkedEmail ?? "vinculada") y la carpeta «\(CaptureNaming.folderName)». No comparte la carpeta ni borra originales. Puede incluir conversaciones y audio de fondo: grabá sólo con consentimiento de los participantes.")
        }
        .alert("Sincronizar ahora", isPresented: $confirmManual) {
            Button(model.network.wifi ? "Sincronizar" : "Permitir red disponible") { run { await model.syncNow() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Subir los audios de Captura a «\(CaptureNaming.folderName)», cuenta \(model.linkedEmail ?? "vinculada"). \(connectionText) Si estás grabando, guarda el tramo y sigue grabando. Conserva los originales. No ejecuta lo que se dice en los audios.")
        }
        .confirmationDialog("¿Desvincular Google Drive?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Desvincular", role: .destructive) { run { await model.unlinkDrive() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Deja de subir audios desde este iPhone y apaga el Wi-Fi automático. Los audios siguen en el iPhone; lo ya subido queda en tu Drive.")
        }
    }

    @ViewBuilder
    private var syncControls: some View {
        Toggle(isOn: automaticBinding) {
            Text("Sincronizar automáticamente por Wi-Fi")
                .foregroundStyle(model.isLinked ? Theme.fg : Theme.muted)
        }
        .tint(Theme.accent)
        .frame(minHeight: Theme.touchTarget)
        .disabled(!model.isLinked)
        .accessibilityHint("Sube los audios finalizados solo por Wi-Fi. Pide confirmación al activarlo.")

        Button("Sincronizar ahora") {
            if model.isLinked { confirmManual = true } else { run { await model.syncNow() } }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(isBusy)
        .accessibilityHint("Sube ahora los audios pendientes. Permite datos móviles por 30 minutos.")

        queueSummary
        folderBlock

        VStack(alignment: .leading, spacing: 4) {
            Text(model.syncMessage)
                .foregroundStyle(Theme.muted)
            if let date = model.syncMessageAt {
                Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "es")))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Último estado: \(model.syncMessage)")

        Text("Sin Internet, los audios esperan en el iPhone. «Sincronizar ahora» permite Wi-Fi o datos móviles por 30 minutos y guarda el tramo actual sin detener la grabación.")
            .font(.footnote)
            .foregroundStyle(Theme.muted)
    }

    @ViewBuilder
    private var queueSummary: some View {
        let counts = model.counts
        Text("\(counts.waiting) pendientes · \(counts.verified) subidos · \(counts.quarantined) en revisión")
            .font(.body.monospacedDigit())
            .foregroundStyle(Theme.fg)
            .accessibilityLabel("\(counts.waiting) audios pendientes, \(counts.verified) subidos, \(counts.quarantined) en revisión")
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 6) {
                Text("Subiendo \(progress.fileName)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subiendo un audio, \(Int(progress.fraction * 100)) por ciento")
        } else if model.isSyncing {
            ProgressView("Sincronizando…")
                .tint(Theme.accent)
                .foregroundStyle(Theme.muted)
        }
        if counts.quarantined > 0 {
            Text("Los audios en revisión se conservan en el iPhone y no se reintentan solos.")
                .font(.callout)
                .foregroundStyle(Theme.error)
            Button("Reintentar los audios en revisión") { run { await model.retryQuarantined() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var folderBlock: some View {
        if let folderID = model.settings.folderID {
            VStack(alignment: .leading, spacing: 8) {
                Text("ID de la carpeta «\(CaptureNaming.folderName)» para la Mac (folder_id):")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
                Text(folderID)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.fg)
                    .textSelection(.enabled)
                    .accessibilityLabel("ID de carpeta \(folderID)")
                Button(copiedFolderID == folderID ? "ID copiado" : "Copiar ID de carpeta") {
                    UIPasteboard.general.string = folderID
                    copiedFolderID = folderID
                    UIAccessibility.post(notification: .announcement, argument: "ID de carpeta copiado")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 4)
        } else if model.isPreparingFolder {
            ProgressView("Preparando la carpeta en Drive…")
                .tint(Theme.accent)
                .foregroundStyle(Theme.muted)
        }
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { model.settings.automaticSync },
            set: { enabled in
                if enabled { confirmAutomatic = true } else { model.setAutomaticSync(false) }
            }
        )
    }

    private var connectionText: String {
        if !model.network.online { return "No hay conexión: el pedido esperará hasta 30 minutos." }
        if model.network.wifi { return "Usará Wi-Fi." }
        return "Usará datos móviles / la red disponible. Puede consumir tu plan de datos."
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

// MARK: - Local recordings

private struct RecordingsPanel: View {
    let rows: [RecordingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Grabaciones en este iPhone")
                .padding(.bottom, 8)
            if rows.isEmpty {
                Text("Todavía no hay grabaciones.")
                    .foregroundStyle(Theme.muted)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        RecordingRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct RecordingRowView: View {
    let row: RecordingRow

    private static let dateStyle = Date.FormatStyle(date: .abbreviated, time: .standard).locale(Locale(identifier: "es"))

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.startedAt.map { $0.formatted(Self.dateStyle) } ?? "Sin fecha")
                    .foregroundStyle(Theme.fg)
                Spacer(minLength: 8)
                Text(row.statusLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(row.fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var statusColor: Color {
        switch row.status {
        case .uploaded: return Theme.accent
        case .review, .incomplete: return Theme.error
        default: return Theme.muted
        }
    }

    private var accessibilityText: String {
        let date = row.startedAt.map { $0.formatted(Self.dateStyle) } ?? "sin fecha"
        let size = ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)
        return "Grabación del \(date), \(size), \(row.statusLabel)"
    }
}
