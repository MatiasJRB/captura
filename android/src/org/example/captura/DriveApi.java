package org.example.captura;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/** Fixed Google endpoints, stable IDs, bounded streams and canonical checksum receipts. */
final class DriveApi {
    static final String API = "https://www.googleapis.com/drive/v3/";
    static final String UPLOAD = "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable";
    interface Cancel { void check() throws Exception; }
    interface Source { InputStream open() throws Exception; }
    interface Transport { Reply send(String method, String url, Map<String,String> headers, Source body, long length) throws Exception; }
    static final class Reply {
        final int code; final String body; final Map<String,String> headers;
        Reply(int c, String b, Map<String,String> h) { code=c; body=b; headers=h; }
        String header(String key) { return headers.get(key.toLowerCase(java.util.Locale.US)); }
        JSONObject json() throws Exception { return new JSONObject(body); }
    }
    private final Transport transport; private final String token;
    DriveApi(String token, Transport transport) { this.token=token; this.transport=transport; }
    Reply call(String method, String url, Source body, long length, Map<String,String> extra) throws Exception {
        safe(url);
        Map<String,String> h = new HashMap<>(extra); h.put("Authorization", "Bearer " + token);
        return transport.send(method, url, h, body, length);
    }
    static void safe(String url) throws Exception {
        URL u = new URL(url);
        if (!"https".equals(u.getProtocol()) || !"www.googleapis.com".equals(u.getHost())
                || (u.getPort()!=-1 && u.getPort()!=443) || u.getUserInfo()!=null) throw new SecurityException("invalid-google-endpoint");
    }
    static void ok(Reply r) throws Exception { if (r.code<200 || r.code>=300) throw new java.io.IOException("Drive HTTP " + r.code); }
    static Source bytes(byte[] data) { return () -> new java.io.ByteArrayInputStream(data); }
    Reply json(String method, String url, JSONObject data) throws Exception {
        byte[] payload = data.toString().getBytes(StandardCharsets.UTF_8);
        return call(method, url, bytes(payload), payload.length, Map.of("Content-Type","application/json; charset=UTF-8"));
    }
    String generateId() throws Exception {
        Reply r = call("GET", API+"files/generateIds?count=1&space=drive&type=files", null,0,Map.of()); ok(r);
        return r.json().getJSONArray("ids").getString(0);
    }
    JSONObject metadata(String id) throws Exception {
        if (!id.matches("[A-Za-z0-9_-]+")) throw new SecurityException("invalid-file-id");
        Reply r = call("GET", API+"files/"+id+"?fields=id,name,mimeType,size,md5Checksum,parents,properties,shared,ownedByMe,trashed",null,0,Map.of());
        if (r.code==404) return null; ok(r); return r.json();
    }
    String ensureFolder(String id, String device) throws Exception {
        JSONObject m = metadata(id);
        if (m==null) {
            JSONObject data = new JSONObject().put("id",id).put("name",SyncConfig.FOLDER_NAME)
                    .put("mimeType","application/vnd.google-apps.folder")
                    .put("properties",new JSONObject().put("personalCaptureInbox","1").put("device",device));
            Reply r = json("POST",API+"files?fields=id",data);
            if (r.code!=409) ok(r);
            m=metadata(id);
        }
        if (m==null || !"application/vnd.google-apps.folder".equals(m.optString("mimeType"))
                || m.optBoolean("trashed") || m.optBoolean("shared") || !m.optBoolean("ownedByMe")
                || !device.equals(m.optJSONObject("properties")==null ? "" : m.getJSONObject("properties").optString("device")))
            throw new SecurityException("invalid-private-folder");
        return id;
    }
    String begin(SyncQueue.Item i, String folder) throws Exception {
        JSONObject data = new JSONObject().put("id",i.driveId).put("name",i.name).put("mimeType","audio/mp4")
                .put("parents",new JSONArray().put(folder))
                .put("properties",new JSONObject().put("personalCaptureAudio","1").put("sha256",i.sha));
        byte[] payload=data.toString().getBytes(StandardCharsets.UTF_8);
        Reply r=call("POST",UPLOAD+"&fields=id",bytes(payload),payload.length,
                Map.of("Content-Type","application/json; charset=UTF-8","X-Upload-Content-Type","audio/mp4","X-Upload-Content-Length",Long.toString(i.bytes)));
        ok(r); String url=r.header("location"); if(url==null) throw new java.io.IOException("missing-upload-session"); safe(url); return url;
    }
    long position(String session, long size) throws Exception {
        Reply r=call("PUT",session,bytes(new byte[0]),0,Map.of("Content-Range","bytes */"+size));
        if(r.code==404 || r.code==410) return -1;
        if(r.code==200 || r.code==201) return size;
        if(r.code!=308) { ok(r); throw new java.io.IOException("invalid-upload-position"); }
        String range=r.header("range");
        if(range==null) return 0;
        if(!range.matches("bytes=0-[0-9]+")) throw new java.io.IOException("invalid-upload-range");
        long p=Long.parseLong(range.substring(8))+1;
        if(p<0 || p>size) throw new java.io.IOException("invalid-upload-range"); return p;
    }
    void part(String session, Source source, long start, long end, long size) throws Exception {
        Reply r=call("PUT",session,source,end-start+1,
                Map.of("Content-Type","audio/mp4","Content-Range","bytes "+start+"-"+end+"/"+size));
        if(r.code!=308) ok(r);
    }
    boolean verified(SyncQueue.Item i, String folder) throws Exception {
        JSONObject m=metadata(i.driveId); if(m==null) return false;
        if(m.optBoolean("trashed") || m.optBoolean("shared") || !m.optBoolean("ownedByMe")) throw new SecurityException("remote-file-not-private");
        boolean parent=false; JSONArray ps=m.optJSONArray("parents");
        if(ps!=null) for(int n=0;n<ps.length();n++) if(folder.equals(ps.getString(n))) parent=true;
        JSONObject props=m.optJSONObject("properties");
        boolean result=SyncPolicy.verified(i.bytes,i.md5,i.sha,m.optLong("size",-1),m.optString("md5Checksum"),props==null?"":props.optString("sha256"),parent);
        if(!result) {
            if (m.optLong("size",0)==0 && m.optString("md5Checksum").isEmpty() && parent && props!=null && i.sha.equals(props.optString("sha256"))) return false;
            throw new SecurityException("remote-receipt-mismatch");
        } return true;
    }
    static Reply read(HttpURLConnection c) throws Exception {
        int code=c.getResponseCode(); InputStream in=code>=400 ? c.getErrorStream() : c.getInputStream();
        ByteArrayOutputStream out=new ByteArrayOutputStream();
        if(in!=null) try(in) { byte[] b=new byte[4096]; int n; while((n=in.read(b))!=-1) { if(out.size()+n>262144) throw new java.io.IOException("oversized-google-response"); out.write(b,0,n); } }
        Map<String,String> h=new HashMap<>(); c.getHeaderFields().forEach((k,v)->{ if(k!=null && v!=null && !v.isEmpty()) h.put(k.toLowerCase(java.util.Locale.US),v.get(0)); });
        return new Reply(code,out.toString(StandardCharsets.UTF_8),h);
    }
}
