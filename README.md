# ChatGPT Native Linux Repack

This folder contains the working local build path that repackages the official
Windows ChatGPT MSIX into a native Linux Electron `.deb`.

This is the path that worked on this machine. The older Wine wrapper script is
still here for reference, but the native script is the one to use.

## Files

- `build-chatgpt-native-deb.sh`
  - main build script
- `OpenAI.ChatGPT-Desktop_2026.212.2039.0.Msixbundle`
  - example input payload
- `dist/chatgpt-desktop-native_<version>_amd64.deb`
  - output package

## What The Native Script Does

1. extracts the `x64` MSIX from the bundle
2. extracts the official `app.asar`
3. patches a few Windows/macOS assumptions so the app can boot on Linux
4. stages Linux Electron around the official app resources
5. packages everything as `chatgpt-desktop-native`

## Current Linux Patches

- routes the platform chooser through the macOS-style implementation on Linux
- disables macOS-only `setVibrancy(...)` calls on Linux
- avoids the macOS `ioreg` device ID path on Linux
- carries over the official `assets/` directory expected by the app
- declares `chatgpt:` and `chatgpt-alt:` URL handlers in the desktop file
- sets the desktop entry WM class to `electron` so GNOME binds the running
  window to the ChatGPT icon instead of the generic gear

## Dependencies

The build expects local Electron tooling in this folder:

```bash
cd /home/johnohhh1/chatgpt-windows-deb
npm install electron @electron/asar --no-save
```

System tools used by the script:

```bash
sudo apt-get install -y dpkg-dev nodejs python3 file
```

## Build

```bash
cd /home/johnohhh1/chatgpt-windows-deb
./build-chatgpt-native-deb.sh --exe ./OpenAI.ChatGPT-Desktop_2026.212.2039.0.Msixbundle
```

## Install

```bash
sudo apt-get install ./dist/chatgpt-desktop-native_2026.212.2039.0_amd64.deb
```

If you rebuild without changing the version string, force the package refresh:

```bash
sudo apt-get install --reinstall ./dist/chatgpt-desktop-native_2026.212.2039.0_amd64.deb
```

## Register The Login Callback

The package installs a helper that registers the current desktop user as the
handler for the auth callback schemes:

```bash
chatgpt-desktop-native-register
```

You can verify registration with:

```bash
xdg-mime query default x-scheme-handler/chatgpt
xdg-mime query default x-scheme-handler/chatgpt-alt
```

Expected result:

```text
chatgpt-desktop-native.desktop
```

## Launch

```bash
chatgpt-desktop-native
```

## Reproducing On Another Machine

1. copy this folder to the target machine
2. place a real ChatGPT `.msix`, `.msixbundle`, `.appx`, or `.appxbundle` here
3. run the local `npm install electron @electron/asar --no-save`
4. run `./build-chatgpt-native-deb.sh --exe <payload>`
5. install the generated `.deb`
6. run `chatgpt-desktop-native-register`
7. launch `chatgpt-desktop-native`
8. if GNOME still shows the old generic icon, fully close the app and relaunch
   it once; if the shell is stubborn, log out and back in once

## Notes

- the app may still print Electron/NVIDIA/VA-API noise in the terminal
- the successful signal is functional login plus working chat, not a silent
  terminal
- if the upstream Windows app changes significantly, the patch targets in
  `build-chatgpt-native-deb.sh` may need to be updated
