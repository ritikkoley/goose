# Put Goose On Your iPhone

A step-by-step guide for people new to iOS development. It takes about 30–45
minutes the first time, mostly downloads.

## What you need

- A Mac with **Xcode 26 or newer** (free, from the Mac App Store; ~10 GB).
- An iPhone on **iOS 26 or newer** and a USB cable.
- An **Apple ID**. A free account works. A paid Apple Developer account
  ($99/yr) removes the 7-day expiry and allows TestFlight.
- A **WHOOP 5.0** band. Older generations are not supported.

## 1. Get the code onto the Mac

```sh
git clone https://github.com/ritikkoley/goose.git
cd goose
git checkout claude/gifted-goldberg-q5dqdo   # until merged into main
```

## 2. Install Xcode and sign in

1. Install Xcode from the App Store and open it once. Accept the license and
   let it install components. When asked about platforms, include **iOS**.
2. Xcode → Settings → **Accounts** → `+` → Apple ID → sign in.
   A "Personal Team" appears. That's enough.

## 3. Run the setup script

```sh
Scripts/setup_mac.sh
```

The script:

- checks Xcode,
- installs Rust (asks first) and the iOS Rust targets,
- asks for your **Team ID** and a **Bundle ID**, and writes them to
  `Config/Local.xcconfig`. That file is gitignored, so your IDs never get
  committed.

Team ID: if you're unsure, leave it blank and choose the team in Xcode in
step 5. Bundle ID: any unique reverse-domain name, for example
`com.ritik.goose`. The upstream `com.goose.swift` already belongs to another
developer and will fail to sign.

## 4. Prepare the iPhone

1. Connect it by cable and unlock it. Tap **Trust This Computer**.
2. Settings → Privacy & Security → **Developer Mode** → On. The phone
   restarts. Confirm after the restart. (The option appears only after the
   phone has been connected to Xcode once. If it's missing, open Xcode →
   Window → Devices and Simulators with the phone plugged in, then check again.)

## 5. Build and install

**Option A: one command**

```sh
Scripts/deploy_to_iphone.sh
```

**Option B: Xcode UI** (easiest if signing errors appear)

1. `open GooseSwift.xcodeproj`
2. At the top, pick the **GooseSwift** scheme and your iPhone as the destination.
3. If you left Team ID blank: click the project → target **GooseSwift** →
   *Signing & Capabilities* → Team → your Personal Team. Repeat for the target
   **GooseWorkoutLiveActivityExtension**.
4. Press **▶ Run** (⌘R).

The first build compiles the Rust core, which takes a few minutes. Later
builds are fast.

## 6. First launch on the phone

- Free account only: the first launch fails with "Untrusted Developer". Go to
  Settings → General → **VPN & Device Management** → your Apple ID → **Trust**,
  then open Goose again.
- Allow **Bluetooth** when asked. Location, Notifications and Health are
  optional.

## 7. Pair with the WHOOP band

1. **Force-quit the official WHOOP app.** Swipe it away in the app switcher.
   The band talks to one app at a time.
2. Keep the band close to the phone.
3. In Goose onboarding (or More → Device), tap **Scan** and pick your WHOOP.
   Bands already connected to iOS through the WHOOP app now appear in the
   list too.
4. If iOS shows a Bluetooth pairing request, accept it.
5. When the status shows **ready**, live heart rate should start. Use
   Sync / historical sync to pull stored data off the band.

If the band never appears: turn Bluetooth off and on, make sure the WHOOP app
is closed, and try again. Don't "Forget" the band in iOS Bluetooth settings
unless you're prepared to re-pair it with the WHOOP app afterwards.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cargo not found` / `Rust target … not installed` during build | Re-run `Scripts/setup_mac.sh` |
| "No profiles for 'com.…' were found" / "Failed to register bundle identifier" | Pick a different `GOOSE_BUNDLE_ID` in `Config/Local.xcconfig` |
| "Signing requires a development team" | Set `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` or choose a team in Xcode |
| HealthKit capability error with a free account | In Xcode, Signing & Capabilities → remove HealthKit (only the weight prefill uses it) |
| "iOS 26.0 required" / device not eligible | Update the iPhone, or the app can't run on it |
| App stops opening after 7 days | Free-account limit. Re-run `Scripts/deploy_to_iphone.sh` |
| Phone not listed by the script | `xcrun devicectl list devices`. Unlock the phone, re-plug it, re-trust it |

## Rebuilding after code changes

```sh
git pull
Scripts/deploy_to_iphone.sh
```
