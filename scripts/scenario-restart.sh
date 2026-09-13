#!/usr/bin/env bash
# Restart on a v2 tip: the node comes back, re-runs the chain check, and
# resumes at the tip. Also checks that swapping the backend to the SHA256d
# node under a restart is refused.
source "$(dirname "$0")/lib.sh"

wait_for "lf1 synced" 120 lnd_synced lf1

step "restart: lf1 restarts on a v2 tip"
tip=$(b2b getbestblockhash)
$COMPOSE restart lf1 >/dev/null
wait_for "lf1 back" 120 lnd_ready lf1
wait_for "lf1 synced" 120 lnd_synced lf1
[ "$(status_state lf1)" = confirmed ] || fail "lf1 state after restart is $(status_state lf1)"
[ "$(lf1 getinfo | jq -r .block_hash)" = "$tip" ] || fail "lf1 did not resume at the tip"
mine_b2b 2
wait_for "lf1 follows after restart" 60 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo | jq -r .block_hash)\" = $(b2b getbestblockhash) ]"
pass "lf1 resumed on the v2 tip and kept following"

step "restart: lf1 restarted against the SHA256d node must refuse"
$COMPOSE stop lf1 >/dev/null
# Run the same data directory against bitcoind-sha with a one-off container.
set +e
out=$(docker run --rm --network lightning-fork-lab_lab \
    -v lightning-fork-lab_lf1-data:/root/.lnd \
    lightning-fork:dev \
    --noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
    --bitcoin.blake2b-activation-height="$ACTIVATION_HEIGHT" \
    --bitcoind.rpchost=bitcoind-sha:18443 --bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
    --bitcoind.zmqpubrawblock=tcp://bitcoind-sha:28332 --bitcoind.zmqpubrawtx=tcp://bitcoind-sha:28333 \
    --rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 --alias=lf1-swapped --debuglevel=info 2>&1)
code=$?
set -e
[ "$code" != 0 ] || fail "lf1 started against the SHA256d node"
echo "$out" | grep -q "not on the Bitcoin BLAKE2b chain" || { echo "$out" | tail -10; fail "no refusal in the output"; }
pass "swapped backend refused (exit $code)"

$COMPOSE up -d lf1 >/dev/null
wait_for "lf1 back on knots-b2b" 120 lnd_ready lf1
wait_for "lf1 synced again" 120 lnd_synced lf1
[ "$(status_state lf1)" = confirmed ] || fail "lf1 not confirmed after returning to knots-b2b"
pass "lf1 is back on the BLAKE2b node and confirmed"

record restart result PASS
echo "RESTART PASSED"
