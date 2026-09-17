#!/usr/bin/env bash
# Does the gossip height rule actually drop a channel funded before the proof
# of work changed?
#
# The rule is unit tested, and a unit test cannot tell you whether the value
# is wired to anything. This funds a channel, then starts a node whose
# activation height is above that channel's funding height, and asks whether
# the channel ever reaches its graph.
#
# Mirrors what privkeyio did on their side, by setting the threshold rather
# than by rewinding a chain: the rule cares about the short_channel_id's
# height, so moving the threshold up is the same experiment as funding
# something older.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
NODE=lf-gossip-probe

docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true

step "gossip: a channel between lf1 and lf2"
lf2_pub=$(pubkey_of lf2)
lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
lf1 openchannel --node_key "$lf2_pub" --local_amt 1000000 >/dev/null 2>&1 || true
mine_b2b 6 >/dev/null 2>&1

scid=""
for i in $(seq 1 24); do
	# scid, not chan_id: chan_id here is the 32 byte channel id, and the
	# funding height lives in the short channel id.
	scid=$(lf1 listchannels | jq -r \
		".channels[] | select(.remote_pubkey == \"$lf2_pub\" and .active) | .scid" | head -1)
	[ -n "$scid" ] && [ "$scid" != null ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 8
done
[ -n "$scid" ] && [ "$scid" != null ] || { echo "FAIL: no active channel"; exit 1; }

# The funding height is the top 24 bits of the short channel id.
fund_height=$(( scid >> 40 ))
echo "  channel        : $scid"
echo "  funded at      : $fund_height"
record gossip fund_height "$fund_height"

# Above the channel, and low enough to be a real BLAKE2b block so the chain
# identity check at startup still passes.
threshold=$(( fund_height + 1 ))
echo "  probe threshold: $threshold (so the channel is 'before the change')"

step "gossip: a node that considers that channel too old"
docker run -d --name $NODE --network "$N" -v "$NODE-data:/root/.lnd" \
	lightning-fork:dev \
	--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
	--bitcoin.blake2b-activation-height=$threshold \
	--fee.url=http://fees:8080/fees.json \
	--bitcoind.rpchost=knots-b2b:18443 \
	--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
	--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
	--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
	--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
	--externalip=$NODE:9735 --tlsextradomain=$NODE --alias=$NODE \
	--debuglevel=info,DISC=debug >/dev/null

probe() { docker exec $NODE lncli --network=regtest --rpcserver=127.0.0.1:10009 "$@"; }
wait_for "$NODE up" 180 sh -c \
	"docker exec $NODE lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo >/dev/null 2>&1"

step "gossip: give it the announcement and see whether it keeps it"
# Waited for rather than fired and forgotten. The first version connected
# with errors discarded, and the probe was still syncing: it ended with no
# peers, no announcement and an empty graph, which looks exactly like the rule
# working and proves nothing at all.
peered=no
for i in $(seq 1 30); do
	probe connect "$(pubkey_of lf1)@lf1:9735" >/dev/null 2>&1 || true
	probe connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
	n=$(probe listpeers 2>/dev/null | jq '.peers | length')
	if [ "${n:-0}" -gt 0 ]; then
		peered=yes
		break
	fi
	sleep 10
done
echo "  probe peers    : $peered"
record gossip peered "$peered"
[ "$peered" = yes ] || { echo "FAIL: the probe never peered, so it was never"
	echo "offered the announcement and this run says nothing"; exit 1; }
mine_b2b 3 >/dev/null 2>&1

seen=absent
for i in $(seq 1 18); do
	n=$(probe describegraph 2>/dev/null | jq "[.edges[] | select(.channel_id == \"$scid\" or (.channel_id|tostring) == \"$scid\")] | length")
	if [ "${n:-0}" -gt 0 ]; then
		seen=present
		break
	fi
	sleep 10
done

echo "  channel in the probe's graph: $seen"
record gossip channel_in_graph "$seen"

rejected=$(docker logs $NODE 2>&1 | grep -c "before the proof of work changed" || true)
echo "  rejections logged           : $rejected"
record gossip rejections "$rejected"

step "gossip: verdict"
# Absence alone is not evidence: a channel that never arrived is also absent.
# The run only means something if the rule is on the record as having refused
# this channel by name.
if [ "$seen" = absent ] && [ "$rejected" -gt 0 ]; then
	echo "  The channel is funded at $fund_height, the probe's threshold is"
	echo "  $threshold, and the probe refused the announcement by that rule"
	echo "  and never took the channel into its graph."
	echo "PASS"
else
	echo "  seen=$seen rejections=$rejected"
	echo "  Expected the channel to be absent and the rule to have logged."
	echo "FAIL"
	exit 1
fi
