#!/usr/bin/env bash
# Live CLI scenarios against a disposable primary clone. $1 = worktree
set -u
WT=$1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME FM_ROOT
T=$(mktemp -d /tmp/fmlive.XXXXXX); T=$(cd "$T" && pwd -P)
P="$WT/bin/fm-prelaunch.sh"
step(){ printf '\n### %s\n' "$*"; }
run(){ printf '$ fm-prelaunch.sh %s\n' "$(echo "$*" | sed -E 's/--token [^ ]+/--token <redacted>/')"; bash "$P" "$@"; printf '[rc=%s]\n' "$?"; }
git init -q --bare -b main "$T/origin.git"; git -C "$WT" push -q "$T/origin.git" HEAD:refs/heads/main
git clone -q "$T/origin.git" "$T/home"; H="$T/home"
git -C "$H" config user.email t@t; git -C "$H" config user.name t
# advance origin by one commit (the "approved candidate")
git clone -q "$T/origin.git" "$T/pub"; git -C "$T/pub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m candidate; git -C "$T/pub" push -q origin HEAD:refs/heads/main
OLD=$(git -C "$H" rev-parse HEAD); git -C "$H" fetch -q origin; NEW=$(git -C "$H" rev-parse origin/HEAD 2>/dev/null || git -C "$H" rev-parse FETCH_HEAD)
NEW=$(git -C "$T/pub" rev-parse HEAD)
echo "home=$H old=$OLD candidate=$NEW"
TOKEN=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)

step "S1 capabilities advertises fresh profiles with exact launch_env"
run capabilities --home "$H"
step "S2 profile claude (no args) matches capability; resume args refused; unknown harness refused"
run profile --home "$H" --harness claude --
run profile --home "$H" --harness claude -- --resume
run profile --home "$H" --harness evil --
step "S3 relative/symlinked --home refused"
ln -s "$H" "$T/homelink"; run capabilities --home "$T/homelink"

step "S4 happy path: reserve -> check-update -> update(pinned) -> validate -> release"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
echo "reservation file:"; ls -l "$H/state/" | grep -i prelaunch
step "S5 guard: explicit writer (no owner) blocked by live reservation; another token blocked; fm-update.sh refused"
run guard-write --home "$H"
run guard-write --home "$H" --owner-pid $$ --token "${TOKEN}x"
run guard-write --home "$H" --owner-pid $$ --token "$TOKEN"
( cd "$H" && FM_HOME="$H" bash bin/fm-update.sh; echo "[fm-update rc=$?]" ) 2>&1 | tail -3
step "S6 second reserve with different token refused"
run reserve --home "$H" --owner-pid $$ --token "B${TOKEN}"
run check-update --home "$H" --owner-pid $$ --token "$TOKEN" --commit "$NEW"
echo "HEAD after check: $(git -C "$H" rev-parse HEAD)"
run update --home "$H" --owner-pid $$ --token "$TOKEN" --commit "$NEW"
echo "HEAD after update: $(git -C "$H" rev-parse HEAD)"
run validate --home "$H" --owner-pid $$ --token "$TOKEN"
run release --home "$H" --owner-pid $$ --token "$TOKEN"
run guard-write --home "$H"

step "S7 fail closed: dirty checkout refuses update and preserves work"
git -C "$T/pub" -c user.email=t@t -c user.name=t commit -q --allow-empty -m candidate2; git -C "$T/pub" push -q origin HEAD:refs/heads/main; NEW2=$(git -C "$T/pub" rev-parse HEAD); git -C "$H" fetch -q origin
echo "local work" > "$H/README.local-dirty"; echo "edit" >> "$H/AGENTS.md"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
run update --home "$H" --owner-pid $$ --token "$TOKEN" --commit "$NEW2"
echo "HEAD: $(git -C "$H" rev-parse HEAD) (expected unchanged $NEW)"; git -C "$H" status --short
run release --home "$H" --owner-pid $$ --token "$TOKEN"
git -C "$H" checkout -q -- AGENTS.md; rm -f "$H/README.local-dirty"
step "S8 fail closed: local-ahead/divergent refuses"
git -C "$H" commit -q --allow-empty -m local-ahead
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
run update --home "$H" --owner-pid $$ --token "$TOKEN" --commit "$NEW2"
echo "HEAD: $(git -C "$H" log --oneline -1)"
run release --home "$H" --owner-pid $$ --token "$TOKEN"
git -C "$H" reset -q --hard "$NEW"
step "S9 fail closed: live session lock refuses reserve"
mkdir -p "$H/state"; sleep 300 & SL=$!; echo "$SL" > "$H/state/.lock"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
kill $SL; wait $SL 2>/dev/null; rm -f "$H/state/.lock"
step "S10 fail closed: dangling inventory meta symlink refuses reserve (strict snapshot)"
ln -s /nonexistent "$H/state/w1.meta"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
rm -f "$H/state/w1.meta"
step "S11 fail closed: pending wake queue refuses reserve"
printf 'x\n' > "$H/state/.wake-queue"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
rm -f "$H/state/.wake-queue"
step "S12 unknown reservation (garbage record) blocks guard-write / fm-update"
echo garbage > "$H/state/$(cd "$WT" && bash -c '. bin/fm-session-lock-lib.sh; echo $FM_PRELAUNCH_RESERVATION_FILE')"
run guard-write --home "$H"
rm -f "$H/state/.prelaunch"* 
step "S13 enrollment-ineligible primaries keep explicit update authority (guard-write clear)"
git -C "$H" remote remove origin
run guard-write --home "$H"
run reserve --home "$H" --owner-pid $$ --token "$TOKEN"
( cd "$H" && FM_HOME="$H" bash bin/fm-update.sh; echo "[fm-update rc=$?]" ) 2>&1 | tail -4
step "S14 secondmate/lab homes and linked worktrees cannot enroll"
git -C "$H" remote add origin "$T/origin.git"
touch "$H/.fm-lab-home"; run reserve --home "$H" --owner-pid $$ --token "$TOKEN"; rm "$H/.fm-lab-home"
touch "$H/.fm-secondmate-home"; run reserve --home "$H" --owner-pid $$ --token "$TOKEN"; rm "$H/.fm-secondmate-home"
git -C "$H" worktree add -q "$T/linked" -b linked; run reserve --home "$T/linked" --owner-pid $$ --token "$TOKEN"
NO_MISTAKES_GATE=1 bash "$P" reserve --home "$H" --owner-pid $$ --token "$TOKEN"; echo "[rc=$? under NO_MISTAKES_GATE]"
step "S15 owner pid that is not caller ancestor refused"
sleep 30 & O=$!; run reserve --home "$H" --owner-pid $O --token "$TOKEN"; kill $O
rm -rf "$T"
