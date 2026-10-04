# Android setup

1. Install JDK 17 and Android SDK platform 36 / build-tools 36.0.0. Accept the SDK
   licenses using its normal tooling. Set ANDROID_HOME to your own SDK directory.
2. Run `./android/build.sh`. The Gradle wrapper tests and builds a **debug** APK,
   generating a fresh checkout-local development key in `android/.local/` (ignored by Git),
   not your global Android key or a key bundled with this repo. Keep it across updates
   and OAuth registration; a clean clone gets a different development identity.
3. Install the APK on a separate test device. No automatic adb installation is done.
4. Open Captura, grant mic permission, and explicitly start recording. It saves
   AAC mono 16 kHz / 24 kbps M4A chunks of ~15 minutes in Music/PersonalCapture.
   Pause/stop from the app, notification or quick-settings tile. Linking Drive,
   plugging in USB or getting Wi-Fi does not start the microphone. Android may stop
   the service; reopen and verify state. There is no automatic overnight schedule.
5. Battery history reports observed device battery change, not isolated app energy.
   Short or charging sessions cannot yield a useful drain estimate.

## Optional Drive

Offline recording works without Google. For Drive, use **your own** Google Cloud
project, enabled Drive API, consent screen and Android OAuth client. Register the
package ID and SHA-1 of the key signing your APK. `./android/gradlew -p android
signingReport` prints the development fingerprint. No client secret belongs in the APK.

The namespace is `org.example.captura`; the application ID is a placeholder. Build
with `-PcaptureApplicationId=YOUR_OWN_ID` to use your own identity. Component class
names in the manifest are fully qualified so a different application ID still works.
Consult [Google's authorization setup](https://developer.android.com/identity/authorization).
Use a matching user/test-user authorization and consult Google's current OAuth rules.

Linking an account alone does not upload. Automatic Wi-Fi sync is opt-in with a
confirmation; manual sync can use mobile data after confirmation, for a 30-minute
window. Closed chunks are queued, resumable uploads verified, originals retained.
Jobs obey battery/network restrictions, so uploads are not guaranteed instantaneous.

Production/release APK signing and public shared OAuth onboarding are deliberately
not configured. Never distribute an APK signed with someone else's private phone key.
