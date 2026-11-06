import AppKit
import AVFoundation
import CoreMedia

@MainActor final class VideoRenderer: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published var hasFrame = false
    private(set) var frameCount = 0
    @Published var error: String?
    private var sps: Data?, pps: Data?
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true

    init() { layer.videoGravity = .resizeAspect; layer.backgroundColor = NSColor.black.cgColor }
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
                    if status != noErr { error = "视频格式无效（\(status)）" }
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
        if !hasFrame { hasFrame = true }
    }
    func reset() { layer.flushAndRemoveImage(); hasFrame = false; frameCount = 0; error = nil; format = nil; sps = nil; pps = nil; waitingForKey = true }
}
