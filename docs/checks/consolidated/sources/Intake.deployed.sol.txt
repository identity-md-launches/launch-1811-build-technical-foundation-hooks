// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title The swarm's door on a chain: one transaction buys work
/// @notice A payer sends the price, the ask and, if it wants one, a contract and function to call
/// with the result. The contract holds nothing: every payment is forwarded to `payTo` in the same
/// call, and what it keeps is a record of who asked and where the answer goes.
///
/// Two ways in:
///
/// - `request(action, body, callback, asset, amount)` carries the whole ask. `action` names a paid
///   action and its version as one right-padded string, the action, an at sign and the version
///   (`oracle.request`, `oracle-1`); `body` is the
///   same JSON the HTTP door takes for that action, as UTF-8 bytes. The price is the one set here
///   for that action and asset, so a short payment reverts instead of landing in `payTo`.
/// - `pay(quoteHash, asset, amount, expiresAt, signature)` settles an ask that was quoted off
///   chain, for a body a human wrote. The plane signed the terms; the contract checks them, so a
///   wrong asset, a short amount or a stale quote reverts too.
///
/// The body travels in the `Requested` event, whole. A contract that calls `request` from inside
/// its own function is the usual caller, and its transaction's input is that function, not this
/// one; the event is the one place the body can be read back from whoever sent it.
///
/// One way out. When the work ends the plane's writer calls `complete`, which records the result
/// hash and its URL and, when the request named a callback, calls it once with a fixed gas stipend
/// inside a try. A callback that reverts or runs out of gas cannot block the write and costs the
/// network nothing beyond that stipend; the result is still readable by the request's transaction.
///
/// A request made with `requestWithFailure` also names a second function on the same target, called
/// the same way when the plane refused the ask or the work ended without a result:
/// `onFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered,
/// bytes signature)`. The payer commits to that selector in its own call, so the writer can never
/// choose which of the payer's functions it reaches; it supplies only the arguments, and the
/// contract checks that they name this request and this status.
///
/// Version 2. Every function, event and getter of version 1 is here unchanged, so a contract or a
/// service written for version 1 works against this one at its new address; `requestWithFailure`,
/// `failureSelectorOf` and `FailureHookSet` are what is new.
///
/// @dev Deployed through CREATE2 with the same salt and constructor arguments on every chain, so
/// the address a contract author stores is the same everywhere. An `action` whose price is zero
/// is not sold: retiring a version is `setPrice(action, asset, 0)`, after which a stale caller
/// loses gas and nothing else. Ownership moves in two steps, so a mistyped owner cannot take the
/// price list, the treasury or the writer with it.
contract Intake is Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;

    struct Callback {
        address target;
        bytes4 selector;
    }

    struct Request {
        address payer;
        address callbackTarget;
        bytes4 callbackSelector;
        bool completed;
    }

    /// @dev The largest body accepted, in bytes. A job draft is a few kilobytes; a request that
    /// needs more carries a pointer in the body instead.
    uint256 public constant MAX_BODY_BYTES = 16_384;
    /// @dev Gas kept back for the rest of `complete` once the callback returns: the event and the
    /// call's own overhead.
    uint256 internal constant CALLBACK_RESERVE = 20_000;
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(bytes32 quoteHash,address asset,uint256 amount,uint64 expiresAt)");

    error ActionNotSold(bytes32 action, address asset);
    error PriceNotMet(uint256 price, uint256 amount);
    error EmptyBody();
    error BodyTooLong(uint256 length);
    error WrongValue(uint256 expected, uint256 sent);
    error QuoteExpired(uint64 expiresAt);
    error QuoteAlreadyPaid(bytes32 quoteHash);
    error BadQuoteSignature();
    error UnknownRequest(bytes32 requestId);
    error AlreadyCompleted(bytes32 requestId);
    error NotWriter();
    error CallbackGasShort(uint256 needed, uint256 left);
    error ZeroAddress();
    error ForwardFailed();
    error FailureHookWithoutTarget();
    error FailureArgsMismatch(bytes32 requestId, uint8 status);

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );
    /// @notice Emitted beside `Requested` by `requestWithFailure`: the function the target is called
    /// on when the request is refused or fails.
    event FailureHookSet(bytes32 indexed requestId, bytes4 selector);
    event Paid(bytes32 indexed quoteHash, address indexed payer, address asset, uint256 amount);
    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);
    event PriceSet(bytes32 indexed action, address indexed asset, uint256 amount);
    event PayToSet(address indexed payTo);
    event WriterSet(address indexed writer);
    event SignerSet(address indexed signer);
    event CallbackGasSet(uint64 gas);

    /// @notice Where every payment goes, in the same call that made it.
    address public payTo;
    /// @notice The plane's writer: the only caller of `complete`.
    address public writer;
    /// @notice The key the plane signs off-chain quotes with, checked by `pay`.
    address public signer;
    /// @notice The gas a callback is given. Fixed so a hostile target costs a known amount.
    uint64 public callbackGas = 200_000;
    /// @notice Price per action and asset; zero means the action is not sold in that asset here.
    /// The native coin is `address(0)`.
    mapping(bytes32 action => mapping(address asset => uint256 amount)) public priceOf;
    mapping(bytes32 requestId => Request) public requests;
    /// @notice The callback target's function for a refusal or a failure; zero when the request
    /// named none. Kept apart from `requests` so that getter reads as it did in version 1.
    mapping(bytes32 requestId => bytes4 selector) public failureSelectorOf;
    mapping(bytes32 quoteHash => bool paid) public paidQuotes;
    uint256 public nonce;

    constructor(address owner_, address payTo_, address writer_, address signer_)
        Ownable(owner_)
        EIP712("IdentityMD Intake", "1")
    {
        if (payTo_ == address(0) || writer_ == address(0) || signer_ == address(0)) revert ZeroAddress();
        payTo = payTo_;
        writer = writer_;
        signer = signer_;
        emit PayToSet(payTo_);
        emit WriterSet(writer_);
        emit SignerSet(signer_);
    }

    // ---- the way in ----

    /// @notice Buys one action with the ask on chain. Reverts below the action's price.
    /// @param action The paid action and its version as one right-padded string: the action, an at
    /// sign, the version.
    /// @param body The action's request body, the JSON the HTTP door takes, as UTF-8 bytes.
    /// @param callback Where the result goes; a zero target means nowhere on chain.
    /// @param asset The asset paid in; `address(0)` is the native coin, sent as `msg.value`.
    /// @param amount The amount paid; at least the price. Whatever is paid is forwarded whole.
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        requestId = _request(action, body, callback, bytes4(0), asset, amount);
    }

    /// @notice `request`, and a function on the callback's target to call if the ask is refused or
    /// the work ends without a result. The target is the callback's; a zero `onFailure` is `request`.
    /// @param onFailure The selector of `(bytes32 requestId, uint8 status, bytes32 reason,
    /// uint16 agreed, uint16 answered, bytes signature)` on `callback.target`.
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        if (onFailure != bytes4(0) && callback.target == address(0)) revert FailureHookWithoutTarget();
        requestId = _request(action, body, callback, onFailure, asset, amount);
    }

    function _request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) private returns (bytes32 requestId) {
        uint256 price = priceOf[action][asset];
        if (price == 0) revert ActionNotSold(action, asset);
        if (amount < price) revert PriceNotMet(price, amount);
        if (body.length == 0) revert EmptyBody();
        if (body.length > MAX_BODY_BYTES) revert BodyTooLong(body.length);
        // Recorded before the payment moves, so a treasury or token that calls back finds it done.
        requestId = keccak256(abi.encode(block.chainid, address(this), ++nonce));
        requests[requestId] = Request(msg.sender, callback.target, callback.selector, false);
        if (onFailure != bytes4(0)) failureSelectorOf[requestId] = onFailure;
        _collect(asset, amount);
        emit Requested(requestId, msg.sender, action, body, callback.target, callback.selector, asset, amount);
        if (onFailure != bytes4(0)) emit FailureHookSet(requestId, onFailure);
    }

    /// @notice Settles a quote the plane made off chain. The plane signed these exact terms.
    function pay(bytes32 quoteHash, address asset, uint256 amount, uint64 expiresAt, bytes calldata signature)
        external
        payable
    {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > expiresAt) revert QuoteExpired(expiresAt);
        if (paidQuotes[quoteHash]) revert QuoteAlreadyPaid(quoteHash);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, quoteDigest(quoteHash, asset, amount, expiresAt), signature)) {
            revert BadQuoteSignature();
        }
        paidQuotes[quoteHash] = true;
        _collect(asset, amount);
        emit Paid(quoteHash, msg.sender, asset, amount);
    }

    /// @notice The EIP-712 digest the plane signs for `pay`: this chain, this contract, these terms.
    function quoteDigest(bytes32 quoteHash, address asset, uint256 amount, uint64 expiresAt) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, quoteHash, asset, amount, expiresAt)));
    }

    // ---- the way out ----

    /// @notice Records what became of a request and calls its callback once, if it named one: the
    /// result's function on status 0, the failure's on any other status.
    /// @param status 0 when the work produced a result, 1 when the plane refused the ask, 2 when
    /// the work ended without a result (a panel that disagreed, a job that failed).
    /// @param resultHash The hash of the document `uri` serves; zero when there is none.
    /// @param args The callback's arguments, ABI-encoded without the selector. The shape is the
    /// action's: an oracle answer is `(bytes32 requestId, Attestation a, bytes signature)`, a job
    /// result is `(bytes32 requestId, bytes32 resultHash, string uri)`. On a refusal or a failure it
    /// is `(bytes32 requestId, uint8 status, bytes32 reason, uint16 agreed, uint16 answered,
    /// bytes signature)`, and its first two words must be this request and this status; empty, the
    /// failure function is not called.
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external
    {
        if (msg.sender != writer) revert NotWriter();
        Request storage stored = requests[requestId];
        if (stored.payer == address(0)) revert UnknownRequest(requestId);
        if (stored.completed) revert AlreadyCompleted(requestId);
        stored.completed = true;
        bytes4 selector = stored.callbackSelector;
        if (status != 0) {
            selector = failureSelectorOf[requestId];
            // The writer chooses the arguments, never the function: the payer named the selector,
            // and the arguments must say which request and which outcome they are about.
            if (selector != bytes4(0) && args.length != 0) {
                if (args.length < 64 || bytes32(args[0:32]) != requestId || uint256(bytes32(args[32:64])) != status) {
                    revert FailureArgsMismatch(requestId, status);
                }
            } else {
                selector = bytes4(0);
            }
        }
        bool delivered;
        if ((status == 0 || selector != bytes4(0)) && stored.callbackTarget != address(0)) {
            // A fixed stipend, no value, and the outcome recorded rather than trusted: the target
            // is the payer's code, and a revert there is the payer's problem, not the writer's.
            // A call passes on at most 63/64 of the gas left, so a writer sending too little would
            // starve the callback and still mark it tried; refused here, `delivered == false` is
            // always the target's doing.
            uint256 stipend = callbackGas;
            uint256 needed = stipend + stipend / 63 + CALLBACK_RESERVE;
            if (gasleft() < needed) revert CallbackGasShort(needed, gasleft());
            bytes memory data = bytes.concat(selector, args);
            address target = stored.callbackTarget;
            // An address with no code would "succeed" at anything; it is recorded as not delivered.
            // No return data is copied, so a target cannot make the writer pay to read a large one.
            if (target.code.length > 0) {
                assembly ("memory-safe") {
                    delivered := call(stipend, target, 0, add(data, 0x20), mload(data), 0, 0)
                }
            }
        }
        emit Completed(requestId, status, resultHash, uri, delivered);
    }

    // ---- the operator ----

    function setPrice(bytes32 action, address asset, uint256 amount) external onlyOwner {
        priceOf[action][asset] = amount;
        emit PriceSet(action, asset, amount);
    }

    function setPayTo(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        payTo = to;
        emit PayToSet(to);
    }

    function setWriter(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        writer = to;
        emit WriterSet(to);
    }

    function setSigner(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        signer = to;
        emit SignerSet(to);
    }

    function setCallbackGas(uint64 gas) external onlyOwner {
        callbackGas = gas;
        emit CallbackGasSet(gas);
    }

    /// @dev Forwards the payment to `payTo` in the same call. Nothing is ever held here.
    function _collect(address asset, uint256 amount) private {
        if (asset == address(0)) {
            if (msg.value != amount) revert WrongValue(amount, msg.value);
            // The destination is the owner's `payTo`, never a caller's argument, and the amount is
            // the value this call arrived with: the contract forwards, it never holds or chooses.
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = payTo.call{value: amount}("");
            if (!ok) revert ForwardFailed();
        } else {
            if (msg.value != 0) revert WrongValue(0, msg.value);
            IERC20(asset).safeTransferFrom(msg.sender, payTo, amount);
        }
    }
}
