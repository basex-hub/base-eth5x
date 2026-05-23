// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKxETH5XReserveVault} from "./interfaces/IKxETH5XReserveVault.sol";
import {IKxETH5XVault} from "./interfaces/IKxETH5XVault.sol";

/// @notice Holds BE5X reserve principal and the 0.3% post-graduation debt-buffer fees.
/// @dev V0 has no instant private withdraw. V0->V1 migration is whitelisted and timelocked.
contract ReserveEngineV0 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant NAV_PRECISION = 1e18;
    uint256 public constant MIGRATION_DELAY = 3 days;

    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    /// @notice Optional post-graduation fee token. In BE5X v2 this is kxETH5X.
    IERC20 public kxFeeToken;
    /// @notice Optional NAV source used to convert kx fee buffers to WETH-equivalent keeper thresholds.
    IKxETH5XVault public kxVault;
    IKxETH5XReserveVault public reserveVault;
    address public swapExecutor;
    address public feeRecorder;
    uint256 public minWethToRebalance;

    /// @notice Graduation reserve principal held for deleverage / reserve-health operations.
    uint256 public principalReserveWeth;
    /// @notice WETH fees from the 0.3% ReserveEngine leg, queued for debt-buffer operations.
    uint256 public debtBufferWeth;
    /// @notice kxETH5X fees from the 0.3% post-graduation leg, held as reserve-side buffer.
    uint256 public debtBufferKx;

    mapping(address => bool) public migrationTargetWhitelist;
    address public pendingMigrationTarget;
    uint256 public migrationExecutableAt;

    event PrincipalReserveSynced(uint256 amountAdded, uint256 principalReserveWeth);
    event DebtBufferRecorded(address indexed token, uint256 amount, uint256 debtBufferWeth);
    event KxDebtBufferRecorded(address indexed token, uint256 amount, uint256 debtBufferKx);
    event KxFeeTokenUpdated(address indexed kxFeeToken);
    event KxVaultUpdated(address indexed kxVault);
    event ReserveVaultUpdated(address indexed reserveVault);
    event SwapExecutorUpdated(address indexed swapExecutor);
    event FeeRecorderUpdated(address indexed feeRecorder);
    event MinWethToRebalanceUpdated(uint256 minWethToRebalance);
    event MigrationTargetWhitelistUpdated(address indexed target, bool allowed);
    event MigrationInitiated(address indexed target, uint256 executableAt);
    event MigrationCancelled(address indexed target);
    event TokensMigrated(address indexed token, address indexed to, uint256 amount);
    event DebtRepaid(uint256 usdcRepaid, address indexed caller);

    error ZeroAddress();
    error BelowThreshold();
    error WrongToken();
    error WrongValue();
    error UnauthorizedFeeRecorder();
    error MigrationTargetNotWhitelisted();
    error MigrationNotReady();
    error MigrationNotInitiated();

    constructor(address initialOwner, IERC20 weth_, IERC20 usdc_, IKxETH5XReserveVault reserveVault_, address swapExecutor_) Ownable(initialOwner) {
        if (initialOwner == address(0) || address(weth_) == address(0) || address(usdc_) == address(0) || address(reserveVault_) == address(0)) {
            revert ZeroAddress();
        }
        weth = weth_;
        usdc = usdc_;
        reserveVault = reserveVault_;
        swapExecutor = swapExecutor_;
        minWethToRebalance = 0.03 ether;
    }

    function setReserveVault(IKxETH5XReserveVault reserveVault_) external onlyOwner {
        if (address(reserveVault_) == address(0)) revert ZeroAddress();
        reserveVault = reserveVault_;
        emit ReserveVaultUpdated(address(reserveVault_));
    }

    function setSwapExecutor(address swapExecutor_) external onlyOwner {
        swapExecutor = swapExecutor_;
        emit SwapExecutorUpdated(swapExecutor_);
    }

    function setKxFeeToken(IERC20 kxFeeToken_) external onlyOwner {
        if (address(kxFeeToken_) == address(0)) revert ZeroAddress();
        kxFeeToken = kxFeeToken_;
        emit KxFeeTokenUpdated(address(kxFeeToken_));
    }

    function setKxVault(IKxETH5XVault kxVault_) external onlyOwner {
        if (address(kxVault_) == address(0)) revert ZeroAddress();
        kxVault = kxVault_;
        emit KxVaultUpdated(address(kxVault_));
    }

    function setFeeRecorder(address feeRecorder_) external onlyOwner {
        if (feeRecorder_ == address(0)) revert ZeroAddress();
        feeRecorder = feeRecorder_;
        emit FeeRecorderUpdated(feeRecorder_);
    }

    function setMinWethToRebalance(uint256 minWethToRebalance_) external onlyOwner {
        minWethToRebalance = minWethToRebalance_;
        emit MinWethToRebalanceUpdated(minWethToRebalance_);
    }

    function setMigrationTargetWhitelisted(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        migrationTargetWhitelist[target] = allowed;
        emit MigrationTargetWhitelistUpdated(target, allowed);
    }

    function initiateMigration(address target) external onlyOwner {
        if (!migrationTargetWhitelist[target]) revert MigrationTargetNotWhitelisted();
        pendingMigrationTarget = target;
        migrationExecutableAt = block.timestamp + MIGRATION_DELAY;
        emit MigrationInitiated(target, migrationExecutableAt);
    }

    function cancelMigration() external onlyOwner {
        address target = pendingMigrationTarget;
        if (target == address(0)) revert MigrationNotInitiated();
        pendingMigrationTarget = address(0);
        migrationExecutableAt = 0;
        emit MigrationCancelled(target);
    }

    function completeMigration(IERC20[] calldata tokens) external onlyOwner nonReentrant {
        address target = pendingMigrationTarget;
        if (target == address(0)) revert MigrationNotInitiated();
        if (!migrationTargetWhitelist[target]) revert MigrationTargetNotWhitelisted();
        if (block.timestamp < migrationExecutableAt) revert MigrationNotReady();

        pendingMigrationTarget = address(0);
        migrationExecutableAt = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = tokens[i];
            if (address(token) == address(0)) revert ZeroAddress();
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) continue;
            token.safeTransfer(target, balance);
            emit TokensMigrated(address(token), target, balance);
        }
    }

    /// @notice Accounts newly received WETH as reserve principal, e.g. the 0.7E graduation reserve.
    function syncPrincipalReserve() public onlyOwner returns (uint256 added) {
        uint256 accounted = principalReserveWeth + debtBufferWeth;
        uint256 balance = weth.balanceOf(address(this));
        if (balance <= accounted) return 0;
        added = balance - accounted;
        principalReserveWeth += added;
        emit PrincipalReserveSynced(added, principalReserveWeth);
    }

    /// @notice Authorized fee recorder calls this after transferring the 0.3% reserve leg.
    /// @dev WETH fees are tracked as repayable debt buffer. kxETH5X fees are held as a reserve-side share buffer.
    function recordDebtBuffer(address token, uint256 amount) external {
        if (msg.sender != feeRecorder) revert UnauthorizedFeeRecorder();
        if (amount == 0) revert WrongValue();

        if (token == address(weth)) {
            if (weth.balanceOf(address(this)) < principalReserveWeth + debtBufferWeth + amount) revert WrongValue();
            debtBufferWeth += amount;
            emit DebtBufferRecorded(token, amount, debtBufferWeth);
            return;
        }

        if (address(kxFeeToken) != address(0) && token == address(kxFeeToken)) {
            if (kxFeeToken.balanceOf(address(this)) < debtBufferKx + amount) revert WrongValue();
            debtBufferKx += amount;
            emit KxDebtBufferRecorded(token, amount, debtBufferKx);
            return;
        }

        revert WrongToken();
    }

    /// @notice Repay debt after USDC has been delivered by an approved mature swap path.
    /// @dev V1 keeps WETH->USDC routing outside this contract until the exact Base route is selected.
    function repayAvailableUsdc() external nonReentrant returns (uint256 repaid) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance != 0) {
            usdc.forceApprove(address(reserveVault), balance);
            repaid = reserveVault.repayDebt(balance);
            usdc.forceApprove(address(reserveVault), 0);
        }
        emit DebtRepaid(repaid, msg.sender);
    }

    function debtBufferWethEquivalent() public view returns (uint256 totalWethEquivalent) {
        totalWethEquivalent = debtBufferWeth;
        if (debtBufferKx == 0 || address(kxVault) == address(0)) return totalWethEquivalent;
        totalWethEquivalent += debtBufferKx * kxVault.navWethPerKx() / NAV_PRECISION;
    }

    /// @notice Guard for keepers/UI before executing an external mature route into this engine.
    function canRebalance() external view returns (bool) {
        return debtBufferWethEquivalent() >= minWethToRebalance;
    }
}
