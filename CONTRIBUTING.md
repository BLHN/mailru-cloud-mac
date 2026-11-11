# Contributing

Thanks for helping. Issues and pull requests are welcome in Russian or English.

## Build

Requirements: macOS 14 or later, Xcode or the Command Line Tools (Swift 5.9+).

```sh
./build.sh              # dist/Облачко.app, universal (arm64 + x86_64), rclone inside
./build.sh --run        # the same, then open it
./build.sh --dev        # dist/Облачко Dev.app for this Mac's architecture only
```

`scripts/fetch-rclone.sh` downloads the pinned official rclone release once (into
`.build/rclone-cache`, override with `RCLONE_CACHE_DIR`) and checks it against the SHA-256 sums pinned
in the script. Builds are signed ad-hoc unless `SIGN_IDENTITY` names a code signing identity from your
keychain.

## The dev build

`./build.sh --dev` compiles with `-DCLOUDMAIL_DEV` and makes a separate app with the bundle id
`ru.blhn.cloudmail.dev`: its own queue, UserDefaults, log (`~/Library/Logs/CloudMail-Dev.log`) and
Keychain item, no Finder services and no `.mailcloud` file type. It can run next to an installed copy
without touching it. Start it in the background:

```sh
open -n -g "dist/Облачко Dev.app" --args --dev-demo --dev-section transfers
```

Dev flags (they work only in the dev build; the full list is in `Sources/CloudMail/AppPaths.swift`):

- `--dev-demo`: fake transfers and a fake cloud listing in every state, no rclone, nothing saved.
  `--dev-demo-promo` switches to a calmer, presentable data set.
- `--dev-section transfers|cloud|settings`, `--dev-appearance light|dark`, `--dev-window-size 1100x700`.
- `--dev-onboarding welcome|password|phone|signin|done|move` and
  `--dev-onboarding-error 3.1 ... 3.8`: one onboarding screen or error state.
- `--dev-selftest`: account plumbing checks with invented credentials, then quit.

Environment for the demo: `CLOUDMAIL_DEV_DEMO_ACCOUNT=example@mail.ru` shows that invented address as
signed in; `CLOUDMAIL_DEV_DEMO_NO_SUPERVISOR=1` hides the optional background supervisor view.

`Packaging/dev/devshots.sh <name> [dev flags]` launches the dev app in the background, captures its
window into `docs/screenshots/<name>.png` and quits that instance by pid. The README screenshots were
made with:

```sh
export DEVSHOTS_ENV="RCLONE_CONFIG=/dev/null CLOUDMAIL_DEV_DEMO_NO_SUPERVISOR=1 CLOUDMAIL_DEV_DEMO_ACCOUNT=example@mail.ru"
Packaging/dev/devshots.sh transfers-light --dev-demo --dev-demo-promo --dev-section transfers --dev-appearance light --dev-window-size 1100x700
```

## Rules

- **No telemetry**, analytics or calls to any server other than Mail.ru's WebDAV endpoint.
- **The password lives only in the Keychain.** Never put it, or rclone's obscured form of it, in argv,
  a file, the log or a crash message. rclone gets it only through its own process environment.
- **Screenshots only from the demo mode**, never from a real account or real folders. Strip their
  metadata before committing.
- Code, comments and commit messages in English. The interface is in conversational Russian, without
  exclamation marks and without the long dash.
- Dev-only code stays behind `AppPaths.isDev` or `#if CLOUDMAIL_DEV`.
- The look of the app is described in `docs/DESIGN.md`; follow it.
- Run `scripts/privacy-gate.sh` before you push. CI runs it too. It also reads extra forbidden
  patterns (one extended regex per line, for words personal to you) from `.git/info/privacy-patterns`
  or the file named by `PRIVACY_PATTERNS_FILE`, which is never committed.
