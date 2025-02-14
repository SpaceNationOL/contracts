// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OIK Token Contract
 * @author
 * @notice Implements an ERC20 token including minting, burning functions.
 */
contract OIK is ERC20, ERC20Burnable, Ownable {
    /**
     * @notice The maximum supply of the token
     */
    uint256 public immutable MAX_SUPPLY;

    /**
     * @notice Custom decimals for the token
     */
    uint8 private immutable CUSTOM_DECIMALS;

    /**
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param maxSupply The maximum supply of the token
     * @param customDecimals The custom decimals for the token
     */
    constructor(
        string memory name,
        string memory symbol,
        uint256 maxSupply,
        uint8 customDecimals
    ) ERC20(name, symbol) {
        require(maxSupply > 0, "MAX_SUPPLY_MUST_THAN_0");
        MAX_SUPPLY = maxSupply;
        CUSTOM_DECIMALS = customDecimals;
    }

    /**
     * @notice Returns the decimals of the token
     * @return The number of decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return CUSTOM_DECIMALS;
    }

    /**
     * @notice Mints new tokens to a specified address
     * @dev Can only be called by contract owners
     * @param to The address to receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) public onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "EXCEED_MAX_SUPPLY");
        _mint(to, amount);
    }
}
