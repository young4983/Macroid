package io.macroid.fixture;

import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;

public final class StateProvider extends ContentProvider {
    public boolean onCreate() { return true; }
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        SharedPreferences prefs = getContext().getSharedPreferences("state", Context.MODE_PRIVATE);
        String[] keys = {"display", "text", "clicks", "editorX", "editorY", "buttonX", "buttonY", "task", "width", "height", "density",
                "widthDp", "heightDp", "smallestDp", "insetTop", "insetBottom", "statusVisible", "navigationVisible"};
        MatrixCursor cursor = new MatrixCursor(keys);
        Object[] values = new Object[keys.length];
        for (int i = 0; i < keys.length; i++) values[i] = keys[i].equals("text") ? prefs.getString("text", "") : prefs.getInt(keys[i], -1);
        cursor.addRow(values);
        return cursor;
    }
    public String getType(Uri uri) { return "vnd.android.cursor.item/macroid-test"; }
    public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
