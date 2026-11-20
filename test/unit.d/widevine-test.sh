#!/bin/bash

# silverblue-asahi-widevine copies the Widevine CDM that Fedora Asahi's widevine-installer put in
# /var/lib/widevine into each Chromium-family Flatpak's own profile, because the sandbox cannot see
# /var/lib/widevine. Exercised hermetically with a fake CDM, a fake $HOME and a stub `flatpak`.
#
# The detail that cost real debugging: the hint file's Path must be the CANONICAL path the sandboxed
# browser resolves — /var/home/<user>/..., not the /home symlink. A /home path makes Chromium log
# "Widevine enabled but no library found" and skip the CDM. And Brave reads its opt-in only from
# Local State; the same key in the profile's Preferences is ignored and Widevine stays off.

source "$(dirname "$0")/base-test.sh"
require_command jq

tool="$ROOT/system/platform/usr/bin/silverblue-asahi-widevine"
[[ -f $tool ]] || fail "silverblue-asahi-widevine ships"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/uname" <<'SH'
#!/bin/bash
[[ $1 == "-m" ]] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
SH
cat >"$mock_bin/flatpak" <<'SH'
#!/bin/bash
# `flatpak ps` — report Brave as running when MOCK_RUNNING=1
[[ $1 == "ps" && ${MOCK_RUNNING:-0} == "1" ]] && echo com.brave.Browser
exit 0
SH
cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
echo "sudo called: $*" >>"$MOCK_LOG"
exit 1
SH
chmod +x "$mock_bin"/*

cdm="$test_tmp/widevine"
mkdir -p "$cdm"
printf 'not-really-a-cdm' >"$cdm/libwidevinecdm.so"
printf '{"version":"4.10.2830.0"}' >"$cdm/manifest.json"

# A real directory reached through a symlink stands in for /var/home vs /home.
real_home="$test_tmp/var/home/tester"
mkdir -p "$real_home/.var/app/com.brave.Browser" "$test_tmp/home"
ln -s "$real_home" "$test_tmp/home/tester"
link_home="$test_tmp/home/tester"

run_tool() {
  env PATH="$mock_bin:$PATH" HOME="$link_home" SILVERBLUE_ASAHI_WIDEVINE_DIR="$cdm" MOCK_LOG="$test_tmp/mock.log" \
    "$@" >"$test_tmp/out.log" 2>&1
}

# 1) --wire-only with a CDM present wires Brave into its profile.
run_tool bash "$tool" --wire-only || fail "--wire-only succeeds" "$(cat "$test_tmp/out.log")"
profile="$real_home/.var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser"
dest="$profile/WidevineCdm/4.10.2830.0"
[[ -f $dest/_platform_specific/linux_arm64/libwidevinecdm.so ]] || fail "the CDM is copied into Brave's profile" "$(cat "$test_tmp/out.log")"
[[ -f $dest/manifest.json ]] || fail "the CDM manifest is copied alongside it"
pass "the CDM is copied into the Brave Flatpak profile"

hint="$(cat "$profile/WidevineCdm/latest-component-updated-widevine-cdm")"
[[ $hint == "{\"Path\":\"$dest\"}" ]] || fail "the hint points at the canonical (symlink-resolved) path" "got: $hint"
[[ $hint != *"$link_home"* ]] || fail "the hint must not use the /home symlink" "$hint"
pass "the hint file uses the canonical path the sandbox resolves"

optin="$(jq -r '.brave.widevine_opted_in' "$profile/Local State")"
[[ $optin == "true" ]] || fail "Brave's widevine_opted_in is set in Local State" "got: $optin"
[[ ! -e $profile/Default/Preferences ]] || fail "the opt-in is not written to the profile's Preferences, which Brave ignores"
pass "Brave's Widevine opt-in is set in Local State"

# 2) An existing Local State keeps its other keys.
printf '{"browser":{"enabled_labs_experiments":["x"]},"brave":{"other":1}}' >"$profile/Local State"
run_tool bash "$tool" --wire-only || fail "re-wiring succeeds"
[[ "$(jq -r '.browser.enabled_labs_experiments[0]' "$profile/Local State")" == "x" ]] || fail "unrelated Local State keys survive"
[[ "$(jq -r '.brave.other' "$profile/Local State")" == "1" ]] || fail "sibling brave.* keys survive"
[[ "$(jq -r '.brave.widevine_opted_in' "$profile/Local State")" == "true" ]] || fail "the opt-in is merged in"
pass "the opt-in is merged into an existing Local State"

# 3) A running, already opted-in browser just gets the restart notice.
MOCK_RUNNING=1 run_tool bash "$tool" --wire-only || fail "wiring with Brave running succeeds"
grep -q 'still running' "$test_tmp/out.log" || fail "a running browser gets a restart notice" "$(cat "$test_tmp/out.log")"
! grep -q 'brave://settings/extensions' "$test_tmp/out.log" || fail "no opt-in notice once Brave is opted in" "$(cat "$test_tmp/out.log")"
pass "a running browser is told to restart"

# 4) A running Brave that is not opted in keeps its Local State untouched (it would overwrite the
#    edit on exit) and the user is told how to finish.
printf '{"brave":{"other":1}}' >"$profile/Local State"
MOCK_RUNNING=1 run_tool bash "$tool" --wire-only || fail "wiring with Brave running succeeds"
[[ "$(cat "$profile/Local State")" == '{"brave":{"other":1}}' ]] || fail "Local State is left alone while Brave runs" "$(cat "$profile/Local State")"
grep -q 'brave://settings/extensions' "$test_tmp/out.log" || fail "the user is told to quit Brave or use its toggle" "$(cat "$test_tmp/out.log")"
pass "a running Brave's Local State is left alone, with instructions to finish"

# 5) --wire-only with no CDM is a quiet no-op and never escalates.
rm -f "$cdm/libwidevinecdm.so"
: >"$test_tmp/mock.log"
run_tool bash "$tool" --wire-only || fail "--wire-only without a CDM exits 0"
[[ ! -s $test_tmp/mock.log ]] || fail "--wire-only never calls sudo" "$(cat "$test_tmp/mock.log")"
pass "--wire-only without a CDM is a no-op that never escalates"
