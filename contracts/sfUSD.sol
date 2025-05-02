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

contract sfUSD is ISFUSD, ERC165, StakingModule, ERC20Upgradeable, UUPSUpgradeable {
    error ValueTooHigh(uint256 value, uint208 max);

    constructor() {
        _disableInitializers();
    }

    function __sfUSD_init(string memory name_, string memory symbol_, address rewardToken_) external initializer {
        __StakingModule_init(rewardToken_);

        __ERC20_init(name_, symbol_);
        __Ownable_init(_msgSender());
    }

    function mint(address to_, uint256 amount_) external onlyOwner {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external onlyOwner {
        _burn(from_, amount_);
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) + getUserStake(account);
    }

    // from and to here are guaranteed to be non-zero
    function _sfUSDTransfer(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
    }

    function _update(address from_, address to_, uint256 value_) internal override {
        require(value_ <= type(uint200).max, ValueTooHigh(value_, type(uint200).max));

        if (from_ != address(0)) {
            uint256 fromBalance_ = balanceOf(from_);

            require(fromBalance_ >= value_, ERC20InsufficientBalance(from_, fromBalance_, value_));

            uint256 userBalanceRaw_ = super.balanceOf(from_);
            if (userBalanceRaw_ < value_) {
                _unstake(from_, value_ - userBalanceRaw_);
            }
        }

        super._update(from_, to_, value_);

        if (from_ == address(0) && to_ != address(0)) {
            _stake(to_, value_);
        }
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

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function implementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }
}
