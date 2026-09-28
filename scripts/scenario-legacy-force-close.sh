#!/usr/bin/env bash
# Does a force close that is still in progress survive the upgrade?
#
# Releases up to v0.21.3-beta-blake2b.9 kept a closing channel's contract
# resolutions in the chain arbitrator's log, a bucket named after the chain
# hash that release advertised, and outputs waiting out a timelock in a
# nursery bucket named the same way. channeldb migration 36 moves the channel
# itself but neither of those. A node upgraded mid close would then find the
# channel with no resolutions, and nothing would sweep its balance back.
#
#   1. two .9 nodes with a channel; A force closes it and the commitment
#      confirms, so A's balance is waiting out its CSV delay
#   2. upgrade A on its own data directory before the delay expires
#   3. mine past the delay: A must sweep its balance and finish the close
#
# DB_ARGS picks the database, as in scenario-legacy-gossip.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
OLD_IMAGE=${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.9}
NEW_IMAGE=${NEW_IMAGE:-lightning-fork:dev}
A=${PREFIX:-lfc}-a
B=${PREFIX:-lfc}-b
ALL="$A $B"

exec 9>/tmp/scenario-legacy-force-close-${PREFIX:-lfc}.lock
flock -n 9 || fail "another run of this scenario holds the lock"

cleanup() {
	local rc=$?
	if [ "$rc" != 0 ]; then
		for n in $ALL; do
			echo "=== $n (last 15) ==="
			docker logs "$n" 2>&1 | tail -15 || true
		done
	fi
	# KEEP leaves the nodes up after the run, for inspection.
	[ -n "${KEEP:-}" ] || docker rm -f $ALL >/dev/null 2>&1 || true
}
trap cleanup EXIT

start_node() {
	local name=$1 image=$2
	docker run -d --name "$name" --network "$N" -v "$name-data:/root/.lnd" \
		--platform linux/amd64 "$image" \
		--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
		--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
		--fee.url=http://fees:8080/fees.json \
		--bitcoind.rpchost=knots-b2b:18443 \
		--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
		--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
		--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
		--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
		--externalip="$name":9735 --tlsextradomain="$name" \
		${DB_ARGS:-} --alias="$name" \
		--debuglevel="${DEBUGLEVEL:-info}" >/dev/null
}

cli() {
	local name=$1; shift
	docker exec "$name" lncli --network=regtest \
		--rpcserver=127.0.0.1:10009 "$@"
}

wait_up() {
	wait_for "$1 up" 180 sh -c \
		"docker exec $1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo 2>/dev/null | grep -Eq '\"synced_to_chain\": +true'"
}

pub() { cli "$1" getinfo | jq -r .identity_pubkey; }

balance() { cli "$1" walletbalance | jq -r .confirmed_balance; }

docker rm -f $ALL >/dev/null 2>&1 || true
for n in $ALL; do docker volume rm -f "$n-data" >/dev/null 2>&1 || true; done

step "force close: two nodes on the release that stored closes under the old chain hash"
start_node $A "$OLD_IMAGE"
start_node $B "$OLD_IMAGE"
wait_up $A
wait_up $B
echo "  running: $(cli $A getinfo | jq -r .version)  ${DB_ARGS:-(bbolt)}"

addr=$(cli $A newaddress p2tr | jq -r .address)
b2b -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null
mine_b2b 6 >/dev/null 2>&1
wait_for "A funded" 120 sh -c \
	"[ \"\$(docker exec $A lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"

b_pub=$(pub $B)
for i in $(seq 1 18); do
	cli $A connect "$b_pub@$B:9735" >/dev/null 2>&1 || true
	[ "$(cli $A listpeers | jq '.peers | length')" -ge 1 ] && break
	sleep 5
done
cli $A openchannel --node_key "$b_pub" --local_amt 1000000 >/dev/null
mine_b2b 6 >/dev/null 2>&1
cp=""
for i in $(seq 1 24); do
	cp=$(cli $A listchannels | jq -r '.channels[] | select(.active) | .channel_point' | head -1)
	[ -n "$cp" ] && [ "$cp" != null ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 5
done
[ -n "$cp" ] && [ "$cp" != null ] || fail "no active channel"
local_bal=$(cli $A listchannels | jq -r --arg c "$cp" '.channels[] | select(.channel_point == $c) | .local_balance')
echo "  channel        : $cp, A's balance in it $local_bal"

step "force close: A closes by force and the commitment confirms"
cli $A closechannel --force --funding_txid "${cp%:*}" --output_index "${cp#*:}" >/dev/null 2>&1 &
sleep 8
mine_b2b 1 >/dev/null 2>&1
maturity=""
for i in $(seq 1 24); do
	maturity=$(cli $A pendingchannels | jq -r --arg c "$cp" \
		'.pending_force_closing_channels[] | select(.channel.channel_point == $c) | .maturity_height' | head -1)
	[ -n "$maturity" ] && [ "$maturity" != 0 ] && [ "$maturity" != null ] && break
	# The commitment may reach the mempool after the block above.
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 5
done
[ -n "$maturity" ] && [ "$maturity" != 0 ] && [ "$maturity" != null ] || fail "the close never reached its timelock"
before=$(balance $A)
height=$(cli $A getinfo | jq -r .block_height)
echo "  A's balance matures at height $maturity (now $height); wallet holds $before"

step "force close: upgrade A before the delay expires"
docker rm -f $A >/dev/null
start_node $A "$NEW_IMAGE"
wait_up $A
docker logs $A 2>&1 | grep -E "onto the current chain hash|arbitrator log|nothing to do" | sed 's/^.*\] /  log: /' || true

step "force close: mine past the delay"
done_at=""
for i in $(seq 1 40); do
	mine_b2b 10 >/dev/null 2>&1
	sleep 3
	pending=$(cli $A pendingchannels | jq -r --arg c "$cp" \
		'[.pending_force_closing_channels[] | select(.channel.channel_point == $c)] | length')
	now=$(balance $A)
	# The balance reaching the wallet is what matters. Whether the close
	# still lists as pending is reported below rather than required: on
	# SQLite this base keeps listing it, anchor in LIMBO, with or without
	# an upgrade in between.
	if [ $((now - before)) -gt $((local_bal / 2)) ]; then
		done_at=$(cli $A getinfo | jq -r .block_height)
		break
	fi
done
# Give the close a few blocks to finish once the balance is back.
if [ -n "$done_at" ]; then
	for i in $(seq 1 12); do
		pending=$(cli $A pendingchannels | jq -r --arg c "$cp" \
			'[.pending_force_closing_channels[] | select(.channel.channel_point == $c)] | length')
		[ "$pending" = 0 ] && break
		mine_b2b 1 >/dev/null 2>&1 || true
		sleep 5
	done
fi
now=$(balance $A)
echo "  pending: ${pending:-?}  wallet: $before -> $now"
if [ "${pending:-0}" != 0 ]; then
	cli $A pendingchannels | jq -c --arg c "$cp" \
		'.pending_force_closing_channels[] | select(.channel.channel_point == $c) | {limbo_balance, recovered_balance, anchor}' | sed 's/^/  still listed as pending: /' || true
fi
record legacy_force_close swept "${done_at:-no}"

step "force close: verdict"
if [ -n "$done_at" ] && [ $((now - before)) -gt $((local_bal / 2)) ]; then
	echo "  swept by height $done_at"
	echo "PASS"
else
	echo "FAIL: A's balance from the close was not swept after the upgrade"
	cli $A pendingchannels | jq -c --arg c "$cp" \
		'.pending_force_closing_channels[] | select(.channel.channel_point == $c) | {limbo_balance, recovered_balance, maturity_height, blocks_til_maturity, anchor, pending_htlcs}' | sed 's/^/  still pending: /' || true
	docker logs $A 2>&1 | grep -iE "no contract resolutions|arbitrat|nursery|sweep" | tail -8 | sed 's/^/  /'
	exit 1
fi
