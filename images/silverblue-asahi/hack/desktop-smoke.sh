#!/bin/bash
# Container smoke test for the silverblue-asahi DESKTOP: GNOME as Silverblue ships it, plus what this
# image adds on top. Run platform-smoke.sh against the same image as well; this file covers only the
# desktop side.
#
# GNOME itself comes from the base untouched, so most of this guards the seams: GDM stays the
# display manager through a first boot's preset pass, GNOME Initial Setup can still create the
# first account, GNOME Software has lost only its OS-package plugins, the Firefox in the image finds
# the Widevine CDM, and the Flatpak app set is one `flatpak preinstall` can actually install.
#
#   ./images/silverblue-asahi/hack/desktop-smoke.sh [IMAGE]     # default silverblue-asahi:44
set -euo pipefail
IMAGE="${1:-silverblue-asahi:44}"
ENGINE="${ENGINE:-podman}"

echo "== desktop smoke: $IMAGE (via $ENGINE) =="
"$ENGINE" run --rm -i --entrypoint bash "$IMAGE" -s <<'CHECKS'
set -uo pipefail
fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }

# Never `cmd | grep -q` here (pipefail + SIGPIPE); capture output, then match in the shell.

echo "== GNOME (from the base) =="
for p in gnome-shell mutter gdm gnome-session-wayland-session gnome-initial-setup gnome-software gnome-keyring \
         xdg-desktop-portal-gnome nautilus ptyxis firefox; do
  rpm -q "$p" >/dev/null 2>&1 && ok "$p" || no "$p missing"
done
[[ -f /usr/share/wayland-sessions/gnome.desktop ]] && ok "GNOME Wayland session" || no "/usr/share/wayland-sessions/gnome.desktop missing"

echo "== GDM =="
dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
[[ $dm == */gdm.service ]] && ok "GDM is the display manager" || no "display-manager is not GDM (${dm:-unset})"
[[ "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]] && ok "default target = graphical.target" || no "default target is not graphical.target"

echo "== GNOME Initial Setup creates the first account =="
[[ -x /usr/libexec/gnome-initial-setup ]] && ok "gnome-initial-setup" || no "/usr/libexec/gnome-initial-setup missing"
# GDM starts GNOME Initial Setup when no human account exists, unless custom.conf turns it off.
gdm_conf="$(cat /etc/gdm/custom.conf 2>/dev/null || true)"
case $gdm_conf in
  *$'\n'InitialSetupEnable=[Ff]alse*|InitialSetupEnable=[Ff]alse*) no "/etc/gdm/custom.conf disables GNOME Initial Setup" ;;
  *) ok "GDM's custom.conf leaves GNOME Initial Setup on" ;;
esac
case $gdm_conf in
  *$'\n'AutomaticLoginEnable=[Tt]rue*) no "/etc/gdm/custom.conf turns on automatic login" ;;
  *) ok "no automatic login" ;;
esac
# Fedora's vendor.conf skips only the third-party software page; the account page must stay.
vendor="$(cat /usr/share/gnome-initial-setup/vendor.conf /etc/gnome-initial-setup/vendor.conf 2>/dev/null || true)"
skip="$(printf '%s\n' "$vendor" | sed -n 's/^skip=//p' | tr ';' ' ')"
case " $skip " in
  *" account "*|*" password "*) no "vendor.conf skips the account or password page (skip=$skip)" ;;
  *) ok "the account and password pages are not skipped (skip=${skip:-nothing})" ;;
esac

echo "== GNOME Software: apps yes, OS updates no =="
rpm -q gnome-software-rpm-ostree >/dev/null 2>&1 \
  && no "gnome-software-rpm-ostree installed (it offers rpm-ostree updates a composefs install cannot apply)" \
  || ok "gnome-software-rpm-ostree removed (OS updates are sudo bootc upgrade)"
plugins="$(find /usr/lib64/gnome-software -name 'libgs_plugin_*.so' -printf '%f\n' 2>/dev/null || true)"
case $plugins in *libgs_plugin_flatpak.so*) ok "GNOME Software keeps its Flatpak plugin" ;; *) no "GNOME Software has no Flatpak plugin" ;; esac
# Without the rpm-ostree plugin's conflict rule the dnf5 plugin would offer RPM updates through
# dnf5daemon-server on a read-only /usr, so the build deletes it (Containerfile step 3).
case $plugins in
  *rpm-ostree*|*dnf5*) no "an OS-package plugin is still installed: $(printf '%s ' $plugins)" ;;
  *) ok "no rpm-ostree or dnf5 plugin left (GNOME Software offers no RPM updates)" ;;
esac

echo "== Firefox finds the Widevine CDM =="
# widevine-installer ships the pref and the environment.d entry; silverblue-asahi-widevine fetches
# the CDM itself on request.
pref="$(cat /usr/lib64/firefox/defaults/pref/gmpwidevine.js 2>/dev/null || true)"
case $pref in *'"media.gmp-widevinecdm.enabled", true'*) ok "Firefox Widevine pref (gmpwidevine.js)" ;; *) no "gmpwidevine.js missing or does not enable the CDM" ;; esac
gmp_env="$(cat /usr/lib/environment.d/50-gmpwidevine.conf 2>/dev/null || true)"
case $gmp_env in *MOZ_GMP_PATH=*/var/lib/widevine/*) ok "MOZ_GMP_PATH points the session at /var/lib/widevine" ;; *) no "50-gmpwidevine.conf missing or not pointed at /var/lib/widevine" ;; esac

# Fedora's launcher copies the langpack only when /run/ostree-booted exists; the build makes it copy
# whenever the langpack's mtime is 0, as every file's is on composefs (step 9).
launcher="$(cat /usr/bin/firefox 2>/dev/null || true)"
case $launcher in
  *'[ "$(stat -c %Y "$MOZ_LANGPACKS_DIR/$langpack" 2>/dev/null)" = "0" ]; then'*) ok "Firefox copies mtime-0 langpacks (no English fallback after updates)" ;;
  *) no "/usr/bin/firefox is not patched to copy mtime-0 langpacks" ;;
esac
bash -n /usr/bin/firefox 2>/dev/null && ok "the patched Firefox launcher parses" || no "/usr/bin/firefox has a syntax error"

echo "== Flatpak app set =="
manifest="$(cat /usr/share/flatpak/preinstall.d/silverblue-asahi.preinstall 2>/dev/null || true)"
[[ -n $manifest ]] && ok "silverblue-asahi.preinstall present" || no "silverblue-asahi.preinstall missing"
# Each group must pin Branch=stable (Flathub's only app branch; flatpak's default "master" makes a
# group install nothing) and be an app, not a runtime.
bad_groups="$(printf '%s\n' "$manifest" | awk '
  /^\[Flatpak Preinstall / { if (id != "" && !(branch && app)) print id; id = $3; sub(/\]$/, "", id); branch = 0; app = 0; next }
  /^Branch=stable$/ { branch = 1 }
  /^IsRuntime=false$/ { app = 1 }
  END { if (id != "" && !(branch && app)) print id }')"
[[ -z $bad_groups ]] && ok "every group pins Branch=stable and IsRuntime=false" || no "groups without Branch=stable/IsRuntime=false: $bad_groups"
for app in org.gnome.Calculator org.gnome.TextEditor org.gnome.Loupe org.gnome.Papers org.gnome.Calendar \
           org.gnome.Weather org.gnome.Maps org.gnome.baobab org.gnome.Snapshot org.fedoraproject.MediaWriter \
           com.brave.Browser com.bitwarden.desktop org.libreoffice.LibreOffice md.obsidian.Obsidian \
           org.localsend.localsend_app com.obsproject.Studio; do
  case $manifest in *"[Flatpak Preinstall $app]"*) ok "Flatpak preinstall: $app" ;; *) no "Flatpak preinstall lacks $app" ;; esac
done
zone="$(firewall-offline-cmd --get-default-zone 2>/dev/null || true)"
[[ "$(firewall-offline-cmd --zone="$zone" --query-service=localsend 2>/dev/null)" == "yes" ]] \
  && ok "LocalSend's port is open in the $zone zone" || no "localsend service not enabled in the default firewalld zone"

echo "== first boot: the preset pass keeps the login screen =="
# platform-smoke.sh requires that a full preset pass changes nothing; this is the outcome that
# matters most if it ever does.
if preset_out="$(systemctl preset-all 2>&1)"; then
  dm="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  [[ $dm == */gdm.service && "$(systemctl get-default 2>/dev/null)" == "graphical.target" ]] \
    && ok "after the preset pass GDM is still the display manager, booting graphical.target" \
    || no "after the preset pass the display manager is '${dm:-unset}', default $(systemctl get-default 2>/dev/null)"
else
  no "systemctl preset-all failed: $preset_out"
fi

echo
if [[ $fail == "0" ]]; then echo "DESKTOP SMOKE: PASS"; else echo "DESKTOP SMOKE: FAIL"; fi
exit "$fail"
CHECKS
