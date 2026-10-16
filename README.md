# Quorum (QRM)

`src/QuorumToken.sol` — Solidity contract name `QuorumToken`.

| Parameter | Value |
|---|---|
| name / symbol | Quorum / QRM |
| decimals | 18 |
| totalSupply | 1,000,000,000 QRM = `1000000000000000000000000000` minor units |
| constructor args | none |

## Behaviour and assumptions
- Plain ERC-20. The entire supply is minted once, in the constructor, to `msg.sender` (the launch factory). No mint, burn, owner, pause, blacklist, fee or tax exists, so supply can never grow and no one can move or freeze a holder's balance.
- `type(uint256).max` allowance is treated as infinite (not decremented).
- Transfers to the zero address and approvals of the zero address revert.
- No external calls, no DELEGATECALL/SELFDESTRUCT, no libraries.

## Deployment
Built with solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`. Deployment is performed by IMD's launch through the factory on Ethereum (chain 1), paired with IMD; the factory distributes the supply per the launch economics. This repo contains no deploy scripts or keys.

## After launch
Nothing to configure; the token has no admin and no operational responsibilities.

## Testing
`forge build && forge test && forge fmt --check`. Tests are not an audit.
forge-std v1.9.4 is vendored in `lib/forge-std` (MIT).
