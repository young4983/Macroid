package io.macroid.bridge;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaCodecList;
import android.os.SystemClock;
import android.os.Handler;
import android.view.Surface;
import org.json.JSONObject;
import java.io.Closeable;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** The control thread owns the display; each encoder generation owns only its codec resources. */
final class VideoSession implements Closeable {
    final int id, displayId;
    volatile int width, height, density;
    final boolean fusion;
    private final Wire wire;
    private final ShellPlatform platform;
    private final Handler handler;
    private ShellPlatform.ScreenInfo mirrorSource;
    interface EncoderFactory { Configured create(int width, int height, JSONObject options) throws IOException; }
    private final EncoderFactory encoderFactory;
    private ShellPlatform.DisplayHandle display;
    private final JSONObject options;
    private final boolean configEvents;
    private final AtomicBoolean closed = new AtomicBoolean();
    private Run run;
    private int generation = 1;

    static final class Configured {
        final MediaCodec codec;
        final Surface surface;
        final String name;
        final int width, height, fps;
        private final AtomicBoolean released = new AtomicBoolean();
        Configured(MediaCodec codec, Surface surface, String name, int width, int height, int fps) {
            this.codec = codec; this.surface = surface; this.name = name;
            this.width = width; this.height = height; this.fps = fps;
        }
        void release() {
            if (!released.compareAndSet(false, true)) return;
            try { codec.stop(); } catch (Exception ignored) { }
            try { codec.release(); } finally { surface.release(); }
        }
    }
    private static final class Run {
        final Configured config;
        final AtomicBoolean running = new AtomicBoolean(true);
        volatile boolean hasPicture;
        Thread worker;
        Run(Configured config) { this.config = config; }
    }

    VideoSession(int id, JSONObject request, ShellPlatform platform, Wire wire, Handler handler) throws Exception {
        this(id, request, platform, wire, handler, VideoSession::configure);
    }
    // Package-local injection supports real-device failure/recovery tests without a wire backdoor.
    VideoSession(int id, JSONObject request, ShellPlatform platform, Wire wire, Handler handler, EncoderFactory encoderFactory) throws Exception {
        this.encoderFactory = encoderFactory;
        this.id = id; this.wire = wire; this.platform = platform; this.handler = handler; options = new JSONObject(request.toString());
        fusion = !"mirror".equals(request.optString("mode", "fusion"));
        configEvents = request.optBoolean("configEvents", false);
        int w = bounded(request.optInt("width", 720), 320, 8192), h = bounded(request.optInt("height", 1280), 320, 8192);
        int dpi = bounded(request.optInt("density", 240), 40, 640);
        if (!fusion) {
            mirrorSource = platform.screenInfo();
            double scale = Math.min(1d, 1920d / Math.max(mirrorSource.width, mirrorSource.height));
            w = Math.max(2, ((int)(mirrorSource.width * scale)) & ~1);
            h = Math.max(2, ((int)(mirrorSource.height * scale)) & ~1); dpi = mirrorSource.density;
        }
        Configured config = encoderFactory.create(w, h, options);
        adopt(config, w, h, dpi);
        ShellPlatform.DisplayHandle created = null;
        try {
            created = platform.createDisplay("Macroid " + id, width, height, density, config.surface, fusion, handler);
            displayId = created.id;
            if (fusion) platform.launch(request.getString("package"), displayId);
        } catch (Exception | LinkageError e) {
            if (created != null) created.release(); config.release(); throw e;
        }
        display = created;
    }

    private void adopt(Configured config, int requestedWidth, int requestedHeight, int dpi) {
        run = new Run(config); width = config.width; height = config.height;
        // Preserve dp dimensions when the encoder falls back to a smaller pixel buffer.
        double scale = Math.min(width / (double)requestedWidth, height / (double)requestedHeight);
        density = fusion ? Math.max(1, (int)Math.round(dpi * scale)) : dpi;
    }

    static Configured configure(int requestedWidth, int requestedHeight, JSONObject request) throws IOException {
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
            int maxSize = bounded(request.optInt("maxSize", 1920), 720, 4096);
            int[] edges = info.isSoftwareOnly() ? new int[]{Math.min(maxSize, 960), Math.min(maxSize, 720)}
                    : new int[]{maxSize, maxSize, Math.min(maxSize, 1920), Math.min(maxSize, 1280)};
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
        Configured config = run.config;
        JSONObject result = new JSONObject().put("stream", id).put("display", displayId).put("width", width)
                .put("height", height).put("density", density).put("generation", generation)
                .put("encoder", config.name).put("fps", config.fps).put("codec", "h264")
                .put("mode", fusion ? "fusion" : "mirror");
        if (!fusion) result.put("rotation", mirrorSource.rotation).put("rotationLocked", platform.rotationLocked());
        return result;
    }
    int generation() { return generation; }
    boolean supportsRotation() { return !fusion && configEvents; }
    boolean isOpen() { return !closed.get(); }
    boolean isActive() { return !closed.get() && run.running.get() && run.hasPicture; }

    void start() throws Exception {
        if (closed.get()) throw new IOException("Window is closed");
        if (configEvents) wire.json(info().put("event", "stream.config"));
        Run current = run;
        current.worker = new Thread(() -> encode(current), "Macroid-video-" + id + "-" + generation);
        current.worker.start();
    }

    JSONObject resize(JSONObject request) throws Exception {
        if (!fusion || !configEvents) throw new IOException("This stream does not support resizing");
        if (closed.get()) throw new IOException("Window is closed");
        int w = request.getInt("width"), h = request.getInt("height"), dpi = request.getInt("density");
        if (w < 320 || h < 320 || w > 8192 || h > 8192 || dpi < 40 || dpi > 640) throw new IOException("Invalid display dimensions");
        int oldW = width, oldH = height, oldDpi = density;
        stopEncoder(); // Joining guarantees that no old packets can follow stream.config.
        generation++;
        try {
            replace(w, h, dpi);
        } catch (Exception failure) {
            try { replace(oldW, oldH, oldDpi); }
            catch (Exception recovery) {
                close();
                wire.json(new JSONObject().put("event", "stream.error").put("stream", id).put("message", "调整尺寸失败，恢复画面失败：" + recovery));
                throw new IOException("调整尺寸失败，请重新连接画面", failure);
            }
            start();
            return info().put("restored", true).put("warning", "无法使用请求尺寸，已恢复上一尺寸：" + failure.getMessage());
        }
        start();
        return info();
    }
    void refreshMirror() throws Exception {
        if (fusion || !configEvents || closed.get()) return;
        ShellPlatform.ScreenInfo latest = platform.screenInfo();
        if (latest.sameAs(mirrorSource)) return;
        platform.cancelGesture(displayId);
        double scale = Math.min(1d, 1920d / Math.max(latest.width, latest.height));
        int w = Math.max(2, ((int)(latest.width * scale)) & ~1);
        int h = Math.max(2, ((int)(latest.height * scale)) & ~1);
        stopEncoder();
        generation++;
        try {
            replace(w, h, latest.density);
            mirrorSource = latest;
            start();
        } catch (Exception failure) {
            close();
            wire.json(new JSONObject().put("event", "stream.error").put("stream", id).put("message", "旋转后无法恢复画面，请重新连接：" + failure));
            throw failure;
        }
    }
    private void replace(int w, int h, int dpi) throws Exception {
        Configured config = encoderFactory.create(w, h, options);
        try {
            adopt(config, w, h, dpi);
            if (!fusion && display.virtual != null) {
                // Android's mirror root may retain the abandoned encoder queue after repeated
                // setSurface calls. A capture display owns no app tasks, so recreate it safely.
                display.release();
                display = platform.createDisplay("Macroid " + id, width, height, density, config.surface, false, handler);
            } else { platform.updateDisplay(display, width, height, density, config.surface); }
        } catch (Exception e) { config.release(); run.running.set(false); throw e; }
    }
    private void stopEncoder() throws IOException {
        Run current = run;
        current.running.set(false);
        if (current.worker == null) { current.config.release(); return; }
        try { current.worker.join(3000); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); throw new IOException(e); }
        if (current.worker.isAlive()) throw new IOException("视频发送阻塞，请重新连接设备");
    }
    private void encode(Run current) {
        MediaCodec encoder = current.config.codec;
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        long started = SystemClock.elapsedRealtime();
        try {
            while (current.running.get()) {
                int index = encoder.dequeueOutputBuffer(info, 10000);
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat output = encoder.getOutputFormat();
                    for (String key : new String[]{"csd-0", "csd-1"}) {
                        ByteBuffer csd = output.getByteBuffer(key);
                        if (csd != null && csd.hasRemaining()) send(csd.duplicate(), 0, 1);
                    }
                }
                if (index < 0) {
                    if (!current.hasPicture && SystemClock.elapsedRealtime() - started > 12000) throw new IOException("编码器未产生画面，请解锁手机并重试");
                    continue;
                }
                try {
                    if (info.size == 0) continue;
                    ByteBuffer source = encoder.getOutputBuffer(index).duplicate();
                    source.position(info.offset); source.limit(info.offset + info.size);
                    int flags = ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 ? 1 : 0)
                            | ((info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 ? 2 : 0);
                    send(source, info.presentationTimeUs, flags);
                    if ((flags & 1) == 0) current.hasPicture = true;
                } finally { encoder.releaseOutputBuffer(index, false); }
            }
        } catch (Exception e) {
            if (current.running.getAndSet(false)) {
                if (closed.compareAndSet(false, true)) display.release();
                try { wire.json(new JSONObject().put("event", "stream.error").put("stream", id).put("message", e.toString())); } catch (Exception ignored) { }
            }
        } finally { current.running.set(false); current.config.release(); }
    }
    private void send(ByteBuffer source, long pts, int flags) throws IOException {
        byte[] packet = new byte[8 + source.remaining()];
        ByteBuffer target = ByteBuffer.wrap(packet); target.putLong(pts); target.put(source);
        wire.send(Wire.VIDEO, flags, id, packet);
    }
    void syncFrame() {
        if (!run.running.get()) return;
        android.os.Bundle bundle = new android.os.Bundle(); bundle.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
        run.config.codec.setParameters(bundle);
    }
    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        try { stopEncoder(); } catch (IOException e) { System.err.println(e); }
        finally { display.release(); }
    }
    private static int bounded(int value, int min, int max) { return Math.max(min, Math.min(value, max)); }
}
