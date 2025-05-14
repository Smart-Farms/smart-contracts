// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import {StakingModule} from "./StakingModule.sol";

import {ISFUSD} from "./interfaces/ISFUSD.sol";
import {IStakingModule} from "./interfaces/IStakingModule.sol";

/**
 * @title sfUSD Token
 * @notice An ERC20 token that automatically stakes user balances to earn rewards.
 * @dev Inherits from `StakingModule` to integrate its logic directly. Overrides ERC20 behavior
 * (`balanceOf`, `_update`) to manage staking/unstaking during transfers, mints, and burns.
 * Users hold a single `sfUSD` balance, representing the sum of their liquid (standard ERC20) and staked amounts.
 */
contract sfUSD is ISFUSD, ERC165, StakingModule, ERC20Upgradeable, UUPSUpgradeable {
    /**
     * @dev Disables initializers to prevent initialization of implementation.
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the sfUSD contract.
     * @param name_ The name of the token
     * @param symbol_ The symbol of the token
     * @param rewardToken_ The address of the ERC20 token used for staking rewards.
     */
    function __sfUSD_init(string memory name_, string memory symbol_, address rewardToken_) external initializer {
        __StakingModule_init(rewardToken_);

        __ERC20_init(name_, symbol_);
        __Ownable_init(_msgSender());
    }

    /**
     * @inheritdoc ISFUSD
     */
    function mint(address to_, uint256 amount_) external onlyOwner {
        _mint(to_, amount_);
    }

    /**
     * @inheritdoc ISFUSD
     */
    function burn(address from_, uint256 amount_) external onlyOwner {
        _burn(from_, amount_);
    }

    /**
     * @notice Gets the total balance of an account, including both liquid and staked tokens.
     * @inheritdoc IERC20
     * @dev Overrides the standard `balanceOf` to provide a unified view of the user's holdings.
     * @param account The address to query the balance of.
     * @return The total balance (liquid + staked).
     */
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + getUserStake(account);
    }

    /**
     * @inheritdoc ERC165
     */
    function supportsInterface(bytes4 interfaceId_) public view override(IERC165, ERC165) returns (bool) {
        return
            interfaceId_ == type(IERC20).interfaceId ||
            interfaceId_ == type(ISFUSD).interfaceId ||
            interfaceId_ == type(IERC6372).interfaceId ||
            interfaceId_ == type(IStakingModule).interfaceId ||
            super.supportsInterface(interfaceId_);
    }

    /**
     * @notice Returns the current implementation address for the UUPS proxy.
     */
    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /**
     * @dev Internal hook called by `_stake` and `_unstake` in the inherited `StakingModule`.
     *      Implements the required token transfer logic for staking/unstaking operations.
     * @inheritdoc StakingModule
     * @param from Address sending the sfUSD token (user for unstake, contract for stake).
     * @param to Address receiving the sfUSD token (contract for unstake, user for stake).
     * @param value Amount of sfUSD being transferred between liquid and staked state.
     */
    function _sfUSDTransfer(address from, address to, uint256 value) internal override {
        // This hook is called *after* StakingModule has updated its shares.
        super._update(from, to, value);
    }

    /**
     * @inheritdoc ERC20Upgradeable
     * @notice This is the central mechanism linking transfers/mints/burns to the staking module.
     * Handles unstaking if `from_` balance is insufficient and staking on mints/transfers-in.
     */
    function _update(address from_, address to_, uint256 value_) internal override {
        require(value_ <= type(uint200).max, ValueTooHigh(value_, type(uint200).max));

        if (from_ != address(0)) {
            uint256 fromBalance_ = balanceOf(from_);

            require(fromBalance_ >= value_, ERC20InsufficientBalance(from_, fromBalance_, value_));

            uint256 fromLiquidBalance_ = super.balanceOf(from_);
            if (fromLiquidBalance_ < value_) {
                _unstake(from_, value_ - fromLiquidBalance_);
            }
        }

        super._update(from_, to_, value_);

        if (from_ == address(0) && to_ != address(0)) {
            _stake(to_, value_);
        }
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
