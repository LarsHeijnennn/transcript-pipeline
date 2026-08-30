import SwiftUI

struct LiveRecordingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var recorder: LiveRecordingService

    let onComplete: (LiveRecordingResult, String, LanguageHint, Bool) -> Void

    @State private var mode: LiveRecordingMode = .macAudioAndMicrophone
    @State private var title = ""
    @State private var language: LanguageHint = .automatic
    @State private var selectedMicrophoneID = ""
    @State private var authorizationConfirmed = false
    @State private var actionError: String?

    var body: some View {
        ZStack {
            AppCanvas()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    SymbolBadge(symbol: "record.circle", color: .red, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New recording").font(.title2.weight(.semibold))
                        Text("Captured locally until you process it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if recorder.phase == .idle {
                        Button("Cancel") { dismiss() }
                            .liquidGlassButton()
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(20)
                .background(.thinMaterial)
                .overlay(alignment: .bottom) { Divider() }

                if recorder.phase == .idle {
                    setup
                } else {
                    activeRecording
                }
            }
        }
        .frame(width: 620, height: 690)
        .interactiveDismissDisabled(recorder.phase.isBusy)
        .onAppear {
            recorder.refreshMicrophones()
            if selectedMicrophoneID.isEmpty {
                selectedMicrophoneID = recorder.defaultMicrophoneID ?? ""
            }
            if title.isEmpty {
                title = "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
                language = settings.defaultLanguage
            }
        }
        .onChange(of: recorder.elapsedSeconds) { _, elapsed in
            guard elapsed >= AppConfiguration.maximumRecordingDuration,
                  recorder.phase == .recording else { return }
            Task { await stop() }
        }
        .alert("Recording failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Unknown recording error")
        }
    }

    private var setup: some View {
        VStack(spacing: 0) {
            Form {
                Section("Recording") {
                    TextField("Title", text: $title)
                    Picker("Language", selection: $language) {
                        ForEach(LanguageHint.allCases) { hint in
                            Text(hint.title).tag(hint)
                        }
                    }
                }

                Section("Source") {
                    ForEach(LiveRecordingMode.allCases) { candidate in
                        Button {
                            mode = candidate
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: candidate.symbol)
                                    .font(.title2)
                                    .frame(width: 30)
                                    .foregroundStyle(mode == candidate ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(candidate.title).fontWeight(.semibold)
                                        if mode == candidate {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    Text(candidate.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(12)
                            .functionalGlass(
                                cornerRadius: 14,
                                tint: mode == candidate ? .accentColor.opacity(0.18) : nil,
                                interactive: true
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(candidate.title). \(candidate.detail)")
                    }
                    .animation(.snappy(duration: 0.24), value: mode)
                }

                Section("Microphone") {
                    if recorder.availableMicrophones.isEmpty {
                        Label("No microphone is currently available", systemImage: "mic.slash")
                            .foregroundStyle(.orange)
                    } else {
                        Picker("Input", selection: $selectedMicrophoneID) {
                            ForEach(recorder.availableMicrophones) { microphone in
                                Text(microphone.isDefault ? "\(microphone.name) — System default" : microphone.name)
                                    .tag(microphone.id)
                            }
                        }
                        Button("Refresh microphones", systemImage: "arrow.clockwise") {
                            recorder.refreshMicrophones()
                            if !recorder.availableMicrophones.contains(where: { $0.id == selectedMicrophoneID }) {
                                selectedMicrophoneID = recorder.defaultMicrophoneID ?? ""
                            }
                        }
                    }
                    Text("For a Teams or FaceTime call, choose the same microphone that the call is using. What Was Said records this input through an independent microphone session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Before recording") {
                    Label(
                        "Recording is saved locally first. Nothing goes to OpenAI until you later click Process.",
                        systemImage: "lock.shield"
                    )
                    Text("For Mac audio, Apple’s system picker asks you to choose the display containing the call. This captures call audio even when Teams or FaceTime plays it through a helper process. It also captures other sounds on that display, while excluding What Was Said itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(
                        "I am permitted to record this conversation and have informed all participants where required.",
                        isOn: $authorizationConfirmed
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Maximum recording length: 3 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Start Recording", systemImage: "record.circle") {
                    Task { await start() }
                }
                .liquidGlassButton(prominent: true)
                .tint(.red)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !authorizationConfirmed || selectedMicrophoneID.isEmpty)
                .keyboardShortcut(.defaultAction)
                .help(authorizationConfirmed ? "Start recording" : "Confirm recording authorization first")
            }
            .padding(16)
            .functionalGlass(cornerRadius: 18)
            .padding(12)
        }
    }

    private var activeRecording: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(.red.opacity(0.13)).frame(width: 118, height: 118)
                Circle().fill(.red).frame(width: 62, height: 62)
                Image(systemName: recorder.phase == .recording ? "waveform" : "ellipsis")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .padding(12)
            .functionalGlass(cornerRadius: 72, tint: .red.opacity(0.15))
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(recorder.phase.title)
                    .font(.title2.bold())
                Text(recorder.elapsedSeconds.clockString)
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                    .accessibilityLabel("Recording duration \(recorder.elapsedSeconds.clockString)")
                if recorder.phase == .choosingContent {
                    Text("Choose the display containing the call in Apple’s picker. Mac audio and your selected microphone will be captured through separate, independently monitored paths.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 390)
                } else if recorder.phase == .recording {
                    Text("Keep this app running. Check that both meters move when you and another participant speak.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 390)
                    VStack(spacing: 10) {
                        AudioSourceHealthRow(status: recorder.microphoneStatus)
                        if mode == .macAudioAndMicrophone {
                            AudioSourceHealthRow(status: recorder.systemAudioStatus)
                        }
                    }
                    .frame(maxWidth: 440)

                    if recordingHasIssue {
                        Label(
                            "One source needs attention. The app will preserve the separate source files if it cannot produce a complete mix.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    }
                }
            }

            if recorder.phase == .recording {
                Button("Stop and Save", systemImage: "stop.circle.fill") {
                    Task { await stop() }
                }
                .liquidGlassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else if recorder.phase == .choosingContent {
                Button("Cancel") {
                    Task {
                        await recorder.cancel()
                        dismiss()
                    }
                }
                .liquidGlassButton()
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding(28)
    }

    private func start() async {
        do {
            try await recorder.start(mode: mode, microphoneDeviceID: selectedMicrophoneID)
        } catch is CancellationError {
            // The system picker or this sheet was intentionally cancelled.
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var recordingHasIssue: Bool {
        let statuses = mode == .microphone
            ? [recorder.microphoneStatus]
            : [recorder.microphoneStatus, recorder.systemAudioStatus]
        return statuses.contains { status in
            switch status.health {
            case .silent, .stalled, .failed: true
            case .waiting, .active: false
            }
        }
    }

    private func stop() async {
        do {
            let result = try await recorder.stop()
            onComplete(
                result,
                title.trimmingCharacters(in: .whitespacesAndNewlines),
                language,
                authorizationConfirmed
            )
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct AudioSourceHealthRow: View {
    let status: LiveAudioSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(status.source.title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(stateTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
            }
            ProgressView(value: status.level, total: 1)
                .progressViewStyle(.linear)
                .tint(color)
            Text(status.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status.health {
        case .waiting: "waveform"
        case .active: status.hasDetectedSound ? "checkmark.circle.fill" : "waveform"
        case .silent: "speaker.slash.fill"
        case .stalled: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch status.health {
        case .active where status.hasDetectedSound: .green
        case .silent, .stalled: .orange
        case .failed: .red
        case .waiting, .active: .secondary
        }
    }

    private var stateTitle: String {
        switch status.health {
        case .waiting: "Starting"
        case .active: status.hasDetectedSound ? "Sound detected" : "Connected"
        case .silent: "Silent"
        case .stalled: "Stalled"
        case .failed: "Failed"
        }
    }
}
