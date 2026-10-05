import SwiftUI

@main
struct AppleMusicLocalizerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}

struct ContentView: View {
    @StateObject private var musicManager = MusicManager()
    private let donateURL = URL(string: "https://buymeacoffee.com/sudo.tinycraft")!

    private var selectableTracks: [LocalTrack] {
        musicManager.tracks.filter(\.hasProposal)
    }

    private var allAvailableSelected: Bool {
        !selectableTracks.isEmpty && selectableTracks.allSatisfy(\.isSelected)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Music 原文還原工具")
                        .font(.title2.bold())
                    Text("讀取同專輯曲目，逐首確認後批次更新")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("掃描目前專輯") {
                    musicManager.fetchCurrentAlbum()
                }
                .disabled(musicManager.isBusy)
                .buttonStyle(.borderedProminent)
                if musicManager.canUndo {
                    Button("復原修改") {
                        musicManager.undoMetadata()
                    }
                    .disabled(musicManager.isBusy)
                    .buttonStyle(.bordered)
                }
            }

            if let album = musicManager.albumName {
                VStack(alignment: .leading, spacing: 5) {
                    Text(album).font(.headline)
                    Text("專輯歌手：\(musicManager.albumArtistName ?? "未知")　目前播放：\(musicManager.currentTrackName ?? "未知") · \(musicManager.currentArtistName ?? "未知")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack {
                Text("曲目對照").font(.headline)
                Text("本機 \(musicManager.tracks.count) 首 · 可套用 \(selectableTracks.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectableTracks.isEmpty {
                    Button(allAvailableSelected ? "取消全選" : "全選可套用曲目") {
                        musicManager.selectAllAvailable(!allAvailableSelected)
                    }
                    .buttonStyle(.plain)
                }
            }

            if musicManager.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            if musicManager.tracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("尚無曲目清單").font(.headline)
                    Text("播放 Apple Music 中的歌曲，再掃描目前專輯。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(musicManager.tracks) { track in
                            trackRow(track)
                            if track.id != musicManager.tracks.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }

            HStack {
                Text(musicManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if !musicManager.canUndo {
                    Button("套用已勾選曲目") {
                        musicManager.applySelectedMetadata()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(musicManager.isBusy || selectableTracks.allSatisfy { !$0.isSelected })
                }
            }

            Divider()
            // Donate 贊助區塊
            Button(action: {
                NSWorkspace.shared.open(donateURL)
            }) {
                HStack(spacing: 8) {
                    Text("☕️")
                    Text("這工具讓你開心嗎？和開發者分享這份喜悅")
                        .font(.footnote)
                        .fontWeight(.medium)
                }
                .foregroundColor(.brown)
            }
            .buttonStyle(.plain)
            .help("點擊以前往贊助頁面，您的支持是開發者持續維護的最大動力！")
        }
        .padding(20)
    }

    @ViewBuilder
    private func trackRow(_ track: LocalTrack) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if track.hasProposal {
                Toggle("選取曲目 \(track.trackNumber)", isOn: Binding(
                    get: { musicManager.tracks.first(where: { $0.id == track.id })?.isSelected ?? false },
                    set: { musicManager.setSelected($0, for: track.id) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            } else {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .padding(.top, 2)
            }

            Text(track.discNumber > 1
                 ? String(format: "%d-%02d", track.discNumber, track.trackNumber)
                 : String(format: "%02d", track.trackNumber))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(track.name).fontWeight(.medium)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(track.proposedName ?? "無對應結果")
                        .foregroundStyle(track.hasProposal ? Color.primary : Color.secondary)
                }
                HStack(spacing: 5) {
                    Text(track.artist)
                    if let artist = track.proposedArtist, track.hasProposal {
                        Text("→ \(artist)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
