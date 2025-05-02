// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IStakingModule} from "./IStakingModule.sol";

interface ISFUSD is IERC165, IStakingModule {
    function mint(address to_, uint256 amount_) external;

    function burn(address from_, uint256 amount_) external;
}
