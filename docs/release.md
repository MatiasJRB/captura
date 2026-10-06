# Before sharing code / binaries

This is an open-source contribution experiment, not a product/market validation plan.

- [ ] Inspect staged files and entire new history; no credentials, private configs,
      phone signing key, personal brand, private recordings/transcripts or runtime DB.
- [ ] Review provenance and exact dependency/license notices. Preserve upstream notices.
- [ ] Build from a clean clone with a fresh debug key. Supply your own SDK path.
- [ ] Try a new application ID + OAuth project/account on a separate phone. Do not
      replace an actively recording phone app. No public shared OAuth is configured.
- [ ] Exercise offline capture, pause/resume, Wi-Fi/manual sync, revoked auth, partial
      retry, hash rejection, dedupe and noisy audio on real hardware.
- [ ] Decide final name, repository owner/visibility and release signing procedure.
- [ ] Show exact public contents/audience and obtain final approval before publishing.

A simple source repo, diagram and fictional demo are enough to share the idea. No
SaaS, pricing, store listing, newsletter or commercial launch is required.

## Before handing out the setup guides

[iPhone setup](ios.md) step 3 and the [worker](worker.md) clone the repository's default
branch. Someone who follows them gets only what that branch has.

- [ ] The branch with the iOS app and these guides is merged into the default branch and
      pushed. Check it offline after `git fetch origin`:
      `python3 scripts/check_public_tree.py --default-branch`. It fails, naming each
      missing file, while `origin/HEAD` lacks `docs/ios.md`, `docs/worker.md`,
      `ios/scripts/configure.py`, `ios/scripts/check.py` or `bin/capture`.
- [ ] One real pass of both guides, recorded in [verification](verification.md): Xcode 27
      on macOS 26.6 or later, a physical iPhone with a free Personal Team (Run, Developer
      Mode, trusting the developer), Google sign-in with a real iOS client, and the worker
      against a real `drive.file` remote (doctor's remote checks and
      `ready_with_warnings`, then `probe`, which decides `drive.file` versus
      `drive.readonly`).
- [ ] Open the project once with the Xcode version the guide names. If it offers
      "Update to recommended settings", decide on a branch: accept it, run the tests and
      commit the project file, so people following the guide are not offered it.
- [ ] The admin knows to send the Desktop client ID and secret through a password
      manager item ([admin step 5](ios.md#google-cloud-setup-for-the-admin)).
