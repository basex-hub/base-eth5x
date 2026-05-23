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

## Official Base mainnet contracts

The following 14 contracts are the official BASEX / ETH5X production contract set on Base mainnet. Always verify contract addresses from the official website and BaseScan before interacting.

| # | Contract | Function | BaseScan |
|---:|---|---|---|
| 1 | BASEX Token | Main token / community asset | [`0x23C54c9d69e6F302b90223bdC2Fa3928F208E54a`](https://basescan.org/address/0x23C54c9d69e6F302b90223bdC2Fa3928F208E54a) |
| 2 | ETH5X Token | 5x leveraged ETH vault share token | [`0x6B0591C7715b48D316817A0393B1e99763595715`](https://basescan.org/address/0x6B0591C7715b48D316817A0393B1e99763595715) |
| 3 | KxVault | ETH5X mint/redeem vault and NAV surface | [`0x414FbB1320ceC6C0CfFf412D45cFca65C0166b07`](https://basescan.org/address/0x414FbB1320ceC6C0CfFf412D45cFca65C0166b07) |
| 4 | MorphoStrategyV1 | Morpho-based 5x ETH strategy | [`0x5aF590Bab543A8F32961B8a0d4Adb5eacceE1c30`](https://basescan.org/address/0x5aF590Bab543A8F32961B8a0d4Adb5eacceE1c30) |
| 5 | ReserveVault | Reserve-side vault accounting | [`0xbf07D7906909191190696D8F0718D74121981e1d`](https://basescan.org/address/0xbf07D7906909191190696D8F0718D74121981e1d) |
| 6 | ReserveEngine | Reserve buffer, fee accounting, and deleveraging support | [`0xc20a9D5688Fd4c0a876518356b96535158838F77`](https://basescan.org/address/0xc20a9D5688Fd4c0a876518356b96535158838F77) |
| 7 | SwapAdapter | Controlled WETH/USDC swap execution for strategy operations | [`0x6FAD1B63AAaf5A56Ed3c6d09C8A2EE32eeb8c030`](https://basescan.org/address/0x6FAD1B63AAaf5A56Ed3c6d09C8A2EE32eeb8c030) |
| 8 | CurveRouter | Fair-launch bonding-curve inventory router | [`0x26Ab661A6bD1fFA05CDB589E6c137D334071e726`](https://basescan.org/address/0x26Ab661A6bD1fFA05CDB589E6c137D334071e726) |
| 9 | LaunchHook | Uniswap v4 launch state control, fee routing, and launch protection | [`0x3FfaC14a58f811f0DcE339B4Fd7c53BEa32AAacC`](https://basescan.org/address/0x3FfaC14a58f811f0DcE339B4Fd7c53BEa32AAacC) |
| 10 | LiquidityVault365 | Graduation LP creation and lock workflow | [`0x577d0AdbDd2eC02858F8Dc214FaEAFc9614F869b`](https://basescan.org/address/0x577d0AdbDd2eC02858F8Dc214FaEAFc9614F869b) |
| 11 | OfficialEthRouter | Official ETH ⇄ BASEX trading route | [`0x39C555dEB2c5820920eBF34Eb014C43358F65215`](https://basescan.org/address/0x39C555dEB2c5820920eBF34Eb014C43358F65215) |
| 12 | ETH5X/WETH ReferenceHook | NAV-aligned ETH5X/WETH reference pricing hook | [`0x5ad9be7b9592457eDF71326De696675003E5AaC0`](https://basescan.org/address/0x5ad9be7b9592457eDF71326De696675003E5AaC0) |
| 13 | ReferenceRouter | Controlled reference-pool sync route | [`0x1304792f18C58363F9C558D9173B472746666C1a`](https://basescan.org/address/0x1304792f18C58363F9C558D9173B472746666C1a) |
| 14 | ReferenceLiquidityManager | Reference liquidity bootstrap and management | [`0x2A0a5a2C873627Cf24573eD022f8720191640d52`](https://basescan.org/address/0x2A0a5a2C873627Cf24573eD022f8720191640d52) |

## Safety notice

Only contracts linked from the official website and verified BaseScan pages should be treated as official. Forks or clones using similar source code, different constructor arguments, different owner configuration, different hooks, or different routes are not endorsed and may be unsafe.

## License

See [LICENSE](./LICENSE). Solidity files also contain SPDX headers.
