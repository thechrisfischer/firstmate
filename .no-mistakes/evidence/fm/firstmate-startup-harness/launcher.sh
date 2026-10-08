#!/usr/bin/env bash
# Minimal stand-in for the dotfiles firstmate-start sequence, driving the real
# fm-prelaunch.sh commands and a real claude child. $1=bundle(worktree) $2=home $3=commit $4=log
set -u
B=$1 H=$2 C=$3 L=$4
P="$B/bin/fm-prelaunch.sh"
TOKEN=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)
OWNER=$$
log(){ printf '%s\n' "$*" >> "$L"; }
r(){ out=$(bash "$P" "$@" 2>&1); rc=$?; log "$1 rc=$rc $out"; return $rc; }
r profile --home "$H" --harness claude -- || exit 1
r reserve --home "$H" --owner-pid $OWNER --token "$TOKEN" || exit 1
r check-update --home "$H" --owner-pid $OWNER --token "$TOKEN" --commit "$C" || { bash "$P" release --home "$H" --owner-pid $OWNER --token "$TOKEN"; exit 1; }
r update --home "$H" --owner-pid $OWNER --token "$TOKEN" --commit "$C" || { bash "$P" release --home "$H" --owner-pid $OWNER --token "$TOKEN"; exit 1; }
r validate --home "$H" --owner-pid $OWNER --token "$TOKEN" || exit 1
D=$(mktemp -d); mkfifo "$D/go"
(
  for _ in $(seq 50); do [ -s "$D/pid" ] && break; sleep 0.1; done
  if r attach --home "$H" --owner-pid $OWNER --token "$TOKEN" --child-pid "$(cat "$D/pid")"; then printf g > "$D/go"; else printf n > "$D/go"; fi
) &
cd "$H"
bash -c 'echo $$ > "$1/pid"; read -r -n1 g < "$1/go"; [ "$g" = g ] || exit 9; exec env FM_PRELAUNCH_OWNER_PID="$2" FM_PRELAUNCH_TOKEN="$3" claude' _ "$D" "$OWNER" "$TOKEN"
log "child exited rc=$?"
r release --home "$H" --owner-pid $OWNER --token "$TOKEN"
