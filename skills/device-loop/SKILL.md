---
name: device-loop
description: Bring up and validate a React Native or Expo mobile app on a physical Android device via adb, seeing the real screen with screencap and iterating with Fast Refresh on a development build. Use when the native app has to be genuinely tested, to reproduce a bug that only happens in release, to validate surfaces the browser does not reproduce (GL maps, camera, sensors) or to do a QA pass on a device.
---

# device-loop

The goal is for the agent to **see** the real native app and be able to iterate
on it. The route is a physical Android device over `adb` plus `screencap`.

To see code changes live you need a **development build** with Metro and Fast
Refresh. To validate an already-built APK it is enough to install, launch and
capture.

It is the native sibling of `/visual-test`. Physical device, not emulator; the
why of that and of each gotcha is in
`<this-skill-directory>/references/por-que.md`.

## When to use

- The native app has to be tested, not a browser approximation.
- Validating surfaces the browser does not faithfully reproduce.
- Reproducing a bug that only appears in the release APK. Typical case:
  environment variables that the bundler injects in development but not in
  release when they are read dynamically.

## 1. adb without sudo

The whole SDK is not needed. Download only the platform-tools to a stable path,
not to a temporary session directory:

```bash
cd ~ && curl -sSL -o pt.zip \
  https://dl.google.com/android/repository/platform-tools-latest-linux.zip
unzip -q -o pt.zip && rm pt.zip
export PATH="$HOME/platform-tools:$PATH"
adb version
```

## 2. Device permissions

It is where the most time is lost the first time.

1. On the phone: Settings, About phone, tap the build number seven times to
   unlock the developer options.
2. Enable **USB debugging**. Some manufacturers also require enabling install
   via USB.
3. Connect the cable in **file transfer** mode, not charge-only.
4. Accept on the phone the dialog allowing debugging, ticking "always allow".

If `adb devices` answers `no permissions (missing udev rules)`, the udev rule is
missing. **The user has to run this in a real terminal**: the agent cannot,
because `sudo` needs a TTY to ask for the password.

```bash
sudo tee /etc/udev/rules.d/51-android.rules >/dev/null <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="XXXX", MODE="0666", GROUP="plugdev"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

The `idVendor` comes from `lsusb`. Afterwards you have to **unplug and replug**
the cable, and restart the server:

```bash
adb kill-server && adb start-server && adb devices -l
```

It must show `device`, not `unauthorized` or `no permissions`.

### Wireless debugging

Without cable or udev, on Android 11 or later. Developer options, wireless
debugging, with the phone and the PC on the same network:

```bash
PAIR=$(adb mdns services | grep pairing | awk '{print $3}' | head -1)
adb pair "$PAIR" <6-digit-code>
adb connect $(adb mdns services | grep connect | awk '{print $3}' | head -1)
```

Two warnings: the error `protocol fault (couldn't read status message): Success`
usually means it **did** pair — check it in the phone's list of paired devices.
And if the network has client isolation, mDNS is visible but the TCP connection
gives "no route to host": then USB it is.

## 3. See the screen

```bash
adb exec-out screencap -p > <path>/phone.png
```

And then open the PNG to look at it.

**If the capture comes out black**, it is almost always that the focus is on the
notification shade or on another window, not on the app:

```bash
adb shell dumpsys window | grep mCurrentFocus
adb shell cmd statusbar collapse
adb shell input keyevent KEYCODE_HOME
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
```

GL views mounted on `TextureView` are captured fine. If the app uses
`SurfaceView`, that area may come out black even though the rest of the
interface is visible; it is not an app failure.

## 4. Iterate

### With live reload

The preview and production profiles are release builds and do **not** connect to
Metro. To iterate you need a development build:

```bash
eas build -p android --profile development   # once, takes a while
adb install -r <dev-client>.apk
pnpm start
```

From there the loop is: edit code, wait for Fast Refresh, capture, validate.
Environment variables are injected by Metro from the local file, not the build
service's.

### Validating a specific APK

```bash
adb install -r <build>.apk
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > shot.png
```

## 5. Navigating the app

**`adb shell input tap` does not reach the app on some manufacturer layers.** Do
not try to navigate with taps or keys: **open the screen by code** (temporarily
instrument the mount, or use its deep link), capture and revert. A clean mount
is needed, so force-stop and relaunch:

```bash
adb shell am force-stop <package>
adb shell am start -a android.intent.action.VIEW -d "<deep-link>"
adb shell input keyevent KEYCODE_BACK
adb exec-out screencap -p > shot.png
adb logcat -d -t 200 | grep -iE "ReactNative|Exception|FATAL"
```

If the screen is off or locked:

```bash
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
```

`dismiss-keyguard` only works if the lock is not secure; with a PIN or
fingerprint, the user unlocks it.

## Anti-patterns

- **Accepting a change without a screenshot that confirms it.** It is the whole
  point of the skill.
- **Validating in a browser something that behaves differently in the app.**
- **Trying `sudo` from the agent.** Without a TTY there is no password; ask the
  user.
- **Trusting the first capture after launching.** Wait for the focus to be the
  main activity and for the screen to have painted.

## Related

- `/visual-test` — the web sibling, with headless Chrome
