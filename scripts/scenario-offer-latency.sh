#!/usr/bin/env bash
# What a BOLT 12 invoice fetch costs, and when it works at all.
#
# The fetch-first payout design makes an OCEAN payout atomic by inverting an
# order. Today the bridge issues the Bitcoin invoice itself, so it holds the
# preimage from the start and could collect without paying; the miner's only
# protection is that it does not. Instead, when a request arrives for the
# bridge's Bitcoin offer, the bridge first fetches an invoice from the *miner's*
# BLAKE2b offer and answers with that invoice's payment hash. It then cannot
# settle the Bitcoin leg without the preimage, and the only way to get it is to
# pay the miner.
#
# That inserts an onion-message round trip on another network into the middle of
# answering an invoice request, so the question was whether it fits inside the
# requesting payer's timeout:
#
#   BUDGET  how long the payer waits for a reply (ours is 60s; OCEAN's is S16)
#   COST    how long our fetch from the miner's offer takes
#
# It does, comfortably. The cost is milliseconds. What this measures instead is
# the thing that turned out to matter: fetches do not always succeed, and
# whether they do depends on the topology and on whether the offer carries a
# blinded path. Run the matrix rather than a single case, because a single case
# reports whichever answer you happened to pick.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

bash "$(dirname "$0")/bolt12-setup.sh"

json_field() {
	grep -m1 "\"$1\"" | sed 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/'
}

now_ms() { date +%s%3N; }
median() { sort -n | awk '{a[NR]=$1} END{print (NR%2) ? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2)}'; }

# try ISSUER FETCHER PATHFLAG REPS: mints an offer on ISSUER and has FETCHER
# fetch an invoice for it, REPS times. Prints "<ok>/<reps> median <ms>".
try() {
	local issuer=$1 fetcher=$2 flag=$3 reps=$4
	local lno ok=0 times
	times=$(mktemp)

	lno=$(lncli_on "$issuer" offer create \
		--description "payout matrix $flag" "$flag" 2>/dev/null |
		json_field bolt12) || true
	if [ -z "${lno:-}" ] || [[ "$lno" != lno1* ]]; then
		echo "offer-mint-failed"

		return
	fi

	for i in $(seq 1 "$reps"); do
		local t0 t1
		t0=$(now_ms)
		if lncli_on "$fetcher" offer fetchinvoice "$lno" \
			--amount_msat 123000 --timeout_seconds 10 \
			--payer_note "matrix $i" >/dev/null 2>&1; then
			t1=$(now_ms)
			ok=$((ok + 1))
			echo $((t1 - t0)) >> "$times"
		fi
	done

	if [ "$ok" = 0 ]; then
		echo "$ok/$reps -"
	else
		echo "$ok/$reps $(median < "$times")ms"
	fi
}

REPS=${REPS:-5}

step "offer-latency: the matrix"
echo
echo "  Both nodes fall back to a blinded path starting at themselves, because"
echo "  in a two-node lab neither has a peer that could be an introduction node"
echo "  for the other. That fallback is not the variable; the matrix is."
echo
printf "  %-28s %-16s %s\n" "case" "with_paths" "no_paths"
printf "  %-28s %-16s %s\n" "----" "----------" "--------"

a=$(try lf1 lf2 --with_paths "$REPS")
b=$(try lf1 lf2 --no_paths "$REPS")
printf "  %-28s %-16s %s\n" "lf2 fetches from lf1" "$a" "$b"

c=$(try lf2 lf1 --with_paths "$REPS")
d=$(try lf2 lf1 --no_paths "$REPS")
printf "  %-28s %-16s %s\n" "lf1 fetches from lf2" "$c" "$d"

echo
record offer-latency lf2_from_lf1_paths "$a"
record offer-latency lf2_from_lf1_nopaths "$b"
record offer-latency lf1_from_lf2_paths "$c"
record offer-latency lf1_from_lf2_nopaths "$d"

step "offer-latency: what it means for the fetch-first design"
cat <<EOF

  Latency is not the risk. Where a fetch succeeds at all it completes in
  roughly a tenth of a second, against a 60s payer timeout in our own
  implementation. The round trip is not what would break this.

  Whether the fetch succeeds is the risk. At 20 reps the measured rate was
  17/20 in all four cells: about 15% of fetches fail, and the rate does not
  move with direction or with whether the offer carries a blinded path.

  Run this with enough reps. At 5 reps an earlier run showed with_paths
  passing and no_paths failing, and that reading was pure small-sample
  noise -- there is no such asymmetry. One cell of five tells you nothing.

  A 15% failure rate is not only the payout design's problem. Offer fetching
  ships today, so this is live. For the fetch-first design specifically it
  means roughly one payout in seven stalls with OCEAN waiting, which is a
  recurring operational cost rather than a one-off.

  Suspected cause, not yet proven: offerpay.deliver() drops a reply whose
  path_id is not exactly 32 bytes, and it does so with no log at all --

      if len(msg.PathID) != 32 {
              return
      }

  The trace is consistent with this. On a failing fetch the messenger logs
  "Delivering onion message to self" and then nothing, and in particular the
  "Reply from peer ... for no pending fetch" line just below never fires. So
  the reply arrives and is discarded before reaching the matcher. Confirming
  that needs a log line at the drop and a rebuild.

  Still unmeasured, because they need an OCEAN account: how long OCEAN waits
  for an invoice reply (S16), and how long it takes to pay one (S17).
EOF
