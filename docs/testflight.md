# TestFlight: install on an iPhone without Xcode

[`docs/ios.md`](ios.md) installs the app from your own Mac with a cable. This page is the
other way round: a GitHub macOS runner builds and uploads the app, and testers install it
from the **TestFlight** app. A tester needs no Mac, no Xcode and no cable.

It costs one paid Apple Developer Program membership (the account that owns the build) and
a first setup of about an hour. After that every build is one click in Actions.

What it does not change: the bundle ID still has to match a Google "iOS" OAuth client, and
the [worker](worker.md) on a Mac is still what transcribes.

## What the account holder sets up once

Everything here is the Apple and GitHub web interface. Xcode is not needed.

1. **Register the bundle ID.** developer.apple.com > Certificates, Identifiers & Profiles >
   Identifiers > **+** > App IDs > App. Use the same bundle ID every tester's build will
   have, for example `com.yourorg.captura`, and enable **Background Modes** is not needed:
   the audio and processing modes in `ios/Support/Info.plist` need no entitlement.
   - Note your **Team ID** (top right of the developer site, 10 characters).
2. **Create the app record.** App Store Connect > Apps > **+** > New App, platform iOS, the
   bundle ID from step 1. The name there must be unique across App Store Connect; it is not
   the name on the Home Screen (that is `CFBundleDisplayName`).
3. **Create an API key.** App Store Connect > Users and Access > Integrations > App Store
   Connect API > **+**, access **App Manager**. Download the `.p8` (only possible once) and
   note the **Key ID** and the **Issuer ID**.
4. **Add the testers.** App Store Connect > Users and Access > **+** for each person, then
   TestFlight > Internal Testing > add them to a group. Internal builds skip App Review.
   - An Apple Developer Program **individual** membership can give up to 50 people App Store
     Connect access, but they are not members of the signing team: only the account holder
     can produce a build. An **organization** membership can share that.
5. **Store the values in the fork's GitHub repository** (Settings > Secrets and variables >
   Actions):

   | Name | Kind | Value |
   | --- | --- | --- |
   | `APPLE_TEAM_ID` | secret | the 10-character Team ID |
   | `ASC_KEY_ID` | secret | Key ID from step 3 |
   | `ASC_ISSUER_ID` | secret | Issuer ID from step 3 |
   | `ASC_KEY_P8` | secret | the whole `.p8` file, `-----BEGIN` line included |
   | `CAPTURA_BUNDLE_ID` | secret | the bundle ID from step 1 |
   | `CAPTURA_GOOGLE_IOS_CLIENT_ID` | secret | the Google iOS client ID for that bundle ID |
   | `CAPTURA_GOOGLE_HOSTED_DOMAIN` | variable | optional Workspace domain, or leave unset |

   The bundle ID and the client ID are not secret, but keeping them as secrets stops a fork
   from building against your Google project by accident.

## Each build

Actions > **iOS TestFlight** > Run workflow. Pushing a tag that starts with `ios-v` does the
same. The run takes about 10 minutes and ends with the build in TestFlight.

- The workflow signs with `-allowProvisioningUpdates` and the API key, so Apple issues and
  renews the distribution certificate and the provisioning profile. No `.p12` is stored.
- `CURRENT_PROJECT_VERSION` is the Actions run number, so every upload has a new build
  number. `MARKETING_VERSION` stays what `project.pbxproj` says.
- `testFlightInternalTestingOnly` is set: the build goes to internal testers only and is
  never offered for external distribution by accident.
- `ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so no export
  compliance question per build.

## What the tester does

1. Install **TestFlight** from the App Store and accept the invitation email.
2. Open TestFlight, install Captura, then continue at [step 10 of the iPhone
   guide](ios.es.md#10-primer-uso) (microphone, Google Drive, folder ID).
3. A TestFlight build stops working after **90 days**. Installing the next build resets it.
   Recordings are not lost, but do not delete the app with recordings still to upload.

## If a run fails

| Message | Cause | Next |
| --- | --- | --- |
| `No Accounts` / `No profiles for '<bundle id>' were found` | the bundle ID of step 1 is not in that team, or the key lacks App Manager | redo steps 1 and 3; check `CAPTURA_BUNDLE_ID` |
| `Invalid Application` / `app record not found` | no app record for the bundle ID | step 2 |
| `The provided entity includes an attribute with a value that has already been used` | the build number repeated | re-run; the run number always grows |
| `Not changed:` from `configure.py` | a secret still holds an example value | fix the secret named in the message |
