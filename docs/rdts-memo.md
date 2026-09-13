# What the reduced block size does to a Lightning node

The Bitcoin BLAKE2b chain caps blocks at 800 kWU ("reduced data", RDTS)
until the deployment expires on 2027-08-28. Bitcoin's cap is 4,000 kWU.
This memo puts numbers on what a fifth of the capacity means for the
transactions a Lightning node must get confirmed on a deadline, and says
which of LND's defaults that argues for changing. The weights are LND's own
constants (`input/size.go`, BOLT 3), not measurements.

## The transactions and their weights

| Transaction | Weight | Of an 800 kWU block |
| --- | --- | --- |
| commitment, no HTLCs, legacy channel | 724 WU | 0.09 % |
| commitment, no HTLCs, anchor channel | 1,124 WU | 0.14 % |
| commitment, no HTLCs, taproot channel | 968 WU | 0.12 % |
| each HTLC output on a commitment | 172 WU | |
| commitment with the maximum 966 HTLCs (anchors) | 167,276 WU | 21 % |
| sweep of one to_local output (CSV path) | about 320 WU | 0.04 % |
| justice input for one revoked HTLC output | about 400 WU | 0.05 % |
| justice transaction over a full 966-HTLC commitment | about 390,000 WU | 49 % |
| anchor CPFP child with one wallet input | about 700 WU | 0.09 % |

The one transaction that is a real fraction of a reduced block is the
justice transaction for a maximally loaded revoked commitment: half a
block. LND already splits justice transactions per output class and the
sweeper batches by deadline, so nothing has to fit in one block, but a
counterparty who breaches with 966 HTLCs outstanding makes the node buy
half a block's worth of space before the CSV delay runs out. On Bitcoin
that is an eighth of a block. Everything else a Lightning node signs is
noise against either cap.

## What changes and what does not

Deadlines are in blocks, and the block interval is unchanged, so nothing
about `timelockdelta` (80), CSV delays, or `sweep.DefaultDeadlineDelta`
follows from the cap. What the cap changes is the price of a block's space
when demand exceeds 800 kWU: at four-fifths less capacity, the fee needed to
be in the next block rises as soon as more than 800 kWU of transactions
want in, where Bitcoin would still have room. The node's defences against
that are fee estimation and the budgets it is allowed to spend:

- `estimatesmartfee` from the node (Knots) sees the reduced blocks and the
  mempool and needs no help; `--bitcoin.feerate` and the static fallback
  (50 sat/vB) are for when it has no data.
- `sweep.maxfeerate` (default 1,000 sat/vB) caps what a sweep will pay.
  A to_local sweep of 320 WU at 1,000 sat/vB is 80,000 sat; the cap binds
  only for small outputs, where the budget ratio already stops the sweep.
- `contractcourt.DefaultBudgetRatio` (0.5) lets a sweep spend up to half
  its value on fees before the deadline. Under a congested 800 kWU block
  that is the right order: the alternative is losing the output.
- `sweep.nodeadlineconftarget` (1,008) governs sweeps with no deadline;
  they can wait a week either way.

## Recommendation

No default changes now. The chain is weeks old and its blocks are far from
800 kWU; the constants are deadline-driven and the deadlines did not move;
fee estimation already follows the cap. What is worth doing:

1. Report RDTS in the daemon's status and log, so an operator knows it is
   on and when it ends. Done (`chain-identity.json` `reduced_data`).
2. Run the congestion experiment (E5) in the lab once a load generator can
   fill regtest blocks to the cap: force-close and breach with default
   settings, and measure whether sweeps and justice transactions confirm
   before their deadlines. If they do not, the first knob is
   `contractcourt` budget ratio, the second `sweep.maxfeerate`.
3. Revisit if mainnet blocks approach the cap before 2027-08-28.
