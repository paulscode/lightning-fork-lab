#!/usr/bin/env bash
# Core Lightning replacing its pending splice at a higher fee (tx_init_rbf):
# Lightning Fork takes part, adding nothing, the channel stays up, both
# transactions are candidates, and the replacement, the one that confirms,
# is locked. (Answered with tx_abort, as before, the port force-closed the
# channel.)
#
#   LF_IMAGE=lightning-fork:splice CLN_IMAGE=cln-blake2b-release:v7 \
#     bash scripts/scenario-splice-rbf.sh
set -euo pipefail
source "$(dirname "$0")/splice-lib.sh"

lf_chan()  { lf listchannels | jq -r ".channels[0].$1"; }
cln_chan() { cln listpeerchannels | jq -r "[.channels[] | select(.state == \"CHANNELD_NORMAL\")][0].$1"; }

step "rbf: fresh nodes, a channel, Core Lightning funded"
for n in sp-lf sp-cln; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
start_lf; start_cln; sleep 5
mine_b2b 1; wait_synced
ensure_b2b_funds 5
b2b -rpcwallet=lab sendtoaddress "$(lf newaddress p2wkh | jq -r .address)" 2 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r .bech32)" 1 >/dev/null
b2b -rpcwallet=lab sendtoaddress "$(cln newaddr | jq -r .bech32)" 1 >/dev/null
mine_b2b 6; wait_synced
lf connect "$(cln getinfo | jq -r .id)@sp-cln:9735" >/dev/null; sleep 2
lf openchannel --node_key "$(cln getinfo | jq -r .id)" --local_amt 1000000 --push_amt 200000 --sat_per_vbyte 2 >/dev/null
mine_b2b 6; wait_synced
wait_for "channel open" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
pass "a channel of 1,000,000 sat"

step "rbf: Core Lightning splices in, then tries to replace it"
cid=$(cln_chan channel_id)
first=$(cln_splicein "$cid" 150000)
wait_for "pending at Lightning Fork" 60 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_splice.txid')\" = $first ]"
# At the fee floor the port replaces at the same rate: the protocol runs to
# the end, and then its own broadcast is refused by the mempool (it doesn't
# pay more). Either way both transactions are candidates.
rbf=$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data -J splicein "$cid" 150000 2>&1) || true
echo "Core Lightning's RBF answered: $(echo "$rbf" | tr -d '\n' | cut -c1-200)"
if echo "$rbf" | grep -q "Peer aborted"; then fail "Lightning Fork refused the RBF: $rbf"; fi
wait_for "two candidates at Core Lightning" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].inflight | length')\" = 2 ]"
second=$(cln listpeerchannels | jq -r --arg f "$first" '.channels[0].inflight[] | select(.funding_txid != $f) | .funding_txid')
wait_for "Lightning Fork logs the replacement" 30 sh -c "docker logs sp-lf 2>&1 | grep -q 'peer replaces splice $first'"
state=$(cln listpeerchannels | jq -r '.channels[0].state')
[ "$state" != AWAITING_UNILATERAL ] || fail "Core Lightning failed the channel"
pass "replaced: $first by $second, the channel up ($state)"

step "rbf: the candidate that confirms is locked"
# Core Lightning's coins in it: one block more than our 6.
mine_b2b 36; wait_synced
wait_for "locked at 1,150,000" 90 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].capacity')\" = 1150000 ] && [ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_splice')\" = null ]"
won=$(lf_chan channel_point | cut -d: -f1)
[ "$won" = "$first" ] || [ "$won" = "$second" ] || fail "locked on $won, neither candidate"
wait_for "Core Lightning on the same funding" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].funding_txid')\" = $won ] && [ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
inv=$(cln invoice 10000000 rbf-after x | jq -r .bolt11)
lf payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "payment after the lock failed"
pass "both locked on $won ($( [ "$won" = "$first" ] && echo the original || echo the replacement )), a payment goes through"

step "rbf: Core Lightning splices while a splice of Lightning Fork's is pending"
# At the floor: Core Lightning replaces at its floor rate, and a
# replacement at a lower rate than ours is refused.
docker exec -d sp-lf sh -c "lncli --network=regtest --rpcserver=127.0.0.1:10009 splice in --chan_point $(lf_chan channel_point) --amt 100000 --sat_per_vbyte 1 > /tmp/ours.log 2>&1"
wait_for "our splice broadcast" 60 sh -c "docker exec sp-lf grep -q '\"broadcast\"' /tmp/ours.log"
ours=$(lf_chan pending_splice.txid)
cap=$(lf_chan capacity)
# Our splice pending, the channel is CHANNELD_AWAITING_SPLICE there.
cid=$(cln listpeerchannels | jq -r '.channels[0].channel_id')
out=$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data -J splicein "$cid" 50000 2>&1) || true
echo "Core Lightning's splicein answered: $(echo "$out" | tr -d '\n' | cut -c1-160)"
if echo "$out" | grep -q "Peer aborted"; then fail "Lightning Fork refused: $out"; fi
wait_for "Lightning Fork logs the replacement" 30 sh -c "docker logs sp-lf 2>&1 | grep -q 'peer replaces splice $ours'"
[ "$(cln listpeerchannels | jq -r '.channels[0].state')" != AWAITING_UNILATERAL ] || fail "Core Lightning failed the channel"
mine_b2b 36; wait_synced
wait_for "locked" 90 sh -c "[ \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].pending_splice')\" = null ]"
newcap=$(lf_chan capacity)
case $((newcap - cap)) in
	100000|150000) ;;
	*) fail "capacity $cap became $newcap" ;;
esac
wait_for "Core Lightning on the same funding" 60 sh -c "[ \"\$(docker exec sp-cln lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].funding_txid')\" = \"\$(docker exec sp-lf lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq -r '.channels[0].channel_point' | cut -d: -f1)\" ]"
inv=$(cln invoice 10000000 rbf-ours x | jq -r .bolt11)
lf payinvoice --force "$inv" 2>&1 | grep -q SUCCEEDED || fail "payment after the lock failed"
pass "Lightning Fork's 100,000 kept, the channel now $newcap (+$((newcap - cap))), a payment goes through"

echo "rbf scenario: all steps passed"
