package org.example.captura;

import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.content.ComponentName;
import android.content.Context;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.PersistableBundle;

final class SyncScheduler {
    static final int AUTO=1301, MANUAL=1302, PERIODIC=1303;
    static void automatic(Context c) {
        if(!SyncConfig.connected(c) || !SyncConfig.automatic(c)) return;
        JobScheduler jobs=c.getSystemService(JobScheduler.class);
        if(jobs.getPendingJob(AUTO)==null) jobs.schedule(wifi(c,AUTO).setBackoffCriteria(30000,JobInfo.BACKOFF_POLICY_EXPONENTIAL).build());
        if(jobs.getPendingJob(PERIODIC)==null) jobs.schedule(wifi(c,PERIODIC).setPeriodic(15*60*1000L).setPersisted(true).build());
    }
    private static JobInfo.Builder wifi(Context c,int id) {
        NetworkRequest network=new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build();
        return new JobInfo.Builder(id,new ComponentName(c,SyncJobService.class)).setRequiredNetwork(network).setRequiresBatteryNotLow(true);
    }
    static void manual(Context c) {
        if(!SyncConfig.connected(c)) { SyncConfig.message(c,"Primero vinculá Google Drive."); return; }
        PersistableBundle extras=new PersistableBundle(); extras.putBoolean("manual",true); extras.putLong("requested_at",System.currentTimeMillis());
        c.getSystemService(JobScheduler.class).schedule(new JobInfo.Builder(MANUAL,new ComponentName(c,SyncJobService.class))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setMinimumLatency(0)
                .setExtras(extras).setBackoffCriteria(30000,JobInfo.BACKOFF_POLICY_EXPONENTIAL).build());
        SyncConfig.message(c,"Pedido manual en cola · permite datos móviles durante 30 minutos.");
    }
    static void disable(Context c) {
        JobScheduler jobs=c.getSystemService(JobScheduler.class); jobs.cancel(AUTO); jobs.cancel(PERIODIC);
    }
    static void cancelAll(Context c) { disable(c); c.getSystemService(JobScheduler.class).cancel(MANUAL); }
}
