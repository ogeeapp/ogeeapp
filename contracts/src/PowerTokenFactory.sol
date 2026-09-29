// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PowerToken} from "./PowerToken.sol";

/// @notice Deploys per-market tokens without embedding their creation bytecode in PowerEngine.
contract PowerTokenFactory {
    function deployToken(string calldata name, string calldata symbol, address engine) external returns (PowerToken) {
        return new PowerToken(name, symbol, engine);
    }
}
