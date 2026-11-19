#!/bin/bash
# Boot smoke test for silverblue-asahi, run at boot by silverblue-asahi-boottest.service
# (images/boottest/). Asserts what a container inspection cannot: that the image booted on the Asahi
# kernel through systemd-boot, brought its services and GDM up, loaded the Apple HID drivers early,
# and that SELinux let GDM and GNOME Initial Setup work. Exits non-zero on any failure.
set -uo pipefail

fail=0
ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗ %s\033[0m\n' "$1"; fail=1; }
note() { printf '  · %s\n' "$1"; }

echo "== kernel =="
kver="$(uname -r)"
echo "  kernel: $kver"
case $kver in
  *16k*|*asahi*) ok "stock Asahi kernel-16k running" ;;
  *) no "unexpected kernel: $kver" ;;
esac
render="$(ls /dev/dri/renderD* 2>/dev/null | head -1 || true)"
[[ -n $render ]] && ok "GPU render node present ($render)" || no "no GPU render node — the desktop would render on llvmpipe"

echo "== bootloader: systemd-boot (not GRUB) =="
# bootctl only looks for the ESP at /efi, /boot and /boot/efi; on Asahi the OS ESP may be mounted
# nowhere. Locate it the way m1n1 does (the device tree names it) and mount it read-only if needed,
# so the "no grub" check below is not vacuous.
esp="$(bootctl --print-esp-path 2>/dev/null || true)" esp_tmp=""
if [[ -z $esp ]]; then
  esp_uuid="$(tr -d '\0' </proc/device-tree/chosen/asahi,efi-system-partition 2>/dev/null || true)"
  esp_dev="$(blkid -t "PARTUUID=$esp_uuid" -o device 2>/dev/null || true)"
  if [[ -n $esp_dev ]]; then
    esp="$(findmnt -no TARGET "$esp_dev" 2>/dev/null | head -1 || true)"
    if [[ -z $esp ]]; then
      esp_tmp="$(mktemp -d)"
      if mount -o ro "$esp_dev" "$esp_tmp" 2>/dev/null; then esp="$esp_tmp"; else rmdir "$esp_tmp"; esp_tmp=""; fi
    fi
  fi
fi
[[ -n $esp ]] && ok "OS ESP located at $esp" || no "OS ESP not found"
# What actually booted, not what is on the ESP (`bootctl status` lists every loader it finds there):
# systemd-boot records itself in the LoaderInfo EFI variable (UTF-16, behind a 4-byte attribute
# header, hence the tr). Should the firmware not hand boot-time variables on to Linux, fall back to
# what U-Boot boots, the removable path.
loader_info="$(tr -cd '[:print:]' </sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f 2>/dev/null || true)"
case $loader_info in
  *systemd-boot*) ok "booted through systemd-boot${loader_info#*systemd-boot}" ;;
  "")
    if [[ -n $esp ]] && grep -qa 'systemd-boot' "$esp/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null; then
      note "no LoaderInfo variable from the firmware; EFI/BOOT/BOOTAA64.EFI (what U-Boot boots) is systemd-boot"
    else
      no "no LoaderInfo variable and EFI/BOOT/BOOTAA64.EFI is not systemd-boot"
    fi
    ;;
  *) no "booted through '$loader_info', not systemd-boot" ;;
esac
if [[ -n $esp ]]; then
  grub="$(find "$esp" -iname 'grub*.efi' -print -quit 2>/dev/null || true)"
  [[ -z $grub ]] && ok "no grub on the ESP" || no "grub on the ESP: $grub"
  [[ -f $esp/m1n1/boot.bin ]] && ok "m1n1 stage 2 present" || no "m1n1/boot.bin missing"
fi
if [[ -n $esp_tmp ]]; then
  umount "$esp_tmp" 2>/dev/null || true
  rmdir "$esp_tmp" 2>/dev/null || true
fi

echo "== m1n1 / devicetree applied for the running kernel =="
[[ "$(cat /var/lib/silverblue-asahi/m1n1-applied 2>/dev/null)" == "$kver" ]] \
  && ok "m1n1 + devicetree applied for $kver" \
  || no "m1n1 not yet applied for the running kernel — reboot once (silverblue-asahi-apply-m1n1)"

echo "== services =="
for u in gdm NetworkManager systemd-resolved tuned tuned-ppd upower firewalld speakersafetyd; do
  systemctl is-active --quiet "$u.service" && ok "$u active" || no "$u not active"
done
systemctl is-active --quiet bluetooth.service && ok "bluetooth active" || note "bluetooth inactive (ok without an adapter)"
swaps="$(cat /proc/swaps 2>/dev/null || true)"
case $swaps in *zram0*) ok "zram swap active" ;; *) no "no zram swap" ;; esac
failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
[[ -z ${failed// /} ]] && ok "no failed system units" || no "failed units: $failed"
sock_group="$(stat -c %G /run/docker.sock 2>/dev/null || true)"
[[ $sock_group == "wheel" ]] && ok "/run/docker.sock belongs to wheel (administrators use Docker without sudo)" \
  || no "/run/docker.sock group is '${sock_group:-missing}', not wheel"

echo "== GDM and GNOME =="
shell="$(pgrep -a gnome-shell 2>/dev/null | head -1 || true)"
[[ -n $shell ]] && ok "gnome-shell running (GDM's greeter, GNOME Initial Setup or a session)" || no "no gnome-shell running — GDM did not bring up a screen"
denials="$(journalctl -b -g 'avc:  denied' --no-pager -q 2>/dev/null | grep -E 'gdm|gnome-initial-setup|xdm|accountsd' || true)"
[[ -z $denials ]] && ok "no SELinux denials for GDM / GNOME Initial Setup" || no "SELinux denials: $(printf '%s' "$denials" | head -3)"

echo "== Apple keyboard + trackpad =="
[[ "$(cat /sys/module/hid_apple/parameters/fnmode 2>/dev/null)" == "1" ]] && ok "hid_apple fnmode=1" || no "hid_apple fnmode is not 1"
devices="$(cat /proc/bus/input/devices 2>/dev/null || true)"
# M1 13" laptops expose SPI devices ("Apple SPI Trackpad"); M2 and later, MTP ("Apple MTP multi-touch").
case $devices in
  *"Apple SPI Trackpad"*|*"Apple MTP multi-touch"*) ok "internal trackpad present" ;;
  *) note "no internal trackpad (desktop Mac?)" ;;
esac
initrd_hid="$(journalctl -b -k --no-pager -q 2>/dev/null | grep -m1 -i 'hid-apple\|hid_apple' || true)"
[[ -n $initrd_hid ]] && note "hid_apple: $initrd_hid"

echo "== first-boot provisioning =="
# The image ships /etc/machine-id empty. On the first boot PID 1 bind-mounts a generated ID over it,
# so reading the file shows an ID either way; it is committed only once that mount is gone and
# systemd-machine-id-commit did not fail. If it never commits, every boot gets a new machine ID
# (journal, DHCP client ID and anything else keyed on it change on every boot).
machine_id="$(cat /etc/machine-id 2>/dev/null || true)"
id_overmount="$(findmnt -n /etc/machine-id 2>/dev/null || true)"
id_commit="$(systemctl is-failed systemd-machine-id-commit.service 2>/dev/null || true)"
if [[ $machine_id =~ ^[0-9a-f]{32}$ && -z $id_overmount && $id_commit != "failed" ]]; then
  ok "machine ID committed after the first boot"
else
  no "machine ID not committed (id '${machine_id:-empty}', overmount '${id_overmount:-none}', commit unit '${id_commit:-?}')"
fi
# GNOME Initial Setup creates the account from GDM; until someone has gone through it there is none,
# which on the first boot is expected rather than a failure.
if primary="$(/usr/libexec/silverblue-asahi-primary-user 2>/dev/null)"; then
  ok "primary user exists (${primary#* }, uid ${primary%% *})"
else
  note "no account yet — finish GNOME Initial Setup on the login screen, then reboot to re-check"
fi
# The Flatpak preinstall and the Brewfile setup are started by their timers (30s after boot, then
# every 2 minutes until the hosts they need answer), so 20s after multi-user.target they are often
# not done yet.
for t in silverblue-asahi-flatpak-preinstall silverblue-asahi-brew-setup; do
  systemctl is-enabled --quiet "$t.timer" && ok "$t.timer enabled" || no "$t.timer not enabled — $t would never run"
done
systemctl is-active --quiet silverblue-asahi-flatpak-preinstall.service && ok "Flatpak app set installed" \
  || note "silverblue-asahi-flatpak-preinstall not done yet (its timer tries every 2 min until the remotes answer)"
[[ -f /var/lib/silverblue-asahi/brew-setup-done ]] && ok "Brewfile applied" \
  || note "silverblue-asahi-brew-setup not done yet (tried every 2 min until the account exists and Homebrew answers; a failed bundle backs off)"

echo "== immutability =="
[[ -L /usr/local ]] && ok "/usr/local is a symlink" || no "/usr/local is not a symlink"
enforce="$(getenforce 2>/dev/null || echo unknown)"
[[ $enforce != "Disabled" ]] && ok "SELinux: $enforce" || no "SELinux disabled"

echo
if [[ $fail == "0" ]]; then echo "BOOT SMOKE: PASS"; else echo "BOOT SMOKE: FAIL"; fi
exit "$fail"
