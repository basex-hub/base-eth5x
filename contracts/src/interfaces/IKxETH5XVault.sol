// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Share-vault interface for kxETH5X. V0 uses mock NAV; future Morpho-backed strategy keeps the same surface.
/// @dev User-facing integrations should present ETH/WETH quotes rather than raw share accounting.
interface IKxETH5XVault {
    /// @notice Current NAV in WETH per 1 kxETH5X, scaled by 1e18.
    function navWethPerKx() external view returns (uint256);

    /// @notice WETH that can back an immediate `redeemWeth` right now (idle buffer net of any reserves).
    function idleWethBuffer() external view returns (uint256);

    /// @notice Largest `wethIn` the vault will accept for `depositWeth` at the current NAV without violating strategy caps.
    function maxImmediateDeposit() external view returns (uint256);

    /// @notice Largest `kxIn` the vault will redeem immediately at the current NAV without exceeding the idle buffer.
    function maxImmediateRedeem() external view returns (uint256);

    /// @notice Current total vault equity, denominated in WETH.
    function totalAssetsWeth() external view returns (uint256);

    function strategyNavEnabled() external view returns (bool);

    /// @notice Dynamic vault execution spread for a WETH deposit amount.
    function depositSpreadBps(uint256 wethIn) external view returns (uint256);

    /// @notice Dynamic vault execution spread for a kxETH5X redeem amount.
    function redeemSpreadBps(uint256 kxAmount) external view returns (uint256);

    function previewDeposit(uint256 wethIn) external view returns (uint256 kxOut);

    function previewRedeem(uint256 kxAmount) external view returns (uint256 wethOut);

    /// @notice Pulls `wethIn`, mints kxETH5X to `receiver` at the same-block-frozen NAV.
    function depositWeth(uint256 wethIn, uint256 minKxOut, address receiver) external returns (uint256 kxOut);

    /// @notice Burns `kxIn` from caller, transfers WETH to `receiver` immediately. Reverts if idle buffer is insufficient.
    function redeemWeth(uint256 kxIn, uint256 minWethOut, address receiver) external returns (uint256 wethOut);

    /// @notice Burns `kxIn` from caller and may pull WETH from the strategy in the same transaction when idle is insufficient.
    function redeemWethWithStrategy(
        uint256 kxIn,
        uint256 minWethOut,
        uint256 maxExecutionCostBps,
        bytes calldata strategyData,
        address receiver
    ) external returns (uint256 wethOut);
}
