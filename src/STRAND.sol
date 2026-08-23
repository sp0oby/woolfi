// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title STRAND
/// @notice Legacy-named WoolFi protocol token. Fixed-cap ERC-20 with owner-controlled minting (for the
///         distribution schedule) and permissionless burning (PROJECT_SPEC.md §7).
/// @dev No inflation beyond {MAX_SUPPLY}. The owner (governance/multisig) mints into the
///      distribution buckets; once minted there is no further supply expansion.
contract STRAND is ERC20, Ownable {
    /// @notice Hard cap on total supply: 100,000,000 STRAND (spec §7.1).
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    /// @notice Thrown when a mint would push total supply above {MAX_SUPPLY}.
    error CapExceeded();

    constructor(address initialOwner) ERC20("Strand", "STRAND") Ownable(initialOwner) {}

    /// @notice Mint new STRAND, subject to the fixed cap. Owner-only.
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }

    /// @notice Burn the caller's STRAND. No special access.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
