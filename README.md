# lightning-fork-lab

Regtest harness for [Lightning Fork](https://github.com/paulscode/lightning-fork),
an `lnd` fork that follows the Bitcoin BLAKE2b chain. Two chains run side by
side: a Bitcoin Knots v29.4.1 regtest that activates BLAKE2b at a configured
height, and a stock SHA256d regtest with a stock `lnd`, so that isolation
between the two Lightning networks is tested rather than assumed.

```
make build        # lnd + lncli from ../lightning-fork, packed into lightning-fork:dev
make up           # both chains, lf1 (ZMQ, strict), lf2 (RPC polling, lenient), lnd-sha
make scenarios    # e3-sync e4b-refuse e4-isolation channel reorg restart
make nuke         # wipe everything
```

The Knots image is `knots-blake2b:final-zmq`, built by `knots/Dockerfile` (ZMQ enabled) from
`bitcoinknots/bitcoin@8c85b1585dac23f964e2dd32045624de7f02aa58`
(v29.4.1.knots20260508) with the container recipe in
`../bitcoin-blake2b-regtest/containers/knots-blake2b`.

Scenarios, in order:

| Target | What it proves |
| --- | --- |
| `e3-sync` | A node waits below the activation height, confirms the chain once the node crosses it, and follows v2 blocks over ZMQ and over RPC polling with the node's block ids |
| `e4b-refuse` | A node pointed at the SHA256d chain refuses to start, in words, and records it in `chain-identity.json` |
| `e4-isolation` | A strict node drops a stock `lnd` peer at the handshake; a lenient node keeps it but every channel open fails on the chain hash, in both directions; invoices do not cross; no gossip crosses |
| `channel` | Open, pay both ways (`lnblakert…` invoice and keysend), cooperative close, force close and sweep between two Lightning Fork nodes |
| `reorg` | A reorg within v2 blocks and one that replaces the activation block itself |
| `restart` | Restart on a v2 tip; a restart against the SHA256d node is refused |

`fixtures/` holds headers read from the BLAKE2b mainnet on 2026-09-12, used
as test data by the btcd fork.
