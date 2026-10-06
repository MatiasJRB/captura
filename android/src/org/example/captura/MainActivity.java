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
    private Button primaryCapture, microphoneControl;
    private boolean showingSettings;
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
        if (CaptureService.ACTION_START.equals(action) || CaptureService.ACTION_LISTEN.equals(action)) {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                startForegroundService(new Intent(this, CaptureService.class)
                        .setAction(action));
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

    private void showOverview() {
        showingSettings = false; setContentView(buildUi()); refreshStatus(); refreshSync();
    }

    @Override public void onBackPressed() {
        if (showingSettings) showOverview(); else super.onBackPressed();
    }

    private View buildUi() {
        batteryStatus = null;
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(24), dp(38), dp(24), dp(44)); root.setBackgroundColor(Color.rgb(17,24,21));
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            // Android 15+ forces edge-to-edge: keep every control above the nav bar.
            view.setPadding(dp(24)+insets.getSystemWindowInsetLeft(), dp(16)+insets.getSystemWindowInsetTop(),
                    dp(24)+insets.getSystemWindowInsetRight(), dp(16)+insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout header = new LinearLayout(this); header.setGravity(Gravity.CENTER_VERTICAL);
        android.widget.ImageView logo = new android.widget.ImageView(this);
        logo.setImageResource(R.mipmap.ic_launcher); logo.setContentDescription("Captura");
        header.addView(logo, new LinearLayout.LayoutParams(dp(44),dp(44)));
        TextView title = new TextView(this); title.setText("Captura"); title.setTextSize(28);
        title.setTextColor(Color.rgb(231,236,232)); title.setPadding(dp(14),0,0,0);
        header.addView(title); root.addView(header);
        status = new TextView(this); status.setTextSize(20); status.setGravity(Gravity.CENTER_VERTICAL);
        status.setPadding(dp(16),dp(20),dp(16),dp(20)); status.setMinHeight(dp(112));
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        LinearLayout.LayoutParams statusParams = new LinearLayout.LayoutParams(-1,-2);
        statusParams.setMargins(0,dp(28),0,dp(10)); root.addView(status,statusParams);
        primaryCapture = button("Grabar"); primaryCapture.setOnClickListener(v -> {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) {
                requestNeededPermissions(); return;
            }
            startForegroundService(new Intent(this,CaptureService.class).setAction(
                    CaptureService.isDictating()?CaptureService.ACTION_DONE:CaptureService.isRecording()?CaptureService.ACTION_PAUSE:CaptureService.ACTION_START));
            status.postDelayed(this::refreshStatus,700);
        });
        primaryCapture.setBackgroundTintList(android.content.res.ColorStateList.valueOf(Color.rgb(161,214,190)));
        primaryCapture.setTextColor(Color.rgb(17,24,21)); root.addView(primaryCapture,buttonParams());
        microphoneControl = button("Activar voz"); microphoneControl.setOnClickListener(v -> {
            if (CaptureService.isMicrophoneActive()) {
                startService(new Intent(this,CaptureService.class).setAction(CaptureService.ACTION_STOP));
            } else {
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) {
                    requestNeededPermissions(); return;
                }
                if (!getSharedPreferences(CaptureService.PREFS,MODE_PRIVATE).getBoolean(VoiceAudioEngine.PREF_ENABLED,false)) {
                    showingSettings=true; setContentView(buildSettingsUi()); refreshStatus(); refreshSync(); return;
                }
                startForegroundService(new Intent(this,CaptureService.class).setAction(CaptureService.ACTION_LISTEN));
            }
            status.postDelayed(this::refreshStatus,700);
        }); root.addView(microphoneControl,buttonParams());
        TextView help = new TextView(this); help.setText("Nota: «Lobo, anotá» → dictá → «Lobo, listo».\nControl: «Lobo, iniciar / pausar captura».");
        help.setTextSize(15); help.setTextColor(Color.rgb(184,197,191));
        LinearLayout.LayoutParams helpParams = new LinearLayout.LayoutParams(-1,-2);
        helpParams.setMargins(0,dp(18),0,0); root.addView(help,helpParams);
        root.addView(new View(this),new LinearLayout.LayoutParams(1,0,1));
        syncStatus = new TextView(this); syncStatus.setTextSize(15); syncStatus.setTextColor(Color.rgb(184,197,191));
        root.addView(syncStatus);
        Button sync = button("Sincronizar ahora"); sync.setOnClickListener(v -> manualSync()); root.addView(sync,buttonParams());
        Button settings = button("Ajustes"); settings.setOnClickListener(v -> {
            showingSettings = true; setContentView(buildSettingsUi()); refreshStatus(); refreshSync();
        }); root.addView(settings,buttonParams());
        return root;
    }

    private View buildSettingsUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(28), dp(46), dp(28), dp(28));
        root.setBackgroundColor(Color.rgb(17, 24, 21));

        TextView title = new TextView(this);
        title.setText("Captura");
        title.setTextSize(30);
        title.setTextColor(Color.rgb(231, 236, 232));
        root.addView(title);

        title.setText("Ajustes");
        Button back = button("Volver a Captura");
        back.setOnClickListener(v -> showOverview()); root.addView(back, buttonParams());
        LinearLayout.LayoutParams textParams = new LinearLayout.LayoutParams(-1, -2);
        textParams.setMargins(0, dp(18), 0, dp(24));

        CheckBox voice = new CheckBox(this);
        boolean modelAvailable = VoiceAudioEngine.modelPackaged(this);
        voice.setText(modelAvailable ? "Voz local: decí «Lobo» · la pausa mantiene la escucha"
                : "Comandos por voz: esta versión no incluye el modelo local");
        voice.setChecked(getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .getBoolean(VoiceAudioEngine.PREF_ENABLED, false));
        voice.setEnabled(modelAvailable);
        voice.setOnClickListener(v -> {
            if (isCaptureServiceRunning()) {
                voice.setChecked(!voice.isChecked());
                new AlertDialog.Builder(this).setMessage("Detené Captura por completo antes de cambiar el modo de micrófono.")
                        .setPositiveButton("Entendido", null).show();
                return;
            }
            getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE).edit()
                    .putBoolean(VoiceAudioEngine.PREF_ENABLED, voice.isChecked()).apply();
        });
        root.addView(voice, textParams);
        Button listen = button("Escuchar comandos sin guardar audio");
        listen.setEnabled(modelAvailable);
        listen.setOnClickListener(v -> {
            if (!getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                    .getBoolean(VoiceAudioEngine.PREF_ENABLED, false)) {
                new AlertDialog.Builder(this).setMessage("Habilitá primero los comandos por voz locales.")
                        .setPositiveButton("Entendido", null).show(); return;
            }
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestNeededPermissions(); return;
            }
            startForegroundService(new Intent(this, CaptureService.class)
                    .setAction(CaptureService.isRecording() ? CaptureService.ACTION_PAUSE : CaptureService.ACTION_LISTEN));
        });
        root.addView(listen, buttonParams());

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
            if (!showingSettings) {
                syncStatus.setText((account.isEmpty()?"Drive sin vincular": "Drive vinculado")
                    + " · " + queue.count("pending") + " por subir"
                    + (queue.count("review") > 0 ? " · " + queue.count("review") + " para revisar" : ""));
                return;
            }
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
        if (status == null) return;
        String value = getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE)
                .getString(CaptureService.KEY_STATE, "detenida");
        boolean recording = CaptureService.isRecording();
        boolean interrupted = "grabando".equals(value) && !recording;
        String message = CaptureService.isDictating() ? "Dictando nota\nDecí Lobo, listo · máximo 60 segundos" : recording ? "Grabando\nGuarda audio en el teléfono"
                : CaptureService.isListening() ? "Escuchando a Lobo\nMicrófono activo · no guarda audio"
                : "preparando_voz".equals(value) ? "Activando micrófono…\nEsperá un momento"
                : "error_voz".equals(value) ? "Micrófono apagado\n" + voiceErrorHelp()
                : interrupted || "escuchando".equals(value) ? "! Captura interrumpida\nAbrí la escucha o tocá reanudar"
                : "error".equals(value) ? "! Error de micrófono\nRevisá permisos y el indicador"
                : "pausada".equals(value) ? "Ⅱ Captura pausada\nMicrófono apagado · tocá reanudar"
                : "Micrófono apagado\nTocá Grabar o Activar voz";
        String noteResult = getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE).getString("note_result", "");
        if (!CaptureService.isDictating() && "saved".equals(noteResult)) message += "\nÚltima nota guardada en el teléfono";
        if (!CaptureService.isDictating() && "interrupted".equals(noteResult)) message += "\nNota interrumpida · revisá el audio";
        if (!message.contentEquals(status.getText())) status.setText(message);
        if (!showingSettings && primaryCapture != null) {
            primaryCapture.setText(CaptureService.isDictating() ? "Guardar nota" : recording ? "Pausar captura" : CaptureService.isListening() ? "Grabar" : "preparando_voz".equals(value) ? "Activando…" : "Grabar");
            boolean preparing = "preparando_voz".equals(value);
            primaryCapture.setEnabled(!preparing); microphoneControl.setEnabled(!preparing);
            microphoneControl.setText(CaptureService.isMicrophoneActive() ? "Apagar micrófono" : "Activar voz");
        }
        if (CaptureService.hasIncompleteChunk(this))
            status.append("\n! Hay un archivo incompleto conservado. No se subirá automáticamente.");
        status.setTextColor(recording ? Color.rgb(255, 181, 166) : Color.rgb(205, 224, 211));
        status.setBackgroundColor(recording ? Color.rgb(65, 36, 31) : Color.rgb(35, 49, 41));
        android.graphics.drawable.Drawable icon = getDrawable(recording ? R.drawable.ic_capture_mono
                : CaptureService.isListening() ? R.drawable.ic_voice_paused : R.drawable.ic_voice_stopped);
        icon.setTint(recording ? Color.rgb(255, 181, 166) : Color.rgb(205, 224, 211));
        icon.setBounds(0, 0, dp(36), dp(36));
        status.setCompoundDrawables(icon, null, null, null); status.setCompoundDrawablePadding(dp(16));
    }

    private String voiceErrorHelp() {
        String error = getSharedPreferences(CaptureService.PREFS, MODE_PRIVATE).getString("voice_error", "unknown");
        if ("microphone_silenced".equals(error)) return "Android silenció el micrófono. Revisá llamadas y tocá Activar voz.";
        if ("microphone_permission".equals(error)) return "Falta permiso. Tocá Activar voz para revisarlo.";
        if ("voice_model".equals(error)) return "Falló el modelo local. Tocá Activar voz para reintentar.";
        return "Tocá Activar voz para reintentar.";
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
