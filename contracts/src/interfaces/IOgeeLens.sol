// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPowerEngine} from "./IPowerEngine.sol";
import {AccountView, MarketView, VaultView} from "../libs/OgeeTypes.sol";

interface IOgeeLens {
    function markets(IPowerEngine engine) external view returns (MarketView[] memory);

    function vault(IPowerEngine engine) external view returns (VaultView memory);

    function account(IPowerEngine engine, address user) external view returns (AccountView memory);
}
