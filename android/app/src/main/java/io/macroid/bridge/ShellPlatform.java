package io.macroid.bridge;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.AttributionSource;
import android.content.ClipboardManager;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.graphics.Rect;
import android.view.*;
import java.io.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** All hidden framework calls are confined here and executed as uid 2000, never the APK uid. */
// These calls run exclusively in app_process as shell, outside application hidden-API enforcement.
@SuppressLint({"PrivateApi", "DiscouragedPrivateApi", "BlockedPrivateApi", "WrongConstant"})
final class ShellPlatform {
    final Context context;
    final DisplayManager displays;
    private final Object input;
    private final Method inject, setDisplay;
    private long gestureStart;

    ShellPlatform() throws Exception {
        Class<?> thread = Class.forName("android.app.ActivityThread");
        Object activityThread = thread.getMethod("systemMain").invoke(null);
        Context system = (Context) thread.getMethod("getSystemContext").invoke(activityThread);
        Context shell = system.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY);
        context = new ContextWrapper(shell) {
            @Override public String getPackageName() { return "com.android.shell"; }
            @Override public String getOpPackageName() { return "com.android.shell"; }
            @Override public AttributionSource getAttributionSource() {
                return new AttributionSource.Builder(android.os.Process.myUid()).setPackageName("com.android.shell").build();
            }
            @Override public Context getApplicationContext() { return this; }
            @Override public int getDeviceId() { return 0; }
        };
        Constructor<DisplayManager> ctor = DisplayManager.class.getDeclaredConstructor(Context.class);
        ctor.setAccessible(true); displays = ctor.newInstance(context);
        Class<?> inputClass;
        try { inputClass = Class.forName("android.hardware.input.InputManagerGlobal"); }
        catch (ClassNotFoundException e) { inputClass = Class.forName("android.hardware.input.InputManager"); }
        input = inputClass.getDeclaredMethod("getInstance").invoke(null);
        inject = inputClass.getMethod("injectInputEvent", InputEvent.class, int.class);
        setDisplay = InputEvent.class.getDeclaredMethod("setDisplayId", int.class);
    }

    ClipboardManager clipboard(Handler handler) throws Exception {
        // A system-context cached service is attributed to package "android", not uid 2000.
        return ClipboardManager.class.getDeclaredConstructor(Context.class, Handler.class).newInstance(context, handler);
    }

    boolean trustedDisplayAllowed() {
        return Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission("android.permission.ADD_TRUSTED_DISPLAY") == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }
    boolean ownFocusAllowed() { return Build.VERSION.SDK_INT >= 34 && trustedDisplayAllowed(); }

    static final class DisplayHandle {
        final VirtualDisplay virtual;
        final IBinder token;
        final int id;
        DisplayHandle(VirtualDisplay display, boolean fusion) { virtual = display; token = null; id = fusion ? display.getDisplay().getDisplayId() : 0; }
        DisplayHandle(IBinder token) { virtual = null; this.token = token; id = 0; }
        void release() {
            if (virtual != null) virtual.release();
            if (token != null) try { Class.forName("android.view.SurfaceControl").getDeclaredMethod("destroyDisplay", IBinder.class).invoke(null, token); }
            catch (Exception e) { System.err.println("Release capture display: " + e); }
        }
    }

    private DisplayHandle legacyMirror(String name, int width, int height, Surface surface) throws Exception {
        Class<?> control = Class.forName("android.view.SurfaceControl");
        IBinder token = (IBinder) control.getDeclaredMethod("createDisplay", String.class, boolean.class).invoke(null, name, false);
        DisplayHandle handle = new DisplayHandle(token);
        try {
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics(); displays.getDisplay(0).getRealMetrics(metrics);
            control.getDeclaredMethod("openTransaction").invoke(null);
            try {
                control.getDeclaredMethod("setDisplaySurface", IBinder.class, Surface.class).invoke(null, token, surface);
                control.getDeclaredMethod("setDisplayProjection", IBinder.class, int.class, Rect.class, Rect.class)
                        .invoke(null, token, 0, new Rect(0, 0, metrics.widthPixels, metrics.heightPixels), new Rect(0, 0, width, height));
                control.getDeclaredMethod("setDisplayLayerStack", IBinder.class, int.class).invoke(null, token, 0);
            } finally { control.getDeclaredMethod("closeTransaction").invoke(null); }
            return handle;
        } catch (Exception e) { handle.release(); throw e; }
    }

    DisplayHandle createDisplay(String name, int width, int height, int density, Surface surface, boolean fusion, Handler handler) throws Exception {
        if (!fusion && Build.VERSION.SDK_INT < 34) return legacyMirror(name, width, height, surface);
        if (!fusion) {
            // Android 14+ exposes this hidden static method; older releases use the flag path.
            try {
                Method mirror = DisplayManager.class.getDeclaredMethod("createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class);
                return new DisplayHandle((VirtualDisplay) mirror.invoke(null, name, width, height, 0, surface), false);
            } catch (NoSuchMethodException ignored) { }
        }
        int flags = fusion ? (1 | 8 | (1 << 6) | (1 << 7) | (1 << 8)) : (1 | 16);
        // AOSP Android 12 does not grant ADD_TRUSTED_DISPLAY to shell; do not request it there.
        if (fusion && trustedDisplayAllowed()) {
            flags |= (1 << 10) | (1 << 11) | (1 << 13);
            if (context.checkSelfPermission("android.permission.ADD_ALWAYS_UNLOCKED_DISPLAY") == android.content.pm.PackageManager.PERMISSION_GRANTED) flags |= (1 << 12);
        }
        if (fusion && ownFocusAllowed()) flags |= (1 << 14);
        VirtualDisplay display;
        if (Build.VERSION.SDK_INT >= 34) {
            display = displays.createVirtualDisplay(new VirtualDisplayConfig.Builder(name, width, height, density)
                    .setFlags(flags).setSurface(surface).build(), handler, null);
        } else {
            display = displays.createVirtualDisplay(name, width, height, density, surface, flags, null, handler);
        }
        if (display == null) throw new IOException("Android did not create the display");
        if (fusion) {
            try {
                Object wm = Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null);
                wm.getClass().getMethod("setDisplayImePolicy", int.class, int.class).invoke(wm, display.getDisplay().getDisplayId(), 0);
            } catch (ReflectiveOperationException e) { System.err.println("Local IME policy unavailable: " + e); }
        }
        return new DisplayHandle(display, fusion);
    }

    void launch(String packageName, int display) throws Exception {
        if (!packageName.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+")) throw new IOException("Invalid package name");
        android.content.Intent intent = context.getPackageManager().getLaunchIntentForPackage(packageName);
        if (intent == null || intent.getComponent() == null) throw new IOException("No launchable activity: " + packageName);
        String output = command("am", "start", "--user", "current", "--display", Integer.toString(display), "-n", intent.getComponent().flattenToString());
        if (output.contains("Error:") || output.contains("Exception")) throw new IOException(output);
    }

    void pointer(int display, int action, float x, float y, float scrollX, float scrollY) throws Exception {
        long now = android.os.SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) gestureStart = now;
        MotionEvent.PointerProperties prop = new MotionEvent.PointerProperties(); prop.id = 0; prop.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords(); coords.x = x; coords.y = y;
        coords.pressure = action == MotionEvent.ACTION_UP ? 0 : 1;
        coords.setAxisValue(MotionEvent.AXIS_HSCROLL, scrollX); coords.setAxisValue(MotionEvent.AXIS_VSCROLL, scrollY);
        int source = action == MotionEvent.ACTION_SCROLL ? InputDevice.SOURCE_MOUSE : InputDevice.SOURCE_TOUCHSCREEN;
        MotionEvent event = MotionEvent.obtain(gestureStart, now, action, 1, new MotionEvent.PointerProperties[]{prop},
                new MotionEvent.PointerCoords[]{coords}, 0, 0, 1, 1, 0, 0, source, 0);
        try { setDisplay.invoke(event, display); inject.invoke(input, event, 0); } finally { event.recycle(); }
    }
    void key(int display, int code, int meta) throws Exception {
        long now = android.os.SystemClock.uptimeMillis();
        for (int action : new int[]{KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP}) {
            KeyEvent event = new KeyEvent(now, now, action, code, 0, meta, -1, 0, 0, InputDevice.SOURCE_KEYBOARD);
            setDisplay.invoke(event, display); inject.invoke(input, event, 0);
        }
    }
    void asciiText(int display, String text) throws Exception {
        KeyEvent[] events = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(text.toCharArray());
        if (events == null) throw new IOException("此字符需要启用 Macroid 键盘");
        for (KeyEvent event : events) { setDisplay.invoke(event, display); inject.invoke(input, event, 0); }
    }

    static String command(String... args) throws Exception {
        Process process = new ProcessBuilder(args).redirectErrorStream(true).start();
        // Commands used here have bounded output. Drain concurrently to avoid blocking on pipe capacity.
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Thread reader = new Thread(() -> {
            try (InputStream in = process.getInputStream()) {
                byte[] buffer = new byte[8192]; int count;
                while ((count = in.read(buffer)) != -1) {
                    if (output.size() + count <= 8 * 1024 * 1024) output.write(buffer, 0, count);
                }
            } catch (IOException ignored) { }
        });
        reader.start();
        if (!process.waitFor(15, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new IOException("Command timed out: " + args[0]); }
        reader.join(2000);
        String result = new String(output.toByteArray(), StandardCharsets.UTF_8);
        if (process.exitValue() != 0) throw new IOException(args[0] + ": " + result);
        return result;
    }
}
