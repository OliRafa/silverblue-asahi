#!/bin/bash

# Static checks on the image that only fail on real hardware if they regress: the Apple HID early-load
# fix has to reach the initramfs, which only happens if its drop-ins are in the image before
# images/silverblue-asahi/Containerfile rebuilds it; the units the Containerfile enables have to
# exist; the first boot must stay GNOME Initial Setup's; and nothing from Omarchy, or from the
# Hyprland image this was derived from, may leak back in.

source "$(dirname "$0")/base-test.sh"

overlay="$ROOT/system/platform"
containerfile="$ROOT/images/silverblue-asahi/Containerfile"
packages="$ROOT/packages/platform.packages"

# --- Apple HID: modprobe + dracut drop-ins ------------------------------------------------------

grep -qx 'options hid_apple fnmode=1' "$overlay/usr/lib/modprobe.d/silverblue-asahi-apple.conf" ||
  fail "hid_apple fnmode=1 is configured"
grep -qE '^force_drivers\+=" hid_apple hid_magicmouse "$' "$overlay/usr/lib/dracut/dracut.conf.d/90-silverblue-asahi-apple-hid.conf" ||
  fail "dracut forces hid_apple + hid_magicmouse into the initramfs"
pass "the Apple HID modprobe and dracut drop-ins are present"

# The overlay COPY must come before the initramfs rebuild, or the drop-ins never reach it.
copy_line=$(grep -n '^COPY system/platform/ /' "$containerfile" | head -1 | cut -d: -f1)
dracut_line=$(grep -n 'dracut --force' "$containerfile" | head -1 | cut -d: -f1)
[[ -n $copy_line && -n $dracut_line ]] || fail "the Containerfile copies the overlay and rebuilds the initramfs"
(( copy_line < dracut_line )) ||
  fail "the platform overlay is copied before the initramfs rebuild" "COPY at $copy_line, dracut at $dracut_line"
pass "the platform overlay is copied before the initramfs rebuild"

# hid-magicmouse is built into the stock kernel-16k while hid-apple is a module. The build-time
# initramfs check must accept a built-in driver, or it rejects every build.
grep -q 'modules.builtin' "$containerfile" || fail "the initramfs check accepts built-in HID drivers"
pass "the initramfs check accepts built-in HID drivers"

# --- units the Containerfile enables exist ------------------------------------------------------

while read -r unit; do
  [[ -f $overlay/usr/lib/systemd/system/$unit ]] || fail "enabled unit ships: $unit"
done < <(grep -oE 'silverblue-asahi-[a-z0-9-]+\.(service|timer)' "$containerfile" | sort -u)
pass "every silverblue-asahi-* unit the Containerfile enables ships in the overlay"

for f in "$overlay"/usr/lib/systemd/system/silverblue-asahi-*.service; do
  grep -qE '^ExecStart=' "$f" || fail "$(basename "$f") has an ExecStart"
  exec_path=$(sed -n 's/^ExecStart=\(\/usr\/[^ ]*\).*/\1/p' "$f" | head -1)
  if [[ $exec_path == /usr/libexec/silverblue-asahi-* || $exec_path == /usr/bin/silverblue-asahi-* ]]; then
    [[ -f $overlay$exec_path ]] || fail "$(basename "$f") runs a helper that ships: $exec_path"
  fi
done
pass "every silverblue-asahi-* service has an ExecStart whose helper ships"

# --- presets: a first boot keeps every unit as built --------------------------------------------

# The image stage: everything from the base image's FROM on (the brew stage before it only supplies
# files).
image_stage=$(sed -n '/^FROM \${BASE}/,$p' "$containerfile")
[[ -n $image_stage ]] || fail "the Containerfile builds FROM the base image"
[[ -n $(printf '%s\n' "$image_stage" | containerfile_units enable) ]] ||
  fail "the image's systemctl enables can be read (else the coverage check proves nothing)"
check_preset "$overlay/usr/lib/systemd/system-preset/50-silverblue-asahi.preset" "$image_stage"
pass "50-silverblue-asahi.preset covers every unit the image enables or disables, read before Fedora's"

# Fedora's 90-default.preset enables sshd; first match wins, so this line keeps it off.
grep -qx 'disable sshd.service' "$overlay/usr/lib/systemd/system-preset/50-silverblue-asahi.preset" ||
  fail "50-silverblue-asahi.preset disables sshd.service"
pass "50-silverblue-asahi.preset disables sshd"

check_machine_id_empty_last "$image_stage"
pass "the image ships /etc/machine-id empty, after its last package transaction (GNOME Initial Setup asks the first-boot questions)"

grep -qE 'tuned-ppd\.service' <<<"$(printf '%s\n' "$image_stage" | containerfile_units enable)" ||
  fail "the image enables tuned-ppd (the base's power-profiles provider)"
pass "the image enables tuned-ppd for power profiles"

boottest="$ROOT/images/boottest/Containerfile"
installed=$(sed -n 's|^COPY images/boottest/silverblue-asahi-boottest.preset /usr/lib/systemd/system-preset/\(.*\)$|\1|p' "$boottest")
[[ -n $installed ]] || fail "the boottest image installs its preset"
check_preset "$ROOT/images/boottest/silverblue-asahi-boottest.preset" "$(cat "$boottest")" "$installed"
pass "the boottest image's preset ($installed) covers the unit it enables"

grep -qF 'systemctl disable sshd.service' "$containerfile" || fail "the Containerfile disables sshd"
grep -qF -- '--remove-service-from-zone=ssh' "$containerfile" ||
  fail "the Containerfile removes ssh from the default firewalld zone"
pass "the Containerfile disables sshd and closes ssh in the default firewalld zone"

# --- package list hygiene -----------------------------------------------------------------------

dupes=$(sed 's/#.*//' "$packages" | awk 'NF{print $1}' | sort | uniq -d)
[[ -z $dupes ]] || fail "platform.packages has no duplicates" "$dupes"
pass "platform.packages has no duplicates"

# GNOME is the base's, untouched; a desktop package here means a second desktop or a swapped piece.
if sed 's/#.*//' "$packages" | awk 'NF{print $1}' | grep -qxE 'quickshell|sddm|hyprland.*|noctalia.*|greetd|gnome-.*|gdm|mutter|nautilus'; then
  fail "the package list carries no desktop packages"
fi
pass "the package list carries no desktop packages"

# power-profiles-daemon conflicts with the base's tuned-ppd; dnf would either fail or swap them.
if sed 's/#.*//' "$packages" | awk 'NF{print $1}' | grep -qx 'power-profiles-daemon'; then
  fail "the package list does not pull power-profiles-daemon (it conflicts with tuned-ppd)"
fi
pass "the package list leaves power profiles to tuned-ppd"

# --- boot tooling and GNOME Software --------------------------------------------------------------

# bootc picks systemd-boot only with bootupd gone; removing it in one transaction with the GRUB EFI
# packages fails as a whole (dnf protects shim-aa64, which requires grub2-efi-aa64) and removes nothing.
grep -qE 'dnf -y remove bootupd;' "$containerfile" || fail "the Containerfile removes bootupd on its own"
grep -qF '! rpm -q bootupd' "$containerfile" || fail "the Containerfile fails the build if bootupd survives"
if grep -vE '^[[:space:]]*#' "$containerfile" | grep -qE 'dnf -y remove( [^;]*)? (grub2-efi[a-z0-9-]*|shim[a-z0-9-]*|rpm-ostree)( |;|$)'; then
  fail "the Containerfile does not try to remove GRUB, shim or rpm-ostree (protected, or held by tuned)" \
    "$(grep -nE 'dnf -y remove' "$containerfile")"
fi
pass "bootupd is removed on its own; GRUB, shim and rpm-ostree are left (protected or required)"

grep -qE 'dnf -y remove gnome-software-rpm-ostree' "$containerfile" ||
  fail "the Containerfile removes GNOME Software's rpm-ostree plugin (it cannot manage a composefs install)"
grep -qF 'rpm -q gnome-software >/dev/null' "$containerfile" ||
  fail "the Containerfile asserts GNOME Software itself survives the plugin's removal"
# The dnf5 plugin ships in gnome-software itself; only the rpm-ostree plugin's conflict rule kept it
# from offering RPM updates.
grep -qF 'rm -f "$plugin_dir/libgs_plugin_dnf5.so"' "$containerfile" ||
  fail "the Containerfile deletes GNOME Software's dnf5 plugin (it would offer RPM updates on a read-only /usr)"
grep -qF '[ -f "$plugin_dir/libgs_plugin_flatpak.so" ]' "$containerfile" ||
  fail "the Containerfile asserts GNOME Software keeps its Flatpak plugin"
if grep -qE 'dnf -y remove( [^;]*)? dnf5daemon-server' "$containerfile"; then
  fail "the Containerfile does not remove dnf5daemon-server (gnome-software requires it)"
fi
pass "GNOME Software loses its rpm-ostree and dnf5 plugins and keeps everything else"

# --- composefs is not ostree ----------------------------------------------------------------------

# A composefs-native boot writes no /run/ostree-booted. Units that skip themselves on ostree would
# run, and units that run only on ostree would never fire, unless the image says otherwise.
grep -qE 'systemctl disable dnf-makecache\.timer' "$containerfile" ||
  fail "the Containerfile disables dnf-makecache.timer (it skips itself only on ostree)"
for u in bootc-fetch-apply-updates.timer bootc-fetch-apply-updates.service \
         fedora-atomic-desktop-appstream-cache-refresh.service fedora-atomic-desktop-mandb-update.service; do
  dropin="$overlay/usr/lib/systemd/system/$u.d/10-silverblue-asahi-composefs.conf"
  [[ -f $dropin ]] || fail "$u has a composefs drop-in"
  grep -qx 'ConditionPathExists=' "$dropin" || fail "$u's drop-in resets the /run/ostree-booted condition"
  grep -E '^Condition' "$dropin" | grep -qF 'ostree-booted' && fail "$u's drop-in does not reinstate the ostree gate"
done
# The reset clears every condition, so the atomic-desktop refreshes must restate their /var one.
for u in fedora-atomic-desktop-appstream-cache-refresh fedora-atomic-desktop-mandb-update; do
  grep -qx 'ConditionPathIsReadWrite=/var' "$overlay/usr/lib/systemd/system/$u.service.d/10-silverblue-asahi-composefs.conf" ||
    fail "$u's drop-in restates ConditionPathIsReadWrite=/var after the reset"
done
grep -qF '[ "$(stat -c %Y "$MOZ_LANGPACKS_DIR/$langpack" 2>/dev/null)" = "0" ]' "$containerfile" ||
  fail "the Containerfile makes Firefox copy mtime-0 langpacks"
grep -qF 'no longer has the ostree langpack test this step patches' "$containerfile" ||
  fail "the Containerfile fails the build when Firefox's ostree test it patches is gone"
pass "composefs boots get stock Silverblue's behaviour: no dnf-makecache, the ostree-only units ungated, Firefox's langpack copy"

# --- Docker: administrators, without sudo ---------------------------------------------------------

socket_dropin="$overlay/usr/lib/systemd/system/docker.socket.d/10-silverblue-asahi-wheel.conf"
[[ -f $socket_dropin ]] || fail "the docker.socket drop-in ships"
grep -qx '\[Socket\]' "$socket_dropin" && grep -qx 'SocketGroup=wheel' "$socket_dropin" ||
  fail "the Docker socket belongs to wheel (GNOME Initial Setup's account is an administrator)"
pass "the Docker socket belongs to wheel, so administrators use Docker without sudo"

# --- systemd-oomd: apps before the session --------------------------------------------------------

# Fedora's systemd-oomd-defaults puts an explicit 80% limit on every user slice, which overrides any
# DefaultMemoryPressureLimit=, so the apps' lower limit has to be set on app.slice itself.
app_slice_dropin="$overlay/usr/lib/systemd/user/app.slice.d/10-silverblue-asahi-oomd.conf"
grep -qx 'ManagedOOMMemoryPressure=kill' "$app_slice_dropin" && grep -qx 'ManagedOOMMemoryPressureLimit=50%' "$app_slice_dropin" ||
  fail "app.slice sets its own 50% memory pressure limit"
! grep -q '^DefaultMemoryPressureLimit=' "$overlay/usr/lib/systemd/oomd.conf.d/10-silverblue-asahi.conf" ||
  fail "oomd.conf sets no DefaultMemoryPressureLimit (Fedora's per-slice limits always override it)"
pass "systemd-oomd acts on apps at a lower pressure than Fedora's 80% for the session"

# --- /var comes from tmpfiles.d, not the image ----------------------------------------------------

# The last step deletes plocate's packaged /var/lib/plocate; without the tmpfiles entry nothing would
# create it again, and plocate-updatedb would fail every day.
plocate_tmpfiles="$overlay/usr/lib/tmpfiles.d/silverblue-asahi-plocate.conf"
if grep -qE '^plocate([[:space:]]|$)' "$packages"; then
  grep -qF 'rm -rf /var/lib/plocate' "$containerfile" || fail "the Containerfile removes plocate's packaged /var content"
  grep -qE '^d /var/lib/plocate ' "$plocate_tmpfiles" && grep -qE '^f /var/lib/plocate/CACHEDIR.TAG .* Signature: 8a477f597d28d172789f06886806bc55$' "$plocate_tmpfiles" ||
    fail "tmpfiles.d creates /var/lib/plocate and its CACHEDIR.TAG"
fi
pass "plocate's /var directory is created by tmpfiles.d, not baked into the image"

# --- no Omarchy, consistent shebangs ------------------------------------------------------------

# The smoke tests under hack/ name what they assert is absent, so they are exempt.
leaks=$(grep -rniE 'omarchy|fenoa|hyprland|noctalia|greetd|uwsm|fairydust' "$ROOT/system" "$ROOT/images" "$ROOT/packages" "$ROOT/Brewfile" 2>/dev/null | grep -v '/hack/' || true)
[[ -z $leaks ]] || fail "no Omarchy, Fenoa or Hyprland-session references in the image sources" "$leaks"
pass "no Omarchy, Fenoa or Hyprland-session references in the image sources"

while IFS= read -r script; do
  first=$(head -n1 "$ROOT/$script")
  [[ $first == "#!/bin/bash" ]] || fail "$script uses #!/bin/bash" "got: $first"
done < <("$ROOT/test/shell-files" | grep -vE '^deploy/lib/|/profile.d/|^test/unit.d/base-test.sh$')
pass "every executable shell script uses #!/bin/bash (sourced files are exempt)"

# A script committed without its executable bit fails wherever it is run directly (CI runs the image
# tests as ./images/...). The Containerfiles chmod the overlay helpers anyway; the repo copy must
# match. base-test.sh is only ever sourced.
while IFS= read -r script; do
  [[ -x $ROOT/$script ]] || fail "$script is executable"
done < <("$ROOT/test/shell-files" | grep -vE '^deploy/lib/|/profile.d/|^test/unit.d/base-test.sh$')
pass "every executable shell script has its executable bit"
