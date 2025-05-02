// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {sfUSD} from "../sfUSD.sol";

contract sfUSDMock is sfUSD {
    function __StakingModule_direct_init() external {
        __StakingModule_init(msg.sender);
    }
}
