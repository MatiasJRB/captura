package org.example.captura;

import android.accounts.Account;
import android.content.Context;
import android.content.SharedPreferences;
import com.google.android.gms.auth.api.identity.AuthorizationRequest;
import com.google.android.gms.common.api.Scope;
import java.util.Collections;
import java.util.UUID;

public final class SyncConfig {
    public static final String SCOPE = "https://www.googleapis.com/auth/drive.file";
    public static final String FOLDER_NAME = "Captura · audios";
    public static SharedPreferences prefs(Context c) { return c.getSharedPreferences("drive_sync", Context.MODE_PRIVATE); }
    public static boolean connected(Context c) { return !prefs(c).getString("account", "").isEmpty(); }
    public static boolean automatic(Context c) { return prefs(c).getBoolean("automatic", false); }
    public static void message(Context c, String text) { prefs(c).edit().putString("message", text).apply(); }
    public static String deviceId(Context c) {
        String id = prefs(c).getString("device_id", "");
        if (id.isEmpty()) { id = UUID.randomUUID().toString(); prefs(c).edit().putString("device_id", id).commit(); }
        return id;
    }
    public static AuthorizationRequest request(String account) {
        return AuthorizationRequest.builder().setAccount(new Account(account, "com.google"))
                .setRequestedScopes(Collections.singletonList(new Scope(SCOPE))).build();
    }
}
