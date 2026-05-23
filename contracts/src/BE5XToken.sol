// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {BE5XConstants} from "./libraries/BE5XConstants.sol";
import {BE5XProjectMetadata} from "./libraries/BE5XProjectMetadata.sol";

/// @notice BaseX meme token. Fixed supply is minted once to the launch inventory recipient.
contract BE5XToken is ERC20, ERC20Burnable {
    constructor(address initialSupplyRecipient) ERC20("BaseX", "BASEX") {
        if (initialSupplyRecipient == address(0)) revert ZeroAddress();
        _mint(initialSupplyRecipient, BE5XConstants.TOTAL_SUPPLY);
    }

    function projectIdentity()
        external
        pure
        returns (
            string memory projectName,
            string memory tokenSymbol_,
            string memory leveragedTokenSymbol,
            string memory websiteUrl,
            string memory xUrl,
            string memory whitepaperUrl,
            string memory mechanism
        )
    {
        return (
            BE5XProjectMetadata.PROJECT_NAME,
            BE5XProjectMetadata.TOKEN_SYMBOL,
            BE5XProjectMetadata.LEVERAGED_TOKEN_SYMBOL,
            BE5XProjectMetadata.OFFICIAL_WEBSITE,
            BE5XProjectMetadata.OFFICIAL_X,
            BE5XProjectMetadata.WHITEPAPER_URI,
            BE5XProjectMetadata.MECHANISM
        );
    }

    function officialWebsite() external pure returns (string memory) {
        return BE5XProjectMetadata.OFFICIAL_WEBSITE;
    }

    function officialX() external pure returns (string memory) {
        return BE5XProjectMetadata.OFFICIAL_X;
    }

    error ZeroAddress();
}
