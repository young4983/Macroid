package io.macroid.bridge;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaCodecList;
import android.os.SystemClock;
import java.io.IOException;
import java.util.*;
import android.os.Handler;
import android.util.DisplayMetrics;
import android.view.Display;
import android.view.Surface;
import org.json.JSONObject;
import java.io.Closeable;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicBoolean;

final class VideoSession implements Closeable {
    final int id, width, height, density, displayId;
    final boolean fusion;
    private final String encoderName;
    private final int fps;
    private final Wire wire;
    private final MediaCodec encoder;
    private final Surface surface;
    private final ShellPlatform.DisplayHandle display;
    private final AtomicBoolean running = new AtomicBoolean(true);
    private Thread worker;

    VideoSession(int id, JSONObject request, ShellPlatform platform, Wire wire, Handler handler) throws Exception {
        this.id = id; this.wire = wire;
        fusion = !"mirror".equals(request.optString("mode", "fusion"));
        int w = bounded(request.optInt("width", 720), 320, 2560), h = bounded(request.optInt("height", 1280), 320, 2560);
        int dpi = bounded(request.optInt("density", 240), 120, 640);
        if (!fusion) {
            DisplayMetrics metrics = new DisplayMetrics(); platform.displays.getDisplay(0).getRealMetrics(metrics);
            float scale = Math.min(1f, 1920f / Math.max(metrics.widthPixels, metrics.heightPixels));
            w = Math.max(2, ((int)(metrics.widthPixels * scale)) & ~1);
            h = Math.max(2, ((int)(metrics.heightPixels * scale)) & ~1); dpi = metrics.densityDpi;
        }
        density = dpi;
        Configured configured = configure(w, h, request);
        encoder = configured.codec; surface = configured.surface;
        width = configured.width; height = configured.height;
        encoderName = configured.name; fps = configured.fps;
        ShellPlatform.DisplayHandle createdDisplay = null;
        try {
            createdDisplay = platform.createDisplay("Macroid " + id, width, height, density, surface, fusion, handler);
            displayId = createdDisplay.id;
            if (fusion) platform.launch(request.getString("package"), displayId);
        } catch (Exception | LinkageError e) {
            if (createdDisplay != null) createdDisplay.release();
            try { encoder.stop(); } catch (Exception ignored) { }
            encoder.release(); surface.release(); throw e;
        }
        display = createdDisplay;
    }

    private record Configured(MediaCodec codec, Surface surface, String name, int width, int height, int fps) {}

    private static Configured configure(int requestedWidth, int requestedHeight, JSONObject request) throws IOException {
        List<MediaCodecInfo> codecs = new ArrayList<>();
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
            if (!info.isEncoder() || info.isAlias()) continue;
            for (String type : info.getSupportedTypes()) if (MediaFormat.MIMETYPE_VIDEO_AVC.equalsIgnoreCase(type)) { codecs.add(info); break; }
        }
        codecs.sort(Comparator.comparing(MediaCodecInfo::isSoftwareOnly));
        StringBuilder failures = new StringBuilder();
        for (MediaCodecInfo info : codecs) {
            MediaCodecInfo.CodecCapabilities caps;
            try { caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC); }
            catch (RuntimeException error) { continue; }
            boolean surfaceSupported = false;
            for (int color : caps.colorFormats) if (color == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface) surfaceSupported = true;
            if (!surfaceSupported) continue;
            MediaCodecInfo.VideoCapabilities video = caps.getVideoCapabilities();
            Set<String> tried = new HashSet<>();
            int[] edges = info.isSoftwareOnly() ? new int[]{960, 720} : new int[]{1920, 1920, 1280};
            for (int attempt = 0; attempt < edges.length; attempt++) {
                int targetFPS = info.isSoftwareOnly() ? 24 : (attempt == 0 ? bounded(request.optInt("fps", 60), 15, 60) : 30);
                double scale = Math.min(1d, Math.min((double)edges[attempt] / Math.max(requestedWidth, requestedHeight),
                        Math.min((double)video.getSupportedWidths().getUpper() / requestedWidth, (double)video.getSupportedHeights().getUpper() / requestedHeight)));
                int w = align((int)(requestedWidth * scale), video.getWidthAlignment());
                int h = align((int)(requestedHeight * scale), video.getHeightAlignment());
                if (!video.isSizeSupported(w, h)) continue;
                targetFPS = Math.max(1, Math.min(targetFPS, (int)Math.floor(video.getSupportedFrameRatesFor(w, h).getUpper())));
                if (!tried.add(w + "x" + h + "@" + targetFPS)) continue;
                int bitrate = video.getBitrateRange().clamp(bounded(request.optInt("bitrate", 6000000), 500000, 24000000));
                MediaCodec codec = null; Surface surface = null;
                String label = info.getName() + " " + w + "x" + h + "@" + targetFPS;
                try {
                    MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h);
                    format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
                    format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
                    format.setInteger(MediaFormat.KEY_FRAME_RATE, targetFPS);
                    format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
                    format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0);
                    // Let the encoder choose its supported AVC profile. Forcing Baseline fails on some Qualcomm/Oplus codecs.
                    if (attempt == 0) format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1000000L / targetFPS);
                    System.err.println("Macroid encoder attempt: " + label + " " + format);
                    codec = MediaCodec.createByCodecName(info.getName());
                    codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
                    surface = codec.createInputSurface(); codec.start();
                    System.err.println("Macroid encoder ready: " + label);
                    return new Configured(codec, surface, info.getName(), w, h, targetFPS);
                } catch (Exception error) {
                    String detail = error instanceof MediaCodec.CodecException ? ((MediaCodec.CodecException)error).getDiagnosticInfo() : error.toString();
                    System.err.println("Macroid encoder rejected: " + label + " " + detail);
                    failures.append(label).append(": ").append(detail).append("\n");
                    if (codec != null) { try { codec.stop(); } catch (Exception ignored) {} codec.release(); }
                    if (surface != null) surface.release();
                }
            }
        }
        throw new IOException("手机 H.264 编码器启动失败，已尝试兼容参数和备用编码器。请关闭其他投屏后重试。\n" + failures);
    }
    private static int align(int value, int alignment) { return value / alignment * alignment; }

    JSONObject info() throws Exception {
        return new JSONObject().put("stream", id).put("display", displayId).put("width", width)
                .put("height", height).put("density", density).put("encoder", encoderName).put("fps", fps).put("codec", "h264").put("mode", fusion ? "fusion" : "mirror");
    }
    void start() {
        worker = new Thread(this::encode, "Macroid-video-" + id); worker.start();
    }
    private void encode() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        long started = SystemClock.elapsedRealtime();
        boolean hasPicture = false;
        try {
            while (running.get()) {
                int index = encoder.dequeueOutputBuffer(info, 10000);
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat output = encoder.getOutputFormat();
                    for (String key : new String[]{"csd-0", "csd-1"}) {
                        ByteBuffer csd = output.getByteBuffer(key);
                        if (csd != null && csd.hasRemaining()) send(csd.duplicate(), 0, 1);
                    }
                }
                if (index < 0) {
                    if (!hasPicture && SystemClock.elapsedRealtime() - started > 12000) throw new IOException("编码器已启动，但未产生画面。请解锁手机并重试投屏。");
                    continue;
                }
                try {
                    if (info.size == 0) continue;
                    ByteBuffer source = encoder.getOutputBuffer(index).duplicate();
                    source.position(info.offset); source.limit(info.offset + info.size);
                    int flags = ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 ? 1 : 0)
                            | ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ? 2 : 0);
                    send(source, info.presentationTimeUs, flags);
                    if ((flags & 1) == 0) hasPicture = true;
                } finally { encoder.releaseOutputBuffer(index, false); }
            }
        } catch (Exception e) {
            if (running.get()) try { wire.json(new JSONObject().put("event", "stream.error").put("stream", id).put("message", e.toString())); } catch (Exception ignored) { }
        } finally {
            running.set(false); display.release();
            try { encoder.stop(); } catch (Exception ignored) { }
            encoder.release(); surface.release();
        }
    }
    private void send(ByteBuffer source, long pts, int flags) throws IOException {
        byte[] packet = new byte[8 + source.remaining()];
        ByteBuffer target = ByteBuffer.wrap(packet); target.putLong(pts); target.put(source);
        wire.send(Wire.VIDEO, flags, id, packet);
    }
    void syncFrame() { android.os.Bundle bundle = new android.os.Bundle(); bundle.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0); encoder.setParameters(bundle); }
    @Override public void close() {
        running.set(false);
        if (worker != null && worker != Thread.currentThread()) try { worker.join(3000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        // The encoder thread owns codec/display cleanup, including failure paths.
        if (worker == null) { display.release(); try { encoder.stop(); } catch (Exception ignored) { } encoder.release(); surface.release(); }
    }
    private static int bounded(int value, int min, int max) { return Math.max(min, Math.min(value, max)); }
}
