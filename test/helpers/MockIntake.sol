// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/imd/IIntake.sol";
import {TestToken} from "./TestToken.sol";

/// @dev Local stand-in for the Intake version 2: records each request, pulls exactly the price,
/// and calls the stored callback or failure function once, under the live 200,000 gas stipend,
/// inside a try. `v1` makes `requestWithFailure` revert as a version 1 intake does.
contract MockIntake is IIntake {
    struct Req {
        address payer;
        bytes32 action;
        bytes body;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        bool settled;
    }

    uint256 public constant STIPEND = 200_000;
    mapping(bytes32 action => mapping(address asset => uint256)) public prices;
    mapping(bytes32 => Req) public reqs;
    bytes32 public lastRequestId;
    uint256 internal nonce;
    bool public v1;
    bool public reuseIds;
    uint256 public unspent;
    /// @dev Nonzero: every ask reverts synchronously with this error, as the live Intake does for
    /// an unsold action (`ActionNotSold`) or a request it refuses before taking payment.
    bytes4 public refusal;

    error SynchronousRefusal(bytes4 code);

    event Requested(bytes32 indexed requestId, bytes32 action, bytes body);
    event Completed(bytes32 indexed requestId, bool called);

    function setPrice(bytes32 action, address asset, uint256 price) external {
        prices[action][asset] = price;
    }

    function setV1(bool on) external {
        v1 = on;
    }

    function setReuseIds(bool on) external {
        reuseIds = on;
    }

    /// @dev Adversarial quote/spend disagreement; zero preserves normal exact-payment behavior.
    function setUnspent(uint256 amount) external {
        unspent = amount;
    }

    function setRefusal(bytes4 code) external {
        refusal = code;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return prices[action][asset];
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32)
    {
        return _request(action, body, callback, bytes4(0), asset, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32) {
        require(!v1, "v1 has no requestWithFailure");
        return _request(action, body, callback, onFailure, asset, amount);
    }

    function _request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) internal returns (bytes32 id) {
        if (refusal != bytes4(0)) revert SynchronousRefusal(refusal);
        uint256 price = prices[action][asset];
        require(price != 0, "ActionNotSold");
        require(amount == price, "wrong amount");
        require(TestToken(asset).transferFrom(msg.sender, address(this), amount - unspent), "pull failed");
        id = reuseIds && lastRequestId != bytes32(0) ? lastRequestId : keccak256(abi.encode(address(this), ++nonce));
        reqs[id] = Req(msg.sender, action, body, callback.target, callback.selector, onFailure, false);
        lastRequestId = id;
        emit Requested(id, action, body);
    }

    function bodyOf(bytes32 id) external view returns (bytes memory) {
        return reqs[id].body;
    }

    /// @dev The writer's completion: callback with `selector ++ args`; a revert is recorded, not retried.
    function complete(bytes32 id, bytes calldata args) external returns (bool called) {
        Req storage r = reqs[id];
        require(r.target != address(0) && !r.settled, "not pending");
        r.settled = true;
        (called,) = r.target.call{gas: STIPEND}(bytes.concat(r.selector, args));
        emit Completed(id, called);
    }

    function fail(bytes32 id, uint8 status, bytes32 reason, uint16 agreed, uint16 answered)
        external
        returns (bool called)
    {
        Req storage r = reqs[id];
        require(r.target != address(0) && !r.settled && r.onFailure != bytes4(0), "not pending");
        r.settled = true;
        (called,) = r.target.call{gas: STIPEND}(
            abi.encodeWithSelector(r.onFailure, id, status, reason, agreed, answered, bytes(""))
        );
        emit Completed(id, called);
    }
}
