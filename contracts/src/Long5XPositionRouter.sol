// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKxETH5XVault} from "./interfaces/IKxETH5XVault.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

interface ILong5XEthUsdOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Official ETH-only Long5X entrypoint and position accountant.
/// @dev This contract records the official-route cost basis only. ETH5X is still a transferable ERC20,
///      so balances acquired elsewhere are intentionally not counted in these snapshots.
contract Long5XPositionRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant NAV_PRECISION = 1e18;
    uint256 public constant ETH_USD_FEED_DECIMALS = 8;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_LONG_OPEN_TVL_BPS = 8_000; // Long open is capped at 80% of shared vault equity.

    struct PositionSnapshot {
        uint256 shares; // ETH5X shares acquired through this router.
        uint256 costWeth; // WETH paid through this router.
        uint256 entryNav; // Weighted average WETH per ETH5X, 1e18 scale.
        uint256 entryEthUsd; // Weighted average ETH/USD at open, Chainlink 1e8 scale.
        uint256 openedAt; // First open timestamp for the current active snapshot.
    }

    IWETH9 public immutable weth;
    IERC20 public immutable eth5x;
    IKxETH5XVault public immutable vault;
    ILong5XEthUsdOracle public immutable ethUsdOracle;

    uint256 public maxOracleStalenessSeconds = 1 hours;
    bool public opensPaused;
    bool public closesPaused;

    mapping(address => PositionSnapshot) private positions;

    event LongOpened(address indexed user, uint256 wethIn, uint256 eth5xOut, uint256 entryNav, uint256 entryEthUsd);
    event LongClosed(address indexed user, uint256 eth5xIn, uint256 wethOut, uint256 exitNav, uint256 exitEthUsd);
    event PositionUpdated(address indexed user, uint256 shares, uint256 costWeth, uint256 averageEntryNav, uint256 averageEntryEthUsd);
    event PausedSet(bool opensPaused, bool closesPaused);
    event OracleStalenessSet(uint256 maxOracleStalenessSeconds);

    error ZeroAddress();
    error ZeroAmount();
    error DeadlineExpired();
    error OpensPaused();
    error ClosesPaused();
    error DepositCapExceeded();
    error InsufficientTrackedShares();
    error BadOraclePrice();
    error StaleOraclePrice();
    error UnauthorizedEth();
    error EthTransferFailed();

    constructor(address initialOwner, IWETH9 weth_, IERC20 eth5x_, IKxETH5XVault vault_, ILong5XEthUsdOracle ethUsdOracle_)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) || address(weth_) == address(0) || address(eth5x_) == address(0)
                || address(vault_) == address(0) || address(ethUsdOracle_) == address(0)
        ) revert ZeroAddress();
        weth = weth_;
        eth5x = eth5x_;
        vault = vault_;
        ethUsdOracle = ethUsdOracle_;
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert UnauthorizedEth();
    }

    function setPaused(bool opensPaused_, bool closesPaused_) external onlyOwner {
        opensPaused = opensPaused_;
        closesPaused = closesPaused_;
        emit PausedSet(opensPaused_, closesPaused_);
    }

    function setOracleStalenessSeconds(uint256 maxOracleStalenessSeconds_) external onlyOwner {
        if (maxOracleStalenessSeconds_ == 0) revert BadOraclePrice();
        maxOracleStalenessSeconds = maxOracleStalenessSeconds_;
        emit OracleStalenessSet(maxOracleStalenessSeconds_);
    }

    function getPosition(address user) external view returns (PositionSnapshot memory) {
        return positions[user];
    }

    function averageEntryNav(address user) external view returns (uint256) {
        return positions[user].entryNav;
    }

    function unrealizedPnlWeth(address user) external view returns (int256) {
        PositionSnapshot memory p = positions[user];
        if (p.shares == 0) return 0;
        uint256 currentValue = (p.shares * vault.navWethPerKx()) / NAV_PRECISION;
        if (currentValue >= p.costWeth) return int256(currentValue - p.costWeth);
        return -int256(p.costWeth - currentValue);
    }

    function maxLongOpenWeth() public view returns (uint256) {
        uint256 vaultMax = vault.maxImmediateDeposit();
        uint256 equity = vault.totalAssetsWeth();
        if (equity == 0) return vaultMax;
        uint256 longMax = (equity * MAX_LONG_OPEN_TVL_BPS) / BPS_DENOMINATOR;
        return vaultMax < longMax ? vaultMax : longMax;
    }

    function maxLongCloseEth5x() public view returns (uint256) {
        return vault.maxImmediateRedeem();
    }

    function openExecutionSpreadBps(uint256 wethIn) external view returns (uint256) {
        return vault.depositSpreadBps(wethIn);
    }

    function closeExecutionSpreadBps(uint256 eth5xIn) external view returns (uint256) {
        return vault.redeemSpreadBps(eth5xIn);
    }

    function openLongWithETH(uint256 minEth5xOut, uint256 deadline) external payable nonReentrant returns (uint256 eth5xOut) {
        if (opensPaused) revert OpensPaused();
        if (block.timestamp > deadline) revert DeadlineExpired();
        uint256 wethIn = msg.value;
        if (wethIn == 0) revert ZeroAmount();
        if (wethIn > maxLongOpenWeth()) revert DepositCapExceeded();

        uint256 entryNav = vault.navWethPerKx();
        uint256 entryEthUsd = _currentEthUsd();

        weth.deposit{value: wethIn}();
        IERC20(address(weth)).forceApprove(address(vault), wethIn);
        eth5xOut = vault.depositWeth(wethIn, minEth5xOut, msg.sender);
        IERC20(address(weth)).forceApprove(address(vault), 0);

        _recordOpen(msg.sender, wethIn, eth5xOut, entryNav, entryEthUsd);
        emit LongOpened(msg.sender, wethIn, eth5xOut, entryNav, entryEthUsd);
    }

    function openLongWithWeth(uint256 wethIn, uint256 minEth5xOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 eth5xOut)
    {
        if (opensPaused) revert OpensPaused();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (wethIn == 0) revert ZeroAmount();
        if (wethIn > maxLongOpenWeth()) revert DepositCapExceeded();

        uint256 entryNav = vault.navWethPerKx();
        uint256 entryEthUsd = _currentEthUsd();

        IERC20(address(weth)).safeTransferFrom(msg.sender, address(this), wethIn);
        IERC20(address(weth)).forceApprove(address(vault), wethIn);
        eth5xOut = vault.depositWeth(wethIn, minEth5xOut, msg.sender);
        IERC20(address(weth)).forceApprove(address(vault), 0);

        _recordOpen(msg.sender, wethIn, eth5xOut, entryNav, entryEthUsd);
        emit LongOpened(msg.sender, wethIn, eth5xOut, entryNav, entryEthUsd);
    }

    function closeLong(uint256 eth5xIn, uint256 minWethOut, uint256 deadline) external nonReentrant returns (uint256 wethOut) {
        wethOut = _closeLong(eth5xIn, minWethOut, 0, bytes(""), deadline);
    }

    function closeLongToEth(
        uint256 eth5xIn,
        uint256 minWethOut,
        uint256 maxExecutionCostBps,
        bytes calldata strategyData,
        uint256 deadline
    ) external nonReentrant returns (uint256 wethOut) {
        wethOut = _closeLong(eth5xIn, minWethOut, maxExecutionCostBps, strategyData, deadline);
    }

    function _closeLong(
        uint256 eth5xIn,
        uint256 minWethOut,
        uint256 maxExecutionCostBps,
        bytes memory strategyData,
        uint256 deadline
    ) internal returns (uint256 wethOut) {
        if (closesPaused) revert ClosesPaused();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (eth5xIn == 0) revert ZeroAmount();
        if (eth5xIn > positions[msg.sender].shares) revert InsufficientTrackedShares();

        uint256 exitNav = vault.navWethPerKx();
        uint256 exitEthUsd = _currentEthUsd();

        eth5x.safeTransferFrom(msg.sender, address(this), eth5xIn);
        wethOut = vault.redeemWethWithStrategy(eth5xIn, minWethOut, maxExecutionCostBps, strategyData, address(this));
        _recordClose(msg.sender, eth5xIn);

        weth.withdraw(wethOut);
        (bool ok,) = msg.sender.call{value: wethOut}("");
        if (!ok) revert EthTransferFailed();

        emit LongClosed(msg.sender, eth5xIn, wethOut, exitNav, exitEthUsd);
    }

    function _recordOpen(address user, uint256 wethIn, uint256 eth5xOut, uint256 entryNav, uint256 entryEthUsd) internal {
        PositionSnapshot storage p = positions[user];
        uint256 oldShares = p.shares;
        uint256 oldCost = p.costWeth;
        uint256 newShares = oldShares + eth5xOut;
        uint256 newCost = oldCost + wethIn;

        p.entryNav = oldShares == 0 ? entryNav : ((p.entryNav * oldShares) + (entryNav * eth5xOut)) / newShares;
        p.entryEthUsd = oldCost == 0 ? entryEthUsd : ((p.entryEthUsd * oldCost) + (entryEthUsd * wethIn)) / newCost;
        p.shares = newShares;
        p.costWeth = newCost;
        if (p.openedAt == 0) p.openedAt = block.timestamp;

        emit PositionUpdated(user, p.shares, p.costWeth, p.entryNav, p.entryEthUsd);
    }

    function _recordClose(address user, uint256 eth5xIn) internal {
        PositionSnapshot storage p = positions[user];
        uint256 oldShares = p.shares;
        uint256 oldCost = p.costWeth;
        if (eth5xIn >= oldShares) {
            delete positions[user];
            emit PositionUpdated(user, 0, 0, 0, 0);
            return;
        }

        uint256 costRemoved = (oldCost * eth5xIn) / oldShares;
        p.shares = oldShares - eth5xIn;
        p.costWeth = oldCost - costRemoved;
        emit PositionUpdated(user, p.shares, p.costWeth, p.entryNav, p.entryEthUsd);
    }

    function _currentEthUsd() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdOracle.latestRoundData();
        if (answer <= 0) revert BadOraclePrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > maxOracleStalenessSeconds) revert StaleOraclePrice();
        return uint256(answer);
    }
}
