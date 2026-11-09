import AppKit
import AVFoundation
import CoreMedia

@MainActor final class VideoRenderer: ObservableObject {
    let container = CALayer()
    private(set) var layer = AVSampleBufferDisplayLayer()
    private var previous: AVSampleBufferDisplayLayer?
    private var displayTask: Task<Void, Never>?
    private var revision = 0
    private(set) var currentFrameReady = false
    var onFirstFrame: (() -> Void)?
    @Published var hasFrame = false
    private(set) var frameCount = 0
    @Published var error: String?
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true

    init() { configureLayer(layer); container.addSublayer(layer) }
    private func configureLayer(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect; layer.backgroundColor = NSColor.black.cgColor
    }
    func layout(in bounds: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.frame = bounds; layer.frame = container.bounds; previous?.frame = container.bounds
        CATransaction.commit()
    }
    func beginConfiguration() {
        revision += 1; displayTask?.cancel(); displayTask = nil
        if currentFrameReady {
            previous?.removeFromSuperlayer(); previous?.flushAndRemoveImage()
            previous = layer; previous?.removeAllAnimations(); previous?.opacity = 1
        } else { layer.removeFromSuperlayer(); layer.flushAndRemoveImage() }
        layer = AVSampleBufferDisplayLayer(); configureLayer(layer)
        layer.frame = container.bounds; layer.opacity = previous == nil ? 1 : 0
        container.addSublayer(layer)
        format = nil; sps = nil; pps = nil; waitingForKey = true; currentFrameReady = false; error = nil
    }
    private func awaitVisibleFrame() {
        guard !currentFrameReady, displayTask == nil else { return }
        let expected = revision
        displayTask = Task { [weak self] in
            for _ in 0..<750 {
                guard !Task.isCancelled, let self, self.revision == expected else { return }
                if self.layer.status == .failed {
                    self.error = self.layer.error?.localizedDescription ?? "视频解码失败"; self.displayTask = nil; return
                }
                let visible: Bool
                if #available(macOS 14.4, *) { visible = self.layer.isReadyForDisplay }
                else { visible = self.layer.status == .rendering }
                if visible {
                    self.currentFrameReady = true; self.hasFrame = true
                    self.layer.opacity = 1
                    let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                    if self.previous != nil && duration > 0 {
                        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.duration = duration
                        self.layer.add(fade, forKey: "resizeFade")
                    }
                    self.onFirstFrame?()
                    if duration > 0 { try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
                    guard !Task.isCancelled, self.revision == expected else { return }
                    self.previous?.removeFromSuperlayer(); self.previous?.flushAndRemoveImage(); self.previous = nil
                    self.displayTask = nil; return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let self, !Task.isCancelled, self.revision == expected else { return }
            self.error = "等待新尺寸画面超时，请重新连接画面"; self.displayTask = nil
        }
    }
    func consume(_ packet: WirePacket) {
        guard packet.payload.count > 8 else { return }
        let units = NALUnit.split(Data(packet.payload.dropFirst(8)))
        for unit in units {
            guard let byte = unit.first else { continue }
            if byte & 31 == 7, unit != sps { sps = unit; format = nil }
            if byte & 31 == 8, unit != pps { pps = unit; format = nil }
        }
        if format == nil, let sps, let pps {
            sps.withUnsafeBytes { s in
                pps.withUnsafeBytes { p in
                    let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                    if status != noErr { error = "视频格式无效：\(status)" }
                }
            }
        }
        guard let format else { return }
        let picture = units.filter { unit in
            guard let byte = unit.first else { return false }; return ![7, 8, 9].contains(Int(byte & 31))
        }
        guard !picture.isEmpty, packet.flags & 1 == 0 else { return }
        if waitingForKey { guard packet.flags & 2 != 0 else { return }; waitingForKey = false }
        var avcc = Data()
        for unit in picture { avcc.appendBE(UInt32(unit.count)); avcc.append(unit) }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        let copyStatus = avcc.withUnsafeBytes { bytes in CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copyStatus == noErr else { return }
        var sample: CMSampleBuffer?, size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                    sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush(); waitingForKey = true; error = layer.error?.localizedDescription; return }
        layer.enqueue(sample); frameCount += 1
        awaitVisibleFrame()
    }
    func reset() {
        revision += 1; displayTask?.cancel(); displayTask = nil
        previous?.removeFromSuperlayer(); previous?.flushAndRemoveImage(); previous = nil
        layer.flushAndRemoveImage(); layer.removeAllAnimations(); layer.opacity = 1
        hasFrame = false; currentFrameReady = false; frameCount = 0; error = nil
        format = nil; sps = nil; pps = nil; waitingForKey = true
    }
}
