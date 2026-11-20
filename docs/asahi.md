# Apple Silicon platform notes

What silverblue-asahi does specifically for Fedora Asahi Remix on Apple Silicon, and why. Most of the hardware enablement (kernel, firmware, audio DSP, Touch Bar, m1n1/U-Boot) comes from the `quay.io/fedora-asahi-remix-atomic-desktops/silverblue` image; this page covers what silverblue-asahi adds or changes on top. The boot chain and the install itself are in [`deploy/README.md`](../deploy/README.md).

## Bootloader: systemd-boot on composefs

The image ships systemd-boot instead of GRUB, installed with `bootc install --composefs-backend --bootloader systemd`. On Asahi the chain is `m1n1 → U-Boot (UEFI) → /EFI/BOOT/BOOTAA64.EFI → kernel`, and the devicetree comes from m1n1, so the bootloader never manages it.

- `bootupd` is removed: with it installed, bootc would manage GRUB. `rpm-ostree`, `grub2-efi-aa64` and `shim-aa64` stay, inert: dnf protects `shim-aa64`, which requires the GRUB EFI binary, and `tuned` requires `rpm-ostree`. A composefs install writes neither GRUB nor shim to the ESP (`install-to-disk.sh` checks), and nothing runs rpm-ostree. GRUB's boot-success units are masked; under systemd-boot they fail on every login otherwise.
- The base image's initramfs is built for the ostree backend. A composefs install writes `composefs=<digest>` onto the kernel command line, which nothing in that initramfs reads, so the machine boots the image's kernel against whatever `/usr` is on disk and lands in emergency mode. Step 5 of `images/silverblue-asahi/Containerfile` rebuilds the initramfs with bootc's `bootc` dracut module and fails the build without `bootc-root-setup.service`. This only fails on hardware; the install succeeds either way.

## m1n1 and the devicetree on an atomic system

On mutable Asahi, `update-m1n1` rewrites `<ESP>/m1n1/boot.bin` (m1n1 stage 2 + U-Boot + devicetree) on kernel updates. On bootc nothing does, and by default it reads the static devicetree in `/boot` rather than the one in the image. A kernel with a changed devicetree (the 6.19 USB change, say) then boots against a stale one and hardware breaks.

- Build time: `DTBS` in `/etc/sysconfig/update-m1n1` points at `/usr/lib/modules/$(uname -r)/dtb`. `update-m1n1` globs `$DTBS/apple/t6*.dtb` and `$DTBS/apple/t81*.dtb`, so a kernel must install its DTBs under `dtb/apple/`.
- Run time: `silverblue-asahi-apply-m1n1.service` runs `update-m1n1` once per kernel, and only on a boot that came through m1n1: it is conditioned on `/proc/device-tree/chosen/asahi,efi-system-partition`, the devicetree property m1n1 sets and `update-m1n1` finds the ESP by (`update-m1n1` itself ships in every image, so its presence proves nothing). Every file in a composefs deployment has mtime 0 and GNU gzip exits 2 on that, killing `update-m1n1` under `set -e`; the helper bind-mounts a copy of the U-Boot blob with a real mtime over the original inside a private mount namespace.
- Two reboots are inherent: the first lands on the new kernel and refreshes `boot.bin`, the second boots with the new devicetree. Set `SILVERBLUE_ASAHI_M1N1_AUTOREBOOT=1` in `/etc/default/silverblue-asahi-m1n1` to take the second one automatically. `SILVERBLUE_ASAHI_FWEXTRACT=1` also refreshes `vendorfw` via `asahi-fwupdate` (off by default; it rarely changes).

## Keyboard and trackpad

- **Trackpad dead after some boots.** The internal keyboard and trackpad (SPI devices on M1 13" laptops — "Apple SPI Keyboard/Trackpad"; DockChannel MTP devices on M2 and later — "Apple MTP keyboard/multi-touch") first bind to `hid-generic`, then get re-created when `hid_apple` / `hid_magicmouse` load from the root filesystem. That reshuffles `/dev/input/eventN` while logind and GNOME Shell are starting; logind's TakeDevice fails ("Could not take device: No such file or directory"), libinput never retries, and the trackpad stays dead for the session. `/usr/lib/dracut/dracut.conf.d/90-silverblue-asahi-apple-hid.conf` loads both drivers from the initramfs so the devices exist before userspace starts. `hid-magicmouse` is built into the stock kernel while `hid-apple` is a module; the build checks accept either. Live recovery without a reboot: `sudo udevadm trigger --action=add /dev/input/eventN`.
- **Keyboard layout.** GNOME Initial Setup asks for it on the first boot (Settings → Keyboard changes it later). No console keymap prompt runs before GDM.
- **Function row.** `/usr/lib/modprobe.d/silverblue-asahi-apple.conf` sets `hid_apple fnmode=1`: the top row sends brightness/volume/media keys and F1–F12 need Fn, like macOS. It has to be in the initramfs too, since that is where `hid_apple` now loads.
- **Keyboard backlight.** Apple's top row has no keyboard-backlight keys. UPower picks up the `kbd_backlight` LED, and GNOME drives it from there (gnome-settings-daemon dims it when the session goes idle); the image binds no keys for it.
- **Touch Bar.** `tiny-dfr` drives the function row on 13" M1/M2 MacBook Pros. It comes with the base image (`asahi-platform-metapackage-core` requires it); `packages/platform.packages` lists it too, so the image keeps it should the base ever drop it.
- **Lid switch.** Apple Silicon reports the lid as the input switch `Apple SMC power/lid events`, not `Lid Switch`; logind handles it, so closing the lid suspends as on any laptop.

## Display

- **Notch.** silverblue-asahi leaves the Asahi default: the area beside the notch is not part of the framebuffer, so GNOME's top bar sits below it and nothing can be hidden behind it.
- **Screen recording.** GNOME's screenshot UI records through PipeWire and GStreamer; for anything more, OBS Studio is installed as a Flatpak on first boot. (gpu-screen-recorder fails on the Asahi GPU with "unknown gpu vendor: Mesa".)

## Audio

The speakers' DSP comes from `asahi-audio` (PipeWire filter chains with the bankstown/triforce LV2 plugins) and `speakersafetyd`, which must be running or the kernel keeps the speakers muted. Both ship in the base image; silverblue-asahi adds no audio tuning of its own and must not run a second DSP (EasyEffects) on the speaker sink.

## DRM (Widevine)

Google serves no arm64 Widevine CDM to the Chromium component updater, so enabling DRM in a browser fetches nothing on aarch64. `silverblue-asahi-widevine` runs Fedora Asahi's `widevine-installer` (ChromeOS LaCrOS image → arm64 CDM in `/var/lib/widevine`, persistent on bootc), so DRM sites (Spotify, Netflix) play.

- **Firefox** (the image's RPM) needs nothing more: the `widevine-installer` package ships the Firefox pref (`gmpwidevine.js`) and the `MOZ_GMP_PATH` environment entry that point it at `/var/lib/widevine`. Restart Firefox after running the command.
- **Chromium-family Flatpaks** (Brave, Chromium, Chrome) cannot see `/var/lib/widevine` from their sandbox, so the command copies the CDM into each browser's own profile. The hint file must use the canonical `/var/home/<user>/...` path the sandbox resolves; a `/home/...` path makes the browser log "Widevine enabled but no library found". Only the profile's `WidevineCdm` folder reaches the sandboxed zygote that preloads the CDM (the Flatpak launcher hands it to zypak as `ZYPAK_EXPOSE_WIDEVINE_PATH`), so the copy must live there; a CDM anywhere else fails to load with "cannot open shared object file: Operation not permitted". Brave additionally needs `brave.widevine_opted_in` in its `Local State` (the Widevine toggle in `brave://settings/extensions`); the same key in a profile's `Preferences` is ignored. A running Brave rewrites `Local State` when it quits, so the command leaves it alone then and says to quit Brave and rerun, or use the toggle. Run `silverblue-asahi-widevine` once after the browser's first start, and `silverblue-asahi-widevine --wire-only` to re-wire after a browser profile is recreated.

## Power and storage tuning

- zram sized to RAM with zstd, sysctls tuned for swap on zram (swappiness 150, page-cluster 0), zswap disabled so pages are not compressed twice.
- Kyber I/O scheduler on whole disks to keep interactive reads flowing under write floods.
- systemd-oomd acts on memory pressure. Fedora makes every user slice a kill candidate at 80% pressure; the image lowers user apps (`app.slice`, where GNOME puts every app it launches) to 50%, so under thrashing oomd takes an app before anything in GNOME Shell's `session.slice`, which keeps Fedora's 80% as a backstop. Apps are also killed when zram is more than 90% full, which Fedora does not do.
- Wi-Fi power save off (`brcmfmac` latency spikes and link drops).
- `InhibitDelayMaxSec=15` gives GNOME Shell time to lock the screen before suspend when closing the lid also reconfigures displays.
- Power profiles come from the base's `tuned` + `tuned-ppd`, which serve GNOME's Power Mode setting over the power-profiles-daemon D-Bus API; `power-profiles-daemon` itself is not installed (it conflicts with `tuned-ppd`).

## Not done (and why)

- **USB autosuspend.** `usbcore` is built into the Asahi kernels, so `options usbcore autosuspend=-1` in `modprobe.d` does nothing; it would need the kernel argument `usbcore.autosuspend=-1` via `/usr/lib/bootc/kargs.d/`, at a battery cost. Not shipped.
- **Battery charge limits.** The `macsmc` battery exposes `charge_control_end_threshold`, but nothing sets it; set it by hand (or a udev rule) if you want one.
