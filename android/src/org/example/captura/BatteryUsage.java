package org.example.captura;

import java.util.List;
import java.util.Locale;

/** Observed whole-phone discharge, never per-app attribution. No Android dependency. */
final class BatteryUsage {
    static final long MAX_GAP_MS = 12 * 60_000L;
    static final long MIN_RATE_MS = 30 * 60_000L;

    static final class Sample {
        final long elapsedMs;
        final double percent;
        final boolean plugged, recording;
        Sample(long elapsedMs, double percent, boolean plugged, boolean recording) {
            this.elapsedMs = elapsedMs; this.percent = percent;
            this.plugged = plugged; this.recording = recording;
        }
    }

    static final class Result {
        long recordingMs, unpluggedMs, chargingMs, excludedMs;
        double lostPoints;
        int intervals;
        Double rate() {
            return unpluggedMs >= MIN_RATE_MS && lostPoints > 0
                    ? lostPoints * 3_600_000d / unpluggedMs : null;
        }
        String text() {
            String base = String.format(Locale.forLanguageTag("es-AR"),
                    "Grabación medida: %d min · sin cargador: %d min\n", recordingMs / 60_000, unpluggedMs / 60_000);
            if (intervals == 0) base += "Todavía no hay intervalos válidos sin cargador.";
            else {
                base += String.format(Locale.forLanguageTag("es-AR"), "Bajó %.1f puntos de batería", lostPoints);
                Double rate = rate();
                base += rate == null ? " · estimación por hora aún insuficiente."
                        : String.format(Locale.forLanguageTag("es-AR"), " · ~%.1f puntos por hora.", rate);
                if (lostPoints == 0) base += " El indicador no cambió; no significa consumo cero.";
            }
            if (chargingMs > 0) base += "\nLos tramos con cargador no cuentan como descarga.";
            if (excludedMs > 0) base += "\nHay intervalos sin medición fiable; no se extrapolan.";
            return base;
        }
    }

    static Result calculate(List<Sample> samples) {
        Result result = new Result();
        for (int i = 1; i < samples.size(); i++) {
            Sample a = samples.get(i - 1), b = samples.get(i);
            long dt = b.elapsedMs - a.elapsedMs;
            if (!a.recording || dt <= 0) continue;
            if (dt > MAX_GAP_MS) { result.excludedMs += dt; continue; }
            result.recordingMs += dt;
            if (a.plugged || b.plugged) { result.chargingMs += dt; continue; }
            if (!Double.isFinite(a.percent) || !Double.isFinite(b.percent)
                    || a.percent < 0 || a.percent > 100 || b.percent < 0 || b.percent > 100
                    || b.percent > a.percent) { result.excludedMs += dt; continue; }
            result.unpluggedMs += dt;
            result.lostPoints += a.percent - b.percent;
            result.intervals++;
        }
        return result;
    }
}
