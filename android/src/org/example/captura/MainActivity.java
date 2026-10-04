package org.example.captura;

import android.Manifest;
import android.accounts.AccountManager;
import android.app.AlertDialog;
import android.content.IntentSender;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.os.Handler;
import android.os.Looper;
import android.widget.CheckBox;
import android.widget.ScrollView;
import com.google.android.gms.auth.api.identity.AuthorizationResult;
import com.google.android.gms.auth.api.identity.Identity;
import android.app.Activity;
import android.app.ActivityManager;
import android.app.KeyguardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static final int PERMISSION_REQUEST = 41;
    private TextView status, syncStatus, batteryStatus;
    private long lastBatteryRefresh = -30_000L;
    private static final int ACCOUNT_PICKER = 51, DRIVE_AUTH = 52;
    private String authorizingAccount;
    private final Handler uiHandler = new Handler(Looper.getMainLooper());
    private final Runnable updateSync = new Runnable() {
        @Override public void run() { refreshStatus(); refreshSync(); refreshBattery(); uiHandler.postDelayed(this, 1500); }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        authorizingAccount = state == null ? null : state.getString("authorizing_account");
        setContentView(buildUi());
        requestNeededPermissions();
    }

    @Override
    protected void onPostResume() {
        super.onPostResume();
        String action = getIntent().getAction();
        getIntent().setAction(null);
        if (CaptureService.ACTION_START.equals(action)) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                startForegroundService(new Intent(this, CaptureService.class)
                        .setAction(CaptureService.ACTION_START));
                status.postDelayed(this::refreshStatus, 700);
            }
        } else {
            recoverExpectedCapture();
        }
        refreshStatus();
        uiHandler.removeCallbacks(updateSync); uiHandler.post(updateSync);
    }

    @Override protected void onPause() { uiHandler.removeCallbacks(updateSync); super.onPause(); }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(requestCode, permissions, grants);
        refreshStatus();
    }

    private View buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(28), dp(46), dp(28), dp(28));
        root.setBackgroundColor(Color.rgb(17, 24, 21));

        TextView title = new TextView(this);
        title.setText("Captura");
        title.setTextSize(30);
        title.setTextColor(Color.rgb(231, 236, 232));
        root.addView(title);

        TextView explanation = new TextView(this);
        explanation.setText("Grabás al tocar «Iniciar / reanudar» o el botón rápido «Captura». Sigue con la pantalla apagada y guarda tramos de 15 minutos. Wi-Fi, Drive y USB no encienden el micrófono. Pausar lo apaga; para volver, tocá reanudar. Después de reiniciar el teléfono, abrí la app y revisá el estado.");
        explanation.setTextSize(17);
        explanation.setTextColor(Color.rgb(184, 197, 191));
        LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(-1, -2);
        textParams.setMargins(0, dp(18), 0, dp(24));
        root.addView(explanation, textParams);

        status = new TextView(this);
        status.setTextSize(19);
        status.setGravity(Gravity.CENTER_VERTICAL);
        status.setPadding(dp(18), dp(18), dp(18), dp(18));
        status.setMinHeight(dp(86));
        root.addView(status, new LinearLayout.LayoutParams(-1, -2));

        Button start = button("Iniciar / reanudar");
        start.setOnClickListener(v -> {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestNeededPermissions();
                return;
            }
            Intent intent = new Intent(this, CaptureService.class).setAction(CaptureService.ACTION_START);
            startForegroundService(intent);
            status.postDelayed(this::refreshStatus, 700);
        });
        root.addView(start, buttonParams());

        Button pause = button("Pausar");
        pause.setOnClickListener(v -> {
            startService(new Intent(this, CaptureService.class).setAction(CaptureService.ACTION_PAUSE));
            status.postDelayed(this::refreshStatus, 400);
        });
        root.addView(pause, buttonParams());

        Button stop = button("Detener por completo");
        stop.setOnClickListener(v -> {
            startService(new Intent(this, CaptureService.class).setAction(CaptureService.ACTION_STOP));
            status.postDelayed(this::refreshStatus, 400);
        });
        root.addView(stop, buttonParams());

        Button settings = button("Abrir ajustes de batería");
        settings.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)));
        root.addView(settings, buttonParams());

        TextView storage = new TextView(this);
        storage.setText("Archivos: Música/PersonalCapture\nFormato: M4A, voz mono, ~260 MB por día si graba sin pausa.");
        storage.setTextSize(15);
        storage.setTextColor(Color.rgb(184, 197, 191));
        LinearLayout.LayoutParams storageParams = new LinearLayout.LayoutParams(-1, -2);
        storageParams.setMargins(0, dp(24), 0, 0);
        root.addView(storage, storageParams);
        TextView batteryHeading = new TextView(this);
        batteryHeading.setText("Batería durante la grabación"); batteryHeading.setTextSize(21);
        root.addView(batteryHeading, storageParams);
        batteryStatus = new TextView(this); batteryStatus.setTextSize(15);
        root.addView(batteryStatus, textParams);
        Button batteryHistory = button("Ver últimas 10 grabaciones");
        batteryHistory.setOnClickListener(v -> {
            try (BatteryMonitor monitor = new BatteryMonitor(this, uiHandler)) {
                new AlertDialog.Builder(this).setTitle("Registro local de batería")
                    .setMessage(monitor.history(10)).setPositiveButton("Cerrar", null).show();
            } catch (RuntimeException error) {
                batteryStatus.setText("No se pudo leer el registro de batería. La grabación no se detiene.");
            }
        });
        root.addView(batteryHistory, buttonParams());
        TextView batteryNote = new TextView(this);
        batteryNote.setText("Se mide sola al grabar, cada 5 minutos y al pausar. Es la descarga de todo el teléfono, no el gasto exclusivo de Captura. Excluye cargador y pausas; necesita 30 minutos sin cargador para estimar por hora. Datos locales, sin permisos nuevos ni envíos.");
        batteryNote.setTextSize(14); batteryNote.setTextColor(Color.rgb(184, 197, 191));
        root.addView(batteryNote, textParams);
        TextView heading = new TextView(this);
        heading.setText("Sincronización privada con Drive"); heading.setTextSize(21);
        root.addView(heading, storageParams);
        syncStatus = new TextView(this); syncStatus.setTextSize(15);
        root.addView(syncStatus, textParams);
        Button connect = button("Vincular / reconectar Drive");
        connect.setOnClickListener(v -> connectDrive()); root.addView(connect, buttonParams());
        CheckBox automatic = new CheckBox(this);
        automatic.setText("Sincronizar automáticamente por Wi-Fi");
        automatic.setChecked(SyncConfig.automatic(this));
        automatic.setOnCheckedChangeListener((button, checked) -> {
            if (checked && !SyncConfig.connected(this)) { button.setChecked(false); SyncConfig.message(this,"Primero vinculá Google Drive."); refreshSync(); return; }
            if (checked) new AlertDialog.Builder(this).setTitle("Activar Wi-Fi automático")
                .setMessage("Subirá los audios M4A finalizados de Captura a Google Drive, en la cuenta " + SyncConfig.prefs(this).getString("account", "") + " y la carpeta «" + SyncConfig.FOLDER_NAME + "». No comparte la carpeta ni borra originales. Puede incluir conversaciones y audio de fondo: grabá sólo con consentimiento de los participantes.")
                .setPositiveButton("Activar", (d,w) -> { SyncConfig.prefs(this).edit().putBoolean("automatic",true).apply(); SyncScheduler.automatic(this); refreshSync(); })
                .setNegativeButton("Cancelar", (d,w) -> button.setChecked(false)).setOnCancelListener(d -> button.setChecked(false)).show();
            else { SyncConfig.prefs(this).edit().putBoolean("automatic",false).apply(); SyncScheduler.disable(this); }
        });
        root.addView(automatic);
        Button sync = button("Sincronizar ahora"); sync.setOnClickListener(v -> manualSync()); root.addView(sync, buttonParams());
        Button cancelSync = button("Cancelar envíos y apagar automático");
        cancelSync.setOnClickListener(v -> {
            automatic.setChecked(false);
            SyncConfig.prefs(this).edit().putBoolean("automatic",false).apply();
            SyncScheduler.cancelAll(this);
            SyncConfig.message(this,"Envíos cancelados. Cola y originales conservados; podés reintentar después.");
            refreshSync();
        }); root.addView(cancelSync, buttonParams());
        TextView note = new TextView(this);
        note.setText("Sin Internet: los audios esperan en el teléfono. Sincronizar ahora permite Wi-Fi o datos móviles por 30 minutos y guarda el tramo actual sin detener la grabación. No transcribe ni ejecuta instrucciones en el teléfono."); note.setTextSize(14);
        root.addView(note, storageParams);
        ScrollView scroll = new ScrollView(this); scroll.addView(root);
        return scroll;
    }

    private void connectDrive() {
        String account = SyncConfig.prefs(this).getString("account", "");
        if (!account.isEmpty()) { authorizingAccount = account; authorizeDrive(); return; }
        startActivityForResult(AccountManager.newChooseAccountIntent(null, null,
                new String[]{"com.google"}, "Elegí la cuenta para los audios privados de Captura", null, null, null), ACCOUNT_PICKER);
    }

    @Override protected void onSaveInstanceState(Bundle state) { state.putString("authorizing_account",authorizingAccount); super.onSaveInstanceState(state); }

    private void authorizeDrive() {
        SyncConfig.message(this, "Esperando autorización de Google…"); refreshSync();
        Identity.getAuthorizationClient(this).authorize(SyncConfig.request(authorizingAccount))
            .addOnSuccessListener(result -> {
                if (result.hasResolution()) {
                    try { startIntentSenderForResult(result.getPendingIntent().getIntentSender(), DRIVE_AUTH, null, 0, 0, 0); }
                    catch (IntentSender.SendIntentException e) { SyncConfig.message(this,"No se pudo abrir la autorización de Google."); }
                } else connectedDrive(result);
            }).addOnFailureListener(e -> { SyncConfig.message(this,"Google no autorizó la conexión. Revisá el registro OAuth de la app y volvé a intentar."); refreshSync(); });
    }

    private void connectedDrive(AuthorizationResult result) {
        if (result.getAccessToken() == null || !result.getGrantedScopes().contains(SyncConfig.SCOPE)) {
            SyncConfig.message(this,"Falta conceder permiso para los archivos de Captura en Drive."); return;
        }
        SyncConfig.prefs(this).edit().putString("account",authorizingAccount).commit();
        SyncConfig.message(this,"Drive vinculado. Activá Wi-Fi automático o elegí Sincronizar ahora."); refreshSync();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request,result,data);
        if (result != RESULT_OK || data == null) { if(request==DRIVE_AUTH) SyncConfig.message(this,"Autorización cancelada; no se subió ningún audio."); return; }
        if(request==ACCOUNT_PICKER) {
            authorizingAccount=data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME);
            if(authorizingAccount!=null) authorizeDrive();
        } else if(request==DRIVE_AUTH) {
            try { connectedDrive(Identity.getAuthorizationClient(this).getAuthorizationResultFromIntent(data)); }
            catch(Exception e) { SyncConfig.message(this,"La autorización de Google no se completó."); }
        }
    }

    private void manualSync() {
        if (!SyncConfig.connected(this)) { SyncConfig.message(this,"Primero vinculá Google Drive."); refreshSync(); return; }
        ConnectivityManager network=getSystemService(ConnectivityManager.class);
        NetworkCapabilities caps=network.getNetworkCapabilities(network.getActiveNetwork());
        boolean wifi=caps!=null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
        String connection=caps==null?"No hay conexión: el pedido esperará hasta 30 minutos.":wifi?"Usará Wi-Fi.":"Usará datos móviles / la red disponible. Puede consumir tu plan de datos.";
        new AlertDialog.Builder(this).setTitle("Sincronizar ahora")
            .setMessage("Subir los audios de Captura a «"+SyncConfig.FOLDER_NAME+"», cuenta "+SyncConfig.prefs(this).getString("account","")+". "+connection+" Si estás grabando, guarda el tramo y continúa. Si está pausada, no prende el micrófono. Conserva los originales. No ejecuta lo que se dice en los audios.")
            .setPositiveButton(wifi?"Sincronizar":"Permitir red disponible",(d,w)->{
                if(CaptureService.isRecording()) startService(new Intent(this,CaptureService.class).setAction(CaptureService.ACTION_FLUSH));
                else SyncScheduler.manual(this);
                refreshSync();
            }).setNegativeButton("Cancelar",null).show();
    }

    private void refreshSync() {
        if(syncStatus==null) return;
        try(SyncQueue queue=new SyncQueue(this)) {
            queue.discover();
            String account=SyncConfig.prefs(this).getString("account","");
            syncStatus.setText((account.isEmpty()?"Drive todavía no vinculado":account+" · "+SyncConfig.FOLDER_NAME)
                +"\n"+queue.count("pending")+" pendientes · "+queue.count("uploaded")+" sincronizados · "+queue.count("review")+" para revisar"
                +"\n"+SyncConfig.prefs(this).getString("message","Originales conservados; sincronización automática apagada."));
        } catch(Exception e) { syncStatus.setText("No se pudo leer la cola. Los originales siguen en el teléfono."); }
    }

    private void refreshBattery() {
        long now = android.os.SystemClock.elapsedRealtime();
        if (batteryStatus == null || now - lastBatteryRefresh < 30_000L) return;
        lastBatteryRefresh = now;
        try (BatteryMonitor monitor = new BatteryMonitor(this, uiHandler)) {
            String text = monitor.latest();
            if (getSharedPreferences("battery_measurement", MODE_PRIVATE).getBoolean("failed", false))
                text += "\nAlguna muestra no pudo guardarse. El registro puede estar incompleto.";
            batteryStatus.setText(text);
        } catch (RuntimeException error) {
            batteryStatus.setText("No se pudo leer el registro de batería. La grabación no se detiene.");
        }
    }

    private void requestNeededPermissions() {
        boolean microphoneGranted = checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
        boolean notificationsGranted = android.os.Build.VERSION.SDK_INT < 33
                || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED;
        if (microphoneGranted && notificationsGranted) return;
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO, Manifest.permission.POST_NOTIFICATIONS}, PERMISSION_REQUEST);
        } else {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, PERMISSION_REQUEST);
        }
    }

    private void refreshStatus() {
        String value = getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .getString(CaptureService.KEY_STATE, "detenida");
        boolean recording = CaptureService.isRecording();
        boolean interrupted = "grabando".equals(value) && !recording;
        status.setText(recording ? "● Grabando en el teléfono\nSigue con la pantalla apagada" : interrupted ? "! Captura interrumpida\nTocá reanudar y revisá el indicador" : "error".equals(value) ? "! Error de micrófono\nRevisá permisos y el indicador" : "pausada".equals(value) ? "Ⅱ Captura pausada\nNo está grabando · tocá reanudar" : "○ Captura detenida\nNo está grabando · tocá iniciar");
        status.setTextColor(recording ? Color.rgb(255, 181, 166) : Color.rgb(205, 224, 211));
        status.setBackgroundColor(recording ? Color.rgb(65, 36, 31) : Color.rgb(35, 49, 41));
    }

    private void recoverExpectedCapture() {
        String expected = getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .getString(CaptureService.KEY_STATE, "detenida");
        KeyguardManager keyguard = (KeyguardManager) getSystemService(KEYGUARD_SERVICE);
        if ("grabando".equals(expected)
                && !isCaptureServiceRunning()
                && !keyguard.isKeyguardLocked()
                && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startForegroundService(new Intent(this, CaptureService.class).setAction(CaptureService.ACTION_START));
            status.postDelayed(this::refreshStatus, 700);
        }
    }

    private boolean isCaptureServiceRunning() {
        ActivityManager manager = (ActivityManager) getSystemService(ACTIVITY_SERVICE);
        for (ActivityManager.RunningServiceInfo service : manager.getRunningServices(Integer.MAX_VALUE)) {
            if (CaptureService.class.getName().equals(service.service.getClassName())) return true;
        }
        return false;
    }

    private Button button(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setTextSize(17);
        button.setAllCaps(false);
        return button;
    }

    private LinearLayout.LayoutParams buttonParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, dp(58));
        params.setMargins(0, dp(14), 0, 0);
        return params;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
