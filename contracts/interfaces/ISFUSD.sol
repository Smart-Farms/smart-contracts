// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IStakingModule} from "./IStakingModule.sol";

/**
 * @title ISFUSD Interface
 * @notice sfUSD combines standard token features with built-in staking. Holding sfUSD implies
 * staking it. Transfers automatically handle unstaking/staking as needed. It inherits
 * from IStakingModule, exposing all staking functions directly on the token contract.
 *
 * @dev The `balanceOf` function specifically is expected to return the *total* balance (liquid + staked).
 */
interface ISFUSD is IERC165, IStakingModule {
    /**
     * @notice Error reverted if a transfer, mint, or burn value exceeds the internal `uint200` limit.
     * @param value The value that exceeded the limit.
     * @param max The maximum allowed value (type(uint200).max).
     */
    error ValueTooHigh(uint256 value, uint208 max);

    /**
     * @notice Mints new sfUSD tokens and assigns them to a recipient.
     * @dev Restricted to an owner. The minted tokens are
     * automatically staked for the recipient via the integrated StakingModule logic.
     * @param to_ The address to receive the minted tokens.
     * @param amount_ The amount of sfUSD tokens to mint.
     */
    function mint(address to_, uint256 amount_) external;

    /**
     * @notice Burns sfUSD tokens from a specified account.
     * @dev Restricted to an owner. If the account's liquid balance
     * is insufficient, tokens are automatically unstaked from the StakingModule to fulfill the burn amount.
     * Requires the specified account to have sufficient total balance (liquid + staked).
     * @param from_ The address from which to burn tokens.
     * @param amount_ The amount of sfUSD tokens to burn.
     */
    function burn(address from_, uint256 amount_) external;
}
