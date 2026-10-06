package org.example.captura;
import java.util.Locale;
import org.json.JSONArray;
import org.json.JSONObject;
/** Live local microphone final results only. Never feed recorded text into this class. */
public final class VoiceCommands {
    public enum Command { NONE, PAUSE, START, STOP, NOTE, DONE }
    // Lobot is absent from this Spanish model. Vosk drops OOV grammar words.
    // Every command requires Lobo in the SAME utterance, not a global wake window.
    public static final String GRAMMAR = "[\"lobo pausar captura\",\"lobo iniciar captura\","
            + "\"lobo empezar captura\",\"lobo reanudar captura\",\"lobo detener por completo\",\"lobo anota\",\"lobo listo\",\"[unk]\"]";
    private long lastAccepted = -10_000;
    private Command lastCommand = Command.NONE;
    public Command accept(String finalJson, long elapsedMs) {
        try {
            JSONObject data = new JSONObject(finalJson);
            String text = data.optString("text", "").trim().toLowerCase(Locale.ROOT);
            Command command;
            switch (text) {
                case "lobo anota": command = Command.NOTE; break;
                case "lobo listo": command = Command.DONE; break;
                case "lobo pausar captura": command = Command.PAUSE; break;
                case "lobo iniciar captura": case "lobo empezar captura": case "lobo reanudar captura": command = Command.START; break;
                case "lobo detener por completo": command = Command.STOP; break;
                default: return Command.NONE;
            }
            JSONArray words = data.optJSONArray("result");
            if (words == null || words.length() != text.split(" ").length) return Command.NONE;
            StringBuilder joined = new StringBuilder();
            for (int i=0; i<words.length(); i++) {
                JSONObject word = words.getJSONObject(i); double confidence = word.optDouble("conf",-1);
                if (!Double.isFinite(confidence) || confidence < (i==0 ? .90 : .85) || confidence > 1) return Command.NONE;
                if (i>0) joined.append(' '); joined.append(word.getString("word"));
            }
            if (!joined.toString().equals(text) || command==lastCommand && elapsedMs-lastAccepted<1500) return Command.NONE;
            lastAccepted=elapsedMs; lastCommand=command; return command;
        } catch (Exception ignored) { return Command.NONE; }
    }
}
