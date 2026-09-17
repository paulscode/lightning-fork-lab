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

# Wait for evidence either way rather than for a fixed time and then looking
# once. A first run polled the graph for three minutes, found the channel
# absent, grepped the log immediately and recorded no rejection; the rejection
# was logged three minutes after that. Absence had simply arrived before the
# announcement did, which is the same false pass the peering loop above guards
# against, one step later. So the rejection is polled too, and the run ends as
# soon as either the channel shows up or the rule speaks.
seen=absent
rejected=0
for i in $(seq 1 60); do
	n=$(probe describegraph 2>/dev/null | jq "[.edges[] | select(.channel_id == \"$scid\" or (.channel_id|tostring) == \"$scid\")] | length")
	if [ "${n:-0}" -gt 0 ]; then
		seen=present
		break
	fi
	rejected=$(docker logs $NODE 2>&1 | grep -c "short_chan_id=$scid: funded at height" || true)
	[ "$rejected" -gt 0 ] && break
	sleep 10
done

echo "  channel in the probe's graph: $seen"
record gossip channel_in_graph "$seen"

echo "  rejections logged           : $rejected"
record gossip rejections "$rejected"

step "gossip: the control, a channel the same probe must accept"
# The rejection above says the rule fired. It does not say the rule is what
# decided the outcome: a probe that cannot learn any channel would also show an
# empty graph, and a threshold high enough to refuse everything would look
# identical to one set correctly. So fund a second channel above the threshold,
# on the same node in the same run, and require this probe to take it.
#
# Either side of the threshold, one node, one run. That is what makes the
# absence above mean something.
lf1 openchannel --node_key "$lf2_pub" --local_amt 1000000 >/dev/null 2>&1 || true
mine_b2b 6 >/dev/null 2>&1

ctrl=""
for i in $(seq 1 30); do
	for s in $(lf1 listchannels | jq -r \
		".channels[] | select(.remote_pubkey == \"$lf2_pub\" and .active) | .scid"); do
		[ "$s" = null ] && continue
		if [ "$(( s >> 40 ))" -ge "$threshold" ]; then ctrl=$s; break; fi
	done
	[ -n "$ctrl" ] && break
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 8
done
[ -n "$ctrl" ] || fail "could not fund a channel above the threshold, so the
control cannot run and the refusal above stands alone"

echo "  control channel: $ctrl (funded at $(( ctrl >> 40 )), threshold $threshold)"
record gossip control_scid "$ctrl"

ctrl_seen=absent
for i in $(seq 1 60); do
	n=$(probe describegraph 2>/dev/null | jq "[.edges[] | select(.channel_id == \"$ctrl\" or (.channel_id|tostring) == \"$ctrl\")] | length")
	if [ "${n:-0}" -gt 0 ]; then
		ctrl_seen=present
		break
	fi
	mine_b2b 1 >/dev/null 2>&1 || true
	sleep 10
done
echo "  control in the probe's graph: $ctrl_seen"
record gossip control_in_graph "$ctrl_seen"

step "gossip: verdict"
# Absence alone is not evidence: a channel that never arrived is also absent.
# The run only means something if the rule is on the record as having refused
# this channel by name, and if the same probe kept a channel on the other side
# of the threshold.
if [ "$seen" = absent ] && [ "$rejected" -gt 0 ] && [ "$ctrl_seen" = present ]; then
	echo "  Funded at $fund_height, below the probe's threshold of $threshold:"
	echo "  refused by that rule, by name, and absent from the graph."
	echo "  Funded at $(( ctrl >> 40 )), above it: present in the same graph."
	echo "  One probe, one run, the threshold the only difference."
	echo "PASS"
else
	echo "  seen=$seen rejections=$rejected control=$ctrl_seen"
	echo "  Expected the old channel absent with the rule logged, and the"
	echo "  control channel present."
	echo "FAIL"
	exit 1
fi
