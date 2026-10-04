package org.example.captura;

import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Environment;
import android.provider.MediaStore;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;

final class SyncQueue extends SQLiteOpenHelper {
    private final Context context;
    SyncQueue(Context c) { super(c, "capture-sync.db", null, 1); context = c.getApplicationContext(); }
    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE queue(uri TEXT PRIMARY KEY,name TEXT NOT NULL,bytes INTEGER NOT NULL,md5 TEXT,sha TEXT,drive_id TEXT,session TEXT,state TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,uploaded_at INTEGER)");
    }
    @Override public void onUpgrade(SQLiteDatabase db, int oldV, int newV) { }
    void discover() {
        String[] projection = {"_id", "_display_name", "_size"};
        String where = "relative_path=? AND is_pending=0 AND owner_package_name=? AND _display_name LIKE ?";
        try (Cursor c = context.getContentResolver().query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, projection, where,
                new String[]{Environment.DIRECTORY_MUSIC + "/PersonalCapture/", context.getPackageName(), "personal-capture-%.m4a"}, null)) {
            if (c == null) return;
            while (c.moveToNext()) {
                if (c.getLong(2) <= 1024) continue;
                ContentValues row = new ContentValues();
                row.put("uri", ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, c.getLong(0)).toString());
                row.put("name", c.getString(1)); row.put("bytes", c.getLong(2));
                getWritableDatabase().insertWithOnConflict("queue", null, row, SQLiteDatabase.CONFLICT_IGNORE);
            }
        }
    }
    static final class Item {
        String uri, name, md5, sha, driveId, session; long bytes;
    }
    List<Item> pending() {
        List<Item> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery("SELECT uri,name,bytes,md5,sha,drive_id,session FROM queue WHERE state='pending' ORDER BY name LIMIT 100", null)) {
            while (c.moveToNext()) {
                Item i = new Item(); i.uri = c.getString(0); i.name = c.getString(1); i.bytes = c.getLong(2);
                i.md5 = c.getString(3); i.sha = c.getString(4); i.driveId = c.getString(5); i.session = c.getString(6); result.add(i);
            }
        }
        return result;
    }
    void prepare(Item i, DriveApi.Cancel cancel) throws Exception {
        // Closed M4A only. A size/hash mismatch is quarantined, never uploaded as success.
        String previousSha = i.sha;
        Uri uri = Uri.parse(i.uri);
        try (MediaMetadataRetriever media = new MediaMetadataRetriever()) {
            media.setDataSource(context, uri);
            String duration = media.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            if (duration == null || Long.parseLong(duration) <= 0) throw new IllegalStateException("invalid-audio");
        }
        MessageDigest md5 = MessageDigest.getInstance("MD5"), sha = MessageDigest.getInstance("SHA-256");
        long length = 0;
        try (InputStream in = context.getContentResolver().openInputStream(uri)) {
            if (in == null) throw new IllegalStateException("missing-audio");
            byte[] buffer = new byte[65536]; int count;
            while ((count = in.read(buffer)) != -1) { cancel.check(); md5.update(buffer, 0, count); sha.update(buffer, 0, count); length += count; }
        }
        if (length != i.bytes) throw new IllegalStateException("changed-audio");
        i.md5 = hex(md5.digest()); i.sha = hex(sha.digest());
        if (previousSha != null && !previousSha.equals(i.sha)) throw new IllegalStateException("changed-audio");
        ContentValues v = new ContentValues(); v.put("md5", i.md5); v.put("sha", i.sha); update(i, v);
    }
    static String hex(byte[] bytes) { StringBuilder s = new StringBuilder(); for (byte b : bytes) s.append(String.format(java.util.Locale.US, "%02x", b & 255)); return s.toString(); }
    void id(Item i, String id) { i.driveId = id; ContentValues v = new ContentValues(); v.put("drive_id", id); update(i, v); }
    void session(Item i, String url) throws Exception { i.session = url == null ? null : SyncCrypto.seal(url); ContentValues v = new ContentValues(); v.put("session", i.session); update(i, v); }
    void uploaded(Item i) { ContentValues v = new ContentValues(); v.put("state", "uploaded"); v.putNull("session"); v.put("uploaded_at", System.currentTimeMillis()); update(i, v); }
    void quarantine(Item i) { ContentValues v = new ContentValues(); v.put("state", "review"); update(i, v); }
    void attempted(Item i) { getWritableDatabase().execSQL("UPDATE queue SET attempts=attempts+1 WHERE uri=?", new Object[]{i.uri}); }
    private void update(Item i, ContentValues v) { getWritableDatabase().update("queue", v, "uri=?", new String[]{i.uri}); }
    int count(String state) { try (Cursor c = getReadableDatabase().rawQuery("SELECT COUNT(*) FROM queue WHERE state=?", new String[]{state})) { return c.moveToFirst() ? c.getInt(0) : 0; } }
}
