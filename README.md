# silverblue-asahi

Fedora Silverblue for Apple Silicon Macs, as a bootc image: stock GNOME on [Fedora Asahi Remix](https://asahilinux.org/fedora/), booted through systemd-boot on bootc's composefs backend.

silverblue-asahi is a [bootc](https://bootc-dev.github.io/bootc/) image built on the [Fedora Asahi Remix atomic desktops](https://github.com/fedora-asahi-remix-atomic-desktops)' Silverblue image. GNOME is left exactly as Fedora ships it; the image changes the platform underneath (bootloader, initramfs, m1n1 refresh, services, tuning) and provisions a set of apps on first boot. The whole OS is one signed container image; updates are atomic and roll back with `bootc rollback`.

| Image | What it is |
|---|---|
| `ghcr.io/olirafa/silverblue-asahi:44` | GNOME on the stock Asahi `kernel-16k`, arm64 only (also tagged `latest`) |

Rebuilt weekly and on every change, smoke-tested, and cosign-signed.

## What you get

- **Desktop:** GNOME on Wayland with GDM, as on Fedora Silverblue. GNOME Initial Setup creates your account on first boot.
- **Apps:** Firefox, Nautilus, Ptyxis and the rest of Silverblue's RPM set in the image; GNOME's default apps (Calculator, Text Editor, Loupe, Papers, Calendar, Maps, Weather and the rest) plus Brave, Bitwarden, LibreOffice, Obsidian and LocalSend from Flathub, and OBS Studio from Fedora's Flatpak registry (Flathub has no aarch64 build), all installed on first boot; Docker, with Compose and Buildx; developer tools (Neovim, language toolchains, gh, ripgrep, fd, bat, lazygit, tmux, btop and more) from the [Brewfile](Brewfile) through Homebrew.
- **Apple Silicon:** systemd-boot on composefs, m1n1/devicetree refresh after updates, the trackpad boot-race fix and macOS-style function keys in the initramfs, Widevine DRM on aarch64 for Firefox and Brave. See [docs/asahi.md](docs/asahi.md).
- **Tuning:** zram with zstd, systemd-oomd killing apps before the session, the Kyber I/O scheduler, Wi-Fi power save off, power profiles from tuned-ppd, driverless printer discovery, SSH off by default.

## Install

On a Mac running **Fedora Asahi Remix 44** (install it alongside macOS first):

```sh
sudo dnf install -y git podman          # Fedora Asahi Remix Minimal ships neither
git clone https://github.com/OliRafa/silverblue-asahi && cd silverblue-asahi
sudo deploy/silverblue-asahi-install ghcr.io/olirafa/silverblue-asahi:44
sudo reboot
```

The installer grows the Asahi ESP if needed, preserves the m1n1/firmware preboot layer, and installs silverblue-asahi with the composefs backend and systemd-boot. Details and recovery: [deploy/README.md](deploy/README.md).

Already on a composefs + systemd-boot bootc image? Switch in place:

```sh
sudo bootc switch ghcr.io/olirafa/silverblue-asahi:44
sudo reboot
```

### First boot

1. GNOME Initial Setup comes up instead of the login screen: language, keyboard layout, Wi-Fi, privacy, timezone, and your account, which becomes an administrator (`sudo`, and Docker without `sudo`). Nothing asks on the console before it. A `bootc switch` keeps the existing account, so it goes straight to the login screen.
2. The Flatpak apps install in the background as soon as the network is up (system-wide, so they need no account, and may already be installing during setup), and the Brewfile once the account exists too: until Flathub, Fedora's registry and Homebrew's servers answer over HTTPS, each is tried again every couple of minutes, so connecting to Wi-Fi during setup is enough. A Brewfile that fails to apply is tried again after a growing delay (5 minutes, up to 2 hours).
3. A reboot or two later, `silverblue-asahi-apply-m1n1` has refreshed m1n1 and the devicetree for the installed kernel.

For DRM video (Spotify, Netflix): run `silverblue-asahi-widevine` once and restart Firefox. For Brave, open it once first, then quit it and run the command.

## Update

```sh
sudo bootc upgrade && sudo reboot
```

GNOME Software updates Flatpaks and firmware, but not the OS: on a composefs install, OS updates come only from `bootc upgrade` (see [docs/desktop.md](docs/desktop.md#updates)). Apple Silicon needs one more reboot when the kernel changes: the first boot onto a new kernel refreshes m1n1 and the devicetree, the next one uses them (`SILVERBLUE_ASAHI_M1N1_AUTOREBOOT=1` in `/etc/default/silverblue-asahi-m1n1` takes it automatically). Flatpaks update daily and Homebrew updates itself, independently of the image. `sudo bootc rollback` returns to the previous image.

## Build and test

On an aarch64 host with podman and ~20 GB free:

```sh
./images/build.sh                # → silverblue-asahi:44
./test/all                       # no image needed: syntax, unit tests, deploy library tests
```

On x86_64, `ENGINE_ARGS=--arch=arm64 ./images/build.sh` builds under qemu-user emulation, slowly. The image smoke tests and a real `bootc install to-disk` run in CI on an arm64 runner. See [docs/testing.md](docs/testing.md).

## Documentation

- [docs/architecture.md](docs/architecture.md) — how the image is put together
- [docs/desktop.md](docs/desktop.md) — what differs from stock Silverblue: apps, first boot, updates, Docker, Homebrew, DRM
- [docs/asahi.md](docs/asahi.md) — Apple Silicon platform decisions
- [docs/testing.md](docs/testing.md) — what is tested where
- [deploy/README.md](deploy/README.md) — installing, the ESP, signing, first boot, m1n1

## Credits

silverblue-asahi's platform layer — the bootc plumbing for Asahi, the provisioning helpers, the deploy tooling and much of the system tuning — comes, by way of Fenoa, from omarchy-atomic, a Fedora Asahi atomic fork of [Omarchy](https://omarchy.org). Thanks to the [Asahi Linux](https://asahilinux.org) project, the [Fedora Asahi Remix atomic desktops](https://github.com/fedora-asahi-remix-atomic-desktops) project, and [Universal Blue](https://universal-blue.org) for the prebuilt Homebrew image.
