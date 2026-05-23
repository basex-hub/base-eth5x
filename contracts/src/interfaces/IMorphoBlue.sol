// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

type MorphoMarketId is bytes32;

struct MorphoMarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct MorphoPosition {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

interface IMorphoBlue {
    function supplyCollateral(MorphoMarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data) external;
    function withdrawCollateral(MorphoMarketParams memory marketParams, uint256 assets, address onBehalf, address receiver) external;
    function borrow(MorphoMarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    function repay(MorphoMarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);
    function accrueInterest(MorphoMarketParams memory marketParams) external;
    function position(MorphoMarketId id, address user) external view returns (MorphoPosition memory p);
    function market(MorphoMarketId id) external view returns (MorphoMarket memory m);
}

library MorphoMarketParamsLib {
    uint256 internal constant MARKET_PARAMS_BYTES_LENGTH = 5 * 32;

    function id(MorphoMarketParams memory marketParams) internal pure returns (MorphoMarketId marketParamsId) {
        assembly ("memory-safe") {
            marketParamsId := keccak256(marketParams, MARKET_PARAMS_BYTES_LENGTH)
        }
    }
}
