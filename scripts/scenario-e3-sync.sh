#!/usr/bin/env bash
# E3: a Lightning Fork node waits below the activation height, confirms the
# chain once the node crosses it, and then follows v2 blocks over ZMQ (lf1)
# and over RPC polling (lf2), computing the same block ids the node does.
source "$(dirname "$0")/lib.sh"

step "E3: the chain is below activation; lf1 and lf2 must be waiting"
h=$(b2b getblockcount)
[ "$h" -lt "$ACTIVATION_HEIGHT" ] || fail "expected the chain below $ACTIVATION_HEIGHT, it is at $h (run make nuke && make up)"

for svc in lf1 lf2; do
    wait_for "$svc status file" 90 sh -c "[ -n \"\$($COMPOSE exec -T $svc sh -c 'cat /root/.lnd/data/chain/bitcoin/regtest/chain-identity.json 2>/dev/null')\" ]"
    st=$(status_state "$svc")
    [ "$st" = "waiting" ] || fail "$svc state is '$st', expected waiting"
    hdrs=$(status_file "$svc" | jq -r .node_headers)
    [ "$hdrs" = "$h" ] || fail "$svc reports node_headers=$hdrs, chain is at $h"
    pass "$svc is waiting at node height $h (status file says so)"
done

step "E3: cross the activation height"
mine_b2b $(( ACTIVATION_HEIGHT - h + 5 ))
w_before=$(header_width $(( ACTIVATION_HEIGHT - 1 )))
w_at=$(header_width "$ACTIVATION_HEIGHT")
[ "$w_before" = 80 ] || fail "header below activation is $w_before bytes"
[ "$w_at" = 164 ] || fail "header at activation is $w_at bytes"
pass "node serves an 80-byte header at $((ACTIVATION_HEIGHT-1)) and a 164-byte header at $ACTIVATION_HEIGHT"

for svc in lf1 lf2; do
    wait_for "$svc confirmed" 120 sh -c "[ \"\$($COMPOSE exec -T $svc sh -c 'cat /root/.lnd/data/chain/bitcoin/regtest/chain-identity.json' | jq -r .state)\" = confirmed ]"
    act=$(status_file "$svc" | jq -r .activation_hash)
    node_act=$(b2b getblockhash "$ACTIVATION_HEIGHT")
    [ "$act" = "$node_act" ] || fail "$svc recorded activation hash $act, node says $node_act"
    pass "$svc confirmed the BLAKE2b chain; activation hash matches the node"
done

step "E3: both nodes reach the RPC and sync to the tip"
for svc in lf1 lf2; do
    wait_for "$svc rpc" 120 lnd_ready "$svc"
    wait_for "$svc synced" 120 lnd_synced "$svc"
    tip=$(b2b getblockcount)
    [ "$(lnd_height "$svc")" = "$tip" ] || fail "$svc height $(lnd_height "$svc") != node tip $tip"
    hash=$(lncli_on "$svc" getinfo | jq -r .block_hash)
    node_hash=$(b2b getbestblockhash)
    [ "$hash" = "$node_hash" ] || fail "$svc best hash $hash != node $node_hash"
    pass "$svc synced to $tip with the node's best hash"
done

step "E3: follow ten more v2 blocks, one at a time"
for i in $(seq 1 10); do
    mine_b2b 1
    tip=$(b2b getblockcount)
    node_hash=$(b2b getbestblockhash)
    for svc in lf1 lf2; do
        wait_for "$svc at $tip" 60 sh -c "[ \"\$($COMPOSE exec -T $svc lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo | jq -r .block_hash)\" = $node_hash ]"
    done
done
pass "lf1 (ZMQ) and lf2 (RPC polling) followed ten v2 blocks with matching hashes"

step "E3: no reorg noise in the logs"
for svc in lf1 lf2; do
    svc_logs=$($COMPOSE logs --no-color "$svc" 2>&1)
    if echo "$svc_logs" | grep -qi "reorg\|orphan block\|unable to find block"; then
        echo "$svc_logs" | grep -i "reorg\|orphan\|unable to find block" | tail -5
        fail "$svc logged reorg/orphan messages while following a linear chain"
    fi
done
pass "no spurious reorg messages"

record e3-sync result PASS
echo "E3 PASSED"
