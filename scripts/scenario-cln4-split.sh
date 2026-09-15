#!/usr/bin/env bash
# Can Lightning Fork and privkeyio v26.06.7-blake2b.4 reach each other?
#
# They are on the same chain. This asks whether they are on the same Lightning
# network, which is a different question and currently has a different answer.
#
# Two independent reasons they might not be, and the point of running it rather
# than reasoning about it is to find out whether both fire or only one:
#
#   chain_hash   Lightning Fork advertises the BLAKE2b chain_hash in the init
#                networks list. .4 keeps Bitcoin's, per the migration plan.
#                Neither list contains the other's value.
#
#   feature bit  .4 signals option_blake2b as compulsory bit 68 and says it
#                will not peer with a node that does not advertise it.
#                Lightning Fork sets no feature bit for this.
#
# Needs the .4 image:
#   R=v26.06.7-blake2b.4
#   T=clightning-$R-Ubuntu-24.04-amd64.tar.xz
#   gh release download $R --repo privkeyio/lightning -p "$T" -p "SHA256SUMS-$R" -D build
#   docker build -f Dockerfile.cln-release --build-arg CLN_TARBALL=$T -t cln-blake2b-4:lab .
set -euo pipefail
source "$(dirname "$0")/lib.sh"

N=$(docker network ls --format '{{.Name}}' | grep -m1 lightning-fork-lab)
IMG=cln-blake2b-4:lab
NODE=cln4

docker rm -f $NODE >/dev/null 2>&1 || true
docker volume rm -f $NODE-data >/dev/null 2>&1 || true

step "cln4-split: start v26.06.7-blake2b.4 on the same chain"
docker run -d --name $NODE --network "$N" -v "$NODE-data:/data" "$IMG" \
	--network=regtest --lightning-dir=/data \
	--bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 \
	--bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab \
	--bind-addr=0.0.0.0:9735 --announce-addr="$NODE:9735" --alias=$NODE \
	--log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest \
	--disable-plugin=cln-bip353 --database-upgrade=true >/dev/null

c4() { docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data "$@"; }
wait_for "$NODE up" 120 sh -c "docker exec $NODE lightning-cli --network=regtest --lightning-dir=/data getinfo >/dev/null 2>&1"
mine_b2b 2
ver=$(c4 getinfo | jq -r .version)
cln4_pub=$(c4 getinfo | jq -r .id)
pass "$NODE up: $ver"

step "cln4-split: what each side advertises"
# Lightning Fork's chain_hash, as it puts it in init.
lf1_pub=$(pubkey_of lf1)
echo "  Lightning Fork : $(lf1 getinfo | jq -r .version), node $lf1_pub"
echo "  privkeyio .4   : $ver, node $cln4_pub"
echo "  .4 invoice     : $(c4 invoice 1000 split-$RANDOM x 2>/dev/null | jq -r .bolt11 | cut -c1-8)..."
echo "  Fork invoice   : $(lf1 addinvoice --amt 1000 2>/dev/null | jq -r .payment_request | cut -c1-12)..."

step "cln4-split: try to peer, both directions"
c4 connect "$lf1_pub@lf1:9735" >/dev/null 2>&1 || true
lf1 connect "$cln4_pub@$NODE:9735" >/dev/null 2>&1 || true
sleep 5

peered_cln=$(c4 listpeers | jq "[.peers[] | select(.id == \"$lf1_pub\" and .connected)] | length")
peered_lf=$(lf1 listpeers | jq "[.peers[] | select(.pub_key == \"$cln4_pub\")] | length")

echo "  .4 sees Lightning Fork connected : $peered_cln"
echo "  Lightning Fork sees .4 connected : $peered_lf"

step "cln4-split: why"
echo "  --- what .4 said ---"
docker logs --since 60s $NODE 2>&1 | grep -iE "chain|network|feature|option_blake2b|68" | tail -6 || true
echo "  --- what Lightning Fork said ---"
$COMPOSE logs --since 60s lf1 2>&1 | grep -iE "no common chain|networks|feature|chain_hash" | tail -6 || true

step "cln4-split: verdict"
if [ "$peered_cln" = 0 ] && [ "$peered_lf" = 0 ]; then
	record cln4-split peered no
	cat <<EOF

  The two do not peer, in either direction.

  They are on the same chain, following the same blocks, and they cannot
  form a Lightning network with each other. Channels opened on one are
  invisible to the other. This is not a 2027 question, it is the state
  today, and it gets more expensive the longer both sides grow separately.
EOF
else
	record cln4-split peered yes
	echo
	echo "  They peered. That is a better answer than expected and the"
	echo "  argument about a split network needs revisiting before it is"
	echo "  made to anyone."
fi

echo
echo "  (leaving $NODE running for inspection; docker rm -f $NODE when done)"
