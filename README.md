# NFT Collection (ERC-721)

A fixed-supply ERC-721 collection with the machinery a real drop needs: a Merkle-gated
allowlist round, a public round, delayed metadata reveal with a provenance commitment,
permanent metadata freeze, and EIP-2981 royalties.

Built with [Foundry](https://getfoundry.sh) and OpenZeppelin v5.

## The three ideas that carry this contract

**The allowlist lives off-chain.** Storing ten thousand addresses on-chain would cost millions
in gas. Instead the addresses form a Merkle tree and only the 32-byte root is stored; each
minter supplies a proof that their entry is in the tree. Ten addresses and ten thousand cost
the same.

The per-wallet allowance is part of the leaf, not a separate mapping:

```
leaf = keccak256(keccak256(abi.encode(account, allowance)))
```

Claiming a bigger allowance produces a different leaf, and the proof stops verifying. One root
therefore encodes both membership and individual limits.

The leaf is hashed twice because internal tree nodes are hashes of 64 bytes while leaves are
hashes of 32. Without the second hash, a 64-byte value could be passed off as a leaf and a
valid-looking proof forged from an internal node.

**Metadata stays hidden until minting closes.** Every token returns the same placeholder URI
until `reveal`. Without that, anyone could read the metadata of an unminted id, find the rare
one, and mint exactly it. The `provenanceHash` is fixed at deploy time and commits to the
artwork and its order, so holders can verify afterwards that nothing was reshuffled.

**Metadata can be frozen forever.** `freezeMetadata` permanently gives up the ability to change
the base URI. A collection whose owner keeps that power can swap every image after the sale.

## Contract

| Function                                       | Access | Description                              |
| ---------------------------------------------- | ------ | ---------------------------------------- |
| `mintAllowlist(quantity, allowance, proof)`     | anyone | Allowlist round, gated by Merkle proof.  |
| `mintPublic(quantity)`                          | anyone | Public round, capped per wallet.         |
| `mintReserve(to, quantity)`                     | owner  | Free team mint, bounded by the reserve.  |
| `isAllowlisted(account, allowance, proof)`      | view   | Check eligibility without paying gas.    |
| `withdraw()`                                    | anyone | Sends the balance to the fixed treasury. |
| `reveal(baseURI)`                               | owner  | Publish real metadata. One-way.          |
| `setBaseURI(baseURI)` / `freezeMetadata()`      | owner  | Move metadata; then lock it forever.     |
| `setPhase` / `setPrice` / `setMaxPerWallet`     | owner  | Sale configuration.                      |
| `setAllowlistRoot(root)`                        | owner  | Publish the allowlist.                   |
| `setDefaultRoyalty(receiver, bps)`              | owner  | EIP-2981 royalty, capped at 10%.         |

Mint phases are `Closed → Allowlist → Public`, advanced manually by the owner. Only one is
open at a time.

## Security decisions

**`nonReentrant` on every mint path.** `_safeMint` calls `onERC721Received` on contract
recipients — a callback that runs *before* the mint transaction finishes. Without the guard a
malicious receiver re-enters and mints past its per-wallet limit. `test_ReentrantMintIsBlocked`
demonstrates the attack and proves the guard stops it.

**The reserve counts against `maxSupply`.** The owner cannot mint the collection out from
under buyers: `reserveSupply` is carved out of the cap, not added on top.

**Exact payment required.** Refunding change would mean an extra external call mid-mint for no
benefit. Over- and underpayment both revert with the expected and actual amounts.

**`withdraw` is permissionless but the destination is fixed.** Anyone may trigger it, which
means proceeds are never stranded if the owner key is lost, and there is nothing to gain by
calling it. It uses `Address.sendValue` rather than `transfer`, whose 2300 gas stipend breaks
payouts to multisig treasuries.

**Royalties capped at 10%.** Higher values get collections delisted on major marketplaces, so
the contract refuses to set them.

### Known and accepted

- **Royalties are not enforceable on-chain.** EIP-2981 only *advertises* a royalty; honouring
  it is the marketplace's choice. Enforcement requires transfer blocklists, which trade away
  composability. This contract advertises and does not enforce.
- **`incorrect-equality` from Slither** on `balance == 0` in `withdraw`. The detector targets
  balance comparisons that can be skewed by donating tokens; here it is a no-op guard whose
  only effect is a clearer revert.
- **Owner is a single address.** Production deployments should point it at a multisig — which
  is the next project in this portfolio.

## Allowlist tooling

The off-chain half is a script that turns a JSON list into a root and per-address proofs:

```bash
cp allowlist.example.json allowlist.json   # then edit
forge script script/AllowlistRoot.s.sol:AllowlistRoot
```

It prints the root to set with `setAllowlistRoot` and writes `allowlist-proofs.json` for the
front end:

```json
{
  "root": "0x4bb2e844...",
  "proofs": {
    "0xf39Fd6e5...": {"allowance": 3, "proof": ["0x956c2927...", "0x77840103..."]}
  }
}
```

`test_ScriptLeafFormatMatchesContract` pins the script's leaf format to the contract's. If they
ever drift, every proof in production silently stops verifying — so it is worth a test.

## Testing

53 tests: unit, fuzz and invariant.

```
forge test
forge test --gas-report
forge coverage
```

Coverage on `NFTCollection.sol`: **100% lines, 100% functions, 95.8% branches**.

The invariant suite drives a bounded [handler](test/handlers/MintHandler.sol) — 256 runs × 128
calls per property — with random interleavings of mints, phase flips, price changes and
withdrawals, checking after every call that:

- supply never exceeds `maxSupply` and the reserve never exceeds `reserveSupply`
- token balances sum to `totalMinted`, and ids stay contiguous from 1
- per-wallet and per-allowance limits hold for every actor
- the contract's ETH balance equals payments in minus withdrawals out, tracked by ghost
  variables independent of the contract's own accounting
- everything withdrawn reached the treasury

## Running locally

```bash
forge install
forge build
forge test

anvil                                                    # terminal 1
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/Deploy.s.sol:Deploy \
  --rpc-url http://127.0.0.1:8545 --broadcast            # terminal 2
```

`anvil`'s first account is prefunded and its key is public — never reuse it on a live network.

## License

MIT
