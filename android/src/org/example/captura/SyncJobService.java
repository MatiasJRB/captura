package org.example.captura;

import android.app.job.JobParameters;
import android.app.job.JobService;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import com.google.android.gms.auth.api.identity.AuthorizationResult;
import com.google.android.gms.auth.api.identity.Identity;
import com.google.android.gms.tasks.Tasks;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;

public final class SyncJobService extends JobService {
    private final ExecutorService executor=Executors.newSingleThreadExecutor();
    private final Map<Integer,Run> runs=new ConcurrentHashMap<>();
    @Override public boolean onStartJob(JobParameters p) {
        Run run=new Run(p); runs.put(p.getJobId(),run);
        executor.execute(()->{
            boolean retry=false;
            try { retry=run.upload(); }
            catch(Stopped ignored) { retry=run.retryAllowed(); }
            catch(Exception e) { SyncConfig.message(this,"No se pudo sincronizar. Los audios siguen en el teléfono. Reintentá o revisá la conexión a Google."); retry=run.retryAllowed(); }
            finally { runs.remove(p.getJobId(),run); if(!run.stopped) jobFinished(p,retry); }
        });
        return true;
    }
    @Override public boolean onStopJob(JobParameters p) {
        Run r=runs.get(p.getJobId()); if(r!=null) r.stop();
        return r!=null && r.retryAllowed();
    }
    @Override public void onDestroy() { for(Run r:runs.values()) r.stop(); executor.shutdownNow(); super.onDestroy(); }
    private static final class Stopped extends Exception { }
    private final class Run implements DriveApi.Cancel,DriveApi.Transport {
        final JobParameters params; final boolean manual; final long requestedAt;
        volatile boolean stopped; volatile HttpURLConnection connection;
        Run(JobParameters p) { params=p; manual=p.getExtras().getBoolean("manual"); requestedAt=p.getExtras().getLong("requested_at"); }
        void stop() { stopped=true; HttpURLConnection c=connection; if(c!=null) c.disconnect(); }
        boolean retryAllowed() { return manual ? System.currentTimeMillis()-requestedAt<SyncPolicy.MANUAL_WINDOW_MS : SyncConfig.automatic(SyncJobService.this); }
        Network network() { return params.getNetwork(); }
        @Override public void check() throws Exception {
            ConnectivityManager manager=getSystemService(ConnectivityManager.class);
            NetworkCapabilities caps=manager.getNetworkCapabilities(network());
            boolean online=caps!=null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
            boolean wifi=caps!=null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
            if(stopped || !SyncPolicy.allowed(manual,wifi,online,requestedAt,System.currentTimeMillis())
                    || (!manual && !SyncConfig.automatic(SyncJobService.this))) throw new Stopped();
        }
        boolean upload() throws Exception {
            if(!SyncConfig.connected(SyncJobService.this)) return false;
            check();
            String account=SyncConfig.prefs(SyncJobService.this).getString("account","");
            AuthorizationResult auth;
            try { auth=Tasks.await(Identity.getAuthorizationClient(SyncJobService.this).authorize(SyncConfig.request(account)),60,TimeUnit.SECONDS); }
            catch(Exception e) { SyncConfig.message(SyncJobService.this,"Google requiere autorización. Tocá Vincular / reconectar Drive."); return false; }
            if(auth.hasResolution() || auth.getAccessToken()==null || !auth.getGrantedScopes().contains(SyncConfig.SCOPE)) { SyncConfig.message(SyncJobService.this,"Google requiere autorización. Tocá Vincular / reconectar Drive."); return false; }
            DriveApi api=new DriveApi(auth.getAccessToken(),this);
            String folder=SyncConfig.prefs(SyncJobService.this).getString("folder_id","");
            if(folder.isEmpty()) { folder=api.generateId(); if(!SyncConfig.prefs(SyncJobService.this).edit().putString("folder_id",folder).commit()) throw new java.io.IOException("config-not-persisted"); }
            api.ensureFolder(folder,SyncConfig.deviceId(SyncJobService.this));
            long deadline=System.currentTimeMillis()+5*60*1000L;
            try(SyncQueue queue=new SyncQueue(SyncJobService.this)) {
                queue.discover();
                for(SyncQueue.Item item:queue.pending()) {
                    check(); if(System.currentTimeMillis()>deadline) return retryAllowed();
                    try { queue.prepare(item,this); }
                    catch(IllegalStateException | IllegalArgumentException | java.io.FileNotFoundException e) { queue.quarantine(item); SyncConfig.message(SyncJobService.this,"Hay un audio que cambió o no es válido. Se conserva para revisar."); continue; }
                    if(item.driveId==null) queue.id(item,api.generateId());
                    queue.attempted(item);
                    if(api.verified(item,folder)) { queue.uploaded(item); continue; }
                    String session=item.session==null ? null : SyncCrypto.open(item.session);
                    long position=session==null ? -1 : api.position(session,item.bytes);
                    if(position<0) { session=api.begin(item,folder); queue.session(item,session); position=0; }
                    SyncConfig.message(SyncJobService.this,"Subiendo "+item.name+(manual?" · pedido manual":" · Wi-Fi"));
                    while(position<item.bytes) {
                        check(); if(System.currentTimeMillis()>deadline) return retryAllowed();
                        long start=position,end=Math.min(item.bytes-1,start+1024*1024-1);
                        DriveApi.Source source=()->{
                            InputStream in=getContentResolver().openInputStream(Uri.parse(item.uri));
                            if(in==null) throw new java.io.IOException("missing-audio");
                            try { long remaining=start; while(remaining>0) { long n=in.skip(remaining); if(n==0) { if(in.read()==-1) throw new java.io.IOException("short-audio"); n=1; } remaining-=n; } }
                            catch(Exception e) { in.close(); throw e; }
                            return in;
                        };
                        api.part(session,source,start,end,item.bytes);
                        long next=api.position(session,item.bytes);
                        if(next<=position) throw new java.io.IOException("upload-no-progress"); position=next;
                    }
                    if(!api.verified(item,folder)) throw new java.io.IOException("missing-remote-receipt");
                    queue.uploaded(item);
                }
                SyncConfig.prefs(SyncJobService.this).edit().putLong("last_success",System.currentTimeMillis()).apply();
                SyncConfig.message(SyncJobService.this,queue.count("review")>0?"Hay audios para revisar; originales conservados.":queue.count("pending")==0?"Sincronizado · originales conservados en el teléfono.":"Quedan audios pendientes.");
                return queue.count("pending")>0 && retryAllowed();
            }
        }
        @Override public DriveApi.Reply send(String method,String url,Map<String,String> headers,DriveApi.Source body,long length) throws Exception {
            check(); Network n=network(); if(n==null) throw new Stopped();
            HttpURLConnection c=(HttpURLConnection)n.openConnection(new URL(url)); connection=c;
            c.setInstanceFollowRedirects(false); c.setConnectTimeout(20000); c.setReadTimeout(30000); c.setRequestMethod(method);
            headers.forEach(c::setRequestProperty);
            try {
                if(body!=null) {
                    c.setDoOutput(true); c.setFixedLengthStreamingMode(length);
                    try(InputStream in=body.open(); OutputStream out=c.getOutputStream()) {
                        byte[] b=new byte[65536]; long remaining=length;
                        while(remaining>0) { check(); int count=in.read(b,0,(int)Math.min(b.length,remaining)); if(count<0) throw new java.io.IOException("short-audio"); out.write(b,0,count); remaining-=count; }
                    }
                }
                check(); return DriveApi.read(c);
            } finally { c.disconnect(); if(connection==c) connection=null; }
        }
    }
}
