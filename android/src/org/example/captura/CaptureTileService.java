package org.example.captura;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

/** A single tap pauses capture or brings the activity forward to resume it. */
public final class CaptureTileService extends TileService {
    private final SharedPreferences.OnSharedPreferenceChangeListener listener =
            (prefs, key) -> updateState();

    @Override
    public void onStartListening() {
        super.onStartListening();
        getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .registerOnSharedPreferenceChangeListener(listener);
        updateState();
    }

    @Override
    public void onStopListening() {
        getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .unregisterOnSharedPreferenceChangeListener(listener);
        super.onStopListening();
    }

    @Override
    public void onClick() {
        super.onClick();
        if (CaptureService.isRecording()) {
            startService(new Intent(this, CaptureService.class)
                    .setAction(CaptureService.ACTION_PAUSE));
            return;
        }
        if (isLocked()) {
            unlockAndRun(this::resumeFromVisibleActivity);
        } else {
            resumeFromVisibleActivity();
        }
    }

    private void resumeFromVisibleActivity() {
        Intent intent = new Intent(this, MainActivity.class)
                .setAction(CaptureService.ACTION_START)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent pending = PendingIntent.getActivity(this, 12, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(pending);
        } else {
            startActivityAndCollapse(intent);
        }
    }

    private void updateState() {
        Tile tile = getQsTile();
        if (tile == null) return;
        boolean active = CaptureService.isRecording();
        tile.setIcon(android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_capture_mono));
        tile.setLabel("Captura");
        tile.setSubtitle(active ? "Grabando" : CaptureService.isListening() ? "Escucha comandos" : "Apagada");
        tile.setState(active ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setContentDescription(active
                ? "Captura grabando. Tocar para pausar."
                : CaptureService.isListening() ? "Archivos pausados, micrófono activo. Tocar para grabar."
                : "Captura apagada. Tocar para grabar.");
        tile.updateTile();
    }

    public static void requestUpdate(Context context) {
        TileService.requestListeningState(context,
                new ComponentName(context, CaptureTileService.class));
    }
}
