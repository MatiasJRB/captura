# iPhone setup

This guide installs Captura on your own iPhone from your own Mac, with a free Apple
Account. It is written so you can follow it alone or with a coding agent reading this
repository. Each step says what you should see and what to do if you don't.

There is no App Store version. You build the app yourself, and it records only while
you can see it recording. Your recordings stay on the iPhone until you turn on Google
Drive sync. Then the [worker](worker.md) on your Mac downloads and transcribes them.

What has been tested so far and what hasn't is listed in [verification](verification.md#ios-client).
In short, the app has passed its tests in the simulator, but nobody has yet followed this
guide end to end on a real iPhone with Xcode 27.

## What you need

- A Mac with Apple silicon (M1 or newer) running macOS 26.6 or later. To check, open
  Apple menu > About This Mac. Xcode 27 does not run on older Macs or older macOS.
- An iPhone with iOS 18 or later, and a cable that connects it to the Mac.
- A free Apple Account (the one you use for the App Store is fine). You don't need the
  paid Apple Developer Program.
- The **iOS client ID** from whoever manages your Google Cloud project. If that's you,
  do [Google Cloud setup (for the admin)](#google-cloud-setup-for-the-admin) first.
  Agree on the bundle ID before you start (see step 4).
- Several GB of free disk space. Xcode is a 3.1 GB download and needs much more once
  installed, plus the iOS platform.

A free Apple Account comes with limits. Apps you install from Xcode stop opening after
**7 days** until you reinstall them (see [every 7 days](#every-7-days-reinstall-from-the-mac)).
You can have **3** such apps on one iPhone, use **3** iPhones, and register **10** app
IDs in any 7 days.

## 1. Install Xcode 27

1. Open the **App Store** on the Mac, search for **Xcode** and click **Get**, then
   **Install**. It's free.
   - *You should see:* Xcode in your Applications folder once the download finishes.
   - *If the App Store says it needs a newer macOS:* go to System Settings > General >
     Software Update and update macOS first.
2. Open Xcode. Accept the license, and enter your Mac password if asked. When Xcode asks
   which platforms to install, tick **iOS** and continue. The download is several GB.
   - *You should see:* the "Welcome to Xcode" window.
   - *If you skipped the iOS platform:* open Xcode > Settings > Components and click
     **Get** next to iOS. You can also run `xcodebuild -downloadPlatform iOS` in Terminal.
3. Sign in with your Apple Account. In Xcode, open **Xcode > Settings > Apple Accounts**,
   click **+**, choose Apple Account and sign in. Approve the sign-in on your other Apple
   devices if asked.
   - *You should see:* your account in the list. Xcode creates a free team for it,
     shown later as "Your Name (Personal Team)".
   - *If sign-in fails:* check the Mac's date, time and internet connection, then try
     again.

## 2. Open Terminal

Open **Terminal**. It's in Applications > Utilities, or search for it with Spotlight
(⌘ Space). Type each command below exactly as written and press Return. Lines that
start with `#` are only notes; you don't need to type them.

## 3. Download Captura

```sh
cd ~
git clone https://github.com/MatiasJRB/captura.git
cd captura
```

- *You should see:* `Cloning into 'captura'...` followed by `done`. From now on, every
  command runs inside this `captura` folder. If you open a new Terminal window, run
  `cd ~/captura` first.
- *If macOS asks to install the command line developer tools:* open Xcode once (step 1),
  then run the commands again.
- Keep the folder in your home folder, as above. Don't put it in Documents, Desktop or
  Downloads, because macOS adds extra permission prompts there. Those prompts get in
  the way if you schedule the worker later.

## 4. Save your settings

Pick a **bundle ID**. It's the app's name for Apple and Google and must be unique to
you. Use `com.` + your name + `.captura`, in lowercase with no spaces, for example
`com.anagarcia.captura`. Whoever creates the Google iOS client must enter **exactly**
this value (see the admin section below). Then run:

```sh
python3 ios/scripts/configure.py --bundle-id com.yourname.captura --google-client-id PASTE-THE-IOS-CLIENT-ID
```

Add `--hosted-domain yourcompany.com` if your Google accounts belong to a Google
Workspace. The app will then only accept accounts from that domain.

- *You should see:* `Wrote ios/Config/Captura.local.xcconfig`, a summary of your values,
  and `Using the team Xcode knows: ABCDE12345 (Your Name (Personal Team))`.
- *If it says `No Apple team found in Xcode yet`:* finish step 1.3, then run
  `python3 ios/scripts/configure.py` again with no other arguments. If it still finds
  no team, carry on: step 6 covers it.
- *If it says `Xcode knows several teams`:* pick the one you want (usually the one marked
  Personal Team) and run `python3 ios/scripts/configure.py --team THAT-TEAM-ID`.
- *If it says `Not changed: ...`:* the message names the value that's wrong and gives
  an example. Fix it and run the command again.
- *If it says the file `already exists`:* you configured it before. Add `--force` to
  replace it.

This file is yours. Git ignores it, so `git pull` never overwrites it and you never
commit it by accident. It holds identifiers, not passwords.

## 5. Check the Mac

```sh
python3 ios/scripts/check.py
```

- *You should see:* a list of `ok` lines and `Ready.` at the end.
- *If a line says `FAIL`:* do what its `Next:` line says, then run the check again. Lines
  marked `warn` or `info` don't block you.

The check is read-only and never goes online. It checks Xcode, the iOS platform, your
settings file, the Apple team, whether Xcode really reads your settings, and any iPhone
connected by cable.

## 6. Open the project and check signing

```sh
open ios/Captura.xcodeproj
```

1. In the left sidebar, click the blue **Captura** project icon at the top. Then, under
   Targets, click **Captura** and open the **Signing & Capabilities** tab.
   - *You should see:* "Automatically manage signing" ticked, **Team** set to
     "Your Name (Personal Team)", and **Bundle Identifier** showing your bundle ID.
2. *If Team shows **None**, or you see "Signing for "Captura" requires a development
   team":* choose your "(Personal Team)" in the **Team** menu. Xcode then writes the
   team into a shared project file, which would block `git pull` later. To move it into
   your own settings instead:
   1. Quit Xcode (Xcode > Quit Xcode).
   2. Run `python3 ios/scripts/configure.py --adopt-xcode-team`.
   3. Open the project again with `open ios/Captura.xcodeproj`.
   - *You should see:* `Saved Apple team ...` and `Restored ios/Captura.xcodeproj/project.pbxproj`.
   - *If it refuses because the project file has other changes:* it lists those
     changes and tells you how to save the team with `--team`.
3. *If you see "Failed Registering Bundle Identifier" or "... is not available":*
   someone else already registered that bundle ID. Pick another one (for example add
   your initials), run step 4 again with `--force`, and ask the Google admin to change
   the iOS client's bundle ID to the new value, or to create a new iOS client for it.
   Don't keep trying new IDs: a free account can register only 10 in 7 days.

## 7. Connect the iPhone

1. Connect the iPhone to the Mac with the cable and unlock it. When the iPhone asks
   **¿Confiar en esta computadora?** (Trust This Computer?), tap **Confiar** and enter
   your iPhone passcode.
2. In Xcode, open the device menu at the top of the window (next to "Captura") and
   choose your iPhone. If Xcode offers to **Pair** it, accept.
3. Turn on Developer Mode. On the iPhone, open **Configuración > Privacidad y seguridad >
   Modo de desarrollador** (Settings > Privacy & Security > Developer Mode), turn it
   on and restart when asked. After the restart, unlock the iPhone, confirm that you
   want to turn it on, and enter your passcode.
   - *If you can't find Modo de desarrollador:* iOS only shows it after the iPhone has
     been connected to Xcode once. Do steps 7.1 and 7.2 again, then look again.
4. Run `python3 ios/scripts/check.py` again.
   - *You should see:* a line with your iPhone's name. If it says `Developer Mode
     disabled` or that the iPhone isn't paired, repeat the step its `Next:` line names.

## 8. Install the app

In Xcode, press the **Run** button (▶) or ⌘R. The first build takes a few minutes.

- *If macOS asks whether `codesign` may use a key in your keychain:* enter your Mac login
  password and click **Always Allow**.
- *You should see:* "Build Succeeded", and Captura appears on the iPhone. The first
  time, iOS won't open it and Xcode reports that the developer isn't trusted. Step 9
  fixes this.

## 9. Trust yourself as the developer

On the iPhone, open **Configuración > General > Admón. de dispositivos y VPN** (Settings >
General > VPN & Device Management). Under the developer apps section, tap your Apple
Account. Tap **Confiar en "…"** (Trust), then confirm.

- *You should see:* the app listed as trusted. Press Run in Xcode again, or tap the
  Captura icon on the Home Screen.

## 10. First launch

1. **Microphone.** Captura opens with "Micrófono apagado". Tap **Grabar**. iOS asks for
   the microphone: tap **Permitir**.
   - *You should see:* "Grabando · 0:01" counting up, and the orange microphone dot at the
     top of the screen. Tap **Detener**. The recording shows up under "Grabaciones en este
     iPhone" with the status "Solo en el iPhone".
   - *If you see "Captura no tiene permiso para usar el micrófono":* tap **Abrir Ajustes**
     and turn on Micrófono.
   - Tell people before you record them. The app reminds you with "Avisá a las personas
     antes de grabar."
2. **Link Google Drive.** Under "Google Drive", tap **Vincular Google Drive**. iOS asks
   whether Captura may use google.com to sign in. Tap **Continuar**, choose your Google
   account and allow access to Drive (tick the Drive box if Google shows one).
   - *You should see:* "Cuenta: you@yourcompany.com", then "Drive vinculado. La carpeta
     «Captura · audios» está lista; copiá su ID para la Mac."
   - *If you see an error:* look it up in [troubleshooting](#troubleshooting).
3. **Turn on Wi-Fi sync.** Turn on **Sincronizar automáticamente por Wi-Fi** and confirm
   with **Activar**. Finished recordings now upload on their own over Wi-Fi. To upload
   right away, tap **Sincronizar ahora**. That also allows mobile data for 30 minutes.
   - *You should see:* the counters change to "0 pendientes · 1 subidos · 0 en revisión"
     once the test recording has uploaded.
4. **Copy the folder ID.** Under "ID de la carpeta «Captura · audios» para la Mac
   (folder_id)", tap **Copiar ID de carpeta**. You'll need it on the Mac. If the Mac and
   iPhone use the same Apple Account, you can paste it straight on the Mac with ⌘V.
   Otherwise, send it to yourself in a note.
5. Set up the [worker on the Mac](worker.md).

Captura records only while the app shows "Grabando". You can also start it from
Shortcuts, Siri or the Action Button with **Grabar con Captura**. It opens the app and
then starts recording, because iOS doesn't let an app start the microphone from the
background.

## Every 7 days: reinstall from the Mac

With a free Apple Account, the app stops opening 7 days after you installed it. Your
recordings and your Google link stay on the iPhone. To renew:

1. In Captura, tap **Detener** if it's recording. Reinstalling stops the app, and that
   cuts off a recording in progress. The cut piece is kept as "Incompleto · conservado",
   but it isn't uploaded automatically.
2. Connect the iPhone, run `open ~/captura/ios/Captura.xcodeproj`, choose the iPhone and
   press **Run**. (To get the latest version first, run `git pull` in the `captura`
   folder.)
3. Open Captura. Your recordings, upload queue and Google account are all still there.

**Never delete the Captura app while recordings are waiting to upload** (the "pendientes"
count is above 0), or before the Mac has imported them. Deleting the app deletes every
recording stored on the iPhone. They aren't in iCloud backups. A fresh install also
forgets the Google sign-in, so you'd have to link Drive again.

A weekly calendar reminder helps. If the 7 days have already passed, iOS just won't
open the app. Do step 2 and everything comes back.

## Troubleshooting

| What you see | What it means | What to do |
|---|---|---|
| "Falta configurar Google: …" under Google Drive | The app was built without your settings file. | Run steps 4 and 5, then press Run in Xcode again. |
| "El valor de CAPTURA_GOOGLE_IOS_CLIENT_ID no parece un ID de cliente…" | The value isn't an iOS client ID. | Run step 4 again with `--force` and the **iOS** client's ID. |
| Google shows "Error 400: redirect_uri_mismatch" or "invalid_request" | The client ID isn't of type iOS, or its bundle ID differs from yours. | The admin checks that the client type is **iOS** and that its bundle ID is exactly yours. Then use that client's ID in step 4. |
| "Google no reconoce el ID de cliente…" | Google doesn't know that client (typo, or the client was deleted). | Get the current iOS client ID, redo step 4 with `--force`, press Run. |
| "El administrador de tu Google Workspace no permite esta app…" (`admin_policy_enforced`) | Your Workspace blocks unapproved apps from Drive. | A Workspace admin opens Admin console > Security > Access and data control > API controls and marks this app (its client ID) as **Trusted**, or trusts internal apps. |
| Google shows "Error 403: org_internal" | The app is Internal and this account is outside the organization. | Use an account from the organization, or the admin switches to External and adds you as a test user. |
| Google shows "Access blocked" / "Error 403: access_denied" | The app is External in Testing and you aren't a test user. | The admin adds your account under test users. |
| "Google pidió volver a vincular la cuenta…" or "Google requiere autorización…" (`invalid_grant`) | The Google permission expired or was revoked. With External + Testing it expires after 7 days. It also expires after 6 months unused, or if you allowed access only for a limited time. | Tap **Vincular Google Drive** (or **Volver a vincular Google Drive**). To stop the 7-day expiry, the admin uses an Internal app (Workspace). Recordings are kept. |
| "Falta el permiso de Google Drive…" | You unticked Drive on Google's consent screen. | Link again and tick the Drive box. |
| "Esa cuenta no es de yourcompany.com…" | `--hosted-domain` only allows that domain. | Choose an account from that domain, or redo step 4 without `--hosted-domain`. |
| Xcode: "Failed Registering Bundle Identifier" / "is not available" | Someone else registered that bundle ID. | See step 6.3. |
| Xcode: "Signing for "Captura" requires a development team" | No team is set. | See step 6.2. |
| Xcode says the App ID limit was reached | A free account can register only 10 App IDs in 7 days. | Keep one bundle ID and wait for the limit to reset. Don't keep changing bundle IDs. |
| Xcode says the maximum number of apps for free development profiles was reached | Only 3 apps installed from Xcode fit on one iPhone. | Remove another app you installed from Xcode. Never remove Captura while it has recordings waiting. Then press Run again. |
| iPhone: "Desarrollador no confiable" (Untrusted Developer) | You haven't trusted your developer account yet. | Step 9. |
| The app won't open after a week | Your free install expired (7 days). | [Reinstall from the Mac](#every-7-days-reinstall-from-the-mac). Your data is kept. |
| Xcode: "Developer Mode disabled" or the iPhone isn't listed | The iPhone isn't paired or Developer Mode is off. | Step 7. Unlock the iPhone and plug the cable in again. After an iOS update, pair again. |
| Xcode: "iOS … is not installed" or "… is not supported" | The iOS platform is missing, or Xcode is older than your iPhone's iOS. | Xcode > Settings > Components > **Get** next to iOS. Update Xcode from the App Store. |
| "En pausa · no se está grabando" | A call, Siri or another app's audio took over the microphone. It doesn't always resume by itself. | Tap **Reanudar ahora**. Make sure you see "Grabando" again. |
| "La grabación se detuvo porque queda poco espacio…" or "Queda poco espacio en el iPhone…" | Less than about 200 MB is free. What was recorded is kept. | Free up space on the iPhone (other apps, photos), then tap **Grabar**. Captura never deletes recordings itself, and deleting the app deletes them all. |
| "Se conservó 1 archivo incompleto…" | A recording was cut off (crash, reinstall). The piece is kept. | Nothing to do. The piece stays on the iPhone and isn't uploaded automatically. |
| "N en revisión" in the sync counters | Some uploads failed several times. They're kept on the iPhone. | Tap **Reintentar los audios en revisión** once the connection works. |
| "La carpeta de Drive no es privada o no se puede usar…" | The folder "Captura · audios" is shared with someone, or isn't owned by the linked account. Nothing was uploaded. | In Drive, stop sharing that folder. To start over instead, move it to the trash: the app then makes a new folder. |
| "Se creó una carpeta nueva en Drive. Actualizá el folder_id en la Mac." | The old folder was trashed or can't be used, so the app made a new one. Linking another account also makes a new one. | Copy the new ID and run `capture pin` on the Mac ([worker step 7](worker.md#7-pin-the-folder)). |

## Google Cloud setup (for the admin)

This part is for whoever manages the Google Cloud project. If your organization uses
Google Workspace, that's a Workspace admin or someone allowed to create projects in it.
You create **one project with two OAuth clients**: an **iOS** client for each iPhone and
a **Desktop** client for rclone on the Mac. Both clients must be in the **same project**.

1. In [Google Cloud console](https://console.cloud.google.com/), create a project, for
   example "Captura". With Workspace, create it inside your organization.
2. Turn on the **Google Drive API**: APIs & Services > Library > Google Drive API >
   **Enable**.
3. Set up the consent screen under Google Auth Platform.
   - **With Google Workspace:** choose the **Internal** audience. Only accounts in your
     organization can sign in, and Google doesn't need to review the app. Permissions
     don't expire after 7 days. If Drive is set to Restricted in Admin console > Security >
     Access and data control > API controls, mark this app as **Trusted** (or trust
     internal apps). Otherwise people see `admin_policy_enforced`.
   - **Without Workspace (personal Gmail accounts):** choose **External**, leave it in
     **Testing**, and add every Gmail address that will sign in as a **test user**.
     While it stays in Testing, Google expires permissions after **7 days**. Each week,
     people then tap "Volver a vincular Google Drive" on the iPhone and run
     `rclone config reconnect captura:` on the Mac.
4. Create the **iOS** client: Clients > Create client > Application type **iOS**. Enter
   the person's bundle ID **exactly** (for example `com.anagarcia.captura`). Leave the
   App Store ID and Team ID empty. Keep App Check off, because free Apple accounts can't
   use it. Click Create and send the person the **Client ID** (it ends in
   `.apps.googleusercontent.com`). An iOS client has no secret. Create one iOS client
   per bundle ID.
5. Create the **Desktop** client for the Mac worker: Clients > Create client >
   Application type **Desktop app**. Copy its **Client ID** and **Client secret** and
   give them to whoever sets up the worker. Treat the secret like a password: don't
   paste it into chats or put it in the repository.
6. Choose the Mac's Drive permission. The iPhone uses `drive.file`, which only covers
   files this project's apps create. Start the Mac with `drive.file` as well. Once the
   iPhone has uploaded one recording, run [`capture probe`](worker.md#6-find-the-phones-folder).
   If probe can't see the folder, recreate the rclone remote with `drive.readonly`
   (read-only access to all of Drive). Google doesn't document whether two clients in
   the same project share `drive.file` files, so this test decides.
   `drive.readonly` is a restricted scope. Internal apps can use it without Google's
   review. External apps in Testing can use it for their test users.

The iPhone asks for `openid`, `email` and `drive.file`. It never asks for full Drive
access, and Captura never shares or deletes files.
