package org.example.captura;

import static org.junit.Assert.*;
import org.junit.Test;
import java.util.Map;
import java.util.ArrayDeque;
import java.util.Queue;

public class SyncTests {
    @Test public void automaticNeverUsesCellular() {
        assertFalse(SyncPolicy.allowed(false,false,true,0,100));
        assertTrue(SyncPolicy.allowed(false,true,true,0,100));
        assertFalse(SyncPolicy.allowed(false,true,false,0,100));
    }
    @Test public void manualCanUseCellularButExpires() {
        assertTrue(SyncPolicy.allowed(true,false,true,100,200));
        assertFalse(SyncPolicy.allowed(true,false,true,100,100+SyncPolicy.MANUAL_WINDOW_MS+1));
        assertFalse(SyncPolicy.allowed(true,false,true,200,100));
        assertFalse(SyncPolicy.allowed(true,false,false,100,200));
    }
    @Test public void receiptNeedsAllEvidence() {
        assertTrue(SyncPolicy.verified(40,"md5","sha",40,"md5","sha",true));
        assertFalse(SyncPolicy.verified(40,"md5","sha",41,"md5","sha",true));
        assertFalse(SyncPolicy.verified(40,"md5","sha",40,"wrong","sha",true));
        assertFalse(SyncPolicy.verified(40,"md5","sha",40,"md5","wrong",true));
        assertFalse(SyncPolicy.verified(40,"md5","sha",40,"md5","sha",false));
    }
    @Test public void rejectsTokenExfiltrationEndpoints() throws Exception {
        for(String s:new String[]{"http://www.googleapis.com/","https://evil.example/","https://www.googleapis.com.evil.example/","https://user@www.googleapis.com/","https://www.googleapis.com:8443/"}) {
            try { DriveApi.safe(s); fail(s); } catch(SecurityException expected) { }
        }
        DriveApi.safe(DriveApi.API);
    }
    static class Fake implements DriveApi.Transport {
        Queue<DriveApi.Reply> replies=new ArrayDeque<>(); int calls=0;
        void add(int code,String body,Map<String,String> headers) { replies.add(new DriveApi.Reply(code,body,headers)); }
        public DriveApi.Reply send(String method,String url,Map<String,String> h,DriveApi.Source body,long size) throws Exception {
            assertEquals("Bearer test-only",h.get("Authorization")); calls++;
            assertFalse("Must never send OAuth tokens in URLs",url.contains("test-only"));
            return replies.remove();
        }
    }
    @Test public void resumesFromCanonicalServerRange() throws Exception {
        Fake f=new Fake(); f.add(308,"",Map.of("range","bytes=0-262143"));
        assertEquals(262144,new DriveApi("test-only",f).position(DriveApi.UPLOAD,400000));
        f.add(308,"",Map.of()); assertEquals(0,new DriveApi("test-only",f).position(DriveApi.UPLOAD,400000));
    }
    @Test public void expiredSessionCanBeRestarted() throws Exception {
        Fake f=new Fake(); f.add(404,"",Map.of()); assertEquals(-1,new DriveApi("test-only",f).position(DriveApi.UPLOAD,400000));
        f.add(201,"{}",Map.of()); assertEquals(400000,new DriveApi("test-only",f).position(DriveApi.UPLOAD,400000));
    }
    @Test public void malformedOrOversizedResumeRangeIsRejected() throws Exception {
        Fake f=new Fake(); DriveApi api=new DriveApi("test-only",f);
        for(String range:new String[]{"bytes=0-999999","garbage"}) {
            f.add(308,"",Map.of("range",range));
            try { api.position(DriveApi.UPLOAD,100); fail(); } catch(java.io.IOException expected) { }
        }
    }
    @Test public void existingRemoteWithWrongChecksumIsNotSuccess() throws Exception {
        Fake f=new Fake(); f.add(200,"{\"size\":40,\"md5Checksum\":\"wrong\",\"parents\":[\"folder\"],\"ownedByMe\":true,\"shared\":false,\"properties\":{\"sha256\":\"sha\"}}",Map.of());
        SyncQueue.Item item=new SyncQueue.Item(); item.bytes=40; item.md5="md5"; item.sha="sha"; item.driveId="safeId";
        try { new DriveApi("test-only",f).verified(item,"folder"); fail(); } catch(SecurityException expected) { }
    }
    @Test public void refusesSharedFolder() throws Exception {
        Fake f=new Fake(); f.add(200,"{\"mimeType\":\"application/vnd.google-apps.folder\",\"shared\":true,\"ownedByMe\":true,\"properties\":{\"device\":\"d\"}}",Map.of());
        try { new DriveApi("test-only",f).ensureFolder("safeId","d"); fail(); } catch(SecurityException expected) { }
        assertEquals(1,f.calls);
    }
    @Test public void missingFileIsPendingNotUploaded() throws Exception {
        Fake f=new Fake(); f.add(404,"",Map.of()); SyncQueue.Item item=new SyncQueue.Item(); item.driveId="safeId";
        assertFalse(new DriveApi("test-only",f).verified(item,"folder"));
    }
}
