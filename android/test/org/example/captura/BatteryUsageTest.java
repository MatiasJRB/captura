package org.example.captura;

import org.junit.Test;
import java.util.Arrays;
import java.util.ArrayList;
import java.util.List;
import static org.junit.Assert.*;

public class BatteryUsageTest {
    private BatteryUsage.Sample s(int minutes, double percent, boolean plugged, boolean recording) {
        return new BatteryUsage.Sample(minutes * 60_000L, percent, plugged, recording);
    }
    @Test public void calculatesObservedWholePhoneRate() {
        List<BatteryUsage.Sample> samples = new ArrayList<>();
        for (int i = 0; i <= 6; i++) samples.add(s(i * 5, 100 - i, false, i != 6));
        BatteryUsage.Result r = BatteryUsage.calculate(samples);
        assertEquals(30 * 60_000L, r.unpluggedMs); assertEquals(6, r.lostPoints, .001);
        assertEquals(12, r.rate(), .001);
    }
    @Test public void pluggedAndTransitionIntervalsAreExcluded() {
        BatteryUsage.Result r = BatteryUsage.calculate(Arrays.asList(s(0,80,false,true),
            s(5,79,true,true),s(10,81,true,true),s(15,80,false,true),s(20,79,false,false)));
        assertEquals(5 * 60_000L, r.unpluggedMs); assertEquals(1, r.lostPoints,.001);
        assertEquals(15 * 60_000L, r.chargingMs); assertNull(r.rate());
    }
    @Test public void pausedGapsDoNotCount() {
        BatteryUsage.Result r = BatteryUsage.calculate(Arrays.asList(s(0,90,false,true),
            s(5,89,false,false),s(65,80,false,true),s(70,79,false,false)));
        assertEquals(10 * 60_000L, r.recordingMs); assertEquals(2, r.lostPoints,.001);
    }
    @Test public void refusesClockResetAndLongUnobservedGaps() {
        BatteryUsage.Result r = BatteryUsage.calculate(Arrays.asList(s(0,90,false,true),
            s(60,80,false,true),s(1,79,false,false)));
        assertEquals(0, r.unpluggedMs); assertEquals(60 * 60_000L, r.excludedMs); assertNull(r.rate());
    }
    @Test public void refusesUnsupportedPercentAndCalibrationRise() {
        BatteryUsage.Result r = BatteryUsage.calculate(Arrays.asList(s(0,Double.NaN,false,true),
            s(5,80,false,true),s(10,82,false,true),s(15,110,false,false)));
        assertEquals(0, r.intervals); assertEquals(0, r.lostPoints,.001); assertNull(r.rate());
    }
    @Test public void unchangedGaugeIsNotZeroConsumption() {
        List<BatteryUsage.Sample> samples = new ArrayList<>();
        for (int i=0;i<=6;i++) samples.add(s(i*5,100,false,i!=6));
        BatteryUsage.Result r=BatteryUsage.calculate(samples);
        assertNull(r.rate()); assertTrue(r.text().contains("no significa consumo cero"));
    }
    @Test public void sessionWithOnlyOneSampleIsInsufficient() {
        BatteryUsage.Result r=BatteryUsage.calculate(Arrays.asList(s(0,80,false,true)));
        assertNull(r.rate()); assertTrue(r.text().contains("Todavía no hay"));
    }
}
