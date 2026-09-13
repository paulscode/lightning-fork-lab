#!/usr/bin/env bash
# Reorgs: within v2 blocks, and across the activation boundary. The nodes
# must follow the new tip and report the node's hash afterwards.
source "$(dirname "$0")/lib.sh"

wait_for "lf1 synced" 120 lnd_synced lf1
wait_for "lf2 synced" 120 lnd_synced lf2

reorg_from() {
    local height=$1 depth=$2
    local old; old=$(b2b getblockhash "$height")
    b2b invalidateblock "$old" >/dev/null
    mine_b2b "$depth"
    local new; new=$(b2b getblockhash "$height")
    [ "$old" != "$new" ] || fail "no reorg happened at $height"
    local tip; tip=$(b2b getblockcount)
    local tiphash; tiphash=$(b2b getbestblockhash)
    for svc in lf1 lf2; do
        wait_for "$svc follows reorg to $tip" 120 sh -c "[ \"\$($COMPOSE exec -T $svc lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo | jq -r .block_hash)\" = $tiphash ]"
    done
}

step "reorg: three v2 blocks deep"
tip=$(b2b getblockcount)
reorg_from $(( tip - 2 )) 5
pass "both nodes followed a 3-deep v2 reorg to $(b2b getblockcount)"

step "reorg: across the activation boundary"
tip=$(b2b getblockcount)
depth=$(( tip - ACTIVATION_HEIGHT + 1 ))
reorg_from $(( ACTIVATION_HEIGHT - 1 )) $(( depth + 3 ))
[ "$(header_width $(( ACTIVATION_HEIGHT - 1 )))" = 80 ] || fail "re-mined block below activation is not 80 bytes"
[ "$(header_width "$ACTIVATION_HEIGHT")" = 164 ] || fail "re-mined activation block is not 164 bytes"
for svc in lf1 lf2; do
    st=$(status_state "$svc")
    [ "$st" = "confirmed" ] || fail "$svc state after the boundary reorg is $st"
done
pass "both nodes followed a reorg that replaced the activation block itself; still confirmed"

record reorg result PASS
echo "REORG PASSED"
