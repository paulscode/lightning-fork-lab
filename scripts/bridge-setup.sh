#!/usr/bin/env bash
# Stands up the two sides a cross-chain swap needs, and prints the credentials
# the bridge's live test connects with.
#
# The bridge receives on the BLAKE2b chain and pays on Bitcoin, so the liquidity
# has to point the same way:
#
#   lf2  --(BLAKE2b channel)-->  lf1        lf1 is the bridge's incoming node,
#                                           lf2 is the user paying it
#
#   lnd-sha --(Bitcoin channel)--> lnd-sha2 lnd-sha is the bridge's outgoing
#                                           node, lnd-sha2 is the destination
#
# Both channels are opened from the side that needs to spend, because a channel
# opened the other way has no outbound balance and the swap fails for a reason
# that has nothing to do with the bridge.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

step "bridge: wait for all four nodes"
for n in lf1 lf2 lnd-sha lnd-sha2; do
    wait_for "$n up" 120 lnd_ready "$n"
done
# On an idle regtest a node reports unsynced because its tip is old, not
# because it is behind: lnd calls itself out of sync when the best block's
# timestamp is far enough in the past. A fresh block on each chain settles it,
# and without this the setup fails for a reason that has nothing to do with
# what it is testing.
mine_b2b 3
mine_sha 3
for n in lf1 lf2; do wait_for "$n synced" 180 lnd_synced "$n"; done
for n in lnd-sha lnd-sha2; do wait_for "$n synced" 180 lnd_synced "$n"; done
pass "lf1, lf2, lnd-sha and lnd-sha2 are all synced"

step "bridge: BLAKE2b side, lf2 -> lf1"
if [ "$(lf2 listchannels | jq '[.channels[] | select(.active)] | length')" = 0 ]; then
    fund_lf lf2 2
    wait_for "lf1 synced after funding" 120 lnd_synced lf1
    wait_for "lf2 synced after funding" 120 lnd_synced lf2
    open_channel lf2 lf1 1000000 b2b
    pass "lf2 -> lf1 open, the user can pay the bridge"
else
    pass "lf2 already has an active channel"
fi

step "bridge: Bitcoin side, lnd-sha -> lnd-sha2"
if [ "$(lndsha listchannels | jq '[.channels[] | select(.active)] | length')" = 0 ]; then
    fund_sha lnd-sha 2
    wait_for "lnd-sha synced after funding" 120 lnd_synced lnd-sha
    wait_for "lnd-sha2 synced after funding" 120 lnd_synced lnd-sha2
    open_channel lnd-sha lnd-sha2 1000000 sha
    pass "lnd-sha -> lnd-sha2 open, the bridge can pay out"
else
    pass "lnd-sha already has an active channel"
fi

step "bridge: export credentials"
out=${BRIDGE_CREDS:-/tmp/bridge-lab}
mkdir -p "$out"
for n in lf1 lf2 lnd-sha lnd-sha2; do
    $COMPOSE cp "$n:/root/.lnd/tls.cert" "$out/$n-tls.cert" >/dev/null
    $COMPOSE cp "$n:/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon" \
        "$out/$n-admin.macaroon" >/dev/null
    ip=$($COMPOSE ps -q "$n" | xargs docker inspect --format \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    echo "$ip" > "$out/$n.addr"
    pass "$n at $ip"
done

cat <<EOF

Credentials in $out. Run the swap with:

  cd /mnt/Black/lightning-fork-bridge
  BRIDGE_LAB=$out go test -run TestLiveSwap -v ./bridgetest/

EOF
