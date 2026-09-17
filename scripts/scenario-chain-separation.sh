#!/usr/bin/env bash
# What keeps this node off the chain that did not upgrade?
#
# Until the chain_hash reversal the answer was chain_hash: the two chains
# advertised different ones, and a peer on the other chain was refused on the
# init networks list. chain_hash is now the genesis hash both chains share, so
# that answer is gone. Nothing in init distinguishes them on its own, and the
# question is worth asking again rather than assumed.
#
# The answer is option_blake2b as an *even* bit, 68. BOLT 9 obliges a peer that
# does not know an even bit to close the connection, so a node that has not
# been updated for this chain hangs up by itself, without knowing why and
# without this node having to decide anything. That is the mechanism the spec
# PR at lightning-blake2b/bolts#1 writes down, and privkeyio's build already
# sets the same bit.
#
# This daemon sent the *odd* bit until the reversal, on the reasoning that
# chain_hash was the real check and the bit was a courtesy. An odd bit is
# ignored by a peer that cannot read it, which is exactly the peer that needs
# to go away, so after the reversal the separation had quietly fallen back to
# RequirePeerNetworks: drop any peer whose init carries no networks TLV.
# That is a heuristic, sending the field is optional, and privkeyio's reviewer
# had already objected that it drops every cln-application dashboard.
#
# So the run has to show two things, not one: that the other side refuses, and
# that it refuses *without* this node's heuristic being involved. Hence
# lf-lenient, which is told to keep peers that send no networks.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
LENIENT=lf-lenient

step "separation: which bit does this node advertise"
bits=$(lf1 getinfo | jq -r '.features | keys[] as $k
	| select(($k|tonumber) >= 68 and ($k|tonumber) <= 69) | $k' | tr '\n' ' ')
echo "  bits 68/69 in init: [${bits% }]"
record separation bits "${bits% }"
echo "$bits" | grep -q 68 || fail "bit 68 is not set. An odd bit cannot separate
the chains: a peer that cannot read it ignores it, which is the peer this is
supposed to disconnect."
echo "$bits" | grep -q 69 && fail "bit 69 is set as well as 68; BOLT 9 gives
the pair one meaning between them and a peer reading both cannot tell which
was meant"
pass "bit 68 only, which is what BOLT 9 requires of it"

step "separation: a stock lnd on the SHA256d chain, connecting to this node"
# The connection is made from their side deliberately. What is being tested is
# that they refuse us, not that we refuse them: a separation that depends on
# this node choosing to enforce it is not symmetric, and the chain that did not
# upgrade has no reason to cooperate.
lf1_pub=$(pubkey_of lf1)
lncli_on lnd-sha connect "$lf1_pub@lf1:9735" >/dev/null 2>&1 || true
sleep 8
n=$(lncli_on lnd-sha listpeers 2>/dev/null \
	| jq --arg p "$lf1_pub" '[.peers[] | select(.pub_key == $p)] | length')
echo "  stock lnd peered with lf1: $n"
record separation stock_lnd_peered "$n"
[ "${n:-0}" = 0 ] || fail "a node on the SHA256d chain is peered with this one"

why=$($COMPOSE logs --no-color --tail 300 lnd-sha 2>/dev/null \
	| grep -oE "unknown required features: \[[0-9]+\]" | tail -1)
echo "  their reason: ${why:-(not found)}"
record separation stock_lnd_reason "${why:-none}"
[ "$why" = "unknown required features: [68]" ] ||
	fail "expected them to refuse on bit 68, got: ${why:-nothing}. If they
refused for another reason the bit is not what is separating the chains, and
whatever is doing it instead should be the thing under test."
pass "they hang up on their own, on bit 68, by BOLT 1's existing rule"

step "separation: and not because of this node's networks heuristic"
# RequirePeerNetworks would also drop that peer, so the run so far cannot tell
# the bit from the heuristic. Turn the heuristic off and try again.
docker rm -f $LENIENT >/dev/null 2>&1 || true
docker volume rm -f $LENIENT-data >/dev/null 2>&1 || true
docker run -d --name $LENIENT --network "$N" -v "$LENIENT-data:/root/.lnd" \
	lightning-fork:dev \
	--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
	--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
	--allow-peers-without-networks \
	--fee.url=http://fees:8080/fees.json \
	--bitcoind.rpchost=knots-b2b:18443 \
	--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
	--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
	--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
	--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
	--externalip=$LENIENT:9735 --tlsextradomain=$LENIENT --alias=$LENIENT \
	--debuglevel=info >/dev/null
wait_for "$LENIENT up" 180 sh -c \
	"docker exec $LENIENT lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo >/dev/null 2>&1"
len_pub=$(docker exec $LENIENT lncli --network=regtest \
	--rpcserver=127.0.0.1:10009 getinfo | jq -r .identity_pubkey)

lncli_on lnd-sha connect "$len_pub@$LENIENT:9735" >/dev/null 2>&1 || true
sleep 8
n2=$(lncli_on lnd-sha listpeers 2>/dev/null \
	| jq --arg p "$len_pub" '[.peers[] | select(.pub_key == $p)] | length')
echo "  stock lnd peered with a node that would have kept it: $n2"
record separation lenient_peered "$n2"
[ "${n2:-0}" = 0 ] || fail "with the heuristic off the two chains peered, so
bit 68 is not carrying the separation and RequirePeerNetworks was"

# Absence is not evidence. A connection that never reached init would also show
# no peer, and would show it for reasons that have nothing to do with the bit.
# Require their refusal of *this* node to be on the record by name.
why2=$($COMPOSE logs --no-color --tail 400 lnd-sha 2>/dev/null \
	| grep "$len_pub" | grep -oE "unknown required features: \[[0-9]+\]" | tail -1)
echo "  their reason: ${why2:-(not found)}"
record separation lenient_reason "${why2:-none}"
[ "$why2" = "unknown required features: [68]" ] ||
	fail "no bit 68 refusal logged against $len_pub, so this step says
nothing: the connection may never have reached init at all."
pass "still refused, on the bit, so the bit is doing the work and not the
      heuristic"

step "separation: the control, nodes that should still peer"
# A separation that also separates this chain from itself is not a separation.
lf2_pub=$(pubkey_of lf2)
lf1 connect "$lf2_pub@lf2:9735" >/dev/null 2>&1 || true
sleep 5
own=$(lf1 listpeers 2>/dev/null \
	| jq --arg p "$lf2_pub" '[.peers[] | select(.pub_key == $p)] | length')
echo "  lf1 peered with lf2: $own"
record separation own_chain_peered "$own"
[ "${own:-0}" -ge 1 ] || fail "two Lightning Fork nodes no longer peer"
pass "this chain still talks to itself"

step "separation: verdict"
cat <<EOF
  Bit 68, even, is what keeps the two chains apart at init now that chain_hash
  is shared. A node on the chain that did not upgrade hangs up on its own, by a
  BOLT 1 rule that predates all of this, and it does so even when this node is
  configured to be as permissive as it can be.

  That matters beyond tidiness: the alternative in place until now was to drop
  any peer that sent no networks TLV, which is optional to send, so the rule
  had false positives and no basis in the spec.

  Nodes on this chain are unaffected: lf1 and lf2 peer as before.
EOF
echo "PASS"
docker rm -f $LENIENT >/dev/null 2>&1 || true
docker volume rm -f $LENIENT-data >/dev/null 2>&1 || true
