// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IKxETH5XStrategy {
    function asset() external view returns (address);
    function totalAssetsWeth() external view returns (uint256);
    function totalCollateralWeth() external view returns (uint256);
    function totalDebtUsdc() external view returns (uint256);
    function currentLtvBps() external view returns (uint256);
    function deposit(uint256 wethAmount) external;
    function withdraw(uint256 wethAmount, address receiver) external returns (uint256 withdrawn);
    function withdrawForRedeem(uint256 wethAmount, address receiver, uint256 maxExecutionCostBps, bytes calldata unwindData)
        external
        returns (uint256 withdrawn, uint256 executionCostWeth);
    function rebalance(uint256 borrowUsdcAmount, uint256 minWethOut, bytes calldata swapData) external returns (uint256 wethAdded);
    function repayWithUsdc(uint256 usdcAmount) external returns (uint256 repaid);
    function emergencyDeleverage(uint256 wethToSwap, uint256 minUsdcOut, bytes calldata swapData) external returns (uint256 repaid);
}
