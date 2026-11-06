package io.macroid.bridge;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.view.MotionEvent;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/** Entry point: CLASSPATH=<installed APK> app_process / io.macroid.bridge.AgentMain <socket> <token>. */
public final class AgentMain {
    private final ShellPlatform platform;
    private final Wire wire;
    private final Handler handler;
    private final Map<Integer, VideoSession> sessions = new ConcurrentHashMap<>();
    private final File sharedRoot = new File("/sdcard").getCanonicalFile();
    private String previousIME;
    private boolean imePreviouslyEnabled;
    private final Map<String, Upload> uploads = new HashMap<>();
    private record Upload(File temporary, File destination, RandomAccessFile handle, long size) {}

    private AgentMain(ShellPlatform platform, Wire wire, Handler handler) throws Exception { this.platform = platform; this.wire = wire; this.handler = handler; }

    public static void main(String[] args) throws Exception {
        if (args.length != 2 || !args[0].matches("macroid_[a-zA-Z0-9_]+") || args[1].length() < 32) throw new IllegalArgumentException("Invalid launch arguments");
        if (android.os.Process.myUid() != 2000 && android.os.Process.myUid() != 0) throw new SecurityException("Start Macroid through ADB shell");
        Looper.prepareMainLooper();
        ShellPlatform platform = new ShellPlatform();
        HandlerThread callbacks = new HandlerThread("Macroid-display"); callbacks.start();
        try (LocalServerSocket server = new LocalServerSocket(args[0])) {
            Thread expiry = new Thread(() -> { try { Thread.sleep(60000); server.close(); } catch (Exception ignored) { } }, "Macroid-accept-expiry");
            expiry.setDaemon(true); expiry.start();
            System.out.println("MACROID_READY " + args[0]); System.out.flush();
            try (LocalSocket socket = server.accept(); Wire wire = new Wire(socket.getInputStream(), socket.getOutputStream())) {
                socket.setSoTimeout(10000);
                Wire.Packet packet = wire.read();
                if (packet.kind() != Wire.JSON || packet.stream() != 0) throw new SecurityException("Expected hello");
                JSONObject hello = new JSONObject(new String(packet.payload(), StandardCharsets.UTF_8));
                if (!"hello".equals(hello.optString("op")) || !MessageDigest.isEqual(args[1].getBytes(StandardCharsets.UTF_8), hello.optString("token").getBytes(StandardCharsets.UTF_8))) throw new SecurityException("Authentication failed");
                socket.setSoTimeout(0);
                AgentMain agent = new AgentMain(platform, wire, new Handler(callbacks.getLooper()));
                try {
                    agent.reply(hello, agent.deviceInfo()); agent.loop();
                } finally { agent.shutdown(); }
            }
        } catch (EOFException ignored) {
            // Closing the transport is a normal session shutdown.
        } catch (Throwable error) {
            error.printStackTrace(System.err);
        } finally {
            callbacks.quitSafely();
            // Binder pools started by the framework would otherwise keep app_process alive.
            System.exit(0);
        }
    }

    private JSONObject deviceInfo() throws Exception {
        return new JSONObject().put("product", "Macroid").put("protocol", 1).put("version", "0.2.0")
                .put("sdk", Build.VERSION.SDK_INT).put("model", Build.MODEL).put("manufacturer", Build.MANUFACTURER)
                .put("capabilities", new JSONObject().put("fusion", true).put("mirror", true).put("ownFocus", platform.ownFocusAllowed())
                        .put("unicodeIME", true).put("files", true).put("audio", false).put("virtualCamera", false).put("maxStreams", 4));
    }
    private void loop() throws Exception {
        while (true) {
            Wire.Packet packet = wire.read();
            if (packet.kind() != Wire.JSON || packet.stream() != 0) throw new IOException("Expected control frame");
            JSONObject request = new JSONObject(new String(packet.payload(), StandardCharsets.UTF_8));
            try { JSONObject result = dispatch(request); if (result != null) reply(request, result); }
            catch (Exception e) {
                e.printStackTrace(System.err);
                Throwable cause = e;
                while (cause instanceof java.lang.reflect.InvocationTargetException && cause.getCause() != null) cause = cause.getCause();
                wire.json(new JSONObject().put("id", request.optLong("id")).put("ok", false).put("error", cause.getMessage() == null ? cause.toString() : cause.getMessage()));
            }
        }
    }
    private void reply(JSONObject request, JSONObject result) throws Exception {
        if (request.optLong("id") != 0) wire.json(new JSONObject().put("id", request.getLong("id")).put("ok", true).put("result", result));
    }
    private JSONObject dispatch(JSONObject request) throws Exception {
        switch (request.getString("op")) {
            case "ping": return new JSONObject().put("time", System.currentTimeMillis());
            case "device.info": return deviceInfo();
            case "apps.launch": { platform.launch(request.getString("package"), 0); return new JSONObject(); }
            case "apps.list": return apps();
            case "apps.icon": return icon(request.getString("package"));
            case "stream.open": {
                int id = request.getInt("stream");
                if (id < 1 || id > 65535 || sessions.containsKey(id)) throw new IOException("Invalid or duplicate stream id");
                if (sessions.size() >= 4) throw new IOException("最多同时打开四个窗口");
                VideoSession session = new VideoSession(id, request, platform, wire, handler);
                sessions.put(id, session);
                // Send metadata before the first codec frame; clients can set up the decoder first.
                reply(request, session.info()); session.start(); return null;
            }
            case "stream.close": { VideoSession session = sessions.remove(request.getInt("stream")); if (session != null) session.close(); return new JSONObject(); }
            case "stream.sync": { session(request).syncFrame(); return new JSONObject(); }
            case "input.pointer": {
                VideoSession session = session(request);
                float x = (float) request.getDouble("x"), y = (float) request.getDouble("y");
                if (!Float.isFinite(x) || !Float.isFinite(y)) throw new IOException("Invalid coordinates");
                x = Math.max(0, Math.min(session.width - 1, x)); y = Math.max(0, Math.min(session.height - 1, y));
                if (!session.fusion) {
                    DisplayMetrics metrics = new DisplayMetrics(); platform.displays.getDisplay(0).getRealMetrics(metrics);
                    x *= metrics.widthPixels / (float)session.width; y *= metrics.heightPixels / (float)session.height;
                }
                int action = request.getInt("action");
                if (action != 0 && action != 1 && action != 2 && action != 3 && action != 8) throw new IOException("Invalid pointer action");
                platform.pointer(session.displayId, action, x, y, (float)request.optDouble("scrollX"), (float)request.optDouble("scrollY"));
                return new JSONObject();
            }
            case "input.key": { platform.key(session(request).displayId, request.getInt("code"), request.optInt("meta")); return new JSONObject(); }
            case "input.text": {
                session(request); String text = request.getString("text");
                if (text.length() > 65536) throw new IOException("Text too long");
                if (previousIME == null) {
                    if (!text.matches("[\\x20-\\x7e]*")) throw new IOException("请先在窗口工具栏启用 Macroid 键盘以输入中文");
                    platform.asciiText(session(request).displayId, text);
                    return new JSONObject();
                }
                String result = broadcast("text", text);
                if (!result.contains("result=1")) throw new IOException("输入框未连接 Macroid 键盘，请先点击输入框");
                return new JSONObject();
            }
            case "ime.enable": { enableIME(); return new JSONObject().put("enabled", true); }
            case "ime.disable": { restoreIME(); return new JSONObject().put("enabled", false); }
            case "clipboard.set": { broadcast("clipboard", request.getString("text")); return new JSONObject(); }
            case "clipboard.get": {
                ClipboardManager manager = platform.clipboard(handler);
                ClipData clip = manager.getPrimaryClip(); String text = clip == null || clip.getItemCount() == 0 ? "" : clip.getItemAt(0).coerceToText(platform.context).toString();
                if (text.length() > 65536) text = text.substring(0, 65536);
                return new JSONObject().put("text", text);
            }
            case "files.list": return list(request.optString("path", "/sdcard"));
            case "files.read": return readFile(request);
            case "files.upload.begin": return beginUpload(request);
            case "files.upload.chunk": return uploadChunk(request);
            case "files.upload.finish": return finishUpload(request);
            case "files.upload.cancel": { discardUpload(request.getString("transfer")); return new JSONObject(); }
            default: throw new IOException("Unknown operation");
        }
    }
    private VideoSession session(JSONObject request) throws Exception {
        VideoSession session = sessions.get(request.getInt("stream"));
        if (session == null) throw new IOException("Window is closed"); return session;
    }
    private JSONObject apps() throws Exception {
        Intent intent = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> results = platform.context.getPackageManager().queryIntentActivities(intent, 0);
        Map<String, String> unique = new TreeMap<>();
        for (ResolveInfo info : results) unique.putIfAbsent(info.activityInfo.packageName, info.loadLabel(platform.context.getPackageManager()).toString());
        JSONArray apps = new JSONArray();
        for (Map.Entry<String, String> entry : unique.entrySet()) apps.put(new JSONObject().put("package", entry.getKey()).put("name", entry.getValue()));
        return new JSONObject().put("apps", apps);
    }
    private JSONObject icon(String packageName) throws Exception {
        Drawable drawable = platform.context.getPackageManager().getApplicationIcon(packageName);
        Bitmap bitmap = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888);
        drawable.setBounds(0, 0, 96, 96); drawable.draw(new Canvas(bitmap));
        ByteArrayOutputStream out = new ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, out); bitmap.recycle();
        return new JSONObject().put("png", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
    }
    private String broadcast(String command, String text) throws Exception {
        if (text.length() > 65536) throw new IOException("Text too long");
        return ShellPlatform.command("am", "broadcast", "--user", "current", "-n", "io.macroid.bridge/.CommandReceiver", "--es", "command", command, "--es", "text", text);
    }
    private void enableIME() throws Exception {
        if (previousIME != null) return;
        String previous = ShellPlatform.command("settings", "get", "secure", "default_input_method").trim();
        if (previous.isEmpty() || previous.equals("null")) throw new IOException("无法读取原输入法，未更改系统设置");
        String id = "io.macroid.bridge/.MacroidIME";
        imePreviouslyEnabled = Arrays.asList(ShellPlatform.command("ime", "list", "-s").split("\\s+")).contains(id);
        previousIME = previous;
        try { ShellPlatform.command("ime", "enable", id); ShellPlatform.command("ime", "set", id); }
        catch (Exception e) { restoreIME(); throw e; }
    }
    private void restoreIME() {
        if (previousIME == null) return;
        String id = "io.macroid.bridge/.MacroidIME";
        try {
            // Respect a keyboard the user selected themselves while Macroid was connected.
            if (ShellPlatform.command("settings", "get", "secure", "default_input_method").trim().equals(id)) ShellPlatform.command("ime", "set", previousIME);
            if (!imePreviouslyEnabled) ShellPlatform.command("ime", "disable", id);
        } catch (Exception e) { System.err.println("Restore keyboard: " + e); }
        previousIME = null;
    }
    private File sharedPath(String path) throws Exception {
        File file = new File(path).getCanonicalFile();
        if (!file.equals(sharedRoot) && !file.toPath().startsWith(sharedRoot.toPath())) throw new IOException("Only shared storage is accessible");
        return file;
    }
    private JSONObject list(String path) throws Exception {
        File directory = sharedPath(path); File[] files = directory.listFiles();
        if (files == null) throw new IOException("无法读取目录");
        Arrays.sort(files, Comparator.comparing((File f) -> !f.isDirectory()).thenComparing(File::getName, String.CASE_INSENSITIVE_ORDER));
        JSONArray entries = new JSONArray();
        for (File file : files) {
            if (file.getName().startsWith(".macroid-upload-")) continue;
            if (entries.length() == 5000) break;
            entries.put(new JSONObject().put("name", file.getName()).put("path", file.getPath()).put("directory", file.isDirectory())
                    .put("size", file.length()).put("modified", file.lastModified()));
        }
        return new JSONObject().put("path", directory.getPath()).put("entries", entries);
    }
    private JSONObject readFile(JSONObject request) throws Exception {
        File file = sharedPath(request.getString("path"));
        long offset = request.getLong("offset"); int count = Math.max(1, Math.min(request.optInt("count", 196608), 196608));
        if (!file.isFile() || offset < 0 || offset > file.length()) throw new IOException("Invalid file or offset");
        try (RandomAccessFile handle = new RandomAccessFile(file, "r")) {
            handle.seek(offset); byte[] data = new byte[(int)Math.min(count, file.length() - offset)]; handle.readFully(data);
            return new JSONObject().put("data", Base64.encodeToString(data, Base64.NO_WRAP)).put("size", file.length()).put("offset", offset);
        }
    }
    private JSONObject beginUpload(JSONObject request) throws Exception {
        if (uploads.size() >= 4) throw new IOException("Too many transfers");
        File destination = sharedPath(request.getString("path"));
        if (destination.exists()) throw new IOException("目标文件已存在，请先重命名本地文件");
        long size = request.getLong("size"); if (size < 0 || size > 64L * 1024 * 1024 * 1024) throw new IOException("Invalid file size");
        String id = UUID.randomUUID().toString();
        File temporary = new File(destination.getParentFile(), ".macroid-upload-" + id);
        RandomAccessFile handle = new RandomAccessFile(temporary, "rw");
        uploads.put(id, new Upload(temporary, destination, handle, size)); return new JSONObject().put("transfer", id);
    }
    private JSONObject uploadChunk(JSONObject request) throws Exception {
        Upload upload = uploads.get(request.getString("transfer")); if (upload == null) throw new IOException("Unknown transfer");
        byte[] data = Base64.decode(request.getString("data"), Base64.DEFAULT);
        if (data.length > 196608 || request.getLong("offset") != upload.handle.getFilePointer() || upload.handle.getFilePointer() + data.length > upload.size) throw new IOException("Invalid upload chunk");
        upload.handle.write(data); return new JSONObject().put("offset", upload.handle.getFilePointer());
    }
    private JSONObject finishUpload(JSONObject request) throws Exception {
        String id = request.getString("transfer"); Upload upload = uploads.get(id);
        if (upload == null || upload.handle.length() != upload.size) throw new IOException("Incomplete transfer");
        // Re-check canonical paths and destination immediately before committing.
        sharedPath(upload.destination.getPath()); sharedPath(upload.temporary.getPath());
        if (upload.destination.exists()) throw new IOException("目标文件已存在");
        upload.handle.getFD().sync(); upload.handle.close();
        if (!upload.temporary.renameTo(upload.destination)) throw new IOException("Cannot commit upload");
        uploads.remove(id); return new JSONObject();
    }
    private void discardUpload(String id) {
        Upload upload = uploads.remove(id); if (upload != null) { try { upload.handle.close(); } catch (IOException ignored) { } upload.temporary.delete(); }
    }
    private void shutdown() {
        for (VideoSession session : sessions.values()) session.close(); sessions.clear(); restoreIME();
        for (String id : new ArrayList<>(uploads.keySet())) discardUpload(id);
    }
}
