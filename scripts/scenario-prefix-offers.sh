#!/usr/bin/env bash
# Since chain_hash went back to the genesis hash both chains share, what is
# left that tells an invoice or an offer for one chain from one for the other?
#
# Two answers, and they are not the same answer.
#
#   BOLT 11  The invoice prefix does it, in both directions. This node refuses
#            a SHA256d invoice and says why; an unmodified node on the other
#            chain refuses ours and cannot say why, which is the compatibility
#            argument rather than a seniority one.
#
#   BOLT 12  Nothing does it. An offer names a chain by chain_hash, both chains
#            now use the same one, and so an offer minted on either chain is
#            "for this chain" on both. Demonstrated here rather than argued,
#            by running a BOLT 12 node on each chain and having each decode the
#            other's offer.
#
# The BOLT 12 half is the reason the reply draft asks for offer_chains to name
# the activation block. Nothing in this scenario proposes that; it establishes
# that the gap is real, which is the part that has to be true first.
#
# A note on regtest and the spec default. BOLT 12 says an absent offer_chains
# means Bitcoin mainnet, so on regtest both implementations write the field out
# and the two values are equal. On mainnet both would omit it and both would
# default to the same chain. The ambiguity is identical; only where it is
# written down differs.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib.sh

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
# blake2b-unified with nothing applied. It has BOLT 12, and stock lnd on the
# SHA256d side does not, so it is the only way to get an offer minted on that
# chain at all. It runs against a SHA256d backend without complaint, which is
# its own small result and the subject of scenario-restamp.sh.
NODE=cln-sha-offers
IMG=${CLN_IMAGE:-cln-vanilla:lab}

shacli() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }

step "prefix: an invoice from the SHA256d chain, offered to this node"
sha_inv=$(lncli_on lnd-sha addinvoice --amt 1000 2>/dev/null | jq -r .payment_request)
[ -n "$sha_inv" ] && [ "$sha_inv" != null ] || fail "lnd-sha issued no invoice"
echo "  ${sha_inv:0:26}..."
[[ "$sha_inv" == lnbcrt* ]] || fail "expected an lnbcrt invoice, got ${sha_inv:0:12}"

if out=$(lf1 decodepayreq --pay_req "$sha_inv" 2>&1); then
	fail "this node decoded a SHA256d invoice: $out"
fi
echo "  refused: $(echo "$out" | tail -1)"
record prefix sha_invoice_refused yes
echo "$out" | grep -qi "prefix" || fail "the refusal does not name the prefix"
pass "refused by prefix, naming both chains and what it expected"

step "prefix: an invoice from this chain, offered to an unmodified node"
b2b_inv=$(lf1 addinvoice --amt 1000 2>/dev/null | jq -r .payment_request)
[ -n "$b2b_inv" ] && [ "$b2b_inv" != null ] || fail "lf1 issued no invoice"
echo "  ${b2b_inv:0:26}..."
[[ "$b2b_inv" == lnblakert* ]] || fail "expected an lnblakert invoice, got ${b2b_inv:0:12}"

if out=$(lncli_on lnd-sha decodepayreq --pay_req "$b2b_inv" 2>&1); then
	fail "stock lnd decoded a BLAKE2b invoice: $out"
fi
echo "  refused: $(echo "$out" | tail -1)"
record prefix b2b_invoice_refused yes
# The point is not that the message is bad. It is that an unmodified node has
# nothing to say here, and never will, because it predates this chain. A
# shared prefix would replace this refusal with a payment.
echo "$out" | grep -qi "not for current active network" ||
	echo "  NOTE: the generic refusal was expected to mention the active network"
pass "refused, and unable to say which chain it was refusing"

step "offers: a BOLT 12 node on the SHA256d chain"
docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true
docker run -d --name $NODE --network "$N" -v "$NODE-data:/data" "$IMG" \
	--network=regtest --lightning-dir=/data \
	--bitcoin-rpcconnect=bitcoind-sha --bitcoin-rpcport=18443 \
	--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
	--bind-addr=0.0.0.0:9735 --alias=$NODE --log-level=debug \
	--disable-plugin=cln-grpc --disable-plugin=clnrest >/dev/null
wait_for "$NODE up" 180 sh -c \
	"docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
echo "  $(shacli getinfo | jq -r .version) at height $(shacli getinfo | jq -r .blockheight)"
echo "  SHA256d chain is at $(sha getblockcount)"

step "offers: an offer minted on the SHA256d chain, read by this node"
sha_offer=$(shacli offer any "sha-side-$RANDOM" 2>/dev/null | jq -r .bolt12)
[ -n "$sha_offer" ] && [ "$sha_offer" != null ] || fail "no offer from the SHA256d node"
echo "  ${sha_offer:0:30}..."

dec=$(lf1 offer decode "$sha_offer" 2>&1) ||
	fail "this node could not decode it at all: $dec"
mine=$(echo "$dec" | jq -r .for_this_chain)
chains=$(echo "$dec" | jq -c '.chains // "absent"')
echo "  this node says for_this_chain=$mine, chains=$chains"
record offers sha_offer_for_this_chain "$mine"

step "offers: an offer minted on this chain, read by the SHA256d node"
b2b_offer=$(lf1 offer create --description "b2b-side-$RANDOM" 2>/dev/null \
	| jq -r .offer.bolt12)
[ -n "$b2b_offer" ] && [ "$b2b_offer" != null ] || fail "no offer from lf1"
echo "  ${b2b_offer:0:30}..."

theirs=$(shacli decode "$b2b_offer" 2>&1)
valid=$(echo "$theirs" | jq -r .valid)
their_chains=$(echo "$theirs" | jq -c '.offer_chains // "absent"')
warn=$(echo "$theirs" | jq -r '.warning_unknown_offer_chains // "none"')
echo "  the SHA256d node says valid=$valid, offer_chains=$their_chains, warning=$warn"
record offers b2b_offer_valid_on_sha "$valid"

step "offers: verdict"
[ "$mine" = true ] || fail "expected this node to read the other chain's offer
as its own; if that has changed, the reply draft needs rewriting"
[ "$valid" = true ] || fail "expected the other chain's node to accept this
chain's offer; if that has changed, the reply draft needs rewriting"
[ "$chains" = "$their_chains" ] || fail "the two offers name different chains
($chains against $their_chains), which would mean the ambiguity is already gone"

cat <<EOF
  Each node minted an offer and read the other's. Both said the offer was for
  their chain, both named $chains, and neither warned.

  A payer therefore cannot tell from an offer which chain it is for, and the
  two chains share an address format and all their pre-fork history. For a
  merchant with channels on both, the invoice comes back and the payment
  settles on whichever chain the payer happened to be on.

  BOLT 11 does not have this problem: the prefix decides, in both directions,
  and the refusal above is what that looks like. The gap is BOLT 12's alone.
EOF
echo "PASS"
