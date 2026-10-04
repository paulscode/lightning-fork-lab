#!/usr/bin/env bash
# The bridge with a SHA256 node Lightning Fork runs for the operator
# (bridgerpc.sha256.supervised), through an operator's first run and the two
# failures that matter.
#
#   1. Turned on with nothing else: the node is created from a derived seed,
#      the bridge comes up and says what is missing (a rate, liquidity).
#   2. The operator funds the SHA256 node, opens a channel from it and sets
#      a rate; a payer on the BLAKE2b chain pays a SHA256 invoice through it.
#   3. The SHA256 node is killed while a payer's HTLC is held. When it comes
#      back the swap completes: nothing is lost and nothing paid twice.
#   4. The gate for Phase B2 (doc 07): the SHA256 node's exported phrase and
#      its channel backup restore it in a separate stock lnd, with the
#      identity the export promised, and its channel funds come back.
#
# Step 4 force-closes the SHA256 node's channel and leaves its process
# stopped, so it runs last and only with RESTORE=1.
#
# Needs: docker-compose.supervised.yml, the dev image built from the tree
# (make build), and the two chains up.
source "$(dirname "$0")/lib.sh"

C="docker compose -f docker-compose.yml -f docker-compose.supervised.yml"
lf3()    { $C exec -T lf3 lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
sha256() { $C exec -T lf3-sha256 lncli --network=regtest \
               --lnddir=/lf/sha256-node --rpcserver=127.0.0.1:10019 "$@"; }
status() { lf3 bridge status; }
node_field() { status | jq -r ".sha256_node.$1"; }

step "1. On, with nothing else configured"
$C up -d lf3 lf3-sha256 >/dev/null 2>&1
wait_for "lf3 to answer" 120 lf3 getinfo
wait_for "the supervised SHA256 node to be ready" 300 \
    sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .sha256_node.state)\" = ready ]"
[ "$(node_field mode)" = supervised ] || fail "mode is $(node_field mode)"
want=$(lf3 bridge sha256seed | jq -r .identity_pubkey)
got=$(node_field identity_pubkey)
[ "$want" = "$got" ] || fail "the node is $got, the derived seed gives $want"
pass "the SHA256 node was created from the derived seed ($got)"
for f in /root/.lnd/data/chain/bitcoin/regtest/bridge/sha256/wallet.password \
         /root/.lnd/data/chain/bitcoin/regtest/bridge/sha256/bridge.macaroon; do
    mode=$($C exec -T lf3 stat -c %a "$f")
    [ "$mode" = 600 ] || fail "$f is $mode, wanted 600"
done
pass "its password and the bridge's macaroon are private to this node"
if [ "$(status | jq -r .rate)" = 0 ]; then
    status | jq -e '.refusals | map(select(test("no rate has been set"))) | length == 1' >/dev/null \
        || fail "no rate, and the status does not say so"
    pass "no rate set yet: the bridge is up and says so instead of guessing"
fi

# The bridge's own macaroon cannot move on-chain funds or open channels.
if $C exec -T lf3-sha256 lncli --network=regtest --rpcserver=127.0.0.1:10019 \
        --tlscertpath=/lf/sha256-node/tls.cert \
        --macaroonpath=/lf/data/chain/bitcoin/regtest/bridge/sha256/bridge.macaroon \
        newaddress p2wkh >/dev/null 2>&1; then
    fail "the bridge's macaroon can make addresses; it should not"
fi
pass "the bridge's macaroon is refused anything beyond what the bridge calls"

step "2. Fund it, open a channel from it, set a rate, and swap"
if [ "$(node_field active_channels)" = 0 ]; then
    addr=$(sha256 newaddress p2tr | jq -r .address)
    sha -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null
    mine_sha 6
    wait_for "the deposit to confirm" 120 \
        sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .sha256_node.onchain_confirmed_sat)\" -gt 0 ]"
    pass "the deposit shows in the bridge's status"

    sha2_key=$(lndsha2 getinfo | jq -r .identity_pubkey)
    wait_for "the SHA256 node to catch up" 120 sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .sha256_node.synced_to_chain)\" = true ]"
    sha256 connect "$sha2_key@lnd-sha2:9735" >/dev/null 2>&1 || true
    sha256 openchannel --node_key "$sha2_key" --local_amt 2000000 >/dev/null
    mine_sha 6
    wait_for "the SHA256 node's channel" 180 \
        sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest bridge status | jq -r .sha256_node.active_channels)\" -ge 1 ]"
fi
pass "the SHA256 node has an active channel ($(node_field outbound_msat) msat outbound)"

lf3 bridge setrate 1.0 >/dev/null
pass "rate set"

# The payer: lf2 on the BLAKE2b chain, with a channel to the bridge.
lf3_key=$(lf3 getinfo | jq -r .identity_pubkey)
if ! lf2 listchannels | jq -e --arg k "$lf3_key" '.channels[] | select(.remote_pubkey==$k and .active)' >/dev/null; then
    ensure_b2b_funds 1
    lf2_addr=$(lf2 newaddress p2tr | jq -r .address)
    b2b -rpcwallet=lab sendtoaddress "$lf2_addr" 0.1 >/dev/null
    mine_b2b 6
    wait_for "lf2's coins" 120 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest walletbalance | jq -r .confirmed_balance)\" -gt 0 ]"
    wait_for "lf2 to catch up" 120 lnd_synced lf2
    wait_for "lf3 to catch up" 120 sh -c "[ \"\$($C exec -T lf3 lncli --network=regtest getinfo | jq -r .synced_to_chain)\" = true ]"
    lf2 connect "$lf3_key@lf3:9735" >/dev/null 2>&1 || true
    lf2 openchannel --node_key "$lf3_key" --local_amt 2000000 >/dev/null
    mine_b2b 6
    wait_for "lf2's channel to lf3" 180 sh -c "$COMPOSE exec -T lf2 lncli --network=regtest listchannels | jq -e --arg k '$lf3_key' '.channels[] | select(.remote_pubkey==\$k and .active)'"
fi
pass "the payer has a channel to the bridge"

# The chain observers need block spacing that looks like a chain.
if ! status | jq -e '.refusals | map(select(test("measuring block spacing"))) | length == 0' >/dev/null; then
    COUNT=${COUNT:-160} bash scripts/pace-blocks.sh >/dev/null
    $C restart lf3 >/dev/null
    wait_for "lf3 to answer" 120 lf3 getinfo
fi
wait_for "the bridge to serve toSHA256" 600 \
    sh -c "$C exec -T lf3 lncli --network=regtest bridge info | jq -e '.directions[] | select(.name==\"toSHA256\" and .open)'"
pass "the bridge is serving toSHA256"

swap() {
    local sats=$1
    local inv; inv=$(lndsha2 addinvoice --amt "$sats" | jq -r .payment_request)
    local hold; hold=$(lf3 bridge quote "$inv" | jq -r .hold_invoice)
    [ -n "$hold" ] && [ "$hold" != null ] || fail "no quote for $inv"
    echo "$inv $hold"
}

read -r inv hold <<<"$(swap 50000)"
lf2 payinvoice --force "$hold" >/dev/null
hash=$(lndsha2 decodepayreq "$inv" | jq -r .payment_hash)
wait_for "the SHA256 invoice to settle" 120 \
    sh -c "[ \"\$($COMPOSE exec -T lnd-sha2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash | jq -r .state)\" = SETTLED ]"
pass "a SHA256 invoice was paid through the supervised node"

step "3. The SHA256 node dies with a payer's HTLC held"
read -r inv hold <<<"$(swap 40000)"
hash=$(lndsha2 decodepayreq "$inv" | jq -r .payment_hash)
$C kill lf3-sha256 >/dev/null
$C stop lf3-sha256 >/dev/null
( lf2 payinvoice --force --timeout 10m "$hold" > results/supervised-held.json 2>&1 || true ) &
payer=$!
sleep 20
[ "$($COMPOSE exec -T lnd-sha2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice "$hash" | jq -r .state)" = OPEN ] \
    || fail "the SHA256 invoice moved while the node that pays it was down"
pass "nothing was paid while the SHA256 node was down"
$C start lf3-sha256 >/dev/null
wait_for "the SHA256 invoice to settle after the restart" 300 \
    sh -c "[ \"\$($COMPOSE exec -T lnd-sha2 lncli --network=regtest --rpcserver=127.0.0.1:10009 lookupinvoice $hash | jq -r .state)\" = SETTLED ]"
wait "$payer" || true
paid=$(lf2 listpayments --include_incomplete --max_payments 1000 \
    | jq -r --arg h "$hash" '.payments[] | select(.payment_hash==$h) | .status')
[ "$paid" = SUCCEEDED ] || fail "the payer's payment is $paid"
[ "$(node_field state)" = ready ] || fail "state after restart: $(node_field state)"
pass "after the restart the swap completed and the payer's payment settled"

if [ "${RESTORE:-0}" != 1 ]; then
    echo
    echo "SUPERVISED SCENARIO PASSED (RESTORE=1 runs the restore gate)"
    exit 0
fi

step "4. The gate: restore the SHA256 node outside Lightning Fork"
export_json=$(lf3 bridge sha256seed)
want_id=$(echo "$export_json" | jq -r .identity_pubkey)
words=$(echo "$export_json" | jq -c .mnemonic)
backup=$($C exec -T lf3 base64 -w0 /root/.lnd/sha256-node/data/chain/bitcoin/regtest/channel.backup)
before=$(sha256 channelbalance | jq -r .local_balance.sat)
[ "$before" -gt 0 ] || fail "nothing to recover"
$C stop lf3-sha256 >/dev/null
docker rm -f lf3-restore >/dev/null 2>&1 || true
docker volume rm -f lf3-restore-data >/dev/null 2>&1 || true

docker run -d --name lf3-restore --network lightning-fork-lab_lab \
    -v lf3-restore-data:/root/.lnd lightninglabs/lnd:v0.21.4-beta \
    --bitcoin.regtest --bitcoin.node=bitcoind \
    --bitcoind.rpchost=bitcoind-sha:18443 --bitcoind.rpcuser=lab \
    --bitcoind.rpcpass=lab \
    --bitcoind.zmqpubrawblock=tcp://bitcoind-sha:28332 \
    --bitcoind.zmqpubrawtx=tcp://bitcoind-sha:28333 \
    --rpclisten=0.0.0.0:10009 --restlisten=0.0.0.0:8080 \
    --tlsextradomain=lf3-restore --alias=lf3-restored >/dev/null
sleep 8

# InitWallet over REST, as any wallet tool would: the exported words, the
# channel backup, nothing from Lightning Fork.
pw=$(printf 'restore-password' | base64 -w0)
body=$(jq -n --argjson w "$words" --arg pw "$pw" --arg mcb "$backup" \
    '{wallet_password: $pw, cipher_seed_mnemonic: $w, recovery_window: 2500,
      channel_backups: {multi_chan_backup: {multi_chan_backup: $mcb}}}')
$C exec -T lf3 curl -sk -X POST https://lf3-restore:8080/v1/initwallet \
    -d "$body" > results/supervised-restore-init.json
restore() { docker exec lf3-restore lncli --network=regtest "$@"; }
wait_for "the restored node to come up" 180 restore getinfo
got_id=$(restore getinfo | jq -r .identity_pubkey)
[ "$got_id" = "$want_id" ] || fail "restored as $got_id, the export said $want_id"
pass "the exported phrase restored the node with the promised identity"

# The channel backup makes the peer close the channel; its funds come back.
wait_for "the restored node to ask its peer to close" 300 \
    sh -c "docker exec lf3-restore lncli --network=regtest pendingchannels | jq -e '(.waiting_close_channels | length) + (.pending_force_closing_channels | length) > 0'"
for _ in $(seq 1 30); do
    mine_sha 6
    bal=$(restore walletbalance | jq -r .confirmed_balance)
    [ "$bal" -gt 0 ] && break
    sleep 5
done
bal=$(restore walletbalance | jq -r .confirmed_balance)
[ "$bal" -gt $((before * 9 / 10)) ] \
    || fail "recovered $bal sat of $before in the channel"
pass "the channel's $before sat came back: $bal sat on chain in the restored node"

echo
echo "SUPERVISED SCENARIO PASSED, INCLUDING THE RESTORE GATE"
