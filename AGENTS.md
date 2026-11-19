# silverblue-asahi

silverblue-asahi is a bootc image for Apple Silicon Macs: Fedora Asahi Remix Silverblue (stock GNOME) on systemd-boot + composefs, with first-boot provisioning of Flatpaks and Homebrew. It publishes one image, `ghcr.io/olirafa/silverblue-asahi:44` (arm64), from `main`.

GNOME stays as the base ships it. Change the platform under it, add provisioning, and remove from GNOME only what cannot work on a composefs install; a GNOME customisation (extensions, dconf defaults, themes) is a deliberate scope change, not a default.

## Layout

- `images/silverblue-asahi/Containerfile` - the image, in numbered steps, plus the `brew` helper stage that only supplies files
- `images/boottest/` - on-hardware boot smoke overlay (never published)
- `images/silverblue-asahi/hack/` - container smoke tests and the install-to-disk check CI runs against the built image
- `images/build.sh` - local build (`ENGINE`, `FEDORA`, `TAG`, `ENGINE_ARGS`)
- `packages/platform.packages` - the dnf packages layered onto the base
- `system/platform/` - boot, services, provisioning and tuning files copied to `/` in step 4
- `system/desktop/` - the Flatpak app set and LocalSend's firewalld service, copied to `/` in step 9
- `Brewfile` - the Homebrew package set, applied on first boot
- `deploy/` - `silverblue-asahi-install` (take over a running Fedora Asahi system) and `silverblue-asahi-grow-esp`, with their library and tests
- `test/` - `test/all` runs everything that needs no image build; unit tests live in `test/unit.d/*-test.sh`
- `docs/` - how the system is shaped and why; read the relevant page before changing an area

## Where things go

- Prefer vendor drop-in paths under `/usr/lib` (`systemd/*.conf.d`, `sysctl.d`, `udev/rules.d`, `modprobe.d`, `tmpfiles.d`, `NetworkManager/conf.d`, `firewalld/services`) so image updates flow through without `/etc` three-way-merge conflicts. Use `/etc` only for files whose consumer reads nothing else (sudoers, docker, cups-browsed).
- A unit the Containerfile enables or disables also needs a matching `enable`/`disable` line in `system/platform/usr/lib/systemd/system-preset/50-silverblue-asahi.preset`: if a full preset pass ever runs, Fedora's `99-default-disable.preset` turns off everything unlisted. Masks need no line (a preset pass leaves them alone). The smoke tests and `test/unit.d/platform-overlay-test.sh` enforce it.
- `/etc/machine-id` ships EMPTY (step 10). Absent or `uninitialized` would make systemd-firstboot prompt on the console before GDM; GNOME Initial Setup asks those questions. Keep that step last.
- The image ships no user. Anything that acts on the first account must wait for GNOME Initial Setup to create it: gate it on `/usr/libexec/silverblue-asahi-primary-user` as an `ExecCondition=` and retry from a timer, like `silverblue-asahi-brew-setup`.
- Anything the initramfs needs (`modprobe.d`, `dracut.conf.d`) must be in the image before the initramfs rebuild in step 5.
- `/var` is seeded only on first boot and never updated by `bootc upgrade`. Never bake state into `/var`; ship a `tmpfiles.d` entry or a first-boot unit instead.
- Units that need the network do not order after `network-online.target` (NetworkManager-wait-online is masked): they use `silverblue-asahi-online` as an `ExecCondition=` and are started by a timer. See `docs/architecture.md`.
- New system packages go in `packages/platform.packages` with Fedora names; no desktop packages (GNOME comes from the base). Check they resolve on Fedora 44 aarch64 before committing. A `dnf remove` that would take a protected or required package with it (shim-aa64, rpm-ostree under tuned, dnf5daemon-server under gnome-software) fails the build or removes GNOME: remove one package at a time and assert what must survive.
- New Flatpaks go in `system/desktop/usr/share/flatpak/preinstall.d/silverblue-asahi.preinstall` with `Branch=stable` and `IsRuntime=false`; check the app exists for aarch64 on Flathub, or on Fedora's registry as the fallback.

## Style

- In markdown documents, write full lines; break only at structural boundaries like headings and list items
- Two spaces for indentation, no tabs
- Shebangs are `#!/bin/bash`; files that are only sourced (`deploy/lib`) need none
- Use bash 5 conditionals: `[[ ]]` for string/file tests and `(( ))` for numeric tests
- In `[[ ]]`, don't quote variables, but do quote string literals when comparing values (e.g. `[[ $mode == "dark" ]]`)
- Prefer `(( count < 50 ))` over `[[ $count -lt 50 ]]`
- Prefer a full `if`/`else` for simple two-path control flow
- Quote paths with spaces instead of escaping them
- Containerfile `RUN` steps run under `/bin/sh`: POSIX only, `set -eux`, and an explicit assertion after anything that must have taken effect
- Smoke tests never pipe into `grep -q` under `pipefail` (the early exit SIGPIPEs the producer and reports failure on a match); capture output first and match in the shell
- Comments explain why, especially for anything that only fails on real hardware

## Tests

Run from the repo root before calling work done:

```bash
./test/all
```

That covers shell syntax, `test/unit.d`, and the `deploy/` library tests. The image tests need a built image and run in `.github/workflows/image-e2e.yml` on an arm64 runner; locally (aarch64, ~20 GB free, or x86_64 with `ENGINE_ARGS=--arch=arm64`, slowly):

```bash
./images/build.sh
./images/silverblue-asahi/hack/platform-smoke.sh silverblue-asahi:44
./images/silverblue-asahi/hack/desktop-smoke.sh silverblue-asahi:44
```

Hardware-only behaviour (boot, m1n1 refresh, GDM and GNOME Initial Setup, SELinux at runtime) is verified with `images/boottest/` on a real Mac.

## Multi-agent loop

For substantive changes (boot chain, initramfs, first boot, provisioning, security), use a SWE → QA → Review loop with the main session as orchestrator:

- SWE implements; one writer at a time on a branch
- QA runs `./test/all` (and the image tests when the image changes) and reports `VERDICT: PASS` or `VERDICT: FAIL` with output; QA never fixes
- Reviewer reviews the diff; severity `bug` blocks, `suggestion`/`nit` are optional
- Max three SWE↔QA rounds, then surface the remaining issues to the user

## Git

- Commits are atomic: one coherent change per commit
- Commit messages are succinct and describe the change
