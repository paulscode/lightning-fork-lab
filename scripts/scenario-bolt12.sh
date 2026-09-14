#!/usr/bin/env bash
# BOLT 12 between two Lightning Fork nodes: lf1 mints a payout-style offer,
# lf2 fetches and pays an invoice for it over onion messages, and the same
# the other way round. Needs an active lf1<->lf2 channel (bolt12-setup.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bash "$(dirname "$0")/bolt12-setup.sh"

json_field() { # json_field <field> reads stdin, prints the first value.
	grep -m1 "\"$1\"" | sed 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/'
}

step "bolt12: lf1 mints a payout offer with a blinded path"
offer_json=$(lf1 offer create --description "OCEAN Payouts for bcrt1qminer" --with_paths)
lno=$(echo "$offer_json" | json_field bolt12)
paths=$(echo "$offer_json" | json_field num_paths)
[[ "$lno" == lno1* ]] || fail "offer prefix wrong: $lno"
[ "$paths" = 1 ] || fail "expected one blinded path, got $paths"
pass "offer minted: ${lno:0:24}... with $paths path"

step "bolt12: lf2 decodes it as for this chain and not its own"
dec=$(lf2 offer decode "$lno")
[ "$(echo "$dec" | json_field for_this_chain)" = true ] || fail "not for this chain"
[ "$(echo "$dec" | json_field ours)" = false ] || fail "lf2 thinks the offer is its own"
pass "decoded"

step "bolt12: lf2 fetches an invoice for 123000 msat"
inv_json=$(lf2 offer fetchinvoice "$lno" --amount_msat 123000 --payer_note "block 1")
lni=$(echo "$inv_json" | json_field bolt12)
[[ "$lni" == lni1* ]] || fail "invoice prefix wrong: $lni"
[ "$(echo "$inv_json" | json_field amount_msat)" = 123000 ] || fail "invoice amount wrong"
[ "$(echo "$inv_json" | json_field signature_valid)" = true ] || fail "invoice signature invalid"
pass "invoice fetched"

step "bolt12: lf2 pays the fetched invoice"
paid=$(lf2 offer pay --invoice "$lni")
[ "$(echo "$paid" | json_field amount_msat)" = 123000 ] || fail "paid amount wrong"
[ -n "$(echo "$paid" | json_field payment_preimage)" ] || fail "no preimage"
pass "paid 123000 msat, fee $(echo "$paid" | json_field fee_msat) msat"

step "bolt12: lf2 pays the offer directly for 250000 msat"
paid=$(lf2 offer pay "$lno" --amount_msat 250000 --payer_note payout)
[ "$(echo "$paid" | json_field amount_msat)" = 250000 ] || fail "paid amount wrong"
pass "paid 250000 msat"

step "bolt12: lf1 sees both invoices settled"
inv_list=$(lf1 offer invoices)
settled=$(echo "$inv_list" | grep -c '"state": *"SETTLED"' || true)
[ "$settled" -ge 2 ] || fail "expected at least two settled invoices, got $settled"
issued=$(lf1 offer list | grep -m1 invoices_issued | sed 's/[^0-9]//g')
[ "$issued" -ge 2 ] || fail "invoices_issued is $issued"
pass "$settled settled invoices on lf1"

step "bolt12: the other way, lf2 mints a priced offer and lf1 pays it"
lno2=$(lf2 offer create --description coffee --amount_msat 50000 --with_paths | json_field bolt12)
paid=$(lf1 offer pay "$lno2")
[ "$(echo "$paid" | json_field amount_msat)" = 50000 ] || fail "paid amount wrong"
wait_for "lf2 settled" 30 sh -c "$COMPOSE exec -T lf2 lncli --network=regtest --rpcserver=127.0.0.1:10009 offer invoices | grep -q '\"state\": *\"SETTLED\"'"
pass "lf1 paid lf2's offer"

step "bolt12: the same offer again is the same offer"
again=$(lf1 offer create --description "OCEAN Payouts for bcrt1qminer" --with_paths)
[ "$(echo "$again" | json_field created)" = false ] || fail "re-minting made a new offer"
[ "$(echo "$again" | json_field bolt12)" = "$lno" ] || fail "re-minted offer differs"
pass "re-minting returned the stored offer"

step "bolt12: a disabled offer is refused"
oid=$(echo "$offer_json" | json_field offer_id)
lf1 offer disable "$oid" >/dev/null
if lf2 offer fetchinvoice "$lno" --amount_msat 1000 >/dev/null 2>&1; then
	fail "a disabled offer was served"
fi
lf1 offer enable "$oid" >/dev/null
pass "disabled offer refused, enabled again"
