# Testing

Three tiers, from cheapest to most faithful.

## 1. No image: `./test/all`

Runs anywhere (CI: `.github/workflows/tests.yml` on ubuntu, plus shellcheck at error level).

- `bash -n` on every shell script (`test/shell-files` lists them: `*.sh` plus anything with a `#!/bin/bash` shebang)
- `test/unit` — every `test/unit.d/*-test.sh`, hermetic, stubbing commands through `PATH`:
  - `apply-m1n1-test.sh` — the zero-mtime gzip workaround in `silverblue-asahi-apply-m1n1`, and that it only runs on a boot that came through m1n1
  - `brew-setup-test.sh` — the timer and its static service, the account condition (`silverblue-asahi-primary-user`, checked before the network), the stamp-or-`silverblue-asahi-online` condition run against a stub, the restart backoff for real failures, wanting and ordering after the unpack, ublue's `brew-update`/`brew-upgrade` held until the Brewfile stamp and run as the prefix's owner, build and preset wiring; primary-user detection (login.defs bounds, the DynamicUser UID trap, the name rather than the passwd placeholder), empty-prefix debris, no download
  - `flatpak-provisioning-test.sh` — the preinstall timer and its static service (`silverblue-asahi-online` condition, no `Restart=`, no condition the timer could loop on, not ordered before the system helper), the update units (a bounded network wait before the metered check), and their build and preset wiring
  - `online-test.sh` — `silverblue-asahi-online` asks `https://HOST/` with neither `--fail` nor `--insecure`; its exit status (0 answered, 1 no answer, a certificate that does not validate or a timeout, 255 misuse, including an octal-looking or overlong `--wait`, or a check that cannot run); `--wait` retrying until an answer or its bound; and the hosts the units pass it
  - `widevine-test.sh` — CDM wiring into Flatpak profiles, the canonical-path hint, Brave's opt-in
  - `platform-overlay-test.sh` — Apple HID drop-ins reach the initramfs step, enabled units ship, `50-silverblue-asahi.preset` (and the boottest image's preset) covers every unit the Containerfile enables or disables and is read before Fedora's presets, `/etc/machine-id` written empty after the last package transaction, bootupd removed on its own (rpm-ostree, GRUB and shim never in a `dnf remove`), GNOME Software's rpm-ostree and dnf5 plugins gone and GNOME Software kept, the composefs-versus-ostree adjustments, the Docker socket's `wheel` group, app.slice's own 50% oomd limit (no dead `DefaultMemoryPressureLimit=`), plocate's `/var` directory from tmpfiles.d, sshd off, no desktop packages in `platform.packages` and no power-profiles-daemon, no Omarchy/Fenoa/Hyprland leftovers, shebangs
- `deploy/tests/*.test.sh` — the ESP backup/restore, capacity, GPT absorb, boot-entry repair and BLS prune libraries

Unit tests source `test/unit.d/base-test.sh` (`pass`, `fail`, `require_command`, and `containerfile_units`/`check_preset` for the preset coverage checks). A file stops at its first failure; the runner keeps going and reports every failing file.

## 2. Built image: `images/silverblue-asahi/hack/`

CI: `.github/workflows/image-e2e.yml` on `ubuntu-24.04-arm`, building with rootful podman because `bootc install` reads `/var/lib/containers`.

| Script | Checks |
|---|---|
| `platform-smoke.sh` | Asahi base, one kernel, systemd-boot, bootupd gone (rpm-ostree/GRUB/shim reported, inert), masked grub units, initramfs (composefs pivot, Apple HID), m1n1 wiring, no human user baked in, `/etc/machine-id` an empty file, root locked, `silverblue-asahi-primary-user` finds no account, Flatpak/brew units (static, started by their enabled timers, `silverblue-asahi-online` executable, curl present, ublue's brew timers gated by our drop-ins), services (tuned-ppd, no power-profiles-daemon), the Docker socket's `wheel` drop-in, zsh in `/etc/shells`, the composefs-versus-ostree adjustments (dnf-makecache off, the ostree-only units ungated as systemd's own unit loader reads them, automatic updates still opt-in), sshd off (also after a preset pass) and closed in firewalld, tuning files, the effective oomd settings of `app.slice` and `session.slice` from systemd's own unit loader (apps at 50%, the session at Fedora's 80%), a full `systemctl preset-all` changes nothing, no Omarchy/Fenoa files or Hyprland/greetd packages, `systemd-analyze verify` of the shipped units (reported, not fatal) |
| `desktop-smoke.sh` | GNOME's packages and Wayland session, GDM as display manager, `graphical.target`, GNOME Initial Setup present and not disabled in `custom.conf` (no automatic login, account page not skipped), GNOME Software without `gnome-software-rpm-ostree` or any rpm-ostree/dnf5 plugin but with its Flatpak plugin, Firefox's Widevine pref and `MOZ_GMP_PATH`, the Firefox launcher patched to copy mtime-0 langpacks (and still parsing), every Flatpak group pinned to `stable` as an app, GNOME's default apps and the everyday apps in the manifest, LocalSend's port, GDM and `graphical.target` survive a full `systemctl preset-all` |
| `install-to-disk.sh` | real `bootc install to-disk --composefs-backend --bootloader systemd`, inspected by loop mount: systemd-boot at `EFI/BOOT/BOOTAA64.EFI` (the only path U-Boot boots) and no GRUB on the ESP, a kernel staged, the composefs layout, the installed `/etc/machine-id` still an empty file |
| `deploy/tests/esp-bootc-integration.sh` | real `bootc install to-filesystem` over a fake Asahi ESP; the preboot layer survives; also reports whether the old system's user carried over (it does not, which is why GNOME Initial Setup has to run) |

On `main` (a push, the weekly scheduled run, or a manual run; never a pull request) the workflow ends by pushing the image every step above tested as the immutable `silverblue-asahi:44-<sha>` and calling `publish.yml` with its digest, which tags it `44` and `latest` and signs it. Nothing is built twice, and what machines pull is byte for byte what passed these tests.

Locally, on an aarch64 host (or under emulation with `ENGINE_ARGS=--arch=arm64`, much slower):

```sh
./images/build.sh
./images/silverblue-asahi/hack/platform-smoke.sh silverblue-asahi:44
./images/silverblue-asahi/hack/desktop-smoke.sh silverblue-asahi:44
sudo ./images/silverblue-asahi/hack/install-to-disk.sh silverblue-asahi:44   # rootful: needs the image in root's storage
```

## 3. Hardware: `images/boottest/`

The Asahi kernels only boot on Apple Silicon, so boot-time behaviour is checked on a Mac:

```sh
podman build -t silverblue-asahi:44-boottest --build-arg BASE=silverblue-asahi:44 -f images/boottest/Containerfile .
# deploy it (bootc switch to a pushed tag, or deploy/silverblue-asahi-install), reboot twice, then:
journalctl -u silverblue-asahi-boottest
```

`boot-smoke.sh` checks the running kernel and GPU render node, that systemd-boot is what booted (its `LoaderInfo` EFI variable, or `BOOTAA64.EFI` if the firmware passes no variables on), no GRUB on the located ESP, the m1n1 stamp, services (GDM, NetworkManager, tuned, tuned-ppd, speakersafetyd…), zram, failed units, `/run/docker.sock` owned by `wheel`, gnome-shell running and no SELinux denials for GDM or GNOME Initial Setup, `hid_apple fnmode`, the trackpad, and first-boot provisioning (a machine ID committed in place of the empty file, the account once GNOME Initial Setup has run, the provisioning timers enabled).

Hardware-only by nature: GNOME Initial Setup itself and the handoff from it into the first session, the m1n1 two-reboot flow, the Touch Bar, suspend on lid close, and anything SELinux only denies at runtime.
