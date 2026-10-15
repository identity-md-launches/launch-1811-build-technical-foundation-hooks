// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TestToken} from "./TestToken.sol";

/// @dev Test-only unlock/settlement driver. No approvals required by the hook itself.
contract PoolRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Action {
        address payer;
        PoolKey key;
        bool isSwap;
        bool skipSettlement;
        IPoolManager.SwapParams swapParams;
        IPoolManager.ModifyLiquidityParams liquidityParams;
        bytes hookData;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hookData, bool skipSettlement)
        external
        returns (BalanceDelta)
    {
        Action memory action;
        action.payer = msg.sender;
        action.key = key;
        action.isSwap = true;
        action.skipSettlement = skipSettlement;
        action.swapParams = params;
        action.hookData = hookData;
        return abi.decode(manager.unlock(abi.encode(action)), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, int256 amount) external returns (BalanceDelta) {
        Action memory action;
        action.payer = msg.sender;
        action.key = key;
        action.liquidityParams = IPoolManager.ModifyLiquidityParams(-120, 120, amount, bytes32(0));
        return abi.decode(manager.unlock(abi.encode(action)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        Action memory action = abi.decode(data, (Action));
        BalanceDelta delta;
        if (action.isSwap) {
            delta = manager.swap(action.key, action.swapParams, action.hookData);
        } else {
            (delta,) = manager.modifyLiquidity(action.key, action.liquidityParams, action.hookData);
        }
        if (!action.skipSettlement) {
            _settle(action.key.currency0, delta.amount0(), action.payer);
            _settle(action.key.currency1, delta.amount1(), action.payer);
        }
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer) private {
        if (delta < 0) {
            manager.sync(currency);
            require(TestToken(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(-int256(delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(int256(delta)));
        }
    }
}
