---
name: device-loop
description: Bring up an Android emulator without Android Studio and without sudo, and validate a React Native or Expo app on it, seeing the real screen with screencap and iterating with Expo Go or a development build. Use when the native app has to be genuinely tested, when a new machine needs the emulator set up, to validate surfaces the browser does not reproduce (notifications, widgets, GL maps, dark mode) or to reproduce a bug that only happens in the built app.
---

# device-loop

The goal is for the agent to **see** the real native app and be able to iterate
on it. The route is an Android emulator, headless, driven over `adb`, with
`screencap` for the eyes.

It is the native sibling of `/visual-test`. The why of each step and of each
gotcha is in `<this-skill-directory>/references/why.md`.

## When to use

- The native app has to be tested, not a browser approximation.
- Validating what the browser does not have: notifications, widgets, native
  maps, dark mode, permissions.
- Setting up the emulator on a machine that does not have it.
- Reproducing a bug that only appears in the built app.

Look first in the project's docs repo: the emulator's name, its image, the
package and the deep links are project data.

## 1. Install it, once per machine

Everything goes under one folder in your home: no Android Studio, no `sudo`,
no system packages. Around 4 GB to run apps; 7 GB with what compiling needs.

```bash
A=~/.local/android; mkdir -p "$A/sdk/cmdline-tools"
# JDK 17, portable
curl -sSL -o /tmp/jdk.tgz \
  "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
mkdir -p "$A/jdk" && tar xzf /tmp/jdk.tgz -C "$A/jdk" --strip-components=1
# command-line tools: the current zip is on developer.android.com/studio,
# section "Command line tools only"
curl -sSL -o /tmp/clt.zip "<commandlinetools-linux-…_latest.zip>"
unzip -q /tmp/clt.zip -d /tmp/clt && mv /tmp/clt/cmdline-tools "$A/sdk/cmdline-tools/latest"
```

The environment, in every shell that uses it (or in the shell profile):

```bash
export JAVA_HOME=~/.local/android/jdk ANDROID_HOME=~/.local/android/sdk
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
```

The pieces and the virtual device. The image and the API level are the
project's; these are an example:

```bash
yes | sdkmanager --licenses >/dev/null
sdkmanager "platform-tools" "emulator" "platforms;android-35" \
  "system-images;android-35;google_apis;x86_64"
avdmanager create avd -n <avd-name> -d pixel_7 \
  -k "system-images;android-35;google_apis;x86_64"
```

To compile a development build, add what the project's Gradle asks for (build
tools, NDK, CMake): the first build says which versions are missing.

### Hardware acceleration

Without it the emulator runs in software and is unusable. Check it:

```bash
emulator -accel-check     # must say KVM is usable
```

If `/dev/kvm` is not accessible, the user runs `sudo usermod -aG kvm $USER` in
a real terminal and logs in again. The agent cannot: `sudo` needs a TTY.

## 2. Start it

```bash
emulator -avd <avd-name> -no-window -no-audio -gpu swiftshader_indirect >/tmp/emulator.log 2>&1 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 2; done
adb shell input keyevent KEYCODE_WAKEUP && adb shell wm dismiss-keyguard
# boot_completed arrives while it still says "starting": wait for the launcher
until adb shell dumpsys window | grep mCurrentFocus | grep -qi launcher; do sleep 2; done
```

If it never finishes booting, `/tmp/emulator.log` says why. To stop it:
`adb emu kill`.

## 3. See the screen

```bash
adb exec-out screencap -p > <path>/screen.png
```

And then open the PNG to look at it. Do not trust the first capture after
launching: wait for the app to paint.

**If the capture comes out black**, the focus is usually on the notification
shade or another window:

```bash
adb shell dumpsys window | grep mCurrentFocus
adb shell cmd statusbar collapse
```

Useful states to validate:

```bash
adb shell cmd uimode night yes        # dark mode (no to go back)
adb shell settings put system font_scale 1.3
```

## 4. Iterate

### Expo Go

Enough for most of the interface. Metro on the machine, the app in the
emulator:

```bash
npx expo start --android
```

If the app is left on "Cannot connect to Expo CLI" after restarting Metro,
forward the port and open the URL by hand:

```bash
adb reverse tcp:<port> tcp:<port>
adb shell am start -a android.intent.action.VIEW -d "exp://127.0.0.1:<port>"
```

### Development build

Notifications, widgets and native modules are not in Expo Go: the app is
compiled. The usual route with Expo:

```bash
npx expo prebuild -p android --no-install
(cd android && ./gradlew assembleDebug -PreactNativeArchitectures=x86_64)
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

`prebuild` can rewrite `package.json`: save a copy before and put it back after,
not with `git checkout`, which also takes uncommitted dependencies.

The development build looks for Metro on 8081. On another port, forward it
with `adb reverse` and tell the app with its `debug_http_host` preference, or
use the deep link of the development client if the project has one.

### Validating a specific APK

```bash
adb install -r <build>.apk
adb shell monkey -p <package> -c android.intent.category.LAUNCHER 1
adb exec-out screencap -p > shot.png
```

## 5. Navigating the app

Taps and keys reach the app in the emulator. Coordinates change with the
device, so look at the capture before tapping:

```bash
adb shell input tap <x> <y>
adb shell input text "<text>"
adb shell input keyevent KEYCODE_BACK
```

Faster and more stable when it exists: **open the screen by its deep link**.

```bash
adb shell am start -a android.intent.action.VIEW -d "<deep-link>"
adb logcat -d -t 200 | grep -iE "ReactNative|Exception|FATAL"
```

To reload code that only runs on mounting, close the app with
`adb shell am kill <package>` from the home screen and open it again. Not with
`am force-stop`: the app would stop receiving widget and notification events.

## Anti-patterns

- **Accepting a change without a screenshot that confirms it.** It is the whole
  point of the skill.
- **Installing Android Studio, or system packages, to get an emulator.**
- **Running the emulator without hardware acceleration.** It looks like the app
  is slow when it is the emulator.

## Related

- `/visual-test` — the web sibling, with headless Chrome
