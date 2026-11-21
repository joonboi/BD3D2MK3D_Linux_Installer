# BD3D2MK3D Linux Installer

Universal Linux installer for **BD3D2MK3D**.

Requires an **x86_64 Linux system** and one of the supported package managers:

- APT
- DNF
- Zypper
- Pacman
- XBPS
- APK

## Tested environments

| Distribution | Package manager | Result |
|---|---|---|
| Ubuntu | APT | Installed and opened |
| Void Linux | XBPS | Installed and opened |
| Fedora | DNF | Installed and opened |
| openSUSE | Zypper | Installed and opened |
| CachyOS | Pacman | Installed and opened |
| Alpine Linux | APK | Installed and opened |

## Install

Download and run the installer from a logged-in graphical desktop session:

```bash
curl -fL -o bd3d2mk3d-installer.sh \
  https://raw.githubusercontent.com/joonboi/BD3D2MK3D_Linux_Installer/main/bd3d2mk3d-installer.sh
chmod +x bd3d2mk3d-installer.sh
./bd3d2mk3d-installer.sh
```

The installer requires administrative access through `sudo`.

## What it installs

The installer creates an isolated 64-bit Wine environment and installs or verifies:

- Wine
- Wine Mono
- Wine Gecko
- Core fonts
- Windows Java
- AviSynth+
- BD3D2MK3D

It creates an application-menu entry and, when available, a desktop shortcut.

## Logs

Installer logs are stored in:

```text
~/.local/state/bd3d2mk3d-installer/
```

The most recent log is:

```text
~/.local/state/bd3d2mk3d-installer/latest.log
```

## License

This project is licensed under the [MIT License](LICENSE).