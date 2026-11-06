package io.macroid.fixture;

import android.content.*;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;

public final class StateProvider extends ContentProvider {
    public boolean onCreate() { return true; }
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        SharedPreferences prefs = getContext().getSharedPreferences("state", Context.MODE_PRIVATE);
        MatrixCursor cursor = new MatrixCursor(new String[]{"display", "text", "clicks", "editorX", "editorY", "buttonX", "buttonY"});
        cursor.addRow(new Object[]{prefs.getInt("display", -1), prefs.getString("text", ""), prefs.getInt("clicks", 0),
                prefs.getInt("editorX", 0), prefs.getInt("editorY", 0), prefs.getInt("buttonX", 0), prefs.getInt("buttonY", 0)});
        return cursor;
    }
    public String getType(Uri uri) { return "vnd.android.cursor.item/macroid-test"; }
    public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
    public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
}
