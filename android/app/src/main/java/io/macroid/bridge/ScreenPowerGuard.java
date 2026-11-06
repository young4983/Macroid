package io.macroid.bridge;

import android.app.KeyguardManager;
import android.content.Context;
import android.os.Looper;
import android.os.PowerManager;

/** Separate app_process. EOF from its parent also runs cleanup after SIGKILL of AgentMain. */
public final class ScreenPowerGuard {
    @SuppressWarnings("deprecation")
    public static void main(String[] args) {
        if (android.os.Process.myUid() != 2000 && android.os.Process.myUid() != 0) return;
        ShellPlatform.PhysicalPower panel = null;
        PowerManager.WakeLock wake = null;
        boolean restore = false;
        try {
            Looper.prepareMainLooper();
            ShellPlatform platform = new ShellPlatform();
            panel = new ShellPlatform.PhysicalPower();
            PowerManager power = (PowerManager)platform.context.getSystemService(Context.POWER_SERVICE);
            KeyguardManager keyguard = (KeyguardManager)platform.context.getSystemService(Context.KEYGUARD_SERVICE);
            wake = power.newWakeLock(PowerManager.SCREEN_DIM_WAKE_LOCK, "Macroid:screen-off-session");
            wake.setReferenceCounted(false);
            say("READY");
            int command;
            while ((command = System.in.read()) != -1) {
                try {
                    if (command == '0') {
                        if (!power.isInteractive() || keyguard.isKeyguardLocked()) throw new IllegalStateException("请先在手机上解锁，再开启关屏使用");
                        wake.acquire();
                        restore = true; // Arm before mutating: partial failure must also restore.
                        panel.set(false);
                        // PowerManager may asynchronously apply the newly acquired wake lock.
                        // Reassert after that transaction, before acknowledging to the client.
                        Thread.sleep(250);
                        panel.set(false); say("OFF");
                    } else if (command == '1') {
                        if (restore) panel.set(true);
                        restore = false;
                        if (wake.isHeld()) wake.release();
                        say("ON");
                    }
                } catch (Throwable error) { say("ERROR " + error.toString()); }
            }
        } catch (Throwable error) { say("ERROR " + error.toString()); }
        finally {
            if (restore && panel != null) {
                for (int i = 0; i < 3; i++) {
                    try { panel.set(true); break; }
                    catch (Throwable error) { System.err.println("Restore screen: " + error); }
                }
            }
            if (wake != null && wake.isHeld()) wake.release();
            System.exit(0);
        }
    }
    private static void say(String value) { System.out.println(value); System.out.flush(); }
}
