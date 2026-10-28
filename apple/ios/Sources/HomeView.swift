import SwiftUI

struct HomeView: View {
    @Bindable var library: Library
    @State private var showSettings = false
    @State private var pairing: PairingLink?
    @State private var showPair = false

    var body: some View {
        NavigationStack {
            Group {
                if library.paired {
                    history
                } else {
                    WelcomeView { showPair = true }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if library.paired {
                    if #available(iOS 26, *) {
                        // A title, not a button, so no glass behind it.
                        ToolbarItem(placement: .topBarLeading) { BrandTitle() }.sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) { BrandTitle() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(library: library) }
            .sheet(isPresented: $showPair) { PairView(library: library, link: pairing) }
            // For development and screenshots: `-HoltOpen pair`, `settings` or `sendfaster`.
            .task {
                switch UserDefaults.standard.string(forKey: "HoltOpen") {
                case "pair": showPair = true
                case "settings", "sendfaster": showSettings = true
                default: break
                }
            }
            .onChange(of: library.pendingPairing) { _, link in
                guard let link else { return }
                pairing = link
                showPair = true
                library.pendingPairing = nil
            }
        }
    }

    /// The newest clip, shown big at the top, when not searching.
    private var latest: Clip? {
        library.query.isEmpty ? library.clips.first(where: { !$0.pinned }) : nil
    }

    private var history: some View {
        List {
            if let status = library.syncStatus, library.query.isEmpty {
                StatusLine(label: status.label, connected: status.connected)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
            }
            if library.newCopy && library.query.isEmpty {
                NewCopyBanner(library: library)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            }
            if let latest {
                LatestClip(clip: latest, showSource: library.devices.count > 1) { library.copy(latest) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            }
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.clips, id: \.id) { clip in
                        ClipRow(clip: clip, showSource: library.devices.count > 1)
                            .contentShape(Rectangle())
                            .onTapGesture { library.copy(clip) }
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                            .swipeActions(edge: .leading) {
                                Button(clip.pinned ? "Unpin" : "Pin", systemImage: clip.pinned ? "pin.slash" : "pin") {
                                    library.togglePin(clip)
                                }
                                .tint(Brand.riverDeep)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) { library.delete(clip) }
                            }
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { library.copy(clip) }
                                ShareLink(item: clip.text)
                                Button(clip.pinned ? "Unpin" : "Pin", systemImage: "pin") { library.togglePin(clip) }
                                Button("Delete", systemImage: "trash", role: .destructive) { library.delete(clip) }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                        .textCase(nil)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 4, trailing: 20))
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $library.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your clips")
        .overlay {
            if library.clips.isEmpty {
                if library.query.isEmpty {
                    ContentUnavailableView(
                        "Nothing copied yet", systemImage: "doc.on.clipboard",
                        description: Text("What you copy on your Mac shows up here."))
                } else {
                    ContentUnavailableView.search(text: library.query)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let notice = library.notice {
                    NoticeToast(message: notice).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                SendBar(library: library)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: library.notice)
        }
    }

    /// Pinned first, then by day, like the Mac popup. The newest clip sits above, on its own.
    private var sections: [(title: String, clips: [Clip])] {
        let calendar = Calendar.current
        var groups: [(title: String, clips: [Clip])] = []
        for clip in library.clips where clip.id != latest?.id {
            let date = Date(timeIntervalSince1970: TimeInterval(clip.createdAt) / 1000)
            let title =
                clip.pinned
                ? "Pinned" : calendar.isDateInToday(date) ? "Today" : calendar.isDateInYesterday(date) ? "Yesterday" : "Earlier"
            if groups.last?.title == title {
                groups[groups.count - 1].clips.append(clip)
            } else {
                groups.append((title, [clip]))
            }
        }
        return groups
    }
}

/// Skip's face and the name, like the search field in the Mac popup.
private struct BrandTitle: View {
    var body: some View {
        HStack(spacing: 10) {
            Skip(faceOnly: true).frame(width: 34, height: 27)
            Text("Holt").font(.system(.title2, design: .rounded).weight(.bold))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// "Copied", "Sent to your Mac". Skip hops in with it, like the arrival toast on the Mac.
private struct NoticeToast: View {
    let message: String
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Skip(faceOnly: true)
                .frame(width: 28, height: 22)
                .offset(y: landed ? 0 : -6)
                .opacity(landed ? 1 : 0)
            Text(message).font(.subheadline.weight(.semibold))
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .onAppear {
            if reduceMotion {
                landed = true
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.08)) { landed = true }
            }
        }
    }
}

private struct StatusLine: View {
    let label: String
    let connected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// The one bold element: the newest clip, large, one tap to copy.
private struct LatestClip: View {
    let clip: Clip
    let showSource: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 14) {
                let text = preview(clip)
                Text(text)
                    .font(
                        .system(text.count > 80 ? .body : .title3, design: text.contains("\n") ? .monospaced : .default)
                            .weight(.medium)
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Age(clip: clip, source: source(clip, showSource))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.river)
                }
            }
            .padding(18)
            .background(Brand.river.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ClipRow: View {
    let clip: Clip
    let showSource: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if clip.pinned {
                    Image(systemName: "pin.fill").font(.footnote).foregroundStyle(Brand.river)
                } else if clip.kind == .link {
                    Image(systemName: "link").font(.footnote).foregroundStyle(Brand.river)
                }
                Text(preview(clip))
                    .lineLimit(2)
            }
            HStack {
                if let source = source(clip, showSource) {
                    Text(source)
                    Spacer()
                }
                Age(clip: clip)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// You copied in another app, then opened Holt. iOS hid the copy from Holt until now,
/// so offer to send it. Apple's paste button reads it without the prompt.
private struct NewCopyBanner: View {
    let library: Library

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("You copied something new").font(.subheadline.weight(.semibold))
                Text(
                    library.devices.contains(where: \.online)
                        ? "Paste sends it to \(library.macs)." : "Paste sends it once \(library.macs) connects."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in await library.send(strings.joined(separator: "\n")) }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .tint(Brand.riverDeep)
            Button("Not now", systemImage: "xmark") { library.markCopySeen() }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity)
    }
}

/// Paste and send, at thumb height. Apple's paste button reads the clipboard without
/// the "Allow Paste?" prompt.
private struct SendBar: View {
    let library: Library

    var body: some View {
        HStack(spacing: 14) {
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in await library.send(strings.joined(separator: "\n")) }
            }
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
            // The deep teal keeps the white label readable in dark mode too.
            .tint(Brand.riverDeep)
            // Apple fixes the button's label to "Paste", so the text says where it goes.
            Text(destination).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var destination: String {
        library.devices.contains(where: \.online) ? "Sends to \(library.macs)" : "Sends once \(library.macs) connects"
    }
}

/// Where a clip came from. With one Mac, naming it on every clip is noise, so only
/// clips from this iPhone say so.
private func source(_ clip: Clip, _ showDevice: Bool) -> String? {
    clip.device == nil ? "This iPhone" : showDevice ? clip.device : nil
}

/// The start of a clip, enough for a few lines, and cheap to render even when the clip is a whole log file.
private func preview(_ clip: Clip) -> String {
    String(clip.text.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// "Just now", "5 min. ago". Updates on its own, since the list only redraws when clips change.
private struct Age: View {
    let clip: Clip
    var source: String?

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(source.map { "\($0), \(age(clip).lowercased())" } ?? age(clip))
        }
    }
}

private func age(_ clip: Clip) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(clip.createdAt) / 1000)
    if Date().timeIntervalSince(date) < 60 { return "Just now" }
    return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
}

/// Before pairing: the one place Skip greets you.
private struct WelcomeView: View {
    let pair: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            Skip().frame(width: 150, height: 150)
            Text("Welcome to Holt")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .padding(.top, 28)
            Text("Everything you copy on your Mac, on your iPhone too. And what you copy here, a tap away on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 12)
            Spacer(minLength: 40)
            Button("Pair with your Mac", action: pair)
                .buttonStyle(PrimaryButtonStyle())
            Text("Holt for Mac is free at holt.snowztech.com")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: 520)
    }
}
