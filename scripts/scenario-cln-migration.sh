#!/usr/bin/env bash
# Upgrade path of the chain-identity series. Two Core Lightning nodes on the released build open an announced channel
# with Bitcoin's identity, then both move to the patched build on the same
# data: the restamp must be refused without --database-upgrade=true, happen
# with it, and the channel must reestablish and be announced again under
# the new identity, so that Lightning Fork (lf1) learns it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
N=lightning-fork-lab_lab
REL=${CLN_RELEASE_IMAGE:-cln-blake2b-release:lab}   # make cln-release
PATCHED=${CLN_IMAGE:-cln-blake2b:lab}               # make cln
common=(--network=regtest --lightning-dir=/data --bitcoin-rpcconnect=knots-b2b --bitcoin-rpcport=18443 --bitcoin-rpcuser=lab --bitcoin-rpcpassword=lab --bind-addr=0.0.0.0:9735 --log-level=debug --disable-plugin=cln-grpc --disable-plugin=clnrest --disable-plugin=cln-bip353)
c() { local n=$1; shift; docker exec "$n" lightning-cli --network=regtest --lightning-dir=/data "$@"; }
start() { local n=$1 img=$2; shift 2; docker run -d --name "$n" --network $N -v "$n-data:/data" "$img" "${common[@]}" --announce-addr="$n:9735" --alias="$n" "$@" >/dev/null; }
synced() { [ "$(c "$1" getinfo 2>/dev/null | jq -r .blockheight)" = "$(b2b getblockcount)" ]; }

for n in mig1 mig2; do docker rm -f $n >/dev/null 2>&1 || true; docker volume rm -f $n-data >/dev/null 2>&1 || true; done
step "migration: two released-build nodes"
start mig1 $REL; start mig2 $REL
mine_b2b 1
wait_for "mig1 synced" 120 synced mig1
wait_for "mig2 synced" 120 synced mig2
[ "$(c mig1 invoice 1000 x x | jq -r .bolt11 | cut -c1-6)" = lnbcrt ] || fail "released build should issue lnbcrt"
pass "released build up: $(c mig1 getinfo | jq -r .version), invoices lnbcrt"

step "migration: an announced channel between them under Bitcoin's identity"
ensure_b2b_funds 2
b2b -rpcwallet=lab sendtoaddress "$(c mig1 newaddr | jq -r .bech32)" 1 >/dev/null
mine_b2b 6
wait_for "mig1 funded" 60 sh -c "[ \"\$(docker exec mig1 lightning-cli --network=regtest --lightning-dir=/data listfunds | jq '[.outputs[] | select(.status == \"confirmed\")] | length')\" != 0 ]"
mig2_pub=$(c mig2 getinfo | jq -r .id); mig1_pub=$(c mig1 getinfo | jq -r .id)
c mig1 connect "$mig2_pub@mig2:9735" >/dev/null
c mig1 fundchannel "$mig2_pub" 500000 normal true >/dev/null
mine_b2b 6
wait_for "channel normal" 120 sh -c "[ \"\$(docker exec mig1 lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
mine_b2b 6
wait_for "channel announced on mig2's graph" 120 sh -c "[ \"\$(docker exec mig2 lightning-cli --network=regtest --lightning-dir=/data listchannels | jq '.channels | length')\" -ge 1 ]"
scid=$(c mig1 listpeerchannels | jq -r '.channels[0].short_channel_id')
pass "channel $scid announced under the old identity"

step "migration: the patched build refuses to restamp without --database-upgrade=true"
docker rm -f mig1 mig2 >/dev/null
start mig1 $PATCHED
sleep 15
docker logs mig1 2>&1 | grep -q "Start once with --database-upgrade=true" || fail "no refusal message"
[ "$(docker inspect -f '{{.State.Running}}' mig1)" = false ] || fail "mig1 kept running"
pass "refused with the message, and stopped"

step "migration: with the flag, both restamp, reestablish and announce again"
docker rm -f mig1 >/dev/null
start mig1 $PATCHED --database-upgrade=true
start mig2 $PATCHED --database-upgrade=true
for n in mig1 mig2; do
	wait_for "$n restamps" 90 sh -c "docker logs $n 2>&1 | grep -q \"adopting this chain's chain_hash\""
	wait_for "$n removes its gossip store" 30 sh -c "docker logs $n 2>&1 | grep -q 'Removed .*gossip_store'"
done
wait_for "mig1 synced" 120 synced mig1
wait_for "mig2 synced" 120 synced mig2
[ "$(c mig1 invoice 1000 y y | jq -r .bolt11 | cut -c1-9)" = lnblakert ] || fail "patched build should issue lnblakert"
pass "both restamped, gossip stores removed, invoices lnblakert"
c mig1 connect "$mig2_pub@mig2:9735" >/dev/null 2>&1 || true
wait_for "channel reestablished" 120 sh -c "[ \"\$(docker exec mig1 lightning-cli --network=regtest --lightning-dir=/data listpeerchannels | jq -r '.channels[0].state')\" = CHANNELD_NORMAL ]"
# A fresh node on the patched build can only accept the channel under the
# new chain_hash; Lightning Fork could not talk to the old identity at all.
docker rm -f mig3 >/dev/null 2>&1 || true; docker volume rm -f mig3-data >/dev/null 2>&1 || true
start mig3 $PATCHED
wait_for "mig3 synced" 120 synced mig3
c mig3 connect "$mig1_pub@mig1:9735" >/dev/null
wait_for "a fresh patched node learns the channel" 180 sh -c "[ \"\$(docker exec mig3 lightning-cli --network=regtest --lightning-dir=/data listchannels | jq '[.channels[] | select(.short_channel_id == \"$scid\")] | length')\" -ge 1 ]"
pass "fresh patched node sees $scid under the new identity"
# lnd asks a peer for its whole channel range only on its startup sync, so
# lf1 is restarted and pointed at mig1.
$COMPOSE restart lf1 >/dev/null 2>&1
sleep 25
lf1 connect "$mig1_pub@mig1:9735" >/dev/null 2>&1 || true
wait_for "lf1's graph has the migrated channel" 180 sh -c "$COMPOSE exec -T lf1 lncli --network=regtest --rpcserver=127.0.0.1:10009 describegraph | jq -e '.edges[] | select(.node1_pub == \"$mig1_pub\" or .node2_pub == \"$mig1_pub\")' >/dev/null"
pass "lf1 sees channel $scid between mig1 and mig2 after the migration"
docker rm -f mig1 mig2 mig3 >/dev/null; docker volume rm -f mig1-data mig2-data mig3-data >/dev/null
echo "MIGRATION PASSED"
