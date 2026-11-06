package io.macroid.bridge;

import org.json.JSONObject;
import java.io.*;
import java.util.concurrent.*;

/** The guard owns the wake lock and panel override. Parent death closes its stdin pipe. */
final class ScreenPower implements Closeable {
    private Process guard;
    private BlockingQueue<String> replies;
    private boolean off;
    synchronized boolean isOff() { return off; }
    synchronized JSONObject info() throws Exception { return new JSONObject().put("screenOff", off); }

    synchronized JSONObject set(boolean requested) throws Exception {
        if (requested == off && (!off || guard != null && guard.isAlive())) return info();
        if (requested) {
            try { startGuard(); exchange('0', "OFF"); off = true; }
            catch (Exception e) { stopGuard(); throw e; }
        } else {
            // Retain ownership on failure so shutdown/monitor can retry restoration.
            if (guard != null && guard.isAlive()) exchange('1', "ON");
            else new ShellPlatform.PhysicalPower().set(true);
            off = false; stopGuard();
        }
        return info();
    }
    private void startGuard() throws Exception {
        stopGuard();
        BlockingQueue<String> childReplies = new LinkedBlockingQueue<>(); replies = childReplies;
        ProcessBuilder builder = new ProcessBuilder("/system/bin/app_process", "/", "io.macroid.bridge.ScreenPowerGuard");
        builder.environment().put("CLASSPATH", System.getenv("CLASSPATH"));
        builder.redirectError(ProcessBuilder.Redirect.INHERIT);
        guard = builder.start();
        Process child = guard;
        Thread reader = new Thread(() -> {
            try (BufferedReader in = new BufferedReader(new InputStreamReader(child.getInputStream()))) {
                String line;
                while ((line = in.readLine()) != null) childReplies.offer(line);
            } catch (IOException ignored) { }
            childReplies.offer("ERROR 屏幕恢复守护已退出");
        }, "Macroid-power-replies");
        reader.setDaemon(true); reader.start();
        expect("READY");
    }
    private void expect(String expected) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8);
        while (true) {
            String reply = replies.poll(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
            if (reply == null) throw new IOException("手机屏幕电源操作超时");
            if (reply.equals(expected)) return;
            if (reply.startsWith("ERROR ")) throw new IOException(reply.substring(6));
            // Framework startup may print diagnostics before the guard handshake.
            System.err.println("Power guard: " + reply);
        }
    }
    private void exchange(int command, String expected) throws Exception {
        guard.getOutputStream().write(command); guard.getOutputStream().flush(); expect(expected);
    }
    private void stopGuard() {
        if (guard == null) return;
        try { guard.getOutputStream().close(); } catch (IOException ignored) { }
        // EOF instructs the child to restore power before exiting; never kill that cleanup.
        try { guard.waitFor(3, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        guard = null;
    }
    synchronized boolean guardFailed() { return off && (guard == null || !guard.isAlive()); }
    @Override public synchronized void close() {
        try { if (off) set(false); }
        catch (Exception e) { System.err.println("Restore screen: " + e); }
        finally { stopGuard(); }
    }
}
