// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title STRANDMainnet
/// @notice Legacy-named production-shape WoolFi protocol token. Same hard cap and same role-gated
///         mint as the simpler {STRAND} used on testnet, plus the two extensions a utility/governance
///         token actually needs: ERC-2612 permit (gasless approvals) and ERC-20 Votes
///         (snapshot voting power, delegation, historical balance queries — prerequisite for the
///         v2 on-chain {Governor} per PROJECT_SPEC.md §7.4).
/// @dev NOT deployed anywhere yet. Lives in the repo so auditors and partners can review the
///      actual mainnet contract; the testnet currently runs `src/STRAND.sol` for iteration speed.
///
///      Distribution pattern (spec §7.2):
///        1. Owner = multisig at genesis
///        2. Multisig mints into the four vesting buckets + airdrop + presale (total ≤ 100M)
///        3. Multisig calls {Ownable-renounceOwnership} to permanently disable further minting
///        4. From then on, supply only decreases (via {burn})
///
///      Voting clock: defaults to `block.number` mode (ERC20Votes default). The on-chain Governor
///      reads block-number snapshots; if a Governor needs `block.timestamp` mode (cross-chain
///      governance, etc) it requires deploying with a clock override — out of scope for v1.
contract STRANDMainnet is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /// @notice Hard cap on total supply: 100,000,000 STRAND (spec §7.1).
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    /// @notice Thrown when a mint would push total supply above {MAX_SUPPLY}.
    error CapExceeded();

    constructor(address initialOwner)
        ERC20("Strand", "STRAND")
        ERC20Permit("Strand") // EIP-712 domain name; used by permit signature verification
        Ownable(initialOwner)
    {}

    /// @notice Mint STRAND into a distribution bucket. Owner-only; reverts past the fixed cap.
    /// @dev After the final distribution mint, call {renounceOwnership} to permanently lock supply.
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) revert CapExceeded();
        _mint(to, amount);
    }

    /// @notice Burn the caller's STRAND. No special access; total supply decreases permanently.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ------------------------------------------------------------------- //
    //              OZ v5 multi-parent disambiguation overrides            //
    // ------------------------------------------------------------------- //

    /// @dev Inherited from ERC20 + ERC20Votes; ERC20Votes wants to update voting power on every
    ///      transfer, so both parents' update logic must run.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @dev Both ERC20Permit and Nonces define `nonces(address)`; this is the single source.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
