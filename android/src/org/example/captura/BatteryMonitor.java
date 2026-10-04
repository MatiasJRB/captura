package org.example.captura;

import android.content.ContentValues;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Handler;
import android.os.SystemClock;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

/** Private telemetry piggybacks on the existing recorder; no alarms/wake locks/network. */
final class BatteryMonitor extends SQLiteOpenHelper {
    static final long SAMPLE_MS = 5 * 60_000L;
    private final Context context;
    private final Handler handler;
    private long session;
    private boolean active;
    private boolean listening;
    private int lastPlugged = -1;
    private final BroadcastReceiver chargingChanges = new BroadcastReceiver() {
        @Override public void onReceive(Context ignored, Intent battery) {
            int plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 ? 1 : 0;
            if (active && plugged != lastPlugged) safely(() -> sample(true));
        }
    };
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (!active) return;
            safely(() -> sample(true));
            handler.postDelayed(this, SAMPLE_MS);
        }
    };

    BatteryMonitor(Context context, Handler handler) {
        super(context, "battery-observations.sqlite", null, 1);
        this.context = context.getApplicationContext(); this.handler = handler;
    }

    @Override public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE sessions(id INTEGER PRIMARY KEY, started INTEGER NOT NULL, ended INTEGER, state TEXT NOT NULL)");
        db.execSQL("CREATE TABLE samples(id INTEGER PRIMARY KEY, session INTEGER NOT NULL, wall INTEGER NOT NULL, elapsed INTEGER NOT NULL, percent REAL, plugged INTEGER NOT NULL, recording INTEGER NOT NULL, temperature INTEGER, charge_uah INTEGER)");
        db.execSQL("CREATE INDEX samples_session ON samples(session,id)");
    }
    @Override public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {
        throw new IllegalStateException("Battery migration required");
    }

    void beginSegment() {
        safely(() -> {
            if (session == 0) {
                // A process death/reboot leaves an honest incomplete record, not a fictitious gap.
                getWritableDatabase().execSQL("UPDATE sessions SET state='interrumpida' WHERE ended IS NULL");
                ContentValues values = new ContentValues();
                values.put("started", System.currentTimeMillis()); values.put("state", "grabando");
                session = getWritableDatabase().insertOrThrow("sessions", null, values);
            }
            active = true; sample(true);
            if (!listening) {
                if (Build.VERSION.SDK_INT >= 33)
                    context.registerReceiver(chargingChanges, new IntentFilter(Intent.ACTION_BATTERY_CHANGED), Context.RECEIVER_NOT_EXPORTED);
                else context.registerReceiver(chargingChanges, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
                listening = true;
            }
        });
        handler.removeCallbacks(tick);
        if (active) handler.postDelayed(tick, SAMPLE_MS);
    }

    void endSegment() {
        if (active) safely(() -> sample(false));
        active = false; handler.removeCallbacks(tick);
        if (listening) {
            safely(() -> context.unregisterReceiver(chargingChanges));
            listening = false;
        }
    }

    void finish(String state) {
        endSegment();
        if (session != 0) safely(() -> {
            ContentValues values = new ContentValues();
            values.put("ended", System.currentTimeMillis()); values.put("state", state);
            getWritableDatabase().update("sessions", values, "id=?", new String[]{Long.toString(session)});
        });
        session = 0;
    }

    private void sample(boolean recording) {
        Intent battery = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
        if (battery == null) return;
        ContentValues values = new ContentValues();
        values.put("session", session); values.put("wall", System.currentTimeMillis());
        values.put("elapsed", SystemClock.elapsedRealtime());
        int level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
        int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1);
        if (level >= 0 && scale > 0 && level <= scale) values.put("percent", level * 100d / scale);
        lastPlugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 ? 1 : 0;
        values.put("plugged", lastPlugged);
        values.put("recording", recording ? 1 : 0);
        int temperature = battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE);
        if (temperature != Integer.MIN_VALUE) values.put("temperature", temperature);
        BatteryManager manager = context.getSystemService(BatteryManager.class);
        int charge = manager == null ? Integer.MIN_VALUE : manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
        if (charge != Integer.MIN_VALUE && charge >= 0) values.put("charge_uah", charge);
        getWritableDatabase().insertOrThrow("samples", null, values);
    }

    String latest() { return history(1); }

    String history(int limit) {
        StringBuilder text = new StringBuilder();
        try (Cursor sessions = getReadableDatabase().rawQuery(
                "SELECT id,started,state FROM sessions ORDER BY id DESC LIMIT ?", new String[]{Integer.toString(limit)})) {
            while (sessions.moveToNext()) {
                long id = sessions.getLong(0);
                List<BatteryUsage.Sample> readings = new ArrayList<>();
                try (Cursor rows = getReadableDatabase().rawQuery(
                        "SELECT elapsed,percent,plugged,recording FROM samples WHERE session=? ORDER BY id", new String[]{Long.toString(id)})) {
                    while (rows.moveToNext()) readings.add(new BatteryUsage.Sample(rows.getLong(0),
                            rows.isNull(1) ? Double.NaN : rows.getDouble(1), rows.getInt(2) != 0, rows.getInt(3) != 0));
                }
                if (text.length() > 0) text.append("\n\n");
                text.append(DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(new Date(sessions.getLong(1))))
                    .append(" · ").append(sessions.getString(2)).append('\n').append(BatteryUsage.calculate(readings).text());
            }
        }
        return text.length() == 0 ? "Todavía no hay mediciones. Empiezan al grabar; no se reconstruye el consumo anterior." : text.toString();
    }

    private void safely(Runnable action) {
        try { action.run(); }
        catch (RuntimeException error) {
            context.getSharedPreferences("battery_measurement", Context.MODE_PRIVATE).edit()
                .putBoolean("failed", true).apply();
            // A telemetry/storage failure must never interrupt the audio recorder.
        }
    }
}
