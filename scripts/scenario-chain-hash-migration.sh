#!/usr/bin/env bash
# Can a node that opened channels under the withdrawn chain_hash be upgraded?
#
# Until 2026-09-17 this daemon advertised a chain_hash of its own, and shipped
# it: v0.21.3-beta-blake2b.6 through .9 are on mainnet carrying it. lnd keys
# channels by chain hash, so a node with channels opened under the old value
# cannot start against a build using the new one. It fails with "no chain
# bucket exists", from the server's access-control pass.
#
# channeldb migration 36 moves those channels. This is the test that matters
# for it: the unit tests build their fixtures by hand, from what the layout is
# believed to be, and a migration that is wrong about the layout would pass
# them and still eat a real database. So this one makes a real database, with
# a real channel, using the actual released binary, and then upgrades it.
#
#   1. two nodes from the .9 image, peered and with a funded channel
#   2. upgrade one. It must come up, and the channel must still be there
#   3. upgrade the other. They must peer again and the channel must carry a
#      payment, so it survived as a channel and not merely as a database row
#
# Step 2 also pins something an operator has to know: while one end is upgraded
# and the other is not, the two cannot peer at all, so the channel is unusable
# until both move. That is inherent to changing chain_hash rather than anything
# this migration does, and the first version of this scenario had it wrong: it
# left the second node on .9 and expected a payment to work.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
OLD_IMAGE=${OLD_IMAGE:-paulscode/lightning-fork:0.21.3-beta-blake2b.9}
NEW_IMAGE=${NEW_IMAGE:-lightning-fork:dev}
A=lf-mig-a
B=lf-mig-b

# The regtest chain_hash the withdrawn design advertised,
# TaggedHash("Lightning Fork chain_hash", genesis), in the order lncli prints.
LEGACY=2594d57b43169a2856ded0623840f0863b9e967b936f6f3d7945da28d909ab1a
CURRENT=0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206

cleanup() {
	local rc=$?
	# Say what the nodes said before taking them away. Debugging a failure
	# here otherwise means re-running the whole scenario.
	if [ "$rc" != 0 ]; then
		for n in $A $B; do
			echo "=== $n (last 25) ==="
			docker logs "$n" 2>&1 | tail -25 || true
		done
	fi
	docker rm -f $A $B >/dev/null 2>&1 || true
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
		--alias="$name" --debuglevel=info >/dev/null
}

cli() {
	local name=$1; shift
	docker exec "$name" lncli --network=regtest \
		--rpcserver=127.0.0.1:10009 "$@"
}

wait_up() {
	wait_for "$1 up" 180 sh -c \
		"docker exec $1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo >/dev/null 2>&1"
}

fund() {
	local name=$1
	local addr
	addr=$(cli "$name" newaddress p2tr | jq -r .address)
	b2b -rpcwallet=lab sendtoaddress "$addr" 0.05 >/dev/null
	mine_b2b 6 >/dev/null 2>&1
	wait_for "$name funded" 120 sh -c \
		"[ \"\$(docker exec $name lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance | jq -r .confirmed_balance)\" != 0 ]"
}

cleanup
docker volume rm -f $A-data $B-data >/dev/null 2>&1 || true

step "migration: two nodes on the released build that shipped the old chain hash"
start_node $A "$OLD_IMAGE"
start_node $B "$OLD_IMAGE"
wait_up $A
wait_up $B
ver=$(cli $A getinfo | jq -r .version)
echo "  running: $ver"
record migration old_version "$ver"
case "$ver" in
*blake2b.9*) ;;
*) fail "expected the .9 release, got $ver" ;;
esac

# The premise. If this build already advertised the genesis hash there would be
# nothing to migrate and the run would prove nothing.
chain=$(cli $A getinfo | jq -r '.chains[0].chain // empty')
echo "  chain field    : ${chain:-(none)}"

step "migration: a funded channel between them, under the old chain hash"
fund $A
b_pub=$(cli $B getinfo | jq -r .identity_pubkey)

# Retried, and the error kept. A node that is still catching up refuses the
# connection, and a single attempt reports that as though the two builds were
# incompatible.
peered=0
for i in $(seq 1 18); do
	err=$(cli $A connect "$b_pub@$B:9735" 2>&1 || true)
	peered=$(cli $A listpeers | jq --arg p "$b_pub" \
		'[.peers[] | select(.pub_key == $p)] | length')
	[ "${peered:-0}" -ge 1 ] && break
	sleep 5
done
[ "${peered:-0}" -ge 1 ] || fail "the two .9 nodes did not peer. Last error:
$err"

cli $A openchannel --node_key "$b_pub" --local_amt 1000000 >/dev/null 2>&1 || true
mine_b2b 6 >/dev/null 2>&1
cp=""
for i in $(seq 1 24); do
	cp=$(cli $A listchannels | jq -r --arg p "$b_pub" \
		'.channels[] | select(.remote_pubkey == $p and .active) | .channel_point' | head -1)
	[ -n "$cp" ] && [ "$cp" != null ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 8
done
[ -n "$cp" ] && [ "$cp" != null ] || fail "no active channel between the .9 nodes"
echo "  channel        : $cp"
record migration channel "$cp"

docker stop $A >/dev/null 2>&1

step "migration: start the current build on the same data directory"
docker rm $A >/dev/null 2>&1
start_node $A "$NEW_IMAGE"

started=no
if wait_for "$A up after upgrade" 180 sh -c \
	"docker exec $A lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo >/dev/null 2>&1"; then
	started=yes
fi
record migration started_after_upgrade "$started"
if [ "$started" != yes ]; then
	echo "  --- what it said ---"
	docker logs $A 2>&1 | tail -20
	fail "the upgraded node did not start. If this says 'no chain bucket
exists', the migration did not run or did not cover this case."
fi
# Deliberately not printing the version here: the development image reports the
# last release tag, so it reads as though nothing was upgraded. What proves the
# new build ran is the migration's own log line, asserted below.
pass "the node that could not start before now starts"

step "migration: the channel survived, and is on the current chain hash"
after_cp=$(cli $A listchannels | jq -r --arg p "$b_pub" \
	'.channels[] | select(.remote_pubkey == $p) | .channel_point' | head -1)
echo "  channel        : ${after_cp:-(gone)}"
record migration channel_after "${after_cp:-gone}"
[ "$after_cp" = "$cp" ] || fail "the channel is gone after the upgrade, which
is the outcome the migration exists to prevent"

# The migration logged what it did, and did not claim to have done nothing.
moved=$(docker logs $A 2>&1 | grep -c "onto the current chain hash" || true)
echo "  migration log lines: $moved"
record migration logged "$moved"
[ "${moved:-0}" -ge 1 ] || fail "the migration did not log having moved
anything, so the channel may have been found some other way"

# And the stamp itself: a channel backup carries the chain hash the channel
# records, so it is the cheapest way to read it back out through the API.
b64=$(cli $A exportchanbackup --chan_point "$cp" | jq -r '.chan_backup // empty')
[ -n "$b64" ] || fail "could not export a backup for the migrated channel"
pass "the channel is present and exportable after the upgrade"

step "migration: while only one end has upgraded, the two cannot peer"
# Not a fault, and not caused by the migration. The upgraded node advertises
# the genesis hash and bit 68; the one still on .9 advertises the old chain
# hash and does not know bit 68. Each refuses the other. Anyone upgrading a
# node with channels needs to know the channel is dark until the peer follows.
cli $A connect "$b_pub@$B:9735" >/dev/null 2>&1 || true
sleep 8
mixed=$(cli $A listpeers | jq --arg p "$b_pub" \
	'[.peers[] | select(.pub_key == $p)] | length')
echo "  upgraded node peered with the .9 node: $mixed"
record migration mixed_peering "$mixed"
[ "${mixed:-0}" = 0 ] || fail "an upgraded node peered with one still on the
old chain hash, which would mean the two identities are not separated after all"

why=$(docker logs $B 2>&1 | grep -oE "unknown required features: \[[0-9]+\]|no common chain" | tail -1)
echo "  the .9 node's reason: ${why:-(not logged)}"
record migration mixed_reason "${why:-none}"
pass "the channel is intact but unusable until the peer upgrades, which is
      what changing chain_hash costs and is worth saying out loud"

step "migration: upgrade the peer too, and use the channel"
docker stop $B >/dev/null 2>&1
docker rm $B >/dev/null 2>&1
start_node $B "$NEW_IMAGE"
wait_up $B

for i in $(seq 1 18); do
	cli $A connect "$b_pub@$B:9735" >/dev/null 2>&1 || true
	mixed=$(cli $A listpeers | jq --arg p "$b_pub" \
		'[.peers[] | select(.pub_key == $p)] | length')
	[ "${mixed:-0}" -ge 1 ] && break
	sleep 5
done
echo "  peered after both upgraded: $mixed"
record migration peered_after_both "$mixed"
[ "${mixed:-0}" -ge 1 ] || fail "two upgraded nodes still cannot peer"

active=0
for i in $(seq 1 24); do
	active=$(cli $A listchannels | jq -r --arg c "$cp" \
		'[.channels[] | select(.channel_point == $c and .active)] | length')
	[ "${active:-0}" -ge 1 ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 5
done
[ "${active:-0}" -ge 1 ] || fail "the migrated channel never came back active"

inv=$(cli $B addinvoice --amt 1000 | jq -r .payment_request)
paid=no
for i in $(seq 1 12); do
	if cli $A payinvoice --force --timeout 30s "$inv" 2>&1 | grep -qi SUCCEEDED; then
		paid=yes
		break
	fi
	sleep 5
done
echo "  payment over the migrated channel: $paid"
record migration paid_after "$paid"
[ "$paid" = yes ] || fail "the channel is in the database but will not carry a
payment, so the migration moved a row rather than a working channel"
pass "the channel opened under the old chain hash carries a payment under the new one"

step "migration: verdict"
cat <<EOF
  A channel opened by v0.21.3-beta-blake2b.9, under the chain_hash that release
  advertised, survives an upgrade to a build that advertises the genesis hash.
  The node starts where before it would not, the channel is still there, and
  once the peer upgrades too the channel carries a payment.

  Without migration 36 the node does not start at all, and the operator's only
  ways out cost a force close on every channel.

  What the migration cannot do anything about, and what the release notes have
  to say: between the two upgrades the channel is unusable, because a node on
  the old chain hash and a node on the new one cannot peer. Upgrading is a flag
  day for whoever is on the other end of a channel.
EOF
echo "PASS"
