package org.example.captura;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import java.nio.charset.StandardCharsets;

/** Upload session URLs are capabilities: encrypt them rather than logging/storing plaintext. */
final class SyncCrypto {
    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if (!store.containsAlias("capture-sync")) {
            KeyGenerator generator = KeyGenerator.getInstance("AES", "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder("capture-sync", KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return (SecretKey) store.getKey("capture-sync", null);
    }
    static String seal(String plain) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE, key());
        return Base64.encodeToString(c.getIV(), Base64.NO_WRAP) + "." + Base64.encodeToString(c.doFinal(plain.getBytes(StandardCharsets.UTF_8)), Base64.NO_WRAP);
    }
    static String open(String sealed) throws Exception {
        String[] bits = sealed.split("\\.", 2);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Base64.decode(bits[0], Base64.NO_WRAP)));
        return new String(c.doFinal(Base64.decode(bits[1], Base64.NO_WRAP)), StandardCharsets.UTF_8);
    }
}
