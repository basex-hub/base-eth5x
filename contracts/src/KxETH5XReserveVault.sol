// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKxETH5XReserveVault} from "./interfaces/IKxETH5XReserveVault.sol";

/// @notice Skeleton reserve vault for protocol-owned ETH 5x exposure.
/// @dev Morpho integration is a P1 task; this contract fixes the external debt-repay contract first.
contract KxETH5XReserveVault is IKxETH5XReserveVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    uint256 public accountingDebtUsdc;

    event DebtRepaid(uint256 requested, uint256 repaid);
    event AccountingDebtSet(uint256 debtUsdc);

    error ZeroAddress();

    constructor(address initialOwner, IERC20 usdc_) Ownable(initialOwner) {
        if (initialOwner == address(0) || address(usdc_) == address(0)) revert ZeroAddress();
        usdc = usdc_;
    }

    function setAccountingDebtUsdc(uint256 debtUsdc) external onlyOwner {
        accountingDebtUsdc = debtUsdc;
        emit AccountingDebtSet(debtUsdc);
    }

    function repayDebt(uint256 usdcAmount) external nonReentrant returns (uint256 repaid) {
        repaid = usdcAmount > accountingDebtUsdc ? accountingDebtUsdc : usdcAmount;
        if (repaid != 0) {
            usdc.safeTransferFrom(msg.sender, address(this), repaid);
            accountingDebtUsdc -= repaid;
        }
        emit DebtRepaid(usdcAmount, repaid);
    }

    function currentLtvBps() external pure returns (uint256) {
        return 0;
    }

    function liquidationPriceUsdE8() external pure returns (uint256) {
        return 0;
    }
}
