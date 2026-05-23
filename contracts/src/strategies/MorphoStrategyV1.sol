// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorphoBlue, MorphoMarketId, MorphoMarketParams, MorphoMarketParamsLib, MorphoPosition} from "../interfaces/IMorphoBlue.sol";
import {IKxETH5XStrategy} from "../interfaces/IKxETH5XStrategy.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

interface IChainlinkAggregatorLike {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Morpho-backed WETH/USDC strategy for kxETH5X.
/// @dev It keeps leverage operations keeper-triggered; deposits from the vault only supply new idle WETH as collateral.
contract MorphoStrategyV1 is IKxETH5XStrategy, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MorphoMarketParamsLib for MorphoMarketParams;

    uint256 public constant BPS = 10_000;
    uint256 public constant ETH_USD_FEED_DECIMALS = 8;

    IMorphoBlue public immutable morpho;
    IERC20 public immutable weth;
    IERC20 public immutable usdc;
    IChainlinkAggregatorLike public immutable ethUsdOracle;
    MorphoMarketParams public marketParams;
    MorphoMarketId public immutable marketId;

    address public vault;
    address public keeper;
    ISwapAdapter public swapAdapter;
    uint256 public maxLtvBps;
    uint256 public targetLeverageBps;
    uint256 public maxOracleStalenessSeconds = 1 hours;

    event VaultSet(address indexed vault);
    event KeeperSet(address indexed keeper);
    event SwapAdapterSet(address indexed swapAdapter);
    event RiskParamsSet(uint256 maxLtvBps, uint256 targetLeverageBps);
    event OracleStalenessSet(uint256 maxOracleStalenessSeconds);
    event DepositedToMorpho(uint256 wethAmount);
    event WithdrawnFromMorpho(uint256 wethAmount, address indexed receiver);
    event RedeemWithdrawnFromMorpho(uint256 wethRequested, uint256 wethWithdrawn, uint256 executionCostWeth, address indexed receiver);
    event Rebalanced(uint256 usdcBorrowed, uint256 wethAdded);
    event UsdcRepaid(uint256 usdcRepaid);
    event IdleUsdcConvertedToWeth(uint256 usdcIn, uint256 wethOut);
    event EmergencyDeleveraged(uint256 wethSold, uint256 usdcRepaid);

    error ZeroAddress();
    error Unauthorized();
    error InvalidRiskParams();
    error BadOraclePrice();
    error StaleOraclePrice();
    error SlippageExceeded();
    error LtvTooHigh();
    error ExecutionCostTooHigh();

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrKeeper() {
        if (msg.sender != owner() && msg.sender != keeper) revert Unauthorized();
        _;
    }

    constructor(
        address initialOwner,
        IMorphoBlue morpho_,
        IERC20 weth_,
        IERC20 usdc_,
        IChainlinkAggregatorLike ethUsdOracle_,
        ISwapAdapter swapAdapter_,
        MorphoMarketParams memory marketParams_,
        uint256 maxLtvBps_,
        uint256 targetLeverageBps_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || address(morpho_) == address(0) || address(weth_) == address(0)
                || address(usdc_) == address(0) || address(ethUsdOracle_) == address(0) || address(swapAdapter_) == address(0)
        ) revert ZeroAddress();
        if (marketParams_.loanToken != address(usdc_) || marketParams_.collateralToken != address(weth_)) revert ZeroAddress();
        morpho = morpho_;
        weth = weth_;
        usdc = usdc_;
        ethUsdOracle = ethUsdOracle_;
        swapAdapter = swapAdapter_;
        marketParams = marketParams_;
        marketId = marketParams_.id();
        _setRiskParams(maxLtvBps_, targetLeverageBps_);
    }

    function asset() external view returns (address) {
        return address(weth);
    }

    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setSwapAdapter(ISwapAdapter swapAdapter_) external onlyOwner {
        if (address(swapAdapter_) == address(0)) revert ZeroAddress();
        swapAdapter = swapAdapter_;
        emit SwapAdapterSet(address(swapAdapter_));
    }

    function setRiskParams(uint256 maxLtvBps_, uint256 targetLeverageBps_) external onlyOwner {
        _setRiskParams(maxLtvBps_, targetLeverageBps_);
    }

    function setOracleStalenessSeconds(uint256 maxOracleStalenessSeconds_) external onlyOwner {
        if (maxOracleStalenessSeconds_ == 0) revert InvalidRiskParams();
        maxOracleStalenessSeconds = maxOracleStalenessSeconds_;
        emit OracleStalenessSet(maxOracleStalenessSeconds_);
    }

    function deposit(uint256 wethAmount) external onlyVault nonReentrant {
        if (wethAmount == 0) return;
        weth.safeTransferFrom(msg.sender, address(this), wethAmount);
        weth.forceApprove(address(morpho), wethAmount);
        morpho.supplyCollateral(marketParams, wethAmount, address(this), hex"");
        weth.forceApprove(address(morpho), 0);
        emit DepositedToMorpho(wethAmount);
    }

    function withdraw(uint256 wethAmount, address receiver) external onlyVault nonReentrant returns (uint256 withdrawn) {
        if (receiver == address(0)) revert ZeroAddress();
        if (wethAmount == 0) return 0;

        uint256 idleWeth = weth.balanceOf(address(this));
        uint256 fromIdle = wethAmount < idleWeth ? wethAmount : idleWeth;
        if (fromIdle != 0) {
            weth.safeTransfer(receiver, fromIdle);
            withdrawn += fromIdle;
        }

        uint256 remaining = wethAmount - fromIdle;
        if (remaining != 0) {
            morpho.withdrawCollateral(marketParams, remaining, address(this), receiver);
            withdrawn += remaining;
            _revertIfLtvTooHigh();
        }
        emit WithdrawnFromMorpho(withdrawn, receiver);
    }

    /// @notice User-triggered redeem primitive used by the vault when idle WETH is insufficient.
    /// @dev `unwindData` may encode `(uint256 wethToDeleverage, uint256 minUsdcOut, bytes swapData)`.
    ///      If supplied, the strategy first sells that WETH amount for USDC and repays debt, then withdraws
    ///      the requested WETH. The caller caps NAV leakage with `maxExecutionCostBps`.
    function withdrawForRedeem(uint256 wethAmount, address receiver, uint256 maxExecutionCostBps, bytes calldata unwindData)
        external
        onlyVault
        nonReentrant
        returns (uint256 withdrawn, uint256 executionCostWeth)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (wethAmount == 0) return (0, 0);
        if (maxExecutionCostBps > BPS) revert InvalidRiskParams();

        uint256 assetsBefore = totalAssetsWeth();

        if (unwindData.length != 0) {
            (uint256 wethToDeleverage, uint256 minUsdcOut, bytes memory swapData) =
                abi.decode(unwindData, (uint256, uint256, bytes));
            if (wethToDeleverage != 0) {
                morpho.withdrawCollateral(marketParams, wethToDeleverage, address(this), address(this));
                weth.forceApprove(address(swapAdapter), wethToDeleverage);
                uint256 usdcOut = swapAdapter.swapExactIn(address(weth), address(usdc), wethToDeleverage, minUsdcOut, swapData);
                weth.forceApprove(address(swapAdapter), 0);
                if (usdcOut < minUsdcOut) revert SlippageExceeded();
                uint256 repaid = _repayWithAvailableUsdc(usdcOut);
                emit EmergencyDeleveraged(wethToDeleverage, repaid);
            }
        }

        withdrawn = _withdrawAvailableWeth(wethAmount, receiver);
        if (withdrawn < wethAmount) revert SlippageExceeded();
        _revertIfLtvTooHigh();

        uint256 assetsAfter = totalAssetsWeth();
        uint256 allowedCost = Math.mulDiv(wethAmount, maxExecutionCostBps, BPS);
        if (assetsBefore > assetsAfter + withdrawn) {
            executionCostWeth = assetsBefore - assetsAfter - withdrawn;
            if (executionCostWeth > allowedCost) revert ExecutionCostTooHigh();
        }

        emit RedeemWithdrawnFromMorpho(wethAmount, withdrawn, executionCostWeth, receiver);
    }

    function rebalance(uint256 borrowUsdcAmount, uint256 minWethOut, bytes calldata swapData)
        external
        onlyOwnerOrKeeper
        nonReentrant
        returns (uint256 wethAdded)
    {
        if (borrowUsdcAmount == 0) return 0;
        morpho.accrueInterest(marketParams);
        (uint256 borrowed,) = morpho.borrow(marketParams, borrowUsdcAmount, 0, address(this), address(this));
        usdc.forceApprove(address(swapAdapter), borrowed);
        wethAdded = swapAdapter.swapExactIn(address(usdc), address(weth), borrowed, minWethOut, swapData);
        usdc.forceApprove(address(swapAdapter), 0);
        if (wethAdded < minWethOut) revert SlippageExceeded();
        weth.forceApprove(address(morpho), wethAdded);
        morpho.supplyCollateral(marketParams, wethAdded, address(this), hex"");
        weth.forceApprove(address(morpho), 0);
        _revertIfLtvTooHigh();
        emit Rebalanced(borrowed, wethAdded);
    }

    function repayWithUsdc(uint256 usdcAmount) external onlyOwnerOrKeeper nonReentrant returns (uint256 repaid) {
        repaid = _repayWithAvailableUsdc(usdcAmount);
        emit UsdcRepaid(repaid);
    }

    function emergencyDeleverage(uint256 wethToSwap, uint256 minUsdcOut, bytes calldata swapData)
        external
        onlyOwnerOrKeeper
        nonReentrant
        returns (uint256 repaid)
    {
        if (wethToSwap == 0) return 0;
        morpho.withdrawCollateral(marketParams, wethToSwap, address(this), address(this));
        weth.forceApprove(address(swapAdapter), wethToSwap);
        uint256 usdcOut = swapAdapter.swapExactIn(address(weth), address(usdc), wethToSwap, minUsdcOut, swapData);
        weth.forceApprove(address(swapAdapter), 0);
        if (usdcOut < minUsdcOut) revert SlippageExceeded();
        repaid = _repayWithAvailableUsdc(usdcOut);
        _revertIfLtvTooHigh();
        emit EmergencyDeleveraged(wethToSwap, repaid);
    }


    function _repayWithAvailableUsdc(uint256 maxUsdcAmount) internal returns (uint256 repaid) {
        if (maxUsdcAmount == 0) return 0;
        morpho.accrueInterest(marketParams);

        MorphoPosition memory position = morpho.position(marketId, address(this));
        if (position.borrowShares == 0) return 0;

        uint256 amount = maxUsdcAmount;
        uint256 balance = usdc.balanceOf(address(this));
        if (amount > balance) amount = balance;
        if (amount == 0) return 0;

        uint256 debt = totalDebtUsdc();
        usdc.forceApprove(address(morpho), amount);
        if (amount >= debt) {
            // Close by shares when enough USDC is available. This avoids Morpho rounding dust
            // where asset-based repayment can leave one last borrow-share that cannot be repaid cleanly.
            (repaid,) = morpho.repay(marketParams, 0, position.borrowShares, address(this), hex"");
        } else {
            (repaid,) = morpho.repay(marketParams, amount, 0, address(this), hex"");
        }
        usdc.forceApprove(address(morpho), 0);
    }

    function _withdrawAvailableWeth(uint256 wethAmount, address receiver) internal returns (uint256 withdrawn) {
        uint256 idleWeth = weth.balanceOf(address(this));
        uint256 fromIdle = wethAmount < idleWeth ? wethAmount : idleWeth;
        if (fromIdle != 0) {
            weth.safeTransfer(receiver, fromIdle);
            withdrawn += fromIdle;
        }

        uint256 remaining = wethAmount - fromIdle;
        if (remaining != 0) {
            morpho.withdrawCollateral(marketParams, remaining, address(this), receiver);
            withdrawn += remaining;
        }
    }


    function convertIdleUsdcToWeth(uint256 usdcAmount, uint256 minWethOut, bytes calldata swapData)
        external
        onlyOwnerOrKeeper
        nonReentrant
        returns (uint256 wethOut)
    {
        uint256 amount = usdcAmount;
        uint256 balance = usdc.balanceOf(address(this));
        if (amount > balance) amount = balance;
        if (amount == 0) return 0;
        usdc.forceApprove(address(swapAdapter), amount);
        wethOut = swapAdapter.swapExactIn(address(usdc), address(weth), amount, minWethOut, swapData);
        usdc.forceApprove(address(swapAdapter), 0);
        if (wethOut < minWethOut) revert SlippageExceeded();
        emit IdleUsdcConvertedToWeth(amount, wethOut);
    }

    function totalCollateralWeth() public view returns (uint256) {
        return morpho.position(marketId, address(this)).collateral;
    }

    function totalDebtUsdc() public view returns (uint256) {
        uint256 borrowShares = morpho.position(marketId, address(this)).borrowShares;
        if (borrowShares == 0) return 0;
        uint256 totalBorrowShares = morpho.market(marketId).totalBorrowShares;
        uint256 totalBorrowAssets = morpho.market(marketId).totalBorrowAssets;
        if (totalBorrowShares == 0) return 0;
        return Math.mulDiv(borrowShares, totalBorrowAssets, totalBorrowShares, Math.Rounding.Ceil);
    }

    function totalAssetsWeth() public view returns (uint256) {
        uint256 assetsWeth = totalCollateralWeth() + weth.balanceOf(address(this)) + _usdcToWeth(usdc.balanceOf(address(this)));
        uint256 debtWeth = _usdcToWeth(totalDebtUsdc());
        if (debtWeth >= assetsWeth) return 0;
        return assetsWeth - debtWeth;
    }

    function currentLtvBps() public view returns (uint256) {
        uint256 collateral = totalCollateralWeth();
        if (collateral == 0) return 0;
        return Math.mulDiv(_usdcToWeth(totalDebtUsdc()), BPS, collateral);
    }

    function _setRiskParams(uint256 maxLtvBps_, uint256 targetLeverageBps_) internal {
        if (maxLtvBps_ == 0 || maxLtvBps_ >= BPS || targetLeverageBps_ < BPS) revert InvalidRiskParams();
        maxLtvBps = maxLtvBps_;
        targetLeverageBps = targetLeverageBps_;
        emit RiskParamsSet(maxLtvBps_, targetLeverageBps_);
    }

    function _revertIfLtvTooHigh() internal view {
        if (currentLtvBps() > maxLtvBps) revert LtvTooHigh();
    }

    function _usdcToWeth(uint256 usdcAmount) internal view returns (uint256) {
        if (usdcAmount == 0) return 0;
        (, int256 answer,, uint256 updatedAt,) = ethUsdOracle.latestRoundData();
        if (answer <= 0) revert BadOraclePrice();
        if (updatedAt == 0 || block.timestamp - updatedAt > maxOracleStalenessSeconds) revert StaleOraclePrice();
        return Math.mulDiv(usdcAmount, 10 ** (18 + ETH_USD_FEED_DECIMALS - 6), uint256(answer));
    }
}
