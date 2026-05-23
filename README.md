# BaseX / ETH5X Contract Source Preview

Official pre-launch source preview for **BaseX (`BASEX`)** and **ETH5X** on Base.

This repository is intentionally minimal before public launch. It focuses only on contracts needed to review token behavior, vault custody, reserve accounting, and the Morpho strategy seam.

## Included before launch

- `BE5XToken.sol` — BaseX / BASEX ERC20 token.
- `KxETH5XToken.sol` — ETH5X share token.
- `KxETH5XVault.sol` — ETH5X vault share accounting and strategy binding surface.
- `KxETH5XReserveVault.sol` — reserve-vault accounting seam.
- `ReserveEngineV0.sol` — reserve buffer and repayment accounting seam.
- `MorphoStrategyV1.sol` — Morpho strategy seam for ETH-denominated reserve exposure.
- `Long5XPositionRouter.sol` — official ETH5X long-position entry/exit surface.
- Minimal interfaces and libraries required to review the above files.

## Intentionally excluded before launch

To reduce copycat launch risk, this preview does **not** include:

- bonding-curve launch router implementation;
- Uniswap v4 launch hook implementation;
- LP-lock / graduation execution vault implementation;
- official user routers;
- reference-pricing keeper implementation;
- swap adapter implementation;
- deployment scripts, private manifests, wallet automation, frontend, keeper, mocks, canary contracts, or secrets.

Full verified source for live deployed contracts should be checked on BaseScan after the official deployment is public.

## Official links

- Website: https://base-eth5x.win
- X: https://x.com/base_eth5x
- Whitepaper: https://base-eth5x.win/whitepaper

## Safety notice

Only contracts linked from the official website and verified BaseScan pages should be treated as official. Forks or clones using similar source code, different constructor arguments, different owner configuration, different hooks, or different routes are not endorsed and may be unsafe.

## License

See [LICENSE](./LICENSE). Solidity files also contain SPDX headers.
