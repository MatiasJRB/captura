# TestFlight: install on an iPhone without Xcode

[`docs/ios.md`](ios.md) installs the app from your own Mac with a cable. This page is the
other way round: a GitHub macOS runner builds and uploads the app, and testers install it
from the **TestFlight** app. A tester needs no Mac, no Xcode and no cable.

It costs one paid Apple Developer Program membership (the account that owns the build) and
a first setup of about an hour. After that every build is one click in Actions.

Nothing signing-related lives in the repository: the Apple team, the App Store Connect API
key and the Google client are repository secrets of whoever runs the fork. A clone that has
not set them stops at the first job and says which ones are missing, instead of failing on a
build it was never meant to run.

What it does not change: the bundle ID still has to match a Google "iOS" OAuth client, and
the [worker](worker.md) on a Mac is still what transcribes.

## What the account holder sets up once

Everything here is the Apple and GitHub web interface. Xcode is not needed.

1. **Register the bundle ID.** developer.apple.com > Certificates, Identifiers & Profiles >
   Identifiers > **+** > App IDs > App. Use the same bundle ID every tester's build will
   have, for example `com.yourorg.captura`. No capability needs to be enabled: the audio
   and processing background modes in `ios/Support/Info.plist` need no entitlement.
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
same. The run takes about 4 to 10 minutes and ends with the build in TestFlight.

- The workflow signs with `-allowProvisioningUpdates` and the API key, so Apple issues and
  renews the distribution certificate and the provisioning profile itself. There is no
  certificate secret and no `.p12` to export, rotate or leak: the private key stays with
  Apple and the API key of step 3 is the only credential the runner ever holds.
- A run first checks that every secret above is set. If one is missing it writes the list to
  the run summary and stops; the build job never starts.
- `CURRENT_PROJECT_VERSION` is the Actions run number, so every upload has a new build
  number. `MARKETING_VERSION` stays what `project.pbxproj` says.
- `testFlightInternalTestingOnly` is set, so the build reaches internal testers only and
  is never offered for external distribution by accident. Internal testers must be users
  of your App Store Connect, and they get every build with no review. To hand the app to
  people who are not users, set the repository variable `TESTFLIGHT_INTERNAL_ONLY` to
  `false`, build again, and distribute that build through an external group: those take
  any email address, but the first build of a version waits for Beta App Review.
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

A run can end green and the build still fail later, while App Store Connect processes it:
TestFlight > Build uploads shows the status and the reason. `90626: Invalid Siri Support`
means an `IntentDescription` in `ios/Captura/Intents` names a device ("iPhone" and the like
are not allowed in Siri-facing text). The build number is burned either way; the next run
uses the next one.
