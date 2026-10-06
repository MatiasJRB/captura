package org.example.captura;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.SystemClock;
import java.io.File;
import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import org.vosk.Model;
import org.vosk.Recognizer;

/** A single mic; paused PCM goes only to the local recognizer and is discarded. */
final class VoiceAudioEngine {
    static final String PREF_ENABLED = "voice_commands";
    interface Listener {
        void ready();
        void command(VoiceCommands.Command command);
        void failed(String reason);
    }
    private final Context context;
    private final Handler main;
    private final Listener listener;
    private volatile boolean stopping;
    private volatile AudioRecord microphone;
    private PcmAacWriter writer;
    private final Object outputLock = new Object();

    VoiceAudioEngine(Context context, Handler main, Listener listener) {
        this.context = context; this.main = main; this.listener = listener;
    }

    static boolean modelPackaged(Context context) {
        try (InputStream ignored = context.getAssets().open("voice-model/am/final.mdl")) {
            return true;
        } catch (IOException error) { return false; }
    }

    void start() { new Thread(this::run, "capture-local-commands").start(); }

    void startFile(FileDescriptor fd) throws IOException {
        synchronized (outputLock) {
            if (stopping || writer != null) throw new IOException("Entrada no disponible");
            writer = new PcmAacWriter(fd);
        }
    }

    boolean finishFile() {
        synchronized (outputLock) {
            if (writer == null) return false;
            PcmAacWriter previous = writer; writer = null;
            try { previous.close(); return true; } catch (Exception error) { return false; }
        }
    }

    void stop() {
        stopping = true;
        AudioRecord current = microphone;
        if (current != null) try { current.stop(); } catch (RuntimeException ignored) { }
        // Release occurs on the reader thread, after any blocking read returns.
    }

    private void run() {
        AudioRecord input = null;
        String failureReason = "voice_model";
        try {
            File directory = new File(context.getNoBackupFilesDir(), "voice-model-v1");
            File complete = new File(directory, ".complete");
            if (!complete.isFile()) {
                copyAsset("voice-model", directory);
                Files.write(complete.toPath(), new byte[]{1});
            }
            if (stopping) return;
            try (Model model = new Model(directory.getAbsolutePath());
                 Recognizer recognizer = new Recognizer(model, 16000, VoiceCommands.GRAMMAR)) {
                recognizer.setWords(true);
                failureReason = "microphone_unavailable";
                int minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT);
                if (minimum <= 0) throw new IOException("Micrófono no admite 16 kHz");
                input = new AudioRecord(MediaRecorder.AudioSource.MIC, 16000,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                        Math.max(minimum, 16_000));
                if (input.getState() != AudioRecord.STATE_INITIALIZED)
                    throw new IOException("Micrófono no disponible");
                microphone = input;
                if (stopping) return;
                input.startRecording();
                failureReason = "microphone_interrupted";
                if (input.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
                    throw new IOException("Micrófono no pudo iniciar");
                main.post(() -> { if (!stopping) listener.ready(); });
                byte[] pcm = new byte[3200]; // 100 ms; no persistent paused buffer.
                VoiceCommands commands = new VoiceCommands();
                while (!stopping) {
                    int count = input.read(pcm, 0, pcm.length, AudioRecord.READ_BLOCKING);
                    if (stopping) break;
                    android.media.AudioRecordingConfiguration configuration = input.getActiveRecordingConfiguration();
                    if (configuration != null && configuration.isClientSilenced())
                        throw new VoiceFailure("microphone_silenced");
                    if (count <= 0 || (count & 1) != 0) throw new IOException("Entrada interrumpida");
                    synchronized (outputLock) {
                        if (writer != null) writer.write(pcm, count);
                    }
                    if (recognizer.acceptWaveForm(pcm, count)) {
                        VoiceCommands.Command command = commands.accept(recognizer.getResult(),
                                SystemClock.elapsedRealtime());
                        if (command != VoiceCommands.Command.NONE)
                            main.post(() -> { if (!stopping) listener.command(command); });
                    }
                }
            }
        } catch (Exception | LinkageError error) {
            String reason = error instanceof VoiceFailure ? error.getMessage()
                    : error instanceof SecurityException ? "microphone_permission" : failureReason;
            if (!stopping) main.post(() -> { if (!stopping) listener.failed(reason); });
        } finally {
            microphone = null;
            if (input != null) {
                try { input.stop(); } catch (RuntimeException ignored) { }
                input.release();
            }
        }
    }

    private static final class VoiceFailure extends IOException {
        VoiceFailure(String reason) { super(reason); }
    }

    private void copyAsset(String path, File target) throws IOException {
        if (stopping) throw new IOException("Cancelado");
        String[] children = context.getAssets().list(path);
        if (children != null && children.length > 0) {
            if (!target.isDirectory() && !target.mkdirs()) throw new IOException("Sin espacio para modelo");
            for (String child : children) copyAsset(path + "/" + child, new File(target, child));
        } else {
            try (InputStream source = context.getAssets().open(path);
                 OutputStream dest = Files.newOutputStream(target.toPath())) {
                byte[] buffer = new byte[8192]; int count;
                while ((count = source.read(buffer)) != -1) {
                    if (stopping) throw new IOException("Cancelado");
                    dest.write(buffer, 0, count);
                }
            }
        }
    }
}
