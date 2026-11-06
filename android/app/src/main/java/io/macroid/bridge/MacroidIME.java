package io.macroid.bridge;

import android.inputmethodservice.InputMethodService;
import android.view.inputmethod.InputConnection;

/** Text is committed through Android's input connection, so Unicode is preserved. */
public final class MacroidIME extends InputMethodService {
    private static MacroidIME active;
    @Override public void onCreate() { super.onCreate(); active = this; }
    @Override public void onDestroy() { if (active == this) active = null; super.onDestroy(); }
    @Override public boolean onEvaluateInputViewShown() { super.onEvaluateInputViewShown(); return false; }
    static boolean commit(String text) {
        InputConnection connection = active == null ? null : active.getCurrentInputConnection();
        return connection != null && connection.commitText(text, 1);
    }
}
