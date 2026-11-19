#!/bin/bash
# Container smoke test for the silverblue-asahi PLATFORM: boot, provisioning, services and tuning.
#
# Runs the built image as a container and asserts the userspace a correct build must produce —
# WITHOUT booting. (The Fedora Asahi kernel only boots on real Apple Silicon, so a generic VM boot
# test isn't possible; boot-time state is covered by images/boottest/, run on hardware.) The GNOME
# side is desktop-smoke.sh's.
#
#   ./images/silverblue-asahi/hack/platform-smoke.sh [IMAGE]       # default silverblue-asahi:44
#   ENGINE=docker ./images/silverblue-asahi/hack/platform-smoke.sh
set -euo pipefail
IMAGE="${1:-silverblue-asahi:44}"
ENGINE="${ENGINE:-podman}"

echo "== platform smoke: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }
# timer_only UNIT: UNIT is static (no [Install]) and not wanted by multi-user.target, so only its
# timer starts it.
timer_only() {
  local state
  state="$(systemctl is-enabled "$1" 2>/dev/null || true)"
  if [[ $state == "static" && ! -e /etc/systemd/system/multi-user.target.wants/$1 && ! -L /etc/systemd/system/multi-user.target.wants/$1 ]]; then
    ok "$1 is static (started by its timer, not at boot)"
  else
    no "$1 is '${state:-unknown}' or wanted by multi-user.target (it would run before the network is up)"
  fi
}

# Never `cmd | grep -q` here: under pipefail grep -q's early exit SIGPIPEs the producer and the
# pipeline reports failure even on a match. Capture output first, then match in the shell.

echo "== Fedora Asahi base (Apple Silicon) =="
[[ $(uname -m) == "aarch64" ]] && ok "aarch64" || no "not aarch64: $(uname -m)"
rpm -q asahi-platform-metapackage >/dev/null 2>&1 && ok "asahi-platform-metapackage" || no "asahi platform packages missing"
rpm -q kernel-16k >/dev/null 2>&1 && ok "kernel-16k (Asahi kernel)" || no "kernel-16k missing — wrong base"
for p in asahi-audio speakersafetyd tiny-dfr widevine-installer update-m1n1; do
  rpm -q "$p" >/dev/null 2>&1 && ok "$p" || no "$p missing"
done

echo "== kernel + bootloader =="
n=$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | wc -l)
[[ $n == "1" ]] && ok "exactly one kernel in /usr/lib/modules" || no "expected 1 kernel in /usr/lib/modules, found $n"
rpm -q systemd-boot-unsigned >/dev/null 2>&1 && ok "systemd-boot-unsigned installed" || no "systemd-boot-unsigned missing"
# bootc picks systemd-boot only without bootupd, and nothing holds it, so it must be gone.
rpm -q bootupd >/dev/null 2>&1 && no "bootupd still installed" || ok "bootupd removed"
# Non-fatal: dnf protects shim-aa64 (which requires grub2-efi-aa64) and tuned requires rpm-ostree, so
# they stay but are inert under --bootloader systemd (the "no grub on the ESP" guarantee is the
# install-to-disk CI assertion).
for p in rpm-ostree grub2-efi-aa64 shim-aa64; do
  rpm -q "$p" >/dev/null 2>&1 && echo "  - $p present (held by a dep; inert under systemd-boot)" || ok "$p removed"
done
for u in /etc/systemd/user/grub-boot-success.timer /etc/systemd/user/grub-boot-success.service \
         /etc/systemd/system/grub-boot-indeterminate.service; do
  [[ "$(readlink -f "$u")" == "/dev/null" ]] && ok "masked $(basename "$u")" || no "$(basename "$u") not masked (fails every boot under systemd-boot)"
done

echo "== initramfs (composefs pivot + Apple HID early load) =="
kver="$(basename "$(dirname "$(find /usr/lib/modules -maxdepth 2 -name vmlinuz 2>/dev/null | head -1)")")"
listing="$(lsinitrd "/usr/lib/modules/$kver/initramfs.img" 2>/dev/null || true)"
case $listing in
  *bootc-root-setup.service*) ok "initramfs carries bootc-root-setup.service (composefs root pivot)" ;;
  *) no "initramfs has no bootc composefs root setup — a composefs install would boot the host's /usr" ;;
esac
builtin="$(cat "/usr/lib/modules/$kver/modules.builtin" 2>/dev/null || true)"
for m in hid-apple hid-magicmouse; do
  case $builtin in
    *"/$m.ko"*) ok "$m built into the kernel" ;;
    *)
      case $listing in
        *"/$m.ko"*) ok "$m in the initramfs (trackpad boot-race fix)" ;;
        *) no "$m neither built in nor in the initramfs — the trackpad can come up dead" ;;
      esac
      ;;
  esac
done
[[ -f /usr/lib/dracut/dracut.conf.d/90-silverblue-asahi-apple-hid.conf ]] && ok "dracut Apple HID drop-in" || no "dracut Apple HID drop-in missing"
modprobe_conf="$(cat /usr/lib/modprobe.d/silverblue-asahi-apple.conf 2>/dev/null || true)"
case $modprobe_conf in
  *"options hid_apple fnmode=1"*) ok "hid_apple fnmode=1 (media keys first)" ;;
  *) no "hid_apple fnmode not configured" ;;
esac

echo "== Asahi m1n1 + devicetree on atomic =="
dtbs="$(grep '^DTBS=' /etc/sysconfig/update-m1n1 2>/dev/null || true)"
case $dtbs in
  *'/usr/lib/modules/$(uname -r)/dtb'*) ok "update-m1n1 DTBS points at the image devicetree" ;;
  *) no "update-m1n1 DTBS not repointed: ${dtbs:-unset}" ;;
esac
command -v update-m1n1 >/dev/null 2>&1 && ok "update-m1n1 present" || no "update-m1n1 missing"
[[ -x /usr/libexec/silverblue-asahi-apply-m1n1 ]] && ok "silverblue-asahi-apply-m1n1 helper" || no "silverblue-asahi-apply-m1n1 missing"
[[ -L /etc/systemd/system/multi-user.target.wants/silverblue-asahi-apply-m1n1.service ]] \
  && ok "silverblue-asahi-apply-m1n1.service enabled" || no "silverblue-asahi-apply-m1n1.service not enabled"

echo "== first boot: GNOME Initial Setup, not the console =="
if getent passwd | awk -F: '$3>=1000 && $3<60000 {f=1} END{exit !f}'; then
  no "a human user is baked into the image (GNOME Initial Setup must create it on first boot)"
else
  ok "no human user baked in"
fi
# systemd counts a boot as the first only when /etc/machine-id is absent or reads "uninitialized"
# (an empty file does not count). Either would make systemd-firstboot prompt on the console before
# GDM; empty, the questions are GNOME Initial Setup's.
if [[ -f /etc/machine-id && ! -s /etc/machine-id ]]; then
  ok "/etc/machine-id is empty (no console first-boot prompts; systemd generates the ID)"
else
  no "/etc/machine-id is '$(cat /etc/machine-id 2>/dev/null || echo absent)', not an empty file (systemd-firstboot would prompt on the console)"
fi
root_shadow="$(awk -F: '$1 == "root" { print $2 }' /etc/shadow 2>/dev/null || true)"
[[ $root_shadow == '*' || $root_shadow == '!'* ]] && ok "root is locked ('$root_shadow'); the first account is an administrator" \
  || no "root's shadow field is '${root_shadow:-missing}', not locked"
[[ -x /usr/libexec/silverblue-asahi-primary-user ]] && ok "silverblue-asahi-primary-user (brew setup's account check)" \
  || no "silverblue-asahi-primary-user missing or not executable"
primary_out="$(/usr/libexec/silverblue-asahi-primary-user 2>&1)"; primary_rc=$?
(( primary_rc == 1 )) && ok "silverblue-asahi-primary-user finds no account in the image (exit 1: brew setup waits)" \
  || no "silverblue-asahi-primary-user exited $primary_rc in an image with no account: $primary_out"

# An account carried over by `bootc switch` keeps its login shell; accountsservice hides an account
# whose shell is not in /etc/shells, and GDM would then run GNOME Initial Setup for a second one.
shells="$(cat /etc/shells 2>/dev/null || true)"
case $shells in *$'\n'/usr/bin/zsh$'\n'*|*$'\n'/usr/bin/zsh) ok "zsh is a login shell (/etc/shells), for accounts switched in with it" ;; *) no "/usr/bin/zsh is not in /etc/shells" ;; esac

echo "== Flatpak provisioning =="
command -v flatpak >/dev/null 2>&1 && ok "flatpak" || no "flatpak missing"
# The exit status, not the text: an unknown subcommand's error message names it too.
flatpak preinstall --help >/dev/null 2>&1 && ok "flatpak preinstall CLI available" || no "flatpak has no preinstall subcommand"
[[ -s /etc/flatpak/remotes.d/flathub.flatpakrepo ]] && ok "Flathub remote baked (registering it downloads nothing)" || no "flathub.flatpakrepo missing"
[[ "$(readlink -f /etc/systemd/system/flatpak-add-fedora-repos.service)" == "/dev/null" ]] \
  && ok "flatpak-add-fedora-repos masked (the preinstall unit adds Fedora at priority 1 itself)" || no "flatpak-add-fedora-repos not masked"
# The preinstall waits for the network itself: silverblue-asahi-online skips it until the remotes answer over
# HTTPS, and its timer starts it again until it has run. Started at boot instead (multi-user.target),
# it would run before Wi-Fi is up, and offline `flatpak preinstall` exits 0 having installed nothing.
# silverblue-asahi-brew-setup (below) works the same way.
[[ -x /usr/libexec/silverblue-asahi-online ]] && ok "silverblue-asahi-online (the provisioning units' network check)" || no "silverblue-asahi-online missing or not executable"
# silverblue-asahi-online asks each host over HTTPS with curl; without it every provisioning unit fails.
command -v curl >/dev/null 2>&1 && ok "curl (silverblue-asahi-online's HTTPS check)" || no "curl missing — silverblue-asahi-online cannot check the network"
timer_only silverblue-asahi-flatpak-preinstall.service
for t in silverblue-asahi-flatpak-preinstall silverblue-asahi-flatpak-update; do
  [[ -L /etc/systemd/system/timers.target.wants/$t.timer ]] && ok "$t.timer enabled" || no "$t.timer not enabled"
done
unit="$(cat /usr/lib/systemd/system/silverblue-asahi-flatpak-preinstall.service 2>/dev/null || true)"
case $unit in *"ExecCondition=/usr/libexec/silverblue-asahi-online dl.flathub.org registry.fedoraproject.org"*) ok "preinstall waits until the remotes answer" ;; *) no "preinstall has no silverblue-asahi-online condition (it would run offline and exit 0)" ;; esac
case $unit in *"--prio=10 flathub"*"--prio=1 fedora"*) ok "Flathub outranks Fedora's registry (OBS-only fallback)" ;; *) no "remote priorities not set (Fedora would win ties)" ;; esac
case $unit in *"dbus-run-session -- /usr/bin/flatpak preinstall"*) ok "preinstall runs under dbus-run-session" ;; *) no "preinstall not wrapped in dbus-run-session (dies without a session bus)" ;; esac
# ...and dbus-run-session must exist: base-atomic has none, and without it the units fail with
# 203/EXEC and retry forever. (The desktop once got it only by accident, via system-config-printer.)
[[ -x /usr/bin/dbus-run-session ]] && ok "dbus-run-session installed" || no "dbus-run-session missing — Flatpak provisioning cannot run"

echo "== Homebrew ships prebuilt (ublue brew image) =="
[[ -s /usr/share/homebrew.tar.zst ]] && ok "homebrew.tar.zst shipped" || no "homebrew.tar.zst missing"
[[ -f /usr/share/silverblue-asahi/Brewfile ]] && ok "/usr/share/silverblue-asahi/Brewfile" || no "Brewfile missing"
[[ -L /etc/systemd/system/multi-user.target.wants/brew-setup.service ]] && ok "brew-setup.service enabled" || no "brew-setup.service not enabled"
# Like the Flatpak preinstall: started by its timer, and skipped until Homebrew's hosts answer
# unless the Brewfile has already been applied.
timer_only silverblue-asahi-brew-setup.service
unit="$(cat /usr/lib/systemd/system/silverblue-asahi-brew-setup.service 2>/dev/null || true)"
case $unit in *"/usr/libexec/silverblue-asahi-online formulae.brew.sh ghcr.io"*) ok "silverblue-asahi-brew-setup waits until Homebrew's hosts answer" ;; *) no "silverblue-asahi-brew-setup has no silverblue-asahi-online condition (brew bundle would run offline)" ;; esac
case $unit in *"Restart=on-failure"*"RestartMode=direct"*) ok "silverblue-asahi-brew-setup backs off a failed brew bundle" ;; *) no "silverblue-asahi-brew-setup does not back off failures (it would rebuild every 2 minutes)" ;; esac
for t in silverblue-asahi-brew-setup brew-update brew-upgrade; do
  [[ -L /etc/systemd/system/timers.target.wants/$t.timer ]] && ok "$t.timer enabled" || no "$t.timer not enabled"
done
helper="$(grep -vE '^[[:space:]]*#' /usr/libexec/silverblue-asahi-brew-setup 2>/dev/null || true)"
case $helper in
  *install.sh*|*curl*|*wget*) no "silverblue-asahi-brew-setup downloads an installer" ;;
  *) ok "silverblue-asahi-brew-setup does not download an installer" ;;
esac
# ublue's brew-update/brew-upgrade run as a fixed uid 1000 from their timers; ours wait for the
# Brewfile stamp and run as the prefix's owner.
for b in brew-update brew-upgrade; do
  dropin="$(cat "/usr/lib/systemd/system/$b.service.d/10-silverblue-asahi.conf" 2>/dev/null || true)"
  case $dropin in
    *"ConditionPathExists=/var/lib/silverblue-asahi/brew-setup-done"*) ok "$b waits for the Brewfile (no 217/USER before the account exists)" ;;
    *) no "$b.service has no brew-setup-done condition (it fails until GNOME Initial Setup has run)" ;;
  esac
  case $dropin in
    *$'\n'"User="$'\n'*"runuser -u"*) ok "$b runs as the prefix's owner, not uid 1000" ;;
    *) no "$b.service still runs as a fixed User=" ;;
  esac
done
brewsh="$(cat /etc/profile.d/brew.sh 2>/dev/null || true)"
case $brewsh in *'PATH}:'*HOMEBREW_PREFIX*) ok "brew is appended to PATH, not prepended" ;; *) no "brew.sh missing or prepends brew" ;; esac

echo "== system services =="
for u in NetworkManager bluetooth firewalld systemd-resolved avahi-daemon tuned tuned-ppd cups cups-browsed systemd-oomd; do
  systemctl is-enabled "$u.service" >/dev/null 2>&1 && ok "$u enabled" || no "$u not enabled"
done
systemctl is-enabled docker.socket >/dev/null 2>&1 && ok "docker.socket enabled" || no "docker.socket not enabled"
rpm -q power-profiles-daemon >/dev/null 2>&1 && no "power-profiles-daemon installed (it conflicts with tuned-ppd)" || ok "power profiles come from tuned-ppd alone"
socket_dropin="$(cat /usr/lib/systemd/system/docker.socket.d/10-silverblue-asahi-wheel.conf 2>/dev/null || true)"
case $socket_dropin in *SocketGroup=wheel*) ok "the Docker socket belongs to wheel (administrators, no sudo)" ;; *) no "docker.socket has no SocketGroup=wheel drop-in" ;; esac
getent group wheel >/dev/null 2>&1 && ok "the wheel group exists" || no "no wheel group (the Docker socket would be unreachable)"
[[ "$(readlink -f /etc/systemd/system/NetworkManager-wait-online.service)" == "/dev/null" ]] \
  && ok "NetworkManager-wait-online masked" || no "NetworkManager-wait-online not masked"

# SSH is opt-in: sshd off, and the default zone does not let it in.
grep -qx 'disable sshd.service' /usr/lib/systemd/system-preset/50-silverblue-asahi.preset 2>/dev/null \
  && ok "50-silverblue-asahi.preset disables sshd" || no "no preset disables sshd (Fedora's 90-default enables it)"
if [[ -f /usr/lib/systemd/system/sshd.service ]]; then
  sshd_state="$(systemctl is-enabled sshd.service 2>/dev/null || true)"
  [[ $sshd_state == "disabled" ]] && ok "sshd disabled (SSH is opt-in)" || no "sshd is '${sshd_state:-unknown}', not disabled"
  # What a first-boot preset pass would do; the container is thrown away afterwards.
  if preset_out="$(systemctl preset sshd.service 2>&1)"; then
    sshd_state="$(systemctl is-enabled sshd.service 2>/dev/null || true)"
    [[ $sshd_state == "disabled" ]] && ok "applying the presets keeps sshd disabled" || no "the presets re-enable sshd ($sshd_state)"
  else
    no "systemctl preset sshd.service failed: $preset_out"
  fi
else
  ok "sshd is not installed"
fi
zone="$(firewall-offline-cmd --get-default-zone 2>/dev/null || true)"
ssh_allowed="$(firewall-offline-cmd --zone="$zone" --query-service=ssh 2>/dev/null || true)"
[[ $ssh_allowed == "no" ]] && ok "the $zone zone does not allow ssh" || no "the $zone zone allows ssh (${ssh_allowed:-query failed})"

echo "== composefs is not ostree (no /run/ostree-booted) =="
# A composefs-native boot writes no /run/ostree-booted, so units gated on it flip: those that run
# only off ostree would start, those that run only on ostree would never fire.
mc="$(systemctl is-enabled dnf-makecache.timer 2>/dev/null || true)"
[[ $mc != enabled* ]] && ok "dnf-makecache.timer is ${mc:-absent} (no dnf metadata downloads every 3 hours)" \
  || no "dnf-makecache.timer is enabled (it skips itself only on ostree)"
# conditions UNIT: UNIT's effective conditions as systemd's own unit loader reads them, drop-ins and
# their resets included (test mode refuses root, hence nobody). "unit-found" marks that the dump has
# the unit at all, so a loader that cannot run fails the checks instead of passing them empty.
conditions() {
  runuser -u nobody -- /usr/lib/systemd/systemd --system --test --unit="$1" --no-pager 2>/dev/null \
    | awk -v want="$1:" '/→ Unit /{u=$3; if (u == want) print "unit-found"} u == want && /^\t+Condition/{sub(/^\t+/, ""); print}'
}
for u in bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service \
         fedora-atomic-desktop-appstream-cache-refresh.service fedora-atomic-desktop-mandb-update.service; do
  cond="$(conditions "$u")"
  if [[ $cond != *unit-found* ]]; then
    no "systemd's loader did not report $u"
  elif [[ $cond == *"/run/ostree-booted"* ]]; then
    no "$u still requires /run/ostree-booted (it would never run on a composefs boot)"
  else
    ok "$u: the /run/ostree-booted gate is reset"
  fi
done
for u in fedora-atomic-desktop-appstream-cache-refresh fedora-atomic-desktop-mandb-update; do
  cond="$(conditions "$u.service")"
  [[ $cond == *"ConditionPathIsReadWrite: /var"* ]] && ok "$u keeps its /var condition" || no "$u lost ConditionPathIsReadWrite=/var with the reset"
  systemctl is-enabled --quiet "$u.service" && ok "$u.service enabled" || no "$u.service not enabled"
done
auto="$(systemctl is-enabled bootc-fetch-apply-updates.timer 2>/dev/null || true)"
[[ $auto != enabled* ]] && ok "automatic updates stay opt-in (bootc-fetch-apply-updates.timer ${auto:-absent})" \
  || no "bootc-fetch-apply-updates.timer is enabled (it reboots into updates on its own)"

echo "== system tuning =="
for f in /usr/lib/sysctl.d/99-silverblue-asahi-sysctl.conf /usr/lib/sysctl.d/90-silverblue-asahi-file-watchers.conf \
         /usr/lib/udev/rules.d/60-silverblue-asahi-io-scheduler.rules /usr/lib/systemd/zram-generator.conf.d/90-silverblue-asahi.conf \
         /usr/lib/systemd/logind.conf.d/20-silverblue-asahi-inhibit-delay.conf \
         /usr/lib/systemd/oomd.conf.d/10-silverblue-asahi.conf /usr/lib/systemd/user/app.slice.d/10-silverblue-asahi-oomd.conf \
         /usr/lib/NetworkManager/conf.d/50-silverblue-asahi-wifi-powersave.conf /usr/lib/tmpfiles.d/silverblue-asahi-zswap.conf \
         /usr/lib/tmpfiles.d/silverblue-asahi-plocate.conf \
         /etc/docker/daemon.json; do
  [[ -f $f ]] && ok "$f" || no "$f missing"
done
[[ -x /usr/lib/systemd/system-sleep/silverblue-asahi-unmount-fuse ]] && ok "gvfs FUSE unmount sleep hook" || no "sleep hook missing or not executable"
# The effective oomd settings of the user slices, from systemd's own unit loader (test mode refuses
# root, hence nobody). Fedora's slice.d drop-in sets 80% on every user slice; the image's app.slice
# drop-in must win, so apps are acted on before the session.
oomd_dump="$(runuser -u nobody -- env XDG_RUNTIME_DIR=/tmp/oomd-test bash -c \
  'mkdir -p "$XDG_RUNTIME_DIR" && /usr/lib/systemd/systemd --user --test --unit=session.slice --no-pager; /usr/lib/systemd/systemd --user --test --unit=app.slice --no-pager' 2>/dev/null \
  | awk '/→ Unit /{u=$3} /ManagedOOM(MemoryPressure|MemoryPressureLimit|Swap):/{print u, $1, $2}' | sort -u)"
for want in "app.slice: ManagedOOMMemoryPressure: kill" "app.slice: ManagedOOMMemoryPressureLimit: 50.00%" "app.slice: ManagedOOMSwap: kill" \
            "session.slice: ManagedOOMMemoryPressure: kill" "session.slice: ManagedOOMMemoryPressureLimit: 80.00%"; do
  [[ $'\n'$oomd_dump$'\n' == *$'\n'$want$'\n'* ]] && ok "oomd: $want" || no "oomd: expected '$want', systemd reports: $(grep -F "${want%% *}" <<<"$oomd_dump" | tr '\n' ';')"
done
visudo -cf /etc/sudoers.d/silverblue-asahi-passwd-tries >/dev/null 2>&1 && ok "sudoers drop-in parses" || no "sudoers drop-in invalid"
[[ "$(stat -c %a /etc/sudoers.d/silverblue-asahi-passwd-tries 2>/dev/null)" == "440" ]] && ok "sudoers drop-in is 0440" || no "sudoers drop-in mode is not 0440"
[[ -x /usr/bin/silverblue-asahi-widevine ]] && ok "silverblue-asahi-widevine on PATH" || no "silverblue-asahi-widevine missing"

echo "== first boot: the preset pass keeps every unit as built =="
# A first boot makes systemd run a FULL `systemctl preset-all`: every unit is set to what the
# presets say, and Fedora's 99-default-disable.preset disables anything they do not list. Do the same
# here (the container is thrown away) and require that it changes no unit-file state, enablement
# link or default target, i.e. the presets keep the image exactly as built.
unit_state() {
  systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{ print $1, $2 }'
  find /etc/systemd/system /etc/systemd/user -type l -printf 'link %P -> %l\n' 2>/dev/null
  echo "default.target: $(systemctl get-default 2>/dev/null)"
}
before="$(unit_state | sort)"
if preset_out="$(systemctl preset-all 2>&1)"; then
  after="$(unit_state | sort)"
  changes="$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
  [[ -z $changes ]] && ok "systemctl preset-all changes nothing (50-silverblue-asahi.preset covers every unit the build enables)" || no "a first boot's preset pass would change the image:"$'\n'"$changes"
else
  no "systemctl preset-all failed: $preset_out"
fi
# homectl's first-boot prompt would ask for a second user (see 50-silverblue-asahi.preset).
homed_firstboot="$(systemctl is-enabled systemd-homed-firstboot.service 2>/dev/null || true)"
case $homed_firstboot in
  enabled*) no "systemd-homed-firstboot.service is enabled (a second user prompt on first boot)" ;;
  *) ok "systemd-homed-firstboot.service is not enabled (${homed_firstboot:-not found})" ;;
esac

echo "== no Omarchy, Fenoa or Hyprland session =="
leftovers="$(ls -d /usr/share/omarchy /usr/bin/omarchy* /usr/libexec/omarchy* /etc/omarchy* /usr/lib/systemd/system/omarchy* \
  /usr/share/fenoa /usr/bin/fenoa* /usr/libexec/fenoa* /usr/lib/systemd/system/fenoa* 2>/dev/null || true)"
[[ -z $leftovers ]] && ok "no omarchy or fenoa files" || no "omarchy/fenoa files present: $leftovers"
for p in hyprland noctalia-shell greetd; do
  rpm -q "$p" >/dev/null 2>&1 && no "$p installed (GNOME is the only desktop)" || ok "$p not installed"
done

echo "== shipped units verify (report) =="
if command -v systemd-analyze >/dev/null 2>&1; then
  for u in /usr/lib/systemd/system/silverblue-asahi-*.service /usr/lib/systemd/system/silverblue-asahi-*.timer; do
    [[ -e $u ]] || continue
    if verify="$(systemd-analyze verify "$u" 2>&1)"; then
      ok "verify $(basename "$u")"
    else
      printf '  \033[2m·\033[0m verify %s: %s (non-fatal in a container)\n' "$(basename "$u")" "${verify%%$'\n'*}"
    fi
  done
fi

[[ -L /usr/local ]] && ok "/usr/local is a symlink (var-backed on bootc)" || no "/usr/local is not a symlink"

echo
if [[ $fail == "0" ]]; then echo "PLATFORM SMOKE: PASS"; else echo "PLATFORM SMOKE: FAIL"; fi
exit "$fail"
CHECKS
