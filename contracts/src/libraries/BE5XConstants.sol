// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library BE5XConstants {
    /// @notice Net WETH that enters the bonding-curve pricing reserves at graduation.
    uint256 internal constant GRADUATION_NET_WETH = 5 ether;
    /// @notice Public narrative target: “5 ETH graduation”.
    uint256 internal constant GRADUATION_TARGET_WETH = GRADUATION_NET_WETH;
    /// @notice Compatibility alias for integrations that display a graduation threshold; denominated as net WETH.
    uint256 internal constant GRADUATION_PUBLIC_WETH = GRADUATION_NET_WETH;
    uint256 internal constant GRADUATION_THRESHOLD_WETH = GRADUATION_NET_WETH;
    /// @notice Gross WETH needed when the 1% launch fee is included.
    uint256 internal constant GRADUATION_GROSS_WETH = 5_050_505_050_505_050_505;
    uint256 internal constant GRADUATION_SHORTFALL_WETH = 0;

    /// @notice Main BASEX/ETH5X LP seed: 4 ETH worth of ETH5X plus 200M BASEX.
    uint256 internal constant GRADUATION_LP_WETH = 4 ether;
    /// @notice Keeper/emergency reserve. The 1% launch fee excess is also swept here at graduation.
    uint256 internal constant GRADUATION_RESERVE_WETH = 0.7 ether;
    /// @notice Graduation execution reserve: UNCX flat fee, finalize/keeper gas, indexing/monitoring, and launch support.
    uint256 internal constant GRADUATION_EXECUTION_BUFFER_WETH = 0.2 ether;
    /// @notice Pricing infrastructure budget for the ETH5X/WETH reference pool and its keeper buffer.
    uint256 internal constant GRADUATION_REFERENCE_PRICING_WETH = 0.1 ether;
    uint256 internal constant GRADUATION_OPS_WETH = GRADUATION_EXECUTION_BUFFER_WETH;
    /// @notice Net WETH dust boundary for precision-filling the last curve increment.
    uint256 internal constant GRADUATION_DUST_WETH = 0.001 ether;

    uint256 internal constant LP_LOCK_DURATION_SECONDS = 365 days;

    /// @notice Pump-style hard cap supply: 80% curve buyers + 20% main LP. No BASEX/WETH mirror reserve.
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant CURVE_BE5X_ALLOCATION = 800_000_000 ether;
    uint256 internal constant GRADUATION_LP_BE5X = 200_000_000 ether;

    /// @dev Solves for 800M BASEX sold at 5E net, with 4E + 200M BASEX LP price continuity at 20E FDV.
    uint256 internal constant INITIAL_BE5X_VIRTUAL_RESERVE = 1_163_636_363_636_363_636_320_000_000;
    uint256 internal constant INITIAL_WETH_VIRTUAL_RESERVE = 2_272_727_272_727_272_727;

    /// @notice Public curve buy cap after the one-time bootstrap transaction. Gross WETH input.
    uint256 internal constant MAX_PUBLIC_CURVE_BUY_WETH = 0.4 ether;

    uint16 internal constant PRE_GRADUATION_FEE_BPS = 100; // 1.0%
    uint16 internal constant POST_GRADUATION_TOTAL_FEE_BPS = 50; // 0.5% hook fee, plus the 0.2% canonical v4 LP fee.
    uint16 internal constant RESERVE_ENGINE_FEE_BPS = 30; // 0.3%
    uint16 internal constant PROTOCOL_MAINTENANCE_FEE_BPS = 20; // 0.2%

    uint16 internal constant BPS_DENOMINATOR = 10_000;
}
