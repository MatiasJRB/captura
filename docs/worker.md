# Local worker (macOS)

The worker runs on your Mac. It downloads the recordings your phone uploaded to its
private Drive folder, checks that every byte matches what the phone sent, and
transcribes them locally with whisper.cpp. Voice activity detection (VAD) skips the
silent parts. Nothing is sent to a hosted AI service, and the worker never acts on
what it hears: every result is marked `review_only`.

The worker only reads from Drive (GET requests). The scripts in this repository never
download a program, a model or a credential. You run those downloads yourself, using
the commands below.

Commands run in Terminal, inside the `captura` folder (`cd ~/captura`). Each step says
what you should see. The `capture` commands print JSON. Under it, Terminal also shows
plain lines with what to do next:

- `Next:` (and sometimes `Or:` or `Fix:`) holds **one** command or one sentence. When it
  is a command, copy only the rest of that one line, after `Next: `, and paste it. Copy
  it from there, not from the JSON: inside the JSON every quote shows as `\"`, and a
  command copied that way fails.
- A line without a label above `Next:` explains it. Don't paste it.
- `Warn:` lines describe something to look at. They don't stop you.
- `Then fix:` names what else is wrong, in the order to fix it.

`python3 bin/capture COMMAND --help` explains each command. If a coding agent (Claude
Code, Codex) is helping you, ask it to follow
[`.claude/skills/captura-setup/SKILL.md`](../.claude/skills/captura-setup/SKILL.md).

## What you need

- The Mac where you set up the iPhone ([iPhone setup](ios.md)). An Android phone works
  the same way.
- [Homebrew](https://brew.sh). Install it by following the instructions on its home page.
  When the installer finishes, it prints **Next steps** with commands that add `brew` to
  your PATH. Run them, then open a new Terminal window.
- A macOS user that is an **administrator**: the Homebrew installer asks for your Mac
  password and needs admin rights. To check, open System Settings > Users & Groups
  (Configuración del Sistema > Usuarios y grupos): your user should say "Admin". If it
  doesn't, for example on a company Mac, ask IT to install Homebrew and
  `brew install whisper.cpp ffmpeg rclone` for you, then continue at step 2.
- Python 3.9 or later. The `python3` that comes with Xcode is enough.
- About 2 GB of free disk space for the speech model.
- From the Google admin: the **Desktop** client ID and client secret, created in the
  same Google Cloud project as the phone's client ([admin steps](ios.md#google-cloud-setup-for-the-admin)).
  Get them through a password manager item the admin shares with you (for example in
  1Password), not by chat or email. You paste them from there in step 3.
- The Google account the phone linked, and the folder ID the phone shows under
  "Copiar ID de carpeta".

## 1. Install the tools

```sh
brew install whisper.cpp ffmpeg rclone
```

- *You should see:* Homebrew finish without errors. The speech tool is called
  `whisper-cli`.
- *If `brew` is not found:* Homebrew isn't installed, or isn't on your PATH yet. If you
  installed it, run the commands it printed under **Next steps**. If that window is
  gone, these two lines do the same on a Mac with Apple silicon:

  ```sh
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

  Then open a new Terminal window and run `brew install ...` again.

## 2. Download the speech models

You run these commands yourself. They download about 1.6 GB.

```sh
mkdir -p ~/.cache/whisper
curl -L --fail -o ~/.cache/whisper/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
curl -L --fail -o ~/.cache/whisper/ggml-silero-v6.2.0.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin
```

- *You should see:* a progress bar for each file. The first file is 1,624,555,275 bytes
  and the second is 885,098 bytes. Step 5 checks both.
- *If a download stops halfway:* run the same `curl` line again.
- *If transcription is too slow or makes the Mac hot:* download the smaller
  [`ggml-large-v3-turbo-q5_0.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin)
  (574 MB) or [`ggml-small.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin)
  (488 MB), in that order of preference. Smaller models such as `ggml-base.bin` work
  but make more mistakes; doctor warns about them. Before step 4, pass `--model ~/.cache/whisper/THAT-FILE` to `capture init`.
  After step 4, switch with `python3 bin/capture set --model ~/.cache/whisper/THAT-FILE`,
  which keeps the rest of your settings and the pinned folder.

Check each model's license before you share it with anyone. This repository doesn't
include any model.

## 3. Connect rclone to Google Drive

The worker uses [rclone](https://rclone.org/drive/) only to keep its Google
authorization fresh. Use the **Desktop** client from the admin. rclone's built-in
shared client is being retired during 2026, so don't use it.

Have the password manager item open. Run these lines one at a time. At each prompt,
paste the value from the item and press Return:

```sh
printf 'Desktop client ID: '; read -r CAPTURA_CLIENT_ID
printf 'Desktop client secret: '; read -rs CAPTURA_SECRET; echo; echo "Got ${#CAPTURA_SECRET} characters."
rclone config create captura drive client_id="$CAPTURA_CLIENT_ID" client_secret="$CAPTURA_SECRET" scope=drive.file > /dev/null
unset CAPTURA_CLIENT_ID CAPTURA_SECRET
```

The secret doesn't show while you paste it, so the second line tells you how many
characters arrived. This keeps the secret out of your shell history, and `> /dev/null`
hides what rclone prints at the end, which includes the secret and the access token.

- *You should see:* `Got` and a number above 0, then a few lines from rclone and your
  browser open on a Google sign-in page. Sign in with the **same account the phone
  linked** and allow access. The browser then says "Success", and Terminal shows the
  prompt again.
- rclone's lines include `NOTICE: Make sure your Redirect URL is set to
  "http://127.0.0.1:53682/" in your custom config`, `Please go to the following link`
  and `Waiting for code...`. Ignore the NOTICE: a Desktop client needs no redirect URL,
  so there is nothing to set in Google Cloud.
- *If it says `Got 0 characters`:* the paste didn't arrive. Run the second line again
  before the third.
- *If the browser does not open:* copy the `http://127.0.0.1:53682/...` link that rclone
  prints into your browser.
- *If rclone or Google says `invalid_client`, `unauthorized_client`, "The OAuth client
  was not found" or `401`:* the client ID or secret was mistyped, or it isn't the
  **Desktop** client. Remove the remote with `rclone config delete captura`, check both
  values in the password manager, and do this step again.
- *If Google says `org_internal`, `access_denied` or `admin_policy_enforced`:* see the
  same messages in the [iPhone troubleshooting](ios.md#troubleshooting). The fixes are
  the same.

`scope=drive.file` is the narrowest permission. Whether it can see files uploaded by
the phone's client isn't documented by Google. Step 6 tests it. If it can't, switch to
read-only access to all of Drive. Same steps, after removing the remote:

```sh
rclone config delete captura
printf 'Desktop client ID: '; read -r CAPTURA_CLIENT_ID
printf 'Desktop client secret: '; read -rs CAPTURA_SECRET; echo; echo "Got ${#CAPTURA_SECRET} characters."
rclone config create captura drive client_id="$CAPTURA_CLIENT_ID" client_secret="$CAPTURA_SECRET" scope=drive.readonly > /dev/null
unset CAPTURA_CLIENT_ID CAPTURA_SECRET
```

The worker still makes only GET requests to one exact private folder. That limit is in
the worker's code, though. Google sees a read-only grant to your whole Drive, so treat
the token rclone saved in `~/.config/rclone/rclone.conf` as private.

## 4. Create the worker's settings

```sh
python3 bin/capture init --account you@yourcompany.com
```

Put the Google account you link on the phone in place of `you@yourcompany.com`. After
linking, the phone shows it under "Cuenta" ([iPhone step 10.2](ios.md#10-first-launch)).
`init` refuses the example address.

- *You should see:* `"state": "config_written"` and the path
  `~/Library/Application Support/Captura/config.json`. Only your macOS user can read
  the file.
- The defaults, and the option that changes each one:
  - transcripts go to `~/Library/Application Support/Captura/inbox` (`--root FOLDER`)
  - model `ggml-large-v3-turbo.bin` (`--model FILE`) and VAD model
    `ggml-silero-v6.2.0.bin`, both from `~/.cache/whisper`
  - Spanish (`--language es`; another code such as `en`, or `auto`)
  - the rclone remote `captura` (`--remote NAME`), read from rclone's default config file
  - the full paths of `ffmpeg`, `whisper-cli` and `rclone`
- To change a value later, use `python3 bin/capture set` with the same options, for
  example `python3 bin/capture set --root ~/Documents/Captura`. It changes only what you
  name and keeps the pinned folder.
- *If it says `invalid_account`:* you left the example address, or the address is
  mistyped. Its `Next:` line is the same command with `YOUR-GOOGLE-ADDRESS`: put your
  address there and run it.
- *If it says `config_exists`:* you already have one, and nothing was written. If you
  passed new values, its `Next:` line is the `set` command that applies just those.
  `--force` starts over instead: it resets every value and clears the pinned folder,
  so after `--force` do step 7 again.

## 5. Check everything (no network)

```sh
python3 bin/capture doctor
```

- *You should see:* `"state": "ready_with_warnings"`, and one `Warn:` line, for the
  phone's Drive folder ("not pinned yet"). The `Next:` line is the probe command.
- *If there are other `Warn:` lines:* read them. A warning about the rclone connection
  (rclone's shared client, or a scope other than `drive.file` or `drive.readonly`) means
  redoing step 3 as the line says. You can still go on and fix it later.
- *If `"state": "blocked"`:* do what the `Next:` line says. When it is a command, copy
  only that line after `Next: `, paste it and press Return. When it is a sentence,
  follow it (for example "Do step 3 of docs/worker.md"). Then run doctor again. If more
  checks fail, the `Then fix:` line names them: fix one at a time.
- *If the speech model is missing but you already have another one:* doctor names it.
  `Next:` downloads the missing model and `Or:` switches to the best one you already
  have. Run one of them, not both.

Doctor checks:

- the Python version and the config file and its permissions
- the account address
- `ffmpeg`, plus `whisper-cli` and its `--vad` option
- the size of both model files
- `rclone` and the remote: it exists, has type `drive`, its scope, that its client ID
  looks like a Google client ID, that it is authorized, and that it has its own client
- the pinned folder
- that the inbox folder is writable

It never prints the token or the client secret.

## 6. Find the phone's folder

The phone has to be linked and has to have uploaded at least one recording
([iPhone step 10](ios.md#10-first-launch)). Then:

```sh
python3 bin/capture probe
```

- *You should see:* `"state": "private_inbox_verified"` and a `folder_id`. The `Next:`
  line is the exact `pin` command for that folder; the line above it reminds you to
  compare the ID with the phone first.
- *If `"state": "waiting_for_phone_folder"` while the phone already shows a folder ID:*
  rclone can't see the phone's files with `drive.file`. Switch to `drive.readonly`
  (end of step 3) and run probe again.
- *If `"errors": ["existing_drive_authorization_unavailable"]` or
  `["existing_drive_authorization_expired"]`:* follow the `Next:` line. It sends you to
  step 3 if rclone has no `captura` remote yet, or gives
  `rclone config reconnect captura:` if the Google authorization expired.
- *If `"errors": ["drive_account_mismatch"]`:* rclone is signed in to a different Google
  account than `--account`. Run `rclone config reconnect captura:` and choose the right
  account.

Probe only reads folder details. It doesn't download any audio.

## 7. Pin the folder

Compare the `folder_id` from probe with the phone's "Copiar ID de carpeta". If they
match, run the `pin` command from probe's `Next:` line. It looks like this, with the
real ID in place of the placeholder:

```sh
python3 bin/capture pin --folder-id PASTE-THE-FOLDER-ID
```

- *You should see:* `"state": "folder_pinned"`. The worker never imports from a folder
  you haven't pinned. If the phone ever says "Se creó una carpeta nueva en Drive", pin
  the new ID.
- *If it says `placeholder_drive_id`:* you ran the line above as it is. Put the folder
  ID in place of `PASTE-THE-FOLDER-ID`. A `https://drive.google.com/drive/folders/...`
  link to the folder works too.

## 8. Run it

```sh
python3 bin/capture run
python3 bin/capture list --root "$HOME/Library/Application Support/Captura/inbox"
```

- *You should see:* `"state": "ready"` with `downloaded` and `transcribed` counts, and
  `at` with the local time of the run. Then `list` shows each recording's text, marked
  `review_only`.
- Each run downloads at most 3 recordings and transcribes at most 1. Run it again, or
  schedule it (below), until everything is done.
- *If `list` says `inbox_not_found`:* the worker hasn't created the inbox yet. Run
  `python3 bin/capture run` first. If you chose another folder with `--root`, list that
  one.
- To read the results in a browser, run
  `python3 bin/capture view --root "$HOME/Library/Application Support/Captura/inbox" --output ~/captura-review`
  and open `~/captura-review/index.html`. That folder holds copies of your audio, so
  keep it private.

## How it behaves

- `status.json`, the SQLite receipts, the failure log and the verified originals all
  stay on your Mac.
- The same file and hash is never processed twice, and the worker rejects a remote file
  that changes after it was accepted.
- After 3 failures a recording is put aside (`quarantined`) for you to inspect. The
  others keep moving.
- A revoked authorization or a missing model shows up as an error. A valid transcript
  with no speech is saved as `no_speech_detected` and not retried forever.
- ffmpeg and Whisper run in a temporary folder, so old output can never count as
  success. `record.json` is written last, so readers only see finished items.
- `quota_project` in the config is optional. Set it only if you are allowed to charge
  that project's API quota. Nothing here turns on billing or changes gcloud.

## Optional: run every 15 minutes with launchd

The scripts don't install this for you. Run one manual `capture run` that works first.
This makes a macOS LaunchAgent that runs the worker every 15 minutes while you're
logged in and the Mac is awake:

```sh
mkdir -p ~/Library/LaunchAgents ~/Library/Logs/Captura
cat > ~/Library/LaunchAgents/org.captura.worker.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.captura.worker</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$HOME/captura/bin/capture</string>
    <string>run</string>
    <string>--config</string>
    <string>$HOME/Library/Application Support/Captura/config.json</string>
  </array>
  <key>StartInterval</key><integer>900</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Captura/worker.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Captura/worker.log</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.captura.worker.plist
```

- Stop it with `launchctl bootout gui/$(id -u)/org.captura.worker`. Delete the `.plist`
  file to remove it for good.
- **Never use `launchctl submit`.** It keeps restarting the job in a loop. `bootstrap`
  with `StartInterval` runs it once per interval.
- The log holds the same JSON as a manual run, with no tokens. If two runs overlap, the
  second one stops with `worker_already_running`.
- `capture init` saved full paths to `ffmpeg`, `whisper-cli` and `rclone`, because
  launchd doesn't search Homebrew's folder. If you move the repository, edit the paths
  in the `.plist`.
