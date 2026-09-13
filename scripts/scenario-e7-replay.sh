#!/usr/bin/env bash
# E7: everything Lightning Fork signs alone carries SIGHASH_UNIFIED (0x20 in
# the hash type byte), which the BLAKE2b regtest accepts and no chain without
# the fork would. A wallet send, and a PSBT funded and finalized by the
# wallet, both confirm with the bit on every input.
source "$(dirname "$0")/lib.sh"

# witness_opts_in TXID: every input's first witness element (the signature)
# ends in a hash type byte with 0x20 set. Prints the bytes it saw.
witness_opts_in() {
    local txid=$1
    local sigs; sigs=$(b2b getrawtransaction "$txid" true | jq -r '.vin[].txinwitness[0]')
    [ -n "$sigs" ] || fail "$txid has no witness"
    local sig last
    for sig in $sigs; do
        last=$(( 16#${sig: -2} ))
        [ $(( last & 0x20 )) -ne 0 ] || fail "$txid: signature ends in hash type 0x$(printf %02x $last), not opted in"
        printf '0x%02x ' "$last"
    done
}

# The wallet backend calls a tip older than two hours "not current", so a
# stack left idle since the last run needs a fresh block before the nodes
# report synced.
mine_b2b 1
wait_for "lf1 synced" 120 lnd_synced lf1

step "E7: a wallet send opts in"
fund_lf lf1 1
addr=$(lf1 newaddress p2wkh | jq -r .address)
txid=$(lf1 sendcoins --addr="$addr" --amt=200000 --sat_per_vbyte=2 --force | jq -r .txid)
wait_for "send in the mempool" 30 sh -c "$COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawtransaction $txid >/dev/null 2>&1"
bytes=$(witness_opts_in "$txid")
mine_b2b 1
conf=$(b2b getrawtransaction "$txid" true | jq -r .confirmations)
[ "$conf" -ge 1 ] || fail "send $txid did not confirm"
pass "wallet send $txid confirmed with hash type byte(s) $bytes"

step "E7: a taproot input opts in too (65-byte signature)"
addr=$(lf1 newaddress p2tr | jq -r .address)
txid=$(lf1 sendcoins --addr="$addr" --amt=150000 --sat_per_vbyte=2 --force | jq -r .txid)
mine_b2b 1
# Spend the taproot output we just made: send everything it can reach.
txid2=$(lf1 sendcoins --addr="$(lf1 newaddress p2wkh | jq -r .address)" --amt=100000 --sat_per_vbyte=2 --force | jq -r .txid)
wait_for "taproot spend in the mempool" 30 sh -c "$COMPOSE exec -T knots-b2b bitcoin-cli -datadir=/data -rpcuser=lab -rpcpassword=lab getrawtransaction $txid2 >/dev/null 2>&1"
bytes=$(witness_opts_in "$txid2")
sigs=$(b2b getrawtransaction "$txid2" true | jq -r '.vin[].txinwitness[0]')
for sig in $sigs; do
    [ ${#sig} -eq 130 ] && pass "a 65-byte Schnorr signature carries the byte: ${sig: -2}"
done
mine_b2b 1
[ "$(b2b getrawtransaction "$txid2" true | jq -r .confirmations)" -ge 1 ] || fail "$txid2 did not confirm"
pass "taproot-funded send $txid2 confirmed with $bytes"

step "E7: a PSBT the wallet funds and finalizes opts in"
dest=$(lf1 newaddress p2wkh | jq -r .address)
funded=$(lf1 wallet psbt fund --outputs="{\"$dest\":120000}" --sat_per_vbyte=2)
psbt=$(echo "$funded" | jq -r .psbt)
# The inputs the wallet added were stamped with the opt-in hash type.
decoded=$(echo "$psbt" | base64 -d | xxd -p | tr -d '\n')
finalized=$(lf1 wallet psbt finalize "$psbt")
rawtx=$(echo "$finalized" | jq -r .final_tx)
txid3=$(b2b sendrawtransaction "$rawtx")
bytes=$(witness_opts_in "$txid3")
mine_b2b 1
[ "$(b2b getrawtransaction "$txid3" true | jq -r .confirmations)" -ge 1 ] || fail "$txid3 did not confirm"
pass "wallet-funded PSBT $txid3 confirmed with hash type byte(s) $bytes"

step "E7: a PSBT carrying a legacy signature is refused at finalization"
# Fund a fresh PSBT and stamp the first input with SIGHASH_ALL, as an external
# signer that did not opt in would leave it; finalization must refuse.
funded=$(lf1 wallet psbt fund --outputs="{\"$dest\":110000}" --sat_per_vbyte=2)
psbt=$(echo "$funded" | jq -r .psbt)
python3 - "$psbt" > /tmp/e7-legacy.psbt <<'PY'
import base64, sys
raw = bytearray(base64.b64decode(sys.argv[1]))
# PSBT_IN_SIGHASH_TYPE is key type 0x03 with a 4-byte LE value; the first
# input map follows the global map's 0x00 separator.
i = raw.index(b"\x00", 5)  # end of the global map
i += 1
# walk the first input map replacing the sighash record if present
j = i
found = False
while raw[j] != 0:
    klen = raw[j]; key = raw[j+1:j+1+klen]; j += 1 + klen
    vlen = raw[j]; j += 1
    if key[:1] == b"\x03":
        raw[j:j+4] = (1).to_bytes(4, "little"); found = True
    j += vlen
if not found:
    raise SystemExit("no sighash record in the first input; the wallet did not stamp it")
print(base64.b64encode(bytes(raw)).decode())
PY
legacy=$(cat /tmp/e7-legacy.psbt)
if out=$(lf1 wallet psbt finalize "$legacy" 2>&1); then
    fail "a PSBT with a legacy hash type was finalized: $out"
fi
echo "$out" | grep -q "opt into the unified signature hash" || fail "unexpected refusal: $out"
pass "finalization refused the legacy hash type: $(echo "$out" | grep -o 'input 0 declares[^;]*' | head -1)"
# Release the leased inputs so later scenarios can use them.
lf1 wallet releaseoutput --lock_id="$(echo "$funded" | jq -r '.locked_utxos[0].id')" --outpoint="$(echo "$funded" | jq -r '.locked_utxos[0].outpoint.txid_str'):$(echo "$funded" | jq -r '.locked_utxos[0].outpoint.output_index')" >/dev/null 2>&1 || true

record e7-replay result PASS
echo "E7 PASSED"
