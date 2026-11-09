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
import android.os.Binder;
import android.os.Parcel;
import android.os.RemoteException;
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
    private final Map<Integer, Long> gestures = new HashMap<>();

    static final class ScreenInfo {
        final int width, height, density, rotation;
        ScreenInfo(Display display, int rotation) {
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics(); display.getRealMetrics(metrics);
            width = metrics.widthPixels; height = metrics.heightPixels; density = metrics.densityDpi; this.rotation = rotation;
        }
        boolean sameAs(ScreenInfo other) {
            return other != null && width == other.width && height == other.height && density == other.density && rotation == other.rotation;
        }
    }
    ScreenInfo screenInfo() throws Exception {
        Display display = displays.getDisplay(Display.DEFAULT_DISPLAY);
        if (display == null) throw new IOException("手机主屏幕不可用");
        Object wm = windowManager();
        int rotation = (int)wm.getClass().getMethod("getDefaultDisplayRotation").invoke(wm);
        return new ScreenInfo(display, rotation);
    }

    private Object windowManager() throws Exception {
        return Class.forName("android.view.WindowManagerGlobal").getMethod("getWindowManagerService").invoke(null);
    }
    // This listener runs only in the uid-2000 app_process agent, outside APK hidden-API enforcement.
    @SuppressLint("SoonBlockedPrivateApi")
    Closeable watchRotation(Handler handler, Runnable changed) throws Exception {
        Class<?> watcherType = Class.forName("android.view.IRotationWatcher");
        Class<?> stub = Class.forName("android.view.IRotationWatcher$Stub");
        Field transaction = stub.getDeclaredField("TRANSACTION_onRotationChanged"); transaction.setAccessible(true);
        int rotationTransaction = transaction.getInt(null);
        Binder binder = new Binder() {
            @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
                if (code == IBinder.INTERFACE_TRANSACTION) {
                    if (reply != null) reply.writeString("android.view.IRotationWatcher");
                    return true;
                }
                if (code == rotationTransaction) {
                    data.enforceInterface("android.view.IRotationWatcher"); data.readInt();
                    handler.post(changed); return true;
                }
                return super.onTransact(code, data, reply, flags);
            }
        };
        Object watcher = stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
        Object wm = windowManager();
        wm.getClass().getMethod("watchRotation", watcherType, int.class).invoke(wm, watcher, 0);
        return () -> {
            try { wm.getClass().getMethod("removeRotationWatcher", watcherType).invoke(wm, watcher); }
            catch (Exception e) { throw new IOException("Remove rotation watcher", e); }
        };
    }
    boolean rotationLocked() throws Exception {
        Object wm = windowManager();
        try { return (boolean)wm.getClass().getMethod("isDisplayRotationFrozen", int.class).invoke(wm, 0); }
        catch (NoSuchMethodException e) { return (boolean)wm.getClass().getMethod("isRotationFrozen").invoke(wm); }
    }
    private void freezeRotation(int rotation) throws Exception {
        Object wm = windowManager();
        try { wm.getClass().getMethod("freezeDisplayRotation", int.class, int.class, String.class).invoke(wm, 0, rotation, "Macroid"); }
        catch (NoSuchMethodException e) {
            try { wm.getClass().getMethod("freezeDisplayRotation", int.class, int.class).invoke(wm, 0, rotation); }
            catch (NoSuchMethodException older) { wm.getClass().getMethod("freezeRotation", int.class).invoke(wm, rotation); }
        }
    }
    private void thawRotation() throws Exception {
        Object wm = windowManager();
        try { wm.getClass().getMethod("thawDisplayRotation", int.class, String.class).invoke(wm, 0, "Macroid"); }
        catch (NoSuchMethodException e) {
            try { wm.getClass().getMethod("thawDisplayRotation", int.class).invoke(wm, 0); }
            catch (NoSuchMethodException older) { wm.getClass().getMethod("thawRotation").invoke(wm); }
        }
    }
    org.json.JSONObject rotationInfo() throws Exception {
        return new org.json.JSONObject().put("rotation", screenInfo().rotation).put("rotationLocked", rotationLocked());
    }
    org.json.JSONObject rotate(boolean automatic) throws Exception {
        int target = -1;
        if (automatic) { thawRotation(); }
        else {
            boolean locked = rotationLocked();
            // Toggle each portrait/landscape pair; many phone policies disallow upside-down portrait.
            target = screenInfo().rotation ^ 1;
            try { freezeRotation(target); }
            finally { if (!locked) thawRotation(); }
        }
        return rotationInfo().put("requestedRotation", target);
    }

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

    boolean alwaysUnlockedAllowed() {
        return trustedDisplayAllowed() && context.checkSelfPermission("android.permission.ADD_ALWAYS_UNLOCKED_DISPLAY") == android.content.pm.PackageManager.PERMISSION_GRANTED;
    }

    /** Interface discovery only; actual device/OEM permission failures are returned by the operation. */
    static final class PhysicalPower {
        private static Class<?> serverDisplayControl;
        private static synchronized Class<?> displayControl() throws Exception {
            if (serverDisplayControl == null) {
                String classpath = System.getenv("SYSTEMSERVERCLASSPATH");
                if (classpath == null || classpath.isEmpty()) classpath = "/system/framework/services.jar";
                // DisplayControl moved out of the boot classpath on Android 14. Its JNI library
                // must be associated with this system-server loader (ordinary PathClassLoader
                // cannot access the private system library namespace).
                Class<?> factory = Class.forName("com.android.internal.os.ClassLoaderFactory");
                Method create = factory.getDeclaredMethod("createClassLoader", String.class, String.class, String.class,
                        ClassLoader.class, int.class, boolean.class, String.class);
                ClassLoader loader = (ClassLoader)create.invoke(null, classpath, null, null, ClassLoader.getSystemClassLoader(), 0, true, null);
                Class<?> control = loader.loadClass("com.android.server.display.DisplayControl");
                Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
                load.setAccessible(true); load.invoke(Runtime.getRuntime(), control, "android_servers");
                serverDisplayControl = control;
            }
            return serverDisplayControl;
        }
        private final Method setPower;
        private final List<IBinder> tokens = new ArrayList<>();
        PhysicalPower() throws Exception {
            Class<?> surface = Class.forName("android.view.SurfaceControl");
            setPower = surface.getMethod("setDisplayPowerMode", IBinder.class, int.class);
            Class<?> lookup = surface;
            try { surface.getMethod("getPhysicalDisplayIds"); }
            catch (NoSuchMethodException e) { lookup = displayControl(); }
            long[] ids = (long[]) lookup.getMethod("getPhysicalDisplayIds").invoke(null);
            Method getToken = lookup.getMethod("getPhysicalDisplayToken", long.class);
            for (long id : ids) {
                IBinder token = (IBinder)getToken.invoke(null, id);
                if (token != null) tokens.add(token);
            }
            if (tokens.isEmpty()) throw new IOException("找不到手机物理显示器");
        }
        void set(boolean on) throws Exception {
            Exception failure = null;
            for (IBinder token : tokens) {
                try { setPower.invoke(null, token, on ? 2 : 0); }
                catch (Exception e) { failure = e; }
            }
            if (failure != null) throw failure;
        }
    }
    String screenPowerUnavailableReason() {
        try { new PhysicalPower(); return ""; }
        catch (Throwable e) { return "此设备没有可用的物理屏幕电源接口：" + e.getClass().getSimpleName(); }
    }

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
            updateDisplay(handle, width, height, 0, surface);
            return handle;
        } catch (Exception e) { handle.release(); throw e; }
    }

    void updateDisplay(DisplayHandle display, int width, int height, int density, Surface surface) throws Exception {
        if (display.virtual != null) {
            display.virtual.resize(width, height, density);
            display.virtual.setSurface(surface);
            return;
        }
        ScreenInfo info = screenInfo();
        Class<?> control = Class.forName("android.view.SurfaceControl");
        control.getDeclaredMethod("openTransaction").invoke(null);
        try {
            control.getDeclaredMethod("setDisplaySurface", IBinder.class, Surface.class).invoke(null, display.token, surface);
            // Layer-stack content already uses the current logical orientation.
            control.getDeclaredMethod("setDisplayProjection", IBinder.class, int.class, Rect.class, Rect.class)
                    .invoke(null, display.token, 0, new Rect(0, 0, info.width, info.height), new Rect(0, 0, width, height));
            control.getDeclaredMethod("setDisplayLayerStack", IBinder.class, int.class).invoke(null, display.token, 0);
        } finally { control.getDeclaredMethod("closeTransaction").invoke(null); }
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
            if (alwaysUnlockedAllowed()) flags |= (1 << 12);
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
                if (trustedDisplayAllowed()) {
                    try { wm.getClass().getMethod("setShouldShowSystemDecors", int.class, boolean.class).invoke(wm, display.getDisplay().getDisplayId(), false); }
                    catch (ReflectiveOperationException e) { System.err.println("Display decorations policy unavailable: " + e); }
                }
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
        if (action == MotionEvent.ACTION_DOWN) gestures.put(display, now);
        long gestureStart = gestures.getOrDefault(display, now);
        MotionEvent.PointerProperties prop = new MotionEvent.PointerProperties(); prop.id = 0; prop.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords coords = new MotionEvent.PointerCoords(); coords.x = x; coords.y = y;
        coords.pressure = action == MotionEvent.ACTION_UP ? 0 : 1;
        coords.setAxisValue(MotionEvent.AXIS_HSCROLL, scrollX); coords.setAxisValue(MotionEvent.AXIS_VSCROLL, scrollY);
        int source = action == MotionEvent.ACTION_SCROLL ? InputDevice.SOURCE_MOUSE : InputDevice.SOURCE_TOUCHSCREEN;
        MotionEvent event = MotionEvent.obtain(gestureStart, now, action, 1, new MotionEvent.PointerProperties[]{prop},
                new MotionEvent.PointerCoords[]{coords}, 0, 0, 1, 1, 0, 0, source, 0);
        try { setDisplay.invoke(event, display); inject.invoke(input, event, 0); } finally { event.recycle(); }
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) gestures.remove(display);
    }
    void cancelGesture(int display) throws Exception {
        if (gestures.containsKey(display)) pointer(display, MotionEvent.ACTION_CANCEL, 0, 0, 0, 0);
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
