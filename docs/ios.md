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

En español: [guía rápida](ios.es.md), con los mismos pasos. If a coding agent (Claude Code,
Codex) is helping you, ask it to follow [`.claude/skills/captura-setup/SKILL.md`](../.claude/skills/captura-setup/SKILL.md).

The Mac labels below are in English, with the Spanish ones in parentheses when they
differ. Xcode itself is only in English. The iPhone labels are in Spanish.

## What you need

- A Mac with Apple silicon (M1 or newer) running macOS 26.6 or later. To check, open
  Apple menu > About This Mac (Acerca de esta Mac). Xcode 27 does not run on older Macs
  or older macOS.
- An iPhone with iOS 18 or later, and a cable that connects it to the Mac.
- A free Apple Account (the one you use for the App Store is fine). You don't need the
  paid Apple Developer Program.
- The **iOS client ID** from whoever manages your Google Cloud project. If that's you,
  do [Google Cloud setup (for the admin)](#google-cloud-setup-for-the-admin) first.
  The admin needs your bundle ID to create it: step 4.1 checks it and tells you what to
  send.
- Several GB of free disk space. Xcode is a 3.1 GB download and needs much more once
  installed, plus the iOS platform.

A free Apple Account comes with limits. Apps you install from Xcode stop opening after
**7 days** until you reinstall them (see [every 7 days](#every-7-days-reinstall-from-the-mac)).
You can have **3** such apps on one iPhone, use **3** iPhones, and register **10** app
IDs in any 7 days.

## 1. Install Xcode 27

1. Open the **App Store** on the Mac, search for **Xcode** and click **Get**, then
   **Install**. It's free.
   - *You should see:* Xcode in your Applications (Aplicaciones) folder once the download finishes.
   - *If the App Store says it needs a newer macOS:* go to System Settings > General >
     Software Update (Configuración del Sistema > General > Actualización de software)
     and update macOS first.
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

Open **Terminal**. It's in Applications > Utilities (Aplicaciones > Utilidades), or
search for it with Spotlight (⌘ Space). Type each command below exactly as written and
press Return. Lines that start with `#` are only notes; you don't need to type them.

## 3. Download Captura

```sh
cd ~
git clone https://github.com/MatiasJRB/captura.git
cd captura
ls ios/scripts
```

- *You should see:* `Cloning into 'captura'...` followed by `done`, and then
  `check.py` and `configure.py` from the last command. From now on, every command runs
  inside this `captura` folder. If you open a new Terminal window, run `cd ~/captura`
  first.
- *If it says `destination path 'captura' already exists`:* you downloaded it before.
  Update that copy instead, then check again:

  ```sh
  git -C ~/captura pull
  cd ~/captura
  ls ios/scripts
  ```

  If `git pull` refuses because of local changes in `ios/Captura.xcodeproj` (Xcode
  makes them), run `git -C ~/captura checkout -- ios/Captura.xcodeproj`, then
  `git -C ~/captura pull` again.
- *If the last command says `No such file or directory`:* the version you downloaded
  doesn't include the iPhone app yet. Stop here and tell whoever sent you this guide.
  (For them: [before handing out this guide](release.md#before-handing-out-the-setup-guides).)
- *If macOS asks to install the command line developer tools:* open Xcode once (step 1),
  then run the commands again.
- Keep the folder in your home folder, as above. Don't put it in Documents, Desktop or
  Downloads, because macOS adds extra permission prompts there. Those prompts get in
  the way if you schedule the worker later.

## 4. Save your settings

1. Pick a **bundle ID**. It's the app's name for Apple and Google and must be unique to
   you. Use `com.` + your name + `.captura`, all in lowercase, with no spaces or accents.
   For example, Ana García would use `com.anagarcia.captura` (the script refuses this
   example and `com.yourname.captura`: use your own name). Check it, with your name in
   place of `yourname`:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura
   ```

   - *You should see:* `Bundle ID ... looks right. Nothing was written.` and
     `Send the Google admin exactly this value: ...`. Send the admin that value. The admin
     creates the iOS client with it and sends you its **client ID**.
   - *If it says `Not changed: ...`:* the message says what's wrong (capital letters, an
     example value, accents or spaces). Fix it and run the command again.
2. When you have the iOS client ID, save your settings. Use the same bundle ID and put
   the client ID in place of `PASTE-THE-IOS-CLIENT-ID`:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura --google-client-id PASTE-THE-IOS-CLIENT-ID
   ```

   If your Google accounts belong to a Google Workspace, add `--hosted-domain` and your
   domain (the part after @ in your work address) at the end. The app will then only
   accept accounts from that domain.

   **From a password manager item (recommended when the admin shares one).** If the
   admin saved the client ID in a 1Password item, with the field `ios_client_id` (and
   optionally `bundle_id` and `hosted_domain`), read the values from the item instead
   of pasting them. Use the item's vault and name in place of the example:

   ```sh
   python3 ios/scripts/configure.py --bundle-id com.yourname.captura --from "op://Captura/Captura iOS"
   ```

   Leave out `--bundle-id` if the item has a `bundle_id` field. Values you pass as
   options win over the item. Fields with other names: add, for example,
   `--field-map ios_client_id="iOS client ID"`. `--from "keychain://Captura iOS"` reads
   the macOS Keychain instead (one password per field, with the field name as the
   account). This needs the [1Password CLI](https://developer.1password.com/docs/cli)
   with 1Password > Settings > Developer > **Integrate with 1Password CLI** turned on;
   the script prints `Read ... from op://...` and then the same summary as above. If it
   says `Not changed: The 1Password CLI is not signed in` or `has no item`, do what the
   message says and run it again.

- *You should see:* `Wrote ios/Config/Captura.local.xcconfig`, a summary of your values,
  and `Using the team Xcode knows: ABCDE12345 (Your Name (Personal Team))`.
- *If it says `No Apple team found in Xcode yet`:* finish step 1.3, then run
  `python3 ios/scripts/configure.py` again with no other arguments. If it still finds
  no team, carry on: step 5 then reports only the Apple team as missing, and step 6
  sets it.
- *If it says `Xcode knows several teams`:* pick the one you want (usually the one marked
  Personal Team) and run `python3 ios/scripts/configure.py --team THAT-TEAM-ID`.
- *If it says `Not changed: ...`:* the message names the value that's wrong and why. If
  it calls a value an example or a placeholder, you left a value from this guide in the
  command: put your own there. Fix it and run the command again.
- *If it says `Already configured: ...`:* you ran this step before. To replace your
  settings, run the same command again with `--force` at the end. The Apple team you
  saved before is kept (add `--team` only to change it).

This file is yours. Git ignores it, so `git pull` never overwrites it and you never
commit it by accident. It holds identifiers, not passwords.

## 5. Check the Mac

```sh
python3 ios/scripts/check.py
```

- *You should see:* a list of `ok` lines and `Ready.` at the end.
- *If the only `FAIL` is `Apple team` and step 4 said no team was found:* that's
  expected at this point. The check ends with "Only the Apple team is missing". Go on to
  step 6, which sets the team.
- *If any other line says `FAIL`:* do what its `Next:` line says, then run the check
  again. Lines marked `warn` or `info` don't block you.

The check is read-only and never goes online. It checks Xcode, the iOS platform, your
settings file, the Apple team, whether Xcode really reads your settings, and any iPhone
connected by cable.

## 6. Open the project and check signing

```sh
open ios/Captura.xcodeproj
```

If Xcode offers to update the project, for example **Update to recommended settings**
(as a dialog, or as a yellow warning in the list of issues), don't apply it: click
**Not Now** or **Cancel**, or just leave the warning there. Never click **Perform
Changes**. The project already has the settings it needs, and applying them changes
shared project files, which later stops `git pull`. If you applied it by mistake, quit
Xcode and run `git checkout -- ios/Captura.xcodeproj`; `check.py` shows the same command.

1. In the left sidebar, click the blue **Captura** project icon at the top. Then, under
   Targets, click **Captura** and open the **Signing & Capabilities** tab.
   - *You should see:* "Automatically manage signing" ticked, **Team** set to
     "Your Name (Personal Team)", and **Bundle Identifier** showing your bundle ID.
   - *If Bundle Identifier shows `org.example.captura`:* Xcode isn't reading your
     settings. Don't pick a team yet: Xcode would register `org.example.captura` and use
     up one of your 10 app IDs. Quit Xcode, do steps 4 and 5 again, then open the
     project again.
2. *If Team shows **None**, or you see "Signing for "Captura" requires a development
   team":* choose your "(Personal Team)" in the **Team** menu. Xcode then writes the
   team into a shared project file, which would block `git pull` later. To move it into
   your own settings instead:
   1. Quit Xcode (Xcode > Quit Xcode).
   2. Run `python3 ios/scripts/configure.py --adopt-xcode-team`.
   3. Run `python3 ios/scripts/check.py` again.
   4. Open the project again with `open ios/Captura.xcodeproj`.
   - *You should see:* `Saved Apple team ...` and `Restored ios/Captura.xcodeproj/project.pbxproj`,
     then `Ready.` from the check.
   - *If it refuses because the project file has other changes:* it lists them and
     prints two commands. Unless you edited the project on purpose, run both, in the
     order shown: the first undoes the changes, the second saves your team.
3. *If you see "Failed Registering Bundle Identifier" or "... is not available":*
   someone else already registered that bundle ID. Pick another one (for example add
   your initials), run step 4 again with `--force` (your Apple team is kept), and ask
   the Google admin to change the iOS client's bundle ID to the new value, or to create
   a new iOS client for it. Don't keep trying new IDs: a free account can register only
   10 in 7 days.

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
  password and click **Always Allow** (Permitir siempre).
- *You should see:* "Build Succeeded", and Captura appears on the iPhone. The first
  time, iOS won't open it and Xcode reports that the developer isn't trusted. Step 9
  fixes this.

## 9. Trust yourself as the developer

On the iPhone, open **Configuración > General > Admón. de dispositivos y VPN** (Settings >
General > VPN & Device Management). Under the developer apps section, tap your Apple
Account. Tap **Confiar en "…"** (Trust), then confirm.

- *You should see:* the app listed as trusted. Press Run in Xcode again, or tap the
  Captura icon on the iPhone's Home Screen (pantalla de inicio).

## 10. First launch

1. **Microphone.** Captura opens with "Micrófono apagado". Tap **Grabar**. iOS asks for
   the microphone: tap **Permitir**.
   - *You should see:* "Grabando · 0:01" counting up, and the orange microphone dot at the
     top of the screen. Tap **Detener**. The recording shows up under "Grabaciones en este
     iPhone" with the status "Solo en el iPhone".
   - *If you see "Captura no tiene permiso para usar el micrófono":* tap **Abrir Ajustes**
     and turn on Micrófono.
   - While it records the first time, iOS also asks whether Captura may send
     notifications. Tap **Permitir**: if recording pauses while Captura isn't on screen
     (a call, low storage), you get "Captura se pausó" or "Captura dejó de grabar". If you
     don't allow them, recording works the same, but nothing tells you it paused.
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

**Where to read the transcripts.** The Mac transcribes; the iPhone app doesn't show
text. On the Mac, `capture list` and `capture view` show them ([worker step 8](worker.md#8-run-it)).
To read them on the phone, turn on publishing on the Mac
([worker step 9](worker.md#9-publish-transcripts-to-drive-optional)): each transcript
then also appears as a Google Doc in the Drive folder **Captura · transcripciones**, which
you open in the Google Drive or Google Docs app. It is off by default.

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
   press **Run**. (To get the latest version first, run `git -C ~/captura pull`. If it
   refuses because of local changes, see [troubleshooting](#troubleshooting).)
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
| Xcode: "Captura has no settings for this Mac yet, so the app would be signed with a placeholder bundle ID" | You pressed Run on the iPhone before step 4. | Quit Xcode, do steps 4 and 5, then open the project and press Run. |
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
| Xcode: "Update to recommended settings" | A newer Xcode offers to change the project files. | Click **Not Now** or **Cancel** (step 6). If you applied it, quit Xcode and run `git checkout -- ios/Captura.xcodeproj`. |
| `git pull`: "Your local changes to the following files would be overwritten" | Xcode changed a shared project file (the team or recommended settings). | Quit Xcode and run `python3 ios/scripts/check.py`. Run the command on its `Xcode project` or `Apple team` line, then `git pull` again. If the files are in `ios/Captura.xcodeproj`, `git checkout -- ios/Captura.xcodeproj` undoes them. |
| `git clone`: "destination path 'captura' already exists" | You downloaded Captura before. | Step 3: `git -C ~/captura pull`. |
| Xcode says the App ID limit was reached | A free account can register only 10 App IDs in 7 days. | Keep one bundle ID and wait for the limit to reset. Don't keep changing bundle IDs. |
| Xcode says the maximum number of apps for free development profiles was reached | Only 3 apps installed from Xcode fit on one iPhone. | Remove another app you installed from Xcode. Never remove Captura while it has recordings waiting. Then press Run again. |
| iPhone: "Desarrollador no confiable" (Untrusted Developer) | You haven't trusted your developer account yet. | Step 9. |
| The app won't open after a week | Your free install expired (7 days). | [Reinstall from the Mac](#every-7-days-reinstall-from-the-mac). Your data is kept. |
| Xcode: "Developer Mode disabled" or the iPhone isn't listed | The iPhone isn't paired or Developer Mode is off. | Step 7. Unlock the iPhone and plug the cable in again. After an iOS update, pair again. |
| Xcode: "iOS … is not installed" or "… is not supported" | The iOS platform is missing, or Xcode is older than your iPhone's iOS. | Xcode > Settings > Components > **Get** next to iOS. Update Xcode from the App Store. |
| "En pausa · no se está grabando", or the notification "Captura se pausó" | A call, Siri or another app's audio took over the microphone. It doesn't always resume by itself. | Open Captura and tap **Reanudar ahora**. Make sure you see "Grabando" again. |
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
   the person's bundle ID **exactly** as they sent it: `configure.py` printed it after
   "Send the Google admin exactly this value" (all lowercase, for example
   `com.anagarcia.captura`). Leave the App Store ID and Team ID empty. Keep App Check off, because free Apple accounts can't
   use it. Click Create and send the person the **Client ID** (it ends in
   `.apps.googleusercontent.com`). An iOS client has no secret. Create one iOS client
   per bundle ID.
5. Create the **Desktop** client for the Mac worker: Clients > Create client >
   Application type **Desktop app**. Copy its **Client ID** and **Client secret** and
   give them to whoever sets up the worker through a password manager: save both in one
   item (for example in 1Password), in fields named `client_id` and `client_secret`, and
   share that item with them. Send them the item's reference, for example
   `op://Captura/Captura worker OAuth` (vault, then item name): at
   [worker step 3](worker.md#3-connect-rclone-to-google-drive), `capture drive-setup
   --from` reads both fields from it, so nobody pastes the secret. Treat the secret like
   a password: don't send it by chat or email, and don't put it in the repository.
   For the iPhone, an item with `ios_client_id` (and `hosted_domain`, if you use one)
   lets people run step 4.2 with `--from` too. The iOS client ID isn't secret.
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
