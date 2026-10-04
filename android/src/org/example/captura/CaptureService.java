package org.example.captura;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.media.MediaRecorder;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.provider.MediaStore;
import android.content.ContentUris;
import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

public final class CaptureService extends Service {
    public static final String ACTION_START = "org.example.captura.START";
    public static final String ACTION_PAUSE = "org.example.captura.PAUSE";
    public static final String ACTION_FLUSH = "org.example.captura.FLUSH_FOR_SYNC";
    public static final String ACTION_STOP = "org.example.captura.STOP";
    public static final String PREFS = "capture_state";
    public static final String KEY_STATE = "state";
    private static final String KEY_PENDING_URI = "pending_uri";

    private static final String CHANNEL = "personal_capture";
    private static final int NOTIFICATION_ID = 1207;
    private static final long CHUNK_MS = 15L * 60L * 1000L;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaRecorder recorder;
    private ParcelFileDescriptor outputDescriptor;
    private Uri outputUri;
    private PowerManager.WakeLock wakeLock;
    private BatteryMonitor batteryMonitor;
    private boolean recording;
    private boolean chunkStarted;
    private static volatile boolean microphoneActive;

    public static boolean isRecording() {
        return microphoneActive;
    }

    private final Runnable rotate = new Runnable() {
        @Override public void run() {
            if (!recording) return;
            stopChunk();
            handler.postDelayed(CaptureService.this::startChunk, 350);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "personal-capture:recorder");
        wakeLock.setReferenceCounted(false);
        batteryMonitor = new BatteryMonitor(this, handler);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null && "pausada".equals(
                getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_STATE, "detenida"))) {
            stopSelf();
            return START_NOT_STICKY;
        }
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_FLUSH.equals(action)) {
            if (recording) { stopChunk(); startChunk(); }
            SyncScheduler.manual(this);
            return START_STICKY;
        }
        if (ACTION_STOP.equals(action)) {
            stopCapture("detenida");
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (ACTION_PAUSE.equals(action)) {
            stopCapture("pausada");
            startForeground(NOTIFICATION_ID, buildNotification(false));
            return START_NOT_STICKY;
        }

        startForeground(NOTIFICATION_ID, buildNotification(true));
        if (!recording) {
            recoverLastInterruptedFile();
            recoverInterruptedFiles();
            startChunk();
        }
        return START_STICKY;
    }

    private void recoverInterruptedFiles() {
        ContentResolver resolver = getContentResolver();
        String[] projection = {
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.DATE_ADDED,
                MediaStore.Audio.Media.SIZE
        };
        String selection = MediaStore.Audio.Media.RELATIVE_PATH + "=? AND "
                + MediaStore.Audio.Media.IS_PENDING + "=1 AND "
                + MediaStore.Audio.Media.DISPLAY_NAME + " LIKE ?";
        String[] args = {Environment.DIRECTORY_MUSIC + "/PersonalCapture/", "personal-capture-%"};
        long staleBefore = System.currentTimeMillis() / 1000L - 30L;
        try (Cursor cursor = resolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection, selection, args, null)) {
            if (cursor == null) return;
            int idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID);
            int dateIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DATE_ADDED);
            int sizeIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE);
            while (cursor.moveToNext()) {
                if (cursor.getLong(dateIndex) > staleBefore) continue;
                Uri uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                        cursor.getLong(idIndex));
                if (cursor.getLong(sizeIndex) > 1024L) {
                    ContentValues done = new ContentValues();
                    done.put(MediaStore.Audio.Media.IS_PENDING, 0);
                    resolver.update(uri, done, null, null);
                } else {
                    resolver.delete(uri, null, null);
                }
            }
        } catch (RuntimeException ignored) {
            // Recovery is best-effort; it must never prevent a new recording.
        }
    }

    private void recoverLastInterruptedFile() {
        String saved = getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_PENDING_URI, null);
        if (saved == null) return;
        Uri uri = Uri.parse(saved);
        try (ParcelFileDescriptor descriptor = getContentResolver().openFileDescriptor(uri, "r")) {
            if (descriptor != null && descriptor.getStatSize() > 1024L) {
                ContentValues done = new ContentValues();
                done.put(MediaStore.Audio.Media.IS_PENDING, 0);
                getContentResolver().update(uri, done, null, null);
            } else {
                getContentResolver().delete(uri, null, null);
            }
        } catch (Exception ignored) {
            // The row may already be finalized or removed.
        }
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(KEY_PENDING_URI).apply();
    }

    private void startChunk() {
        if (recording) return;
        try {
            ContentValues values = new ContentValues();
            String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
            values.put(MediaStore.Audio.Media.DISPLAY_NAME, "personal-capture-" + stamp + ".m4a");
            values.put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4");
            values.put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/PersonalCapture");
            values.put(MediaStore.Audio.Media.IS_PENDING, 1);

            ContentResolver resolver = getContentResolver();
            outputUri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values);
            if (outputUri == null) throw new IOException("No se pudo crear el archivo de audio");
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putString(KEY_PENDING_URI, outputUri.toString()).commit();
            outputDescriptor = resolver.openFileDescriptor(outputUri, "w");
            if (outputDescriptor == null) throw new IOException("No se pudo abrir el archivo de audio");

            recorder = Build.VERSION.SDK_INT >= 31 ? new MediaRecorder(this) : new MediaRecorder();
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            recorder.setAudioChannels(1);
            recorder.setAudioSamplingRate(16000);
            recorder.setAudioEncodingBitRate(24000);
            recorder.setOutputFile(outputDescriptor.getFileDescriptor());
            recorder.setOnErrorListener((mr, what, extra) -> {
                stopChunk();
                handler.postDelayed(this::startChunk, 5000);
            });
            recorder.prepare();
            recorder.start();
            chunkStarted = true;
            recording = true;
            microphoneActive = true;
            batteryMonitor.beginSegment();
            setState("grabando");
            if (!wakeLock.isHeld()) wakeLock.acquire();
            handler.removeCallbacks(rotate);
            handler.postDelayed(rotate, CHUNK_MS);
            ((NotificationManager) getSystemService(NOTIFICATION_SERVICE))
                    .notify(NOTIFICATION_ID, buildNotification(true));
        } catch (Exception error) {
            stopChunk();
            batteryMonitor.finish("error");
            setState("error");
            handler.postDelayed(this::startChunk, 10000);
        }
    }

    private void stopChunk() {
        if (batteryMonitor != null) batteryMonitor.endSegment();
        handler.removeCallbacks(rotate);
        boolean completedRecording = chunkStarted;
        if (recorder != null) {
            try { recorder.stop(); } catch (RuntimeException ignored) { }
            recorder.reset();
            recorder.release();
            recorder = null;
        }
        chunkStarted = false;
        recording = false;
        microphoneActive = false;
        if (outputDescriptor != null) {
            try { outputDescriptor.close(); } catch (IOException ignored) { }
            outputDescriptor = null;
        }
        if (outputUri != null) {
            if (completedRecording) {
                ContentValues done = new ContentValues();
                done.put(MediaStore.Audio.Media.IS_PENDING, 0);
                getContentResolver().update(outputUri, done, null, null);
                SyncScheduler.automatic(this);
            } else {
                getContentResolver().delete(outputUri, null, null);
            }
            outputUri = null;
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(KEY_PENDING_URI).apply();
        }
    }

    private void stopCapture(String state) {
        handler.removeCallbacksAndMessages(null);
        stopChunk();
        if (batteryMonitor != null) batteryMonitor.finish(state);
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        setState(state);
    }

    private void setState(String state) {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(KEY_STATE, state).apply();
        CaptureTileService.requestUpdate(this);
    }

    private Notification buildNotification(boolean active) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent openIntent = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        String action = active ? ACTION_PAUSE : ACTION_START;
        PendingIntent controlIntent;
        if (active) {
            Intent control = new Intent(this, CaptureService.class).setAction(action);
            controlIntent = PendingIntent.getService(this, 1, control,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        } else {
            Intent control = new Intent(this, MainActivity.class).setAction(action);
            controlIntent = PendingIntent.getActivity(this, 11, control,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        }

        Intent stop = new Intent(this, CaptureService.class).setAction(ACTION_STOP);
        PendingIntent stopIntent = PendingIntent.getService(this, 2, stop,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_capture_mono)
                .setLargeIcon(brandIcon())
                .setContentTitle(active ? "Captura local activa" : "Captura local pausada")
                .setContentText(active ? "Grabando en el teléfono · sin Internet" : "No se está grabando")
                .setContentIntent(openIntent)
                .setOngoing(true)
                .setCategory(Notification.CATEGORY_SERVICE)
                .addAction(0, active ? "Pausar" : "Reanudar", controlIntent)
                .addAction(0, "Detener", stopIntent)
                .build();
    }

    private Bitmap brandIcon() {
        int size = Math.round(64 * getResources().getDisplayMetrics().density);
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Drawable logo = getDrawable(R.drawable.ic_capture_color);
        logo.setBounds(0, 0, size, size);
        logo.draw(new Canvas(bitmap));
        return bitmap;
    }

    private void createNotificationChannel() {
        NotificationChannel channel = new NotificationChannel(
                CHANNEL, "Captura de audio personal", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("Mantiene visible el estado de la captura local del micrófono");
        channel.setShowBadge(false);
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(channel);
    }

    @Override
    public void onDestroy() {
        stopCapture("detenida");
        if (batteryMonitor != null) batteryMonitor.close();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
