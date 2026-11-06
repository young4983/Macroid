package io.macroid.bridge;

import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;

/** Macroid Wire v1: 16-byte big-endian header followed by a bounded payload. */
final class Wire implements Closeable {
    static final int MAGIC = 0x4d435244, VERSION = 1, JSON = 1, VIDEO = 2, MAX_PAYLOAD = 16 * 1024 * 1024;
    final DataInputStream in;
    private final DataOutputStream out;
    Wire(InputStream in, OutputStream out) { this.in = new DataInputStream(new BufferedInputStream(in)); this.out = new DataOutputStream(new BufferedOutputStream(out)); }
    record Packet(int kind, int flags, int stream, byte[] payload) {}
    Packet read() throws IOException {
        if (in.readInt() != MAGIC || in.readUnsignedByte() != VERSION) throw new IOException("Unsupported Macroid protocol");
        int kind = in.readUnsignedByte(), flags = in.readUnsignedShort(), stream = in.readInt(), size = in.readInt();
        if ((kind != JSON && kind != VIDEO) || size < 0 || size > MAX_PAYLOAD || stream < 0) throw new IOException("Invalid frame");
        byte[] payload = new byte[size]; in.readFully(payload);
        return new Packet(kind, flags, stream, payload);
    }
    synchronized void send(int kind, int flags, int stream, byte[] payload) throws IOException {
        if (payload.length > MAX_PAYLOAD) throw new IOException("Frame too large");
        out.writeInt(MAGIC); out.writeByte(VERSION); out.writeByte(kind); out.writeShort(flags);
        out.writeInt(stream); out.writeInt(payload.length); out.write(payload); out.flush();
    }
    void json(JSONObject value) throws IOException { send(JSON, 0, 0, value.toString().getBytes(StandardCharsets.UTF_8)); }
    @Override public void close() throws IOException { try { in.close(); } finally { out.close(); } }
}
