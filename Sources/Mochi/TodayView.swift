import MochiCapture
import MochiKit
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let session = model.session {
                LiveView(session: session)
            } else {
                IdleToday()
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: model.isRecording)
    }
}

struct IdleToday: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    if CapturePermission.microphoneDenied {
                        Banner(text: "Microphone access is off. Mochi cannot record.", actionTitle: "Open System Settings") {
                            CapturePermission.openSettings("Privacy_Microphone")
                        }
                    }
                    UpdateBanner()
                    if let app = model.detectedApp {
                        DetectedCallCard(app: app)
                    }
                    if let error = model.startError { Banner(text: error) }
                    let waiting = model.pendingSuggestions.count
                    if waiting > 0 { ReviewNudge(count: waiting) }
                    if let free = model.storage.freeSpace(), free < 2_000_000_000 {
                        Banner(text: "Less than 2 GB free. A one hour call needs about 700 MB.")
                    }
                }
                .frame(maxWidth: 560)
                .padding(.top, 20)

                Button { model.startRecording() } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(CapturePermission.microphoneDenied)
                .padding(.top, 64)

                Text("Records your mic and the call app. Press ⌃⌥R from any app.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 14)

                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Up next").font(.headline).foregroundStyle(.secondary)
                        if model.calendar.authorized, !model.calendar.meetings.isEmpty,
                           !model.calendar.meetings.contains(where: { Calendar.current.isDateInToday($0.start) }) {
                            Text("No more meetings today.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !model.calendar.authorized {
                            Button {
                                Task { await model.calendar.requestAccess() }
                            } label: {
                                Label("Show meetings from Calendar", systemImage: "calendar.badge.plus")
                            }
                            .buttonStyle(.link)
                        } else if model.calendar.meetings.isEmpty {
                            Text("Nothing scheduled").foregroundStyle(.tertiary)
                        }
                        ForEach(model.calendar.meetings.prefix(2)) { MeetingRow(meeting: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !model.calls.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent calls").font(.headline).foregroundStyle(.secondary)
                            ForEach(model.calls.prefix(3)) { call in
                                RecentCallRow(call: call)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 88)
                .padding(.horizontal, 28)
                .frame(maxWidth: 820)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 28)
        }
        .navigationTitle("Today")
        .navigationSubtitle(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }
}

struct RecentCallRow: View {
    @Environment(AppModel.self) private var model
    let call: Call

    var body: some View {
        HStack(spacing: 10) {
            ProjectDot(project: model.project(call.projectID))
            VStack(alignment: .leading, spacing: 1) {
                Text(call.title).font(.body.weight(.medium)).lineLimit(1)
                Text([call.startedAt.dayGroup, TranscriptText.duration(call.duration), call.appName].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.copyTranscript(call.id) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy Transcript")
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .onTapGesture {
            model.selectedCallID = call.id
            model.section = .calls
        }
    }
}

/// The live recording view: the transcript arriving, the floating pause/stop group.
struct LiveView: View {
    @Environment(AppModel.self) private var model
    let session: RecordingSession

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if case .attention(let why) = session.health { Banner(text: why) }
                        if case .broken(let why) = session.health {
                            Banner(text: "\(why). What was recorded so far is saved.", actionTitle: "Stop") { model.stopRecording() }
                        }
                        if session.segments.isEmpty {
                            Text(session.health == .starting ? "Starting…" : "Listening. Lines appear here a few seconds after they are spoken.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        }
                        TranscriptView(segments: TranscriptText.clean(session.segments), call: session.call, live: true)
                        Color.clear.frame(height: 90).id("bottom")
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onChange(of: session.segments.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Real glass button styles, so the whole circle takes the click. With .plain and the glass
            // drawn outside, only the small glyph was hit-testable and clicks on the circle did nothing.
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { model.togglePause() } label: {
                        Image(systemName: session.paused ? "play.fill" : "pause.fill").font(.title3).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .contentShape(Circle())
                    .help(session.paused ? "Resume recording (⌃⌥P)" : "Pause recording (⌃⌥P)")
                    .accessibilityLabel(session.paused ? "Resume recording" : "Pause recording")
                    Button { model.stopRecording() } label: {
                        Image(systemName: "stop.fill").font(.title3).foregroundStyle(.white).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .contentShape(Circle())
                    .help("Stop recording (⌃⌥R)")
                    .accessibilityLabel("Stop recording")
                }
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
            }
            .padding(.bottom, 22)
        }
        .navigationTitle(session.call.title)
        .navigationSubtitle(session.callApp?.name ?? "Recording")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 14) {
                    LiveWaveform(levels: session.wave, tint: session.paused ? .secondary : .primary)
                    Text(TranscriptText.clock(session.savedSeconds))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(session.paused ? .secondary : .primary)
                    SideTraces(me: session.micLevel, them: session.themLevel, dim: session.paused)
                }
                .padding(.horizontal, 16)
            }
            ToolbarItem(placement: .primaryAction) {
                CopyButton(title: "Copy Transcript", prominent: false) { model.copyTranscript(session.call.id) }
            }
        }
    }
}

struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    var showCalendar = false
    @State private var hovering = false

    var soon: Bool { abs(meeting.start.timeIntervalSinceNow) < 15 * 60 || (meeting.start < Date() && meeting.end > Date()) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                // On Today, a meeting on another day leads with its date, so it never reads as today.
                if !showCalendar && !Calendar.current.isDateInToday(meeting.start) {
                    Text(Calendar.current.isDateInTomorrow(meeting.start) ? "Tomorrow"
                         : meeting.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                Text(meeting.start.formatted(.dateTime.hour().minute()))
                    .font(.body.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 84, alignment: .leading)
            Image(systemName: meeting.symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if soon || hovering {
                Button { model.startRecording(event: meeting) } label: { Label("Record", systemImage: "record.circle") }
                    .buttonStyle(.bordered)
                    .disabled(model.isRecording)
            }
        }
        .frame(minHeight: 44)
        .onHover { hovering = $0 }
    }

    private var detail: String {
        var parts: [String] = []
        if let app = meeting.appName { parts.append(app) }
        if showCalendar { parts.append(meeting.calendarName) }
        let until = meeting.start.timeIntervalSinceNow
        if until > 0 && until < 7200 { parts.append("in \(Int(until / 60)) min") }
        if !meeting.attendees.isEmpty { parts.append(meeting.attendees.prefix(2).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// "Google Chrome is using your mic. Record this call?" inside the app.
struct DetectedCallCard: View {
    @Environment(AppModel.self) private var model
    let app: CallApp

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform.fill").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting detected").font(.headline)
                Text("\(app.name) is using your mic. Record \(model.calendar.eventNow()?.title ?? "this call")?")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now") { CallWatcher.shared.snooze() }
            Button("Record") { model.startRecording(app: app) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(12)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}

/// "A new Mochi is ready" with Install, on Today. Nothing when up to date.
struct UpdateBanner: View {
    private var updater: Updater { Updater.shared }

    var body: some View {
        if let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A new Mochi is ready").font(.headline)
                    Text(updater.error ?? release.notes ?? "Version \(release.version), build \(release.build).")
                        .foregroundStyle(updater.error == nil ? Color.secondary : Color.orange)
                        .lineLimit(2)
                }
                Spacer()
                if updater.installing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Install and Relaunch") { updater.install() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.quaternary, in: .rect(cornerRadius: 12))
        }
    }
}
