import SwiftData
import SwiftUI

struct TranscriptView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var recording: RecordingRecord
    let player: AudioPlayerController
    let isProcessing: Bool
    let onProcess: () -> Void

    @State private var orderedSegments: [TranscriptSegmentRecord]
    @State private var segmentStartTimes: [TimeInterval]
    @State private var activeSegmentID: UUID?
    @State private var showsCompactSpeakerEditor = false

    init(
        recording: RecordingRecord,
        player: AudioPlayerController,
        isProcessing: Bool,
        onProcess: @escaping () -> Void
    ) {
        self.recording = recording
        self.player = player
        self.isProcessing = isProcessing
        self.onProcess = onProcess
        let segments = recording.sortedSegments
        _orderedSegments = State(initialValue: segments)
        _segmentStartTimes = State(initialValue: segments.map(\.startSeconds))
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                HStack(spacing: 0) {
                    speakerInspector
                    Divider()
                    transcriptContent
                }
            } else {
                VStack(spacing: 0) {
                    compactSpeakerBar
                    Divider()
                    transcriptContent
                }
            }
        }
        .onChange(of: recording.segments.count) { _, _ in reloadTimeline() }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if orderedSegments.isEmpty {
            ContentUnavailableView {
                Label("No transcript yet", systemImage: "text.bubble")
            } description: {
                Text("Process this recording to identify speakers and create a timed transcript.")
            } actions: {
                Button("Process Recording", action: onProcess)
                    .liquidGlassButton(prominent: true)
                    .disabled(isProcessing)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(orderedSegments) { segment in
                    TranscriptSegmentRow(
                        segment: segment,
                        speakers: recording.speakers,
                        isActive: segment.id == activeSegmentID,
                        onSeek: { player.seek(to: segment.startSeconds) },
                        onChanged: {
                            segment.updatedAt = Date()
                            recording.markAnalysesStale()
                            try? modelContext.save()
                        }
                    )
                    .id(segment.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onReceive(player.$currentTime) { time in
                    guard let index = TranscriptTimelineSearch.activeIndex(
                        startTimes: segmentStartTimes,
                        at: time
                    ) else { return }
                    let id = orderedSegments[index].id
                    guard id != activeSegmentID else { return }
                    activeSegmentID = id
                    if player.isPlaying {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var speakerInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModernSectionTitle(title: "Speakers", subtitle: "Rename or merge", symbol: "person.2")
            ForEach(recording.speakers.sorted(by: { $0.colorIndex < $1.colorIndex })) { speaker in
                HStack {
                    Circle().fill(speakerColor(speaker.colorIndex)).frame(width: 9, height: 9)
                    TextField("Speaker", text: Binding(
                        get: { speaker.displayName },
                        set: { speaker.displayName = $0; recording.markAnalysesStale() }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit { try? modelContext.save() }
                    Menu {
                        ForEach(recording.speakers.filter { $0.id != speaker.id }) { target in
                            Button("Merge into \(target.displayName)") { merge(speaker, into: target) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 26, height: 26)
                            .functionalGlass(cornerRadius: 9, interactive: true)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Spacer()
            Text("Renaming or merging speakers marks generated notes as stale.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 230)
        .functionalGlass(cornerRadius: 18)
        .padding(10)
    }

    private var compactSpeakerBar: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsCompactSpeakerEditor.toggle()
                }
            } label: {
                HStack {
                    Label("\(recording.speakers.count) \(recording.speakers.count == 1 ? "speaker" : "speakers")", systemImage: "person.2")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(showsCompactSpeakerEditor ? "Done" : "Manage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showsCompactSpeakerEditor ? 180 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityHint(showsCompactSpeakerEditor ? "Collapse speaker editor" : "Rename or merge speakers")

            if showsCompactSpeakerEditor {
                Divider()
                VStack(spacing: 8) {
                ForEach(recording.speakers.sorted(by: { $0.colorIndex < $1.colorIndex })) { speaker in
                    HStack(spacing: 7) {
                        Circle().fill(speakerColor(speaker.colorIndex)).frame(width: 8, height: 8)
                        TextField("Speaker", text: Binding(
                            get: { speaker.displayName },
                            set: { speaker.displayName = $0; recording.markAnalysesStale() }
                        ))
                        .textFieldStyle(.plain)
                        .onSubmit { try? modelContext.save() }
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(recording.speakers.filter { $0.id != speaker.id }) { target in
                                Button("Merge into \(target.displayName)") { merge(speaker, into: target) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 26, height: 26)
                                .functionalGlass(cornerRadius: 9, interactive: true)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                }
                }
                .padding(10)
            }
        }
        .functionalGlass(cornerRadius: 16, interactive: true)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .animation(.snappy(duration: 0.24), value: showsCompactSpeakerEditor)
    }

    private func reloadTimeline() {
        let segments = recording.sortedSegments
        orderedSegments = segments
        segmentStartTimes = segments.map(\.startSeconds)
        activeSegmentID = nil
    }

    private func merge(_ source: SpeakerRecord, into target: SpeakerRecord) {
        recording.segments.filter { $0.speakerID == source.providerLabel }.forEach {
            $0.speakerID = target.providerLabel
        }
        recording.speakers.removeAll { $0.id == source.id }
        modelContext.delete(source)
        recording.markAnalysesStale()
        try? modelContext.save()
    }
}

private struct TranscriptSegmentRow: View {
    @Bindable var segment: TranscriptSegmentRecord
    let speakers: [SpeakerRecord]
    let isActive: Bool
    let onSeek: () -> Void
    let onChanged: () -> Void
    @FocusState private var textIsFocused: Bool
    @State private var lastCommittedText: String

    init(
        segment: TranscriptSegmentRecord,
        speakers: [SpeakerRecord],
        isActive: Bool,
        onSeek: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.segment = segment
        self.speakers = speakers
        self.isActive = isActive
        self.onSeek = onSeek
        self.onChanged = onChanged
        _lastCommittedText = State(initialValue: segment.editedText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isActive ? Color.accentColor : .clear)
                .frame(width: 3)
            Button(segment.startSeconds.clockString, action: onSeek)
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker("Speaker", selection: $segment.speakerID) {
                ForEach(speakers) { speaker in
                    Text(speaker.displayName).tag(speaker.providerLabel)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .onChange(of: segment.speakerID) { _, _ in onChanged() }
            TextField("Transcript text", text: $segment.editedText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($textIsFocused)
                .onSubmit(commitTextIfNeeded)
                .onChange(of: textIsFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused { commitTextIfNeeded() }
                }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            isActive ? Color.accentColor.opacity(0.075) : .clear,
            in: RoundedRectangle(cornerRadius: AppStyle.compactRadius, style: .continuous)
        )
        .animation(.easeOut(duration: 0.16), value: isActive)
        .accessibilityElement(children: .contain)
        .onDisappear(perform: commitTextIfNeeded)
    }

    private func commitTextIfNeeded() {
        guard segment.editedText != lastCommittedText else { return }
        lastCommittedText = segment.editedText
        onChanged()
    }
}

enum TranscriptTimelineSearch {
    static func activeIndex(startTimes: [TimeInterval], at time: TimeInterval) -> Int? {
        guard !startTimes.isEmpty, time >= startTimes[0] else { return nil }
        var lower = 0
        var upper = startTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if startTimes[middle] <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }
}

func speakerColor(_ index: Int) -> Color {
    let colors: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .brown]
    return colors[abs(index) % colors.count]
}
