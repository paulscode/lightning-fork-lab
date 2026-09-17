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
# RequirePeerNetworks: drop any peer whose init carries no networks TLV. That
# is a heuristic standing in for a mechanism, sending the field is optional in
# BOLT 1, and privkeyio's reviewer had already objected that it drops every
# cln-application dashboard.
#
# With bit 68 doing the job, that heuristic is off by default. So the run has
# to show two things, not one: that the other side refuses, and that nothing
# on this side refused them, because there is no longer anything on this side
# that would.
#
# Note which direction the refusal runs. This node does not refuse them: it
# sets bit 68 but does not require a peer to set it, which is what privkeyio
# settled on too after requiring it broke clients. The separation works
# because *they* hang up on *us*, which is what makes it need no cooperation.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
STRICT=lf-strict

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
# Needed by the next step, which greps this node's log for a refusal against
# them by name. An undefined variable there made the grep match nothing and the
# step pass without testing anything.
sha_pub=$(lncli_on lnd-sha getinfo 2>/dev/null | jq -r .identity_pubkey)
[ -n "$sha_pub" ] && [ "$sha_pub" != null ] || fail "could not read lnd-sha's
pubkey, so the checks below would match nothing and pass regardless"
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

step "separation: and nothing on this side refused them"
# RequirePeerNetworks would have refused that peer too, so a run that only
# checked "no peer" could not tell the bit from the heuristic. The heuristic is
# now off by default, which is checkable: this node must not have logged a
# networks refusal against them.
ours=$($COMPOSE logs --no-color --tail 400 lf1 2>/dev/null \
	| grep -F "$sha_pub" | grep -c "did not advertise the chains it serves" || true)

# The step only means something if this node saw them at all. Otherwise "no
# refusal logged" is just "no log lines", which is what an unbound pattern
# produced before.
saw=$($COMPOSE logs --no-color --tail 400 lf1 2>/dev/null | grep -cF "$sha_pub" || true)
echo "  log lines mentioning them: $saw"
[ "${saw:-0}" -ge 1 ] || fail "this node has no log lines about them at all, so
it never saw the connection and this step says nothing"
echo "  networks refusals logged by this node: $ours"
record separation own_networks_refusals "$ours"
[ "${ours:-0}" = 0 ] || fail "this node refused them on the networks list, so
the run cannot tell bit 68 from the heuristic, and the heuristic was supposed
to be off by default"
pass "the heuristic did not fire, so the bit is what separated them"

step "separation: the heuristic still exists for an operator who wants it"
# Off by default is not the same as gone. A node started with
# --require-peer-networks must still refuse a silent peer, and showing that it
# does is also what shows the default is genuinely different.
docker rm -f $STRICT >/dev/null 2>&1 || true
docker volume rm -f $STRICT-data >/dev/null 2>&1 || true
docker run -d --name $STRICT --network "$N" -v "$STRICT-data:/root/.lnd" \
	lightning-fork:dev \
	--noseedbackup --bitcoin.regtest --bitcoin.node=bitcoind \
	--bitcoin.blake2b-activation-height="${ACTIVATION_HEIGHT:-20}" \
	--require-peer-networks \
	--fee.url=http://fees:8080/fees.json \
	--bitcoind.rpchost=knots-b2b:18443 \
	--bitcoind.rpcuser=lab --bitcoind.rpcpass=lab \
	--bitcoind.zmqpubrawblock=tcp://knots-b2b:28332 \
	--bitcoind.zmqpubrawtx=tcp://knots-b2b:28333 \
	--rpclisten=0.0.0.0:10009 --listen=0.0.0.0:9735 \
	--externalip=$STRICT:9735 --tlsextradomain=$STRICT --alias=$STRICT \
	--debuglevel=info >/dev/null
wait_for "$STRICT up" 180 sh -c \
	"docker exec $STRICT lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo >/dev/null 2>&1"
strict_pub=$(docker exec $STRICT lncli --network=regtest \
	--rpcserver=127.0.0.1:10009 getinfo | jq -r .identity_pubkey)

lncli_on lnd-sha connect "$strict_pub@$STRICT:9735" >/dev/null 2>&1 || true
sleep 10
strict_refusals=$(docker logs $STRICT 2>&1 \
	| grep -c "did not advertise the chains it serves" || true)
echo "  networks refusals logged by the strict node: $strict_refusals"
record separation strict_networks_refusals "$strict_refusals"
[ "${strict_refusals:-0}" -ge 1 ] || fail "--require-peer-networks did not
refuse a peer that sends no networks list, so either the option is not wired
up or the peer never reached init"
pass "the option still works, and the default is genuinely the other way"

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
  BOLT 1 rule that predates all of this, and this node did not refuse it: it
  sets the bit without requiring a peer to set it, so the separation needs no
  cooperation from either side.

  The rule that used to do this job, dropping any peer that sent no networks
  TLV, is off by default now. Sending that TLV is optional, so it dropped
  anything that simply omitted an optional field. It is still available as
  --require-peer-networks and still works, which is the step above.

  Nodes on this chain are unaffected: lf1 and lf2 peer as before.
EOF
echo "PASS"
docker rm -f $STRICT >/dev/null 2>&1 || true
docker volume rm -f $STRICT-data >/dev/null 2>&1 || true
