// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IKxETH5XReserveVault {
    function repayDebt(uint256 usdcAmount) external returns (uint256 repaid);
    function currentLtvBps() external view returns (uint256);
    function liquidationPriceUsdE8() external view returns (uint256);
}
