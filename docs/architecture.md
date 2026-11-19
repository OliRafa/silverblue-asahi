# Architecture

How the silverblue-asahi image is put together, and where each kind of file lives.

## Images

```
quay.io/fedora-asahi-remix-atomic-desktops/silverblue:44   Asahi kernel-16k, firmware, m1n1/U-Boot, dracut, audio DSP, GNOME
  └─ images/silverblue-asahi/Containerfile                 bootc plumbing for Apple Silicon + provisioning  →  ghcr.io/olirafa/silverblue-asahi:44
ghcr.io/ublue-os/brew                                      prebuilt Homebrew tree, copied in from the `brew` helper stage
images/boottest/Containerfile                              FROM silverblue-asahi: the on-hardware boot smoke test (never published)
```

GNOME comes from the base exactly as Fedora Asahi Remix Silverblue ships it: GDM, GNOME Shell, GNOME Initial Setup, Nautilus, Ptyxis, Firefox, GNOME Software. The image changes the platform underneath it (bootloader, initramfs, m1n1, services, tuning) and adds provisioning (Flatpaks, Homebrew), and takes out of GNOME only what cannot work on a composefs install: GNOME Software's OS-package plugins.

### `images/silverblue-asahi/Containerfile`

| Step | What | Why |
|---|---|---|
| 1 | `packages/platform.packages` | system services, Asahi extras (tiny-dfr, widevine-installer, Honeykrisp: already in the base, listed so they stay), Docker, base CLI |
| 2 | systemd-boot; remove bootupd; mask the GRUB boot-success units | composefs + systemd-boot install; rpm-ostree, GRUB and shim stay but are inert. See [asahi.md](asahi.md) |
| 3 | remove `gnome-software-rpm-ostree`; delete GNOME Software's dnf5 plugin | neither can update a composefs install; OS updates are `bootc upgrade`. See [desktop.md](desktop.md#updates) |
| 4 | `COPY system/platform/ /` | units, helpers, tuning drop-ins, Apple HID modprobe/dracut config, the Docker socket drop-in, `50-silverblue-asahi.preset` |
| 5 | rebuild the initramfs with the `bootc` dracut module | composefs pivot; Apple HID drivers loaded early |
| 6 | `DTBS` → image devicetree; enable `silverblue-asahi-apply-m1n1` | m1n1/devicetree refresh on atomic |
| 7 | ublue brew tree + Brewfile; baked Flathub remote; mask `flatpak-add-fedora-repos`; enable the provisioning timers | `/var` is seeded only on first boot; see [Provisioning and the network](#provisioning-and-the-network) |
| 8 | enable system services; mask NetworkManager-wait-online; disable `dnf-makecache.timer`; disable sshd and drop `ssh` from the default firewalld zone | nothing in the boot waits for the network (the units that need it check for themselves); no dnf metadata downloads (see [composefs is not ostree](#composefs-is-not-ostree)); SSH is opt-in |
| 9 | `COPY system/desktop/ /`; open LocalSend's port; assert GDM, `graphical.target` and GNOME Initial Setup; make Firefox copy mtime-0 langpacks | the Flatpak app set; the build fails rather than ship an image with no way to create the first account; a non-English Firefox stays translated after updates |
| 10 | `/etc/machine-id` empty; clean residue; `bootc container lint` | no console first-boot prompts (an empty file is not a first boot); written last so nothing earlier leaves a real ID behind |

## Where files go

| Path | Owner | Notes |
|---|---|---|
| `/usr/lib/systemd/**` (including `system-preset`), `/usr/lib/sysctl.d`, `/usr/lib/udev/rules.d`, `/usr/lib/modprobe.d`, `/usr/lib/dracut/dracut.conf.d`, `/usr/lib/tmpfiles.d`, `/usr/lib/NetworkManager/conf.d`, `/usr/lib/firewalld/services` | image | vendor drop-in paths: updates flow through `bootc upgrade` and an admin can still override in `/etc` |
| `/usr/share/flatpak/preinstall.d/silverblue-asahi.preinstall` | image | the Flatpak app set |
| `/usr/share/silverblue-asahi/Brewfile` | image | the Homebrew package set |
| `/etc/sudoers.d`, `/etc/docker/daemon.json`, `/etc/cups/cups-browsed.conf`, `/etc/gnupg/dirmngr.conf`, `/etc/flatpak/remotes.d` | image, merged | only where the consumer reads nothing else; `/etc` is three-way merged on upgrade, so a local edit sticks |
| `/var/lib/silverblue-asahi` | runtime | the Brewfile stamp and the m1n1 stamp |
| `/var/lib/flatpak`, `/home/linuxbrew` | runtime | Flatpak apps and the Homebrew prefix, provisioned on first boot and updated on their own timers |
| `/var/lib/widevine` | runtime | the Widevine CDM, fetched on request by `silverblue-asahi-widevine` |

Every unit the Containerfile enables or disables also has a line in `/usr/lib/systemd/system-preset/50-silverblue-asahi.preset` (masks need none: a preset pass leaves them alone). The image ships an empty `/etc/machine-id`, so a normal install never runs a full preset pass; the lines are there for the boot that does (a machine-id reset, or a future base that ships `uninitialized`), which would set every unit to what the presets say and, through Fedora's `99-default-disable.preset`, disable anything they do not list. The smoke tests run `systemctl preset-all` in the image and require that nothing changes.

`/var` is created from the image only on the first boot of a deployment and never updated by `bootc upgrade`, so nothing in the image may rely on content baked into `/var`; directories come from `tmpfiles.d`, state from first-boot units.

## composefs is not ostree

Stock Silverblue boots through ostree, and a good deal of Fedora keys its atomic-desktop behaviour on the file ostree writes at boot, `/run/ostree-booted`. A composefs-native bootc boot never writes it (bootc's own `generator.rs` says so), so without adjustments this image would behave like a mutable Fedora in some places and like nothing at all in others:

| Gated on | Unit or program | Off ostree it would | The image |
|---|---|---|---|
| `!/run/ostree-booted` | `dnf-makecache.timer` | download dnf metadata every 3 hours for a read-only `/usr` | disables it (step 8, and the preset) |
| `/run/ostree-booted` | `bootc-fetch-apply-updates.timer` and `.service` | never fire, so enabling automatic updates does nothing | resets the condition in a drop-in; the timer stays disabled |
| `/run/ostree-booted` | `fedora-atomic-desktop-appstream-cache-refresh.service`, `fedora-atomic-desktop-mandb-update.service` | never run, leaving the AppStream and man-db caches in `/var` empty or stale | resets the condition in a drop-in, restating `ConditionPathIsReadWrite=/var` (an empty `Condition*=` clears them all) |
| `-e /run/ostree-booted` | `/usr/bin/firefox` | symlink the language pack instead of copying it; with every file at mtime 0, Firefox misses its updates and falls back to English | step 9 makes it copy whenever the langpack's mtime is 0 |
| `/run/ostree-booted` | `rpm-ostree-countme.timer`, `fedora-third-party-refresh.service`, the ostree units | skip | nothing: none of them can work here |

`platform-smoke.sh` and `desktop-smoke.sh` check each adjustment, and `test/unit.d/platform-overlay-test.sh` the sources.

## Boot and first-boot flow

```
m1n1 → U-Boot → systemd-boot → kernel + initramfs (bootc composefs pivot, hid_apple loaded)
  → systemd: machine ID generated (the image's /etc/machine-id is empty: no systemd-firstboot prompts)
  → GDM
      no human account yet → GNOME Initial Setup (language, keyboard, Wi-Fi, timezone, the admin account)
      otherwise            → the login screen → GNOME on Wayland
background: silverblue-asahi-apply-m1n1, brew-setup (unpacks Homebrew)
timers: silverblue-asahi-flatpak-preinstall (once the remotes answer),
        silverblue-asahi-brew-setup (once the account exists and Homebrew answers)
        — 30s after boot, then every 2 min until they have run
```

## Provisioning and the network

The image masks `NetworkManager-wait-online`, so nothing in the boot waits for the network and `network-online.target` is reached before Wi-Fi has associated; on a fresh install Wi-Fi is not even configured until the user picks a network in GNOME Initial Setup or the session. A unit that needs the network therefore cannot be started at boot and ordered after `network-online.target`: it runs offline. For `flatpak preinstall` that is silent, because offline it skips every ref it cannot reach, prints "Nothing to do." and exits 0.

The units that need the network wait for it themselves:

- `ExecCondition=/usr/libexec/silverblue-asahi-online [--wait=SECONDS] HOST...` asks each host the unit is about to talk to for `https://HOST/` with curl (each request bounded by a timeout). Any HTTP status counts as an answer, but the certificate has to validate: a name that merely resolves is not enough, because a captive portal, or a host pinned to the wrong address, resolves too and `flatpak preinstall` still exits 0 having installed nothing. While a host does not answer it exits 1 and systemd skips the unit: inactive, not failed. `--wait` keeps asking every few seconds for a bounded time before giving up. Misuse, or a check that cannot run (no curl, no CA bundle), exits 255, which systemd counts as a failure rather than a skip, so a broken condition is reported instead of skipping forever. What that failure looks like depends on the unit: the Flatpak units show in `systemctl --failed`; `silverblue-asahi-brew-setup` restarts on it like on any other failure (see below), so it never shows there and only its journal tells.
- A timer starts the unit `OnBootSec=30s` and again `OnUnitInactiveSec=2min` after each run that ended inactive (skipped) or failed.
- The service is `Type=oneshot` with `RemainAfterExit=yes` and no `[Install]` section: a run that exits 0 stays active, so the timer has nothing left to start until the next boot. With `--noninteractive`, an install or download error makes `flatpak preinstall` exit 1, so the unit fails and the timer tries again 2 minutes later. One case waits for the next boot: a remote passes the HTTPS check but its index then cannot be fetched, and `flatpak preinstall` skips its refs, prints "Nothing to do." and exits 0.
- The service has no `Condition*=` at all: a unit skipped by a plain condition is inactive too, so the timer would start it every 2 minutes for the rest of the boot.
- Where a real failure is expensive to repeat (`brew bundle` may build formulae from source), the service backs off on its own: `Restart=on-failure` from 5 minutes up to 2 hours (`RestartSteps=`, `RestartMaxDelaySec=`), with `RestartMode=direct`. Without that mode each failure leaves the unit inactive for an instant, the timer's `OnUnitInactiveSec=` fires on top of the pending restart, and its start cuts the delay short and resets the backoff (seen on systemd 259). A skip by `ExecCondition=` never triggers a restart; a 255 from `silverblue-asahi-online` is a failure, so it does.

| Unit | Started by | Waits for |
|---|---|---|
| `silverblue-asahi-flatpak-preinstall.service` | `silverblue-asahi-flatpak-preinstall.timer`, every boot (later additions to the app set apply; apps the user removed stay removed) | `dl.flathub.org`, `registry.fedoraproject.org` |
| `brew-update.service`, `brew-upgrade.service` (ublue's) | their own timers, 10 and 30 minutes after boot, then every 6 and 8 hours | the Brewfile stamp: our drop-ins add `ConditionPathExists=/var/lib/silverblue-asahi/brew-setup-done`, so they neither fail (ublue runs them as `User=1000`, which may not exist yet) nor race `brew bundle`, and run brew as the prefix's owner through `runuser` instead of a fixed uid |
| `silverblue-asahi-flatpak-update.service` | `silverblue-asahi-flatpak-update.timer`, daily | the same hosts, with `--wait=300`: the catch-up run fires at boot or right at resume, before Wi-Fi has reconnected, and nothing retries it, so it waits up to 5 minutes for the network (then checks for a metered link) and only then skips until the next day |
| `silverblue-asahi-brew-setup.service` | `silverblue-asahi-brew-setup.timer`, every boot; wants and is ordered after `brew-setup.service` (the unpack: re-queued on every try, a no-op once done) | first the account: `ExecCondition=/usr/libexec/silverblue-asahi-primary-user` skips it until GNOME Initial Setup has created one. Then `formulae.brew.sh`, `ghcr.io`, until the Brewfile has been applied: once `/var/lib/silverblue-asahi/brew-setup-done` exists the condition passes at once and the run is an instant no-op. A `brew bundle` that fails is retried with a growing delay instead of every 2 minutes (see above) |
