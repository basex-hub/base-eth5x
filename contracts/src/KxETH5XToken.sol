// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Share token for the ETH5X reserve vault. Mint/burn restricted to the owning vault.
contract KxETH5XToken is ERC20, Ownable {
    error ZeroAddress();

    constructor(address initialOwner) ERC20("ETH5X Reserve", "ETH5X") Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function mint(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
