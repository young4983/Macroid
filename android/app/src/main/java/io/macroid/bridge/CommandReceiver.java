package io.macroid.bridge;

import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;

/** The platform DUMP permission restricts this explicit receiver to shell/system callers. */
public final class CommandReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context, Intent intent) {
        String text = intent.getStringExtra("text");
        if (text == null || text.length() > 65536) { setResultCode(0); return; }
        switch (intent.getStringExtra("command") == null ? "" : intent.getStringExtra("command")) {
            case "text": setResultCode(MacroidIME.commit(text) ? 1 : 0); break;
            case "clipboard":
                context.getSystemService(ClipboardManager.class).setPrimaryClip(ClipData.newPlainText("Macroid", text));
                setResultCode(1); break;
            default: setResultCode(0);
        }
    }
}
