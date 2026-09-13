#!/usr/bin/env bash
# Channel lifecycle between two Lightning Fork nodes on the BLAKE2b regtest:
# open, pay both ways with lnblakert invoices and keysend, cooperative close,
# then a force close whose sweep confirms.
source "$(dirname "$0")/lib.sh"

wait_for "lf1 synced" 120 lnd_synced lf1
wait_for "lf2 synced" 120 lnd_synced lf2
lf1_pub=$(pubkey_of lf1)
lf2_pub=$(pubkey_of lf2)

step "channel: fund lf1 and connect the two nodes"
fund_lf lf1 2
# Funding mines to coinbase maturity; both nodes must have absorbed those
# blocks before a channel open, or the responder rejects it as unsynced.
wait_for "lf1 synced after funding" 120 lnd_synced lf1
wait_for "lf2 synced after funding" 120 lnd_synced lf2
lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
wait_for "lf1<->lf2 connected" 30 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers | jq -e '.peers[] | select(.pub_key == \"$lf2_pub\")' >/dev/null"
pass "lf1 and lf2 are peers (both sent the networks list; both strict-compatible)"

step "channel: open lf1 -> lf2 and confirm"
lf1 openchannel --node_key="$lf2_pub" --local_amt=1000000 --push_amt=300000 >/dev/null
mine_b2b 6
wait_for "channel active on lf1" 90 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" = 1 ]"
wait_for "channel active on lf2" 90 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" = 1 ]"
cp=$(lf1 listchannels | jq -r '.channels[0].channel_point')
pass "channel $cp active on both sides"

step "channel: pay lf1 -> lf2 with a lnblakert invoice"
inv=$(lf2 addinvoice --amt 50000 --memo "lab" | jq -r .payment_request)
[[ "$inv" == lnblakert* ]] || fail "invoice prefix wrong: $inv"
lf1 payinvoice --force "$inv" >/dev/null
wait_for "lf2 settled" 30 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listinvoices | jq -r '.invoices[-1].state')\" = SETTLED ]"
pass "lf2 settled a 50000 sat lnblakert invoice"

step "channel: pay lf2 -> lf1 with keysend"
lf2 sendpayment --keysend --dest="$lf1_pub" --amt 20000 --force >/dev/null
wait_for "lf1 received keysend" 30 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listinvoices | jq -r '.invoices[-1].state')\" = SETTLED ]"
pass "lf1 received 20000 sat by keysend"

step "channel: cooperative close"
lf1 closechannel --funding_txid="${cp%%:*}" --output_index="${cp##*:}" >/dev/null 2>&1 &
sleep 3
mine_b2b 6
wait_for "close settled on lf1" 90 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '.channels | length')\" = 0 ] && [ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.waiting_close_channels | length')\" = 0 ]"
wait
pass "cooperative close confirmed"

step "channel: open again, force close from lf2, sweep confirms"
wait_for "lf1 synced" 120 lnd_synced lf1
wait_for "lf2 synced" 120 lnd_synced lf2
lf1 openchannel --node_key="$lf2_pub" --local_amt=800000 --push_amt=200000 >/dev/null
mine_b2b 6
wait_for "second channel active on lf2" 90 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels | jq '[.channels[] | select(.active)] | length')\" = 1 ]"
cp2=$(lf2 listchannels | jq -r '.channels[] | select(.active) | .channel_point' | head -1)
# closechannel --force streams until the commitment confirms, so run it in
# the background and wait for the commitment to reach the mempool before
# mining, or the block may miss it.
lf2 closechannel --force --funding_txid="${cp2%%:*}" --output_index="${cp2##*:}" >/dev/null 2>&1 &
close_pid=$!
wait_for "commitment broadcast" 60 sh -c "[ \"\$($COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getmempoolinfo | jq -r .size)\" != 0 ] || [ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" != 0 ]"
mine_b2b 1
wait "$close_pid" || true
# lnd keeps the channel in waiting_close until the commitment has three
# confirmations, then moves it to pending_force_closing.
wait_for "close registered on lf2" 60 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '(.waiting_close_channels | length) + (.pending_force_closing_channels | length)')\" != 0 ]"
mine_b2b 3
wait_for "force close pending on lf2" 60 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" != 0 ]"
pass "commitment confirmed; channel is force-closing on lf2"
# Let the CSV delay pass and the sweeps confirm, a few blocks at a time so
# the nodes broadcast their sweeps between blocks. The initiator assigns the
# remote a delay scaled by channel size: roughly 240 blocks for this one.
for i in $(seq 1 16); do
    mine_b2b 20
    sleep 2
done
wait_for "force close resolved on lf2" 240 sh -c "[ \"\$($COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
wait_for "force close resolved on lf1" 240 sh -c "[ \"\$($COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 pendingchannels | jq '.pending_force_closing_channels | length')\" = 0 ]"
pass "force close from lf2 resolved on both sides after the CSV delay"

step "channel: every confirmed block id still matches the node"
tip=$(b2b getblockcount)
for svc in lf1 lf2; do
    wait_for "$svc at tip" 60 sh -c "[ \"\$($COMPOSE exec -T $svc lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo | jq -r .block_hash)\" = $(b2b getbestblockhash) ]"
done
pass "both nodes at tip $tip with the node's hash"

record channel result PASS
echo "CHANNEL PASSED"
