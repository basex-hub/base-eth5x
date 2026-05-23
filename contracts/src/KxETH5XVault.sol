// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KxETH5XToken} from "./KxETH5XToken.sol";
import {IKxETH5XVault} from "./interfaces/IKxETH5XVault.sol";
import {IKxETH5XStrategy} from "./interfaces/IKxETH5XStrategy.sol";

/// @notice Share vault for kxETH5X. V0 defaults to owner-set mock NAV; V1 can enable strategy NAV.
/// @dev Small user-facing paths can redeem against idle WETH. Official routers may also call
///      `redeemWethWithStrategy` to pull/deleverage from the strategy in the same transaction.
contract KxETH5XVault is IKxETH5XVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant NAV_PRECISION = 1e18;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant BASE_EXECUTION_SPREAD_BPS = 20; // 0.20% minimum execution spread, retained by the vault.
    uint256 public constant LARGE_EXECUTION_SPREAD_BPS = 30; // 0.30% for larger immediate routes.
    uint256 public constant DEPOSIT_SPREAD_TIER_BPS = 2_500; // Deposits above 25% of equity use the large spread.
    uint256 public constant REDEEM_SPREAD_TIER_BPS = 1_500; // Redeems above 15% of equity use the large spread.
    uint256 public constant MAX_DEPOSIT_TVL_BPS_CAP = 10_000; // Official ETH routes can deposit up to 100% of current vault equity.
    uint256 public constant MAX_REDEEM_TVL_BPS_CAP = 2_500; // Immediate redeem is capped at 25% of current vault equity.
    uint256 public constant MIN_REDEEM_IDLE_BPS = 3_000; // 30% of idle buffer.
    uint256 public constant MAX_REDEEM_IDLE_BPS_CAP = 7_000; // 70% of idle buffer.
    uint256 public constant MAX_REDEEM_EXECUTION_COST_BPS = 1_000; // User-triggered strategy redeems cannot tolerate >10% execution leakage.

    IERC20 public immutable weth;
    KxETH5XToken public immutable kxToken;

    uint256 private _navStorage;
    uint256 private _navSnapshot;
    uint256 private _navSnapshotBlock;

    uint256 public depositCap;
    uint256 public maxDepositTvlBps;
    uint256 public maxRedeemIdleBps;
    address public strategy;
    address public keeper;
    bool public strategyNavEnabled;
    bool public manualNavLocked;
    bool public depositsPaused;
    bool public redeemsPaused;

    event NavSet(uint256 navWethPerKx);
    event NavFrozen(uint256 navWethPerKx, uint256 blockNumber);
    event DepositCapSet(uint256 cap);
    event VaultRiskLimitsSet(uint256 maxDepositTvlBps, uint256 maxRedeemIdleBps);
    event StrategySet(address indexed strategy);
    event KeeperSet(address indexed keeper);
    event StrategyNavEnabledSet(bool enabled);
    event ManualNavLocked();
    event IdleWethInvested(address indexed strategy, uint256 amount);
    event StrategyWethPulled(address indexed strategy, uint256 amount);
    event Deposited(address indexed caller, address indexed receiver, uint256 wethIn, uint256 kxOut, uint256 nav);
    event Redeemed(address indexed caller, address indexed receiver, uint256 kxIn, uint256 wethOut, uint256 nav);
    event RedeemedWithStrategy(
        address indexed caller,
        address indexed receiver,
        uint256 kxIn,
        uint256 wethOut,
        uint256 nav,
        uint256 pulledFromStrategy,
        uint256 executionCostWeth
    );
    event DepositsPausedSet(bool paused);
    event RedeemsPausedSet(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidNav();
    error StrategyNotSet();
    error DepositsArePaused();
    error RedeemsArePaused();
    error SlippageExceeded();
    error InsufficientIdleBuffer();
    error DepositCapExceeded();
    error RedeemCapExceeded();
    error InvalidBps();
    error UnauthorizedKeeper();
    error ManualNavIsLocked();

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner() && msg.sender != keeper) revert UnauthorizedKeeper();
        _;
    }

    constructor(address initialOwner, IERC20 weth_, KxETH5XToken kxToken_) Ownable(initialOwner) {
        if (initialOwner == address(0) || address(weth_) == address(0) || address(kxToken_) == address(0)) revert ZeroAddress();
        weth = weth_;
        kxToken = kxToken_;
        _navStorage = NAV_PRECISION;
        depositCap = type(uint256).max;
        maxDepositTvlBps = MAX_DEPOSIT_TVL_BPS_CAP;
        maxRedeemIdleBps = MAX_REDEEM_IDLE_BPS_CAP;
    }

    function setNav(uint256 newNav) external onlyOwner {
        if (manualNavLocked || strategyNavEnabled) revert ManualNavIsLocked();
        if (newNav == 0) revert InvalidNav();
        _navStorage = newNav;
        emit NavSet(newNav);
    }

    /// @notice Irreversibly disables owner-set mock NAV for production deployments.
    /// @dev Canary deployments may leave this unlocked while strategy NAV is disabled.
    ///      Once locked, NAV can only come from the strategy path.
    function lockManualNav() external onlyOwner {
        if (!manualNavLocked) {
            manualNavLocked = true;
            emit ManualNavLocked();
        }
    }

    function setDepositCap(uint256 cap) external onlyOwner {
        depositCap = cap;
        emit DepositCapSet(cap);
    }

    function setVaultRiskLimits(uint256 newMaxDepositTvlBps, uint256 newMaxRedeemIdleBps) external onlyOwner {
        if (newMaxDepositTvlBps == 0 || newMaxDepositTvlBps > MAX_DEPOSIT_TVL_BPS_CAP) revert InvalidBps();
        if (newMaxRedeemIdleBps < MIN_REDEEM_IDLE_BPS || newMaxRedeemIdleBps > MAX_REDEEM_IDLE_BPS_CAP) revert InvalidBps();
        maxDepositTvlBps = newMaxDepositTvlBps;
        maxRedeemIdleBps = newMaxRedeemIdleBps;
        emit VaultRiskLimitsSet(newMaxDepositTvlBps, newMaxRedeemIdleBps);
    }

    function setStrategy(address newStrategy) external onlyOwner {
        strategy = newStrategy;
        emit StrategySet(newStrategy);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperSet(newKeeper);
    }

    function setStrategyNavEnabled(bool enabled) external onlyOwner {
        if (enabled && strategy == address(0)) revert StrategyNotSet();
        strategyNavEnabled = enabled;
        emit StrategyNavEnabledSet(enabled);
    }

    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setRedeemsPaused(bool paused) external onlyOwner {
        redeemsPaused = paused;
        emit RedeemsPausedSet(paused);
    }

    function investIdleWeth(uint256 wethAmount) external onlyOwnerOrKeeper nonReentrant {
        if (strategy == address(0)) revert StrategyNotSet();
        if (wethAmount == 0) revert ZeroAmount();
        weth.forceApprove(strategy, wethAmount);
        IKxETH5XStrategy(strategy).deposit(wethAmount);
        weth.forceApprove(strategy, 0);
        emit IdleWethInvested(strategy, wethAmount);
    }

    function pullFromStrategy(uint256 wethAmount) external onlyOwnerOrKeeper nonReentrant returns (uint256 withdrawn) {
        if (strategy == address(0)) revert StrategyNotSet();
        if (wethAmount == 0) revert ZeroAmount();
        withdrawn = IKxETH5XStrategy(strategy).withdraw(wethAmount, address(this));
        emit StrategyWethPulled(strategy, withdrawn);
    }

    function navWethPerKx() public view override returns (uint256) {
        if (_navSnapshotBlock == block.number) return _navSnapshot;
        return _currentNav();
    }

    function totalAssetsWeth() public view returns (uint256 assets) {
        assets = weth.balanceOf(address(this));
        if (strategy != address(0)) {
            assets += IKxETH5XStrategy(strategy).totalAssetsWeth();
        }
    }

    function idleWethBuffer() public view override returns (uint256) {
        return weth.balanceOf(address(this));
    }

    function maxImmediateDeposit() public view override returns (uint256) {
        if (depositsPaused) return 0;
        return _maxImmediateDeposit();
    }

    function maxImmediateRedeem() public view override returns (uint256 kxMax) {
        if (redeemsPaused) return 0;
        uint256 buffer = weth.balanceOf(address(this));
        if (buffer == 0) return 0;
        uint256 nav = navWethPerKx();
        if (nav == 0) revert InvalidNav();
        uint256 grossWethLimit = buffer;
        if (strategyNavEnabled) {
            uint256 idleLimit = Math.mulDiv(buffer, maxRedeemIdleBps, BPS_DENOMINATOR);
            uint256 equityLimit = Math.mulDiv(totalAssetsWeth(), MAX_REDEEM_TVL_BPS_CAP, BPS_DENOMINATOR);
            grossWethLimit = idleLimit < equityLimit ? idleLimit : equityLimit;
        }
        kxMax = Math.mulDiv(grossWethLimit, NAV_PRECISION, nav);
    }

    function depositSpreadBps(uint256 wethIn) public view returns (uint256) {
        if (kxToken.totalSupply() == 0 || !strategyNavEnabled) return 0;
        uint256 assets = totalAssetsWeth();
        if (assets == 0) return BASE_EXECUTION_SPREAD_BPS;
        uint256 tierLimit = Math.mulDiv(assets, DEPOSIT_SPREAD_TIER_BPS, BPS_DENOMINATOR);
        return wethIn <= tierLimit ? BASE_EXECUTION_SPREAD_BPS : LARGE_EXECUTION_SPREAD_BPS;
    }

    function redeemSpreadBps(uint256 kxAmount) public view returns (uint256) {
        if (!strategyNavEnabled) return 0;
        uint256 nav = navWethPerKx();
        if (nav == 0) revert InvalidNav();
        uint256 grossWethOut = Math.mulDiv(kxAmount, nav, NAV_PRECISION);
        uint256 assets = totalAssetsWeth();
        if (assets == 0) return BASE_EXECUTION_SPREAD_BPS;
        uint256 tierLimit = Math.mulDiv(assets, REDEEM_SPREAD_TIER_BPS, BPS_DENOMINATOR);
        return grossWethOut <= tierLimit ? BASE_EXECUTION_SPREAD_BPS : LARGE_EXECUTION_SPREAD_BPS;
    }

    function previewDeposit(uint256 wethIn) public view override returns (uint256 kxOut) {
        uint256 nav = navWethPerKx();
        if (nav == 0) revert InvalidNav();
        uint256 netWethIn = _assetsAfterSpread(wethIn, depositSpreadBps(wethIn));
        kxOut = Math.mulDiv(netWethIn, NAV_PRECISION, nav);
    }

    function previewRedeem(uint256 kxAmount) public view override returns (uint256 wethOut) {
        uint256 nav = navWethPerKx();
        if (nav == 0) revert InvalidNav();
        uint256 grossWethOut = Math.mulDiv(kxAmount, nav, NAV_PRECISION);
        wethOut = _assetsAfterSpread(grossWethOut, redeemSpreadBps(kxAmount));
    }

    function depositWeth(uint256 wethIn, uint256 minKxOut, address receiver) external override nonReentrant returns (uint256 kxOut) {
        if (depositsPaused) revert DepositsArePaused();
        if (wethIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 maxDepositNow = _maxImmediateDeposit();
        if (wethIn > maxDepositNow) revert DepositCapExceeded();

        uint256 nav = _freezeAndGetNav();
        if (nav == 0) revert InvalidNav();
        uint256 netWethIn = _assetsAfterSpread(wethIn, depositSpreadBps(wethIn));
        kxOut = Math.mulDiv(netWethIn, NAV_PRECISION, nav);
        if (kxOut == 0) revert ZeroAmount();
        if (kxOut < minKxOut) revert SlippageExceeded();

        weth.safeTransferFrom(msg.sender, address(this), wethIn);
        kxToken.mint(receiver, kxOut);
        emit Deposited(msg.sender, receiver, wethIn, kxOut, nav);
    }

    function redeemWeth(uint256 kxIn, uint256 minWethOut, address receiver) external override nonReentrant returns (uint256 wethOut) {
        if (redeemsPaused) revert RedeemsArePaused();
        if (kxIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 nav = _freezeAndGetNav();
        if (nav == 0) revert InvalidNav();
        uint256 maxKxNow = maxImmediateRedeem();
        if (kxIn > maxKxNow) revert RedeemCapExceeded();
        uint256 grossWethOut = Math.mulDiv(kxIn, nav, NAV_PRECISION);
        wethOut = _assetsAfterSpread(grossWethOut, redeemSpreadBps(kxIn));
        if (wethOut == 0) revert ZeroAmount();
        if (wethOut < minWethOut) revert SlippageExceeded();

        if (wethOut > weth.balanceOf(address(this))) revert InsufficientIdleBuffer();

        kxToken.burn(msg.sender, kxIn);
        weth.safeTransfer(receiver, wethOut);
        emit Redeemed(msg.sender, receiver, kxIn, wethOut, nav);
    }

    function redeemWethWithStrategy(
        uint256 kxIn,
        uint256 minWethOut,
        uint256 maxExecutionCostBps,
        bytes calldata strategyData,
        address receiver
    ) external override nonReentrant returns (uint256 wethOut) {
        if (redeemsPaused) revert RedeemsArePaused();
        if (kxIn == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (maxExecutionCostBps > MAX_REDEEM_EXECUTION_COST_BPS) revert InvalidBps();

        uint256 nav = _freezeAndGetNav();
        if (nav == 0) revert InvalidNav();
        uint256 grossWethOut = Math.mulDiv(kxIn, nav, NAV_PRECISION);
        wethOut = _assetsAfterSpread(grossWethOut, redeemSpreadBps(kxIn));
        if (wethOut == 0) revert ZeroAmount();
        if (wethOut < minWethOut) revert SlippageExceeded();

        uint256 pulledFromStrategy;
        uint256 executionCostWeth;
        uint256 idle = weth.balanceOf(address(this));
        if (wethOut > idle) {
            if (strategy == address(0)) revert StrategyNotSet();
            (pulledFromStrategy, executionCostWeth) =
                IKxETH5XStrategy(strategy).withdrawForRedeem(wethOut - idle, address(this), maxExecutionCostBps, strategyData);
        }
        if (wethOut > weth.balanceOf(address(this))) revert InsufficientIdleBuffer();

        kxToken.burn(msg.sender, kxIn);
        weth.safeTransfer(receiver, wethOut);
        emit RedeemedWithStrategy(msg.sender, receiver, kxIn, wethOut, nav, pulledFromStrategy, executionCostWeth);
    }

    function _freezeAndGetNav() internal returns (uint256 nav) {
        if (_navSnapshotBlock == block.number) return _navSnapshot;
        nav = _currentNav();
        _navSnapshot = nav;
        _navSnapshotBlock = block.number;
        emit NavFrozen(nav, block.number);
    }

    function _currentNav() internal view returns (uint256) {
        if (!strategyNavEnabled) return _navStorage;
        uint256 totalKx = kxToken.totalSupply();
        if (totalKx == 0) return _navStorage;
        return Math.mulDiv(totalAssetsWeth(), NAV_PRECISION, totalKx);
    }

    function _maxImmediateDeposit() internal view returns (uint256) {
        uint256 currentAssetsWeth = totalAssetsWeth();
        if (currentAssetsWeth >= depositCap) return 0;
        uint256 capRemaining = depositCap - currentAssetsWeth;
        if (currentAssetsWeth == 0 || !strategyNavEnabled) return capRemaining;
        uint256 tvlCap = Math.mulDiv(currentAssetsWeth, maxDepositTvlBps, BPS_DENOMINATOR);
        return capRemaining < tvlCap ? capRemaining : tvlCap;
    }

    function _assetsAfterSpread(uint256 amount, uint256 spreadBps) internal pure returns (uint256) {
        return Math.mulDiv(amount, BPS_DENOMINATOR - spreadBps, BPS_DENOMINATOR);
    }
}
