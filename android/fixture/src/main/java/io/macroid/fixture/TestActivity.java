package io.macroid.fixture;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.widget.*;
import android.view.WindowInsets;
import android.util.DisplayMetrics;

/** A deterministic fixture, built only by integration tests and never bundled in Macroid.app. */
public final class TestActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getSharedPreferences("state", MODE_PRIVATE);
        if (state == null) prefs.edit().clear().putInt("clicks", 0).apply();
        prefs.edit().putInt("display", getDisplay().getDisplayId()).putInt("task", getTaskId()).apply();
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        int pad = (int)(24 * getResources().getDisplayMetrics().density); layout.setPadding(pad, pad, pad, pad);
        layout.setBackgroundColor(Color.rgb(235, 245, 255));
        TextView title = new TextView(this); title.setText("Macroid · Android Integration"); title.setTextSize(22); title.setTextColor(Color.rgb(30, 90, 170));
        layout.addView(title, new LinearLayout.LayoutParams(-1, pad * 3));
        EditText editor = new EditText(this); editor.setId(1001); editor.setSingleLine(true); editor.setHint("Type Unicode here");
        layout.addView(editor, new LinearLayout.LayoutParams(-1, pad * 3));
        Button button = new Button(this); button.setText("Tap to verify input"); layout.addView(button, new LinearLayout.LayoutParams(-1, pad * 3));
        TextView label = new TextView(this); label.setText("Independent display: " + getDisplay().getDisplayId()); layout.addView(label);
        button.setOnClickListener(v -> { int clicks = prefs.getInt("clicks", 0) + 1; prefs.edit().putInt("clicks", clicks).apply(); label.setText("Verified taps: " + clicks); });
        editor.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) { prefs.edit().putString("text", s.toString()).apply(); }
            public void afterTextChanged(Editable text) {}
        });
        layout.getViewTreeObserver().addOnGlobalLayoutListener(() -> {
            int[] e = new int[2], b = new int[2]; editor.getLocationOnScreen(e); button.getLocationOnScreen(b);
            DisplayMetrics metrics = new DisplayMetrics(); getDisplay().getRealMetrics(metrics);
            android.content.res.Configuration config = getResources().getConfiguration();
            WindowInsets insets = layout.getRootWindowInsets();
            android.graphics.Insets bars = insets == null ? android.graphics.Insets.NONE : insets.getInsets(WindowInsets.Type.systemBars());
            prefs.edit().putInt("width", metrics.widthPixels).putInt("height", metrics.heightPixels)
                    .putInt("density", metrics.densityDpi).putInt("widthDp", config.screenWidthDp).putInt("heightDp", config.screenHeightDp)
                    .putInt("smallestDp", config.smallestScreenWidthDp).putInt("insetTop", bars.top).putInt("insetBottom", bars.bottom)
                    .putInt("statusVisible", insets != null && insets.isVisible(WindowInsets.Type.statusBars()) ? 1 : 0)
                    .putInt("navigationVisible", insets != null && insets.isVisible(WindowInsets.Type.navigationBars()) ? 1 : 0).apply();
            prefs.edit().putInt("editorX", e[0] + editor.getWidth()/2).putInt("editorY", e[1] + editor.getHeight()/2)
                    .putInt("buttonX", b[0] + button.getWidth()/2).putInt("buttonY", b[1] + button.getHeight()/2).apply();
        });
        setContentView(layout);
        TextView responsive = new TextView(this);
        responsive.setText(getResources().getConfiguration().screenWidthDp >= 600 ? "Wide layout · tablet" : "Compact layout · phone");
        layout.addView(responsive);
    }
}
