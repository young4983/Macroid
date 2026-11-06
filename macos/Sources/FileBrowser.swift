import AppKit
import SwiftUI

struct PhoneFile: Identifiable {
    let path: String, name: String
    let directory: Bool
    let size: Int64
    var id: String { path }
}

struct FileBrowser: View {
    @ObservedObject var model: AppModel
    @State private var path = "/sdcard"
    @State private var rootPath = ""
    @State private var entries: [PhoneFile] = []
    @State private var loading = false
    @State private var transferTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("手机文件").font(.title3.weight(.semibold))

                }
                Spacer()
                Button { pickUpload() } label: { Label("上传", systemImage: "arrow.up.doc") }
                    .disabled(model.transferProgress != nil)
            }
            HStack {
                Button { Task { await load((path as NSString).deletingLastPathComponent) } } label: { Image(systemName: "chevron.up") }.disabled(path == rootPath || loading)
                Text(path).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button { Task { await load(path) } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading)
            }.buttonStyle(.borderless).padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if let progress = model.transferProgress {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(model.transferLabel).font(.caption); ProgressView(value: progress) }
                    Button("取消") { transferTask?.cancel() }
                }
            }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if entries.isEmpty {
                VStack(spacing: 12) { Image(systemName: "folder").font(.system(size: 36)); Text("此文件夹为空") }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Button {
                                if entry.directory { Task { await load(entry.path) } } else { pickDownload(entry) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.directory ? "folder.fill" : "doc.fill").font(.system(size: 24)).foregroundStyle(entry.directory ? Color.accentColor : .secondary).frame(width: 34)
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(entry.directory ? "文件夹" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: entry.directory ? "chevron.right" : "arrow.down").foregroundStyle(.tertiary).frame(width: 18)
                                }.padding(.vertical, 12).padding(.horizontal, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.transferProgress != nil)
                            Divider()
                        }
                    }
                }
            }
        }.padding(20).task { await load("/sdcard") }
    }
    private func load(_ target: String) async {
        guard let transport = model.transport else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await transport.request("files.list", ["path": target])
            path = result["path"] as? String ?? target
            if rootPath.isEmpty { rootPath = path }
            entries = (result["entries"] as? [[String: Any]] ?? []).compactMap {
                guard let name = $0["name"] as? String, let path = $0["path"] as? String else { return nil }
                return PhoneFile(path: path, name: name, directory: $0["directory"] as? Bool ?? false, size: ($0["size"] as? NSNumber)?.int64Value ?? 0)
            }
        } catch { model.error = error.localizedDescription }
    }
    private func pickUpload() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferTask = Task { await model.upload(url, directory: path); await load(path) }
    }
    private func pickDownload(_ entry: PhoneFile) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transferTask = Task { await model.download(entry, to: url) }
    }
}

extension AppModel {
    func upload(_ url: URL, directory: String) async {
        guard let transport, transferProgress == nil else { return }
        transferProgress = 0; transferLabel = "正在上传 " + url.lastPathComponent
        defer { transferProgress = nil }
        var transfer: String?
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let begin = try await transport.request("files.upload.begin", ["path": (directory as NSString).appendingPathComponent(url.lastPathComponent), "size": size])
            guard let id = begin["transfer"] as? String else { throw WireError.malformed }; transfer = id
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 196608), !data.isEmpty else { throw WireError.remote("本地文件在上传期间发生变化") }
                _ = try await transport.request("files.upload.chunk", ["transfer": id, "offset": offset, "data": data.base64EncodedString()])
                offset += data.count; transferProgress = Double(offset) / Double(max(1, size))
            }
            try Task.checkCancellation()
            _ = try await transport.request("files.upload.finish", ["transfer": id]); transfer = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
        if let transfer { _ = try? await transport.request("files.upload.cancel", ["transfer": transfer]) }
    }
    func download(_ entry: PhoneFile, to destination: URL) async {
        guard let transport, transferProgress == nil else { return }
        transferProgress = 0; transferLabel = "正在下载 " + entry.name
        defer { transferProgress = nil }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".macroid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw WireError.remote("无法创建本地文件") }
            let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
            var offset: Int64 = 0
            while offset < entry.size {
                try Task.checkCancellation()
                let result = try await transport.request("files.read", ["path": entry.path, "offset": offset, "count": 196608])
                guard let encoded = result["data"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty,
                      (result["size"] as? NSNumber)?.int64Value == entry.size,
                      (result["offset"] as? NSNumber)?.int64Value == offset,
                      offset + Int64(data.count) <= entry.size else { throw WireError.remote("手机文件在下载期间发生变化") }
                try handle.write(contentsOf: data); offset += Int64(data.count); transferProgress = Double(offset) / Double(max(1, entry.size))
            }
            try Task.checkCancellation(); try handle.synchronize(); try handle.close()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
