# The desktop

silverblue-asahi's desktop is GNOME exactly as Fedora Asahi Remix Silverblue ships it: GDM, GNOME Shell on Wayland, GNOME Initial Setup, and the GNOME apps of the base image. This page covers what differs from stock Silverblue and why: where the apps come from, the first boot, updates, Docker, Homebrew and DRM.

## First boot

GDM starts GNOME Initial Setup when the machine has no human account, which is the case after any fresh install (`deploy/silverblue-asahi-install` or `bootc install`): the image ships none, and a composefs install does not carry over the old system's users (see [deploy/README.md](../deploy/README.md#first-boot-gnome-initial-setup-creates-the-account)). It asks for the language, keyboard layout, Wi-Fi, privacy settings, timezone, and the account, and makes that account an administrator (`wheel`, so `sudo` works). Root stays locked.

Nothing asks on the console before that. On stock Fedora, Anaconda configures the system before the first boot; `bootc install` runs no installer, so the image ships `/etc/machine-id` empty, which systemd does not count as a first boot, and `systemd-firstboot` never prompts on tty1. All the questions are GNOME Initial Setup's.

The background provisioning finishes on its own: the Flatpak app set installs system-wide as soon as the network is up, which can be while GNOME Initial Setup is still on screen, and the Brewfile within a few minutes of the account existing (see [architecture.md](architecture.md#provisioning-and-the-network)).

## Apps

| From | Apps |
|---|---|
| The image (RPMs from the base) | Firefox, Nautilus, Ptyxis (terminal), GNOME Software, Settings, System Monitor, Disks and the rest of Silverblue's RPM set |
| Flathub, on first boot | GNOME's default apps: Calculator, Calendar, Characters, Clocks, Connections, Contacts, Disk Usage Analyzer, Extensions, Fonts, Image Viewer (Loupe), Logs, Maps, Document Viewer (Papers), Camera (Snapshot), Text Editor, Weather, Sushi (Nautilus previews), Fedora Media Writer |
| Flathub, on first boot | Brave, Bitwarden, LibreOffice, Obsidian, LocalSend |
| Fedora's Flatpak registry, on first boot | OBS Studio (Flathub builds it for x86_64 only) |
| Homebrew, on first boot | the CLI and developer tools in the [Brewfile](../Brewfile): Neovim, language toolchains, gh, ripgrep, fd, bat, lazygit, tmux, btop and more |

Stock Silverblue's installer adds GNOME's default apps from Fedora's Flatpak registry. `bootc install` runs no installer, so the image lists them in `/usr/share/flatpak/preinstall.d/silverblue-asahi.preinstall` (taken from the Silverblue `flatpak_remote_refs` in pungi-fedora's `fedora.conf`) and installs them with `flatpak preinstall`. They come from Flathub like the rest of the set, which keeps every app on one remote and one set of runtimes; Fedora's registry is only the fallback for what Flathub lacks on aarch64. An app you uninstall stays uninstalled: `flatpak preinstall` remembers it.

Install anything else from GNOME Software (Flathub is configured) or with `flatpak install flathub <app>`. For command-line tools, use Homebrew (`brew install <formula>`); for anything that has to be a system package, use a container (`toolbox`, which the base ships, or Docker) or build your own image `FROM ghcr.io/olirafa/silverblue-asahi:44`.

The Brewfile's shell tools are installed but not wired into the shell. To use the starship prompt, `z` and fzf's key bindings, add to `~/.bashrc`:

```sh
eval "$(starship init bash)"
eval "$(zoxide init bash)"
eval "$(fzf --bash)"
```

## Updates

```sh
sudo bootc upgrade && sudo reboot
```

The OS updates as a whole image, with `bootc upgrade`, and `sudo bootc rollback` returns to the previous one. GNOME Software does not offer OS updates on this image. Stock Silverblue's GNOME Software updates the OS through its rpm-ostree plugin, and that plugin needs an ostree system with rpm-ostreed, which a composefs install is not. Its dnf5 plugin would take over without it, offering RPM updates through `dnf5daemon-server` that a read-only `/usr` cannot take. So the image removes the first and deletes the second (`images/silverblue-asahi/Containerfile` step 3). GNOME Software still installs and updates Flatpaks, and updates firmware through fwupd.

Flatpaks also update daily on their own (`silverblue-asahi-flatpak-update.timer`, skipped on metered connections), and Homebrew updates itself (`brew-update.timer`, `brew-upgrade.timer`). For unattended OS updates, `sudo systemctl enable --now bootc-fetch-apply-updates.timer` stages and applies new images, and reboots into them (bootc gates that timer on ostree; the image lifts the gate, see [architecture.md](architecture.md#composefs-is-not-ostree)).

A new Fedora release is a new image tag: `sudo bootc switch ghcr.io/olirafa/silverblue-asahi:45` once it is published. GNOME Software shows no Fedora upgrade banner here: the plugin that offers them only runs when `/etc/os-release` says `ID=fedora`, and Fedora Asahi Remix's says `fedora-asahi-remix`.

## Docker

Docker (Fedora's `moby-engine`, with Compose and Buildx) starts on demand through `docker.socket`. The socket belongs to the `wheel` group (`/usr/lib/systemd/system/docker.socket.d/10-silverblue-asahi-wheel.conf`), so the administrator account GNOME Initial Setup creates can run `docker` without `sudo` and without being added to a `docker` group. That is the same trade as Docker's usual post-install step, adding the account to the `docker` group, and it is a real one: access to the socket is root without a password. `wheel` can already become root through `sudo`, but `sudo` asks for the password, and that prompt is what keeps anything else running as the account (a build script, an editor plugin, a dependency's install hook) from becoming root; through the socket it can start a privileged container instead. To keep the prompt, run `sudo systemctl edit docker.socket`, set `SocketGroup=root` under `[Socket]`, and use `sudo docker`; or use rootless Podman, which every account has. A non-administrator account gets no Docker access.

`/etc/docker/daemon.json` rotates container logs (10 MB × 5) and points container DNS at the `docker0` bridge address, where systemd-resolved also listens (`/usr/lib/systemd/resolved.conf.d/20-silverblue-asahi-docker-dns.conf`), so containers resolve names the way the host does, VPN and split DNS included.

## DRM (Widevine)

Run `silverblue-asahi-widevine` once to fetch the arm64 Widevine CDM, then restart the browser. Firefox needs nothing else; for Brave (and other Chromium-family Flatpaks), start the browser once before running the command, so it has a profile to wire the CDM into. Details in [asahi.md](asahi.md#drm-widevine).

## SSH

SSH is off: `sshd` is disabled and the default firewalld zone does not allow it. To log in remotely, run `sudo systemctl enable --now sshd` and `sudo firewall-cmd --permanent --add-service=ssh && sudo firewall-cmd --reload`.

## Firewall

firewalld's default zone is `public`, as the base ships it (Fedora Workstation's `FedoraWorkstation` zone, which opens every port above 1024, is not the default on Fedora Asahi Remix), minus `ssh`: it allows `dhcpv6-client` and `mdns` (printer and device discovery), plus `localsend` (TCP and UDP 53317, `/usr/lib/firewalld/services/localsend.xml`), which the image adds. Anything else that listens needs its port opened: a development server, and GNOME's own Sharing features (Remote Desktop on 3389, Media Sharing), with `sudo firewall-cmd --permanent --add-port=<port>/tcp && sudo firewall-cmd --reload` or `--add-service=rdp`.
