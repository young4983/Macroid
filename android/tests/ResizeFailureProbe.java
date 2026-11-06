package io.macroid.bridge;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import org.json.JSONObject;
import java.io.*;
import java.util.concurrent.atomic.AtomicInteger;

/** Separate test dex, never packaged in either APK. Uses real codecs/displays with injected creation failures. */
public final class ResizeFailureProbe {
    private static void require(boolean value, String reason) { if (!value) throw new AssertionError(reason); }
    private static void picture(VideoSession session) throws Exception {
        long end = System.currentTimeMillis() + 15000;
        while (!session.isActive() && session.isOpen() && System.currentTimeMillis() < end) Thread.sleep(30);
        require(session.isActive(), "No picture after recovery");
    }
    public static void main(String[] args) {
        VideoSession session = null;
        HandlerThread handler = new HandlerThread("resize-failure-test");
        int status = 1;
        try {
            Looper.prepareMainLooper(); handler.start();
            ShellPlatform platform = new ShellPlatform();
            AtomicInteger creations = new AtomicInteger();
            ByteArrayOutputStream received = new ByteArrayOutputStream();
            Wire wire = new Wire(new ByteArrayInputStream(new byte[0]), received);
            JSONObject request = new JSONObject().put("mode", "fusion").put("package", "io.macroid.fixture")
                    .put("width", 630).put("height", 1080).put("density", 240).put("configEvents", true);
            session = new VideoSession(90, request, platform, wire, new Handler(handler.getLooper()), (w, h, options) -> {
                int attempt = creations.incrementAndGet();
                if (attempt == 2 || attempt >= 4) throw new IOException("injected codec allocation failure");
                return VideoSession.configure(w, h, options);
            });
            session.start(); picture(session);
            int display = session.displayId, width = session.width, height = session.height;
            JSONObject resize = new JSONObject().put("width", 1440).put("height", 960).put("density", 240);
            JSONObject restored = session.resize(resize); picture(session);
            require(restored.getBoolean("restored"), "Missing recovery result");
            require(session.displayId == display && session.width == width && session.height == height, "Recovery changed display identity or geometry");
            require(session.generation() == 2, "Recovery omitted generation boundary");
            try { session.resize(resize); throw new AssertionError("Expected fatal recovery failure"); }
            catch (IOException expected) { }
            require(!session.isOpen(), "Fatal recovery failure left session open");
            long deadline = System.currentTimeMillis() + 5000;
            while (platform.displays.getDisplay(display) != null && System.currentTimeMillis() < deadline) Thread.sleep(30);
            require(platform.displays.getDisplay(display) == null, "Fatal recovery failure leaked display");
            Wire reader = new Wire(new ByteArrayInputStream(received.toByteArray()), new ByteArrayOutputStream());
            int configCount = 0; boolean error = false;
            try {
                while (true) {
                    Wire.Packet packet = reader.read();
                    if (packet.kind() != Wire.JSON) continue;
                    JSONObject event = new JSONObject(new String(packet.payload(), java.nio.charset.StandardCharsets.UTF_8));
                    if ("stream.config".equals(event.optString("event"))) configCount++;
                    if ("stream.error".equals(event.optString("event"))) error = true;
                }
            } catch (EOFException expected) { }
            require(configCount == 2 && error, "Wrong configuration/error sequence");
            System.out.println("RESIZE_FAILURE_TEST_PASSED restore=true sameDisplay=true frames=true fatalCleanup=true");
            status = 0;
        } catch (Throwable error) { error.printStackTrace(); }
        finally { if (session != null) session.close(); handler.quitSafely(); System.exit(status); }
    }
}
