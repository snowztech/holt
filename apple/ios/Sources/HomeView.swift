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
            .navigationTitle(library.paired ? "Holt" : "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .overlay(alignment: .bottom) { NoticeView(text: library.notice) }
            .sheet(isPresented: $showSettings) { SettingsView(library: library) }
            .sheet(isPresented: $showPair) { PairView(library: library, link: pairing) }
            // For development: `-HoltOpen pair` opens the pairing sheet, `-HoltOpen settings` Settings.
            .task {
                switch UserDefaults.standard.string(forKey: "HoltOpen") {
                case "pair": showPair = true
                case "settings": showSettings = true
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

    private var history: some View {
        List {
            if library.query.isEmpty {
                SendHeader(library: library)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 18, trailing: 20))
            }
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.clips, id: \.id) { clip in
                        ClipRow(clip: clip)
                            .contentShape(Rectangle())
                            .onTapGesture { library.copy(clip) }
                            .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                            .swipeActions(edge: .leading) {
                                Button(clip.pinned ? "Unpin" : "Pin", systemImage: clip.pinned ? "pin.slash" : "pin") {
                                    library.togglePin(clip)
                                }
                                .tint(Brand.river)
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
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $library.query, prompt: "Search your clips")
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
    }

    /// Pinned first, then by day, like the Mac popup.
    private var sections: [(title: String, clips: [Clip])] {
        let calendar = Calendar.current
        var groups: [(title: String, clips: [Clip])] = []
        for clip in library.clips {
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

private struct ClipRow: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if clip.kind == .link {
                    Image(systemName: "link").font(.subheadline).foregroundStyle(Brand.river)
                }
                Text(clip.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(3)
            }
            HStack(spacing: 5) {
                if clip.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Brand.river)
                }
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var meta: String {
        let date = Date(timeIntervalSince1970: TimeInterval(clip.createdAt) / 1000)
        let age = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\(clip.device ?? "This iPhone") · \(age)"
    }
}

/// The top of the list: sync status and the paste button, light, without a box.
private struct SendHeader: View {
    let library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = library.syncStatus {
                HStack(spacing: 6) {
                    Circle().fill(status.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                    Text(status.label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            // Apple's paste button reads the clipboard without the "Allow Paste?" prompt.
            HStack(spacing: 12) {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in await library.send(strings.joined(separator: "\n")) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                // The deep teal keeps the white label readable in dark mode too.
                .tint(Brand.riverDeep)
                Text("Send what you copied to your Mac")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
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

/// A short notice at the bottom, like "Copied" or "Sent to your Mac".
private struct NoticeView: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary, Brand.river)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: text)
        }
    }
}
