// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {Math512} from "./Math512.sol";
import {MockERC20} from "./MockERC20.sol";
import {SpotPool} from "./SpotPool.sol";

// Deadlines and witness ages use chain time by contract. The skew allowance bounds acceptable evidence.
// forge-lint: disable-start(block-timestamp)
contract BorrowGate is AbstractCallback {
  enum Status {
    NONE,
    PENDING,
    HELD,
    SETTLED,
    CANCELLED,
    EXPIRED
  }

  struct Request {
    address borrower;
    uint256 requestedAmount;
    uint256 minAcceptableAmount;
    uint256 reservedCollateral;
    uint256 disbursedAmount;
    uint256 keptCollateral;
    uint256 lastEffectivePrice;
    uint64 createdAt;
    uint64 deadline;
    uint32 lastRevision;
    Status status;
  }

  error UseAsyncRequestBorrow();
  error InsufficientCollateral();
  error NotBorrower();
  error NotExpired();
  error RequestNotOpen();
  error InvalidRequest();
  error HoldLimitReached();
  error InvalidConfiguration();
  error InvalidAmount();
  error UnavailablePrice();

  event BorrowRequested(
    bytes32 indexed requestId,
    address indexed borrower,
    uint256 requestedAmount,
    uint256 minAcceptableAmount,
    uint64 createdAt,
    uint64 deadline
  );
  event BorrowOutcome(
    bytes32 indexed requestId,
    uint32 revision,
    Status status,
    uint8 reason,
    uint256 delta,
    uint256 disbursedAmount,
    uint256 remaining,
    uint32 missingTrades
  );
  event BorrowClosed(bytes32 indexed requestId, Status status);

  uint8 public constant REASON_DISBURSED = 0;
  uint8 public constant REASON_STALE_REFERENCE = 1;
  uint8 public constant REASON_BELOW_MIN_ACCEPTABLE = 2;
  uint8 public constant REASON_INSUFFICIENT_LIQUIDITY = 3;
  uint8 public constant REASON_DIVERGENT_PRICE_HOLD = 4;
  uint8 public constant REASON_NOOP_STALE_OR_CLOSED = 5;
  uint8 public constant REASON_CANCELLED = 6;
  uint8 public constant REASON_EXPIRED = 7;

  uint256 public constant LTV_BPS = 8000;
  uint256 public constant MAX_ACTIVE_HOLDS = 4;
  // 10^(18 collateral + 18 price - 6 debt) times the inverse LTV, exactly.
  uint256 private constant LTV_SCALE = (1e30 * 10_000) / LTV_BPS;

  SpotPool public immutable spotPool;
  MockERC20 public immutable mETH;
  MockERC20 public immutable mUSDC;
  uint256 public immutable smallBorrowLimit;
  uint64 public immutable maxEvidenceAge;
  uint64 public immutable maxClockSkew;
  uint32 public immutable requiredFreshTrades;
  uint64 public immutable maxRequestTtl;

  uint256 public activePendingCount;
  uint256 private requestNonce;
  mapping(address => uint256) public totalCollateral;
  mapping(address => uint256) public totalDebt;
  mapping(address => uint256) public lockedForActiveDebt;
  mapping(address => uint256) public lockedForPendingRequests;
  mapping(bytes32 => Request) private requests;

  constructor(
    IPayable callbackProxy_,
    address callbackSender_,
    SpotPool spotPool_,
    uint256 smallBorrowLimit_,
    uint64 maxEvidenceAge_,
    uint64 maxClockSkew_,
    uint32 requiredFreshTrades_,
    uint64 maxRequestTtl_
  ) AbstractCallback(callbackProxy_, callbackSender_) {
    if (
      address(callbackProxy_) == address(0) || callbackSender_ == address(0) || address(spotPool_) == address(0)
        || smallBorrowLimit_ == 0 || maxEvidenceAge_ == 0 || requiredFreshTrades_ == 0 || maxRequestTtl_ == 0
    ) revert InvalidConfiguration();
    spotPool = spotPool_;
    mETH = spotPool_.mETH();
    mUSDC = spotPool_.mUSDC();
    smallBorrowLimit = smallBorrowLimit_;
    maxEvidenceAge = maxEvidenceAge_;
    maxClockSkew = maxClockSkew_;
    requiredFreshTrades = requiredFreshTrades_;
    maxRequestTtl = maxRequestTtl_;
  }

  function requestState(bytes32 requestId) external view returns (Request memory) {
    return requests[requestId];
  }

  function freeCollateral(address borrower) public view returns (uint256) {
    return totalCollateral[borrower] - lockedForActiveDebt[borrower] - lockedForPendingRequests[borrower];
  }

  function depositCollateral(uint256 amount) external {
    totalCollateral[msg.sender] += amount;
    if (!mETH.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
  }

  function withdrawCollateral(uint256 amount) external {
    if (amount > freeCollateral(msg.sender)) revert InsufficientCollateral();
    totalCollateral[msg.sender] -= amount;
    if (!mETH.transfer(msg.sender, amount)) revert TransferFailed();
  }

  function repay(uint256 amount) external {
    uint256 debtBefore = totalDebt[msg.sender];
    if (amount > debtBefore) revert InvalidAmount();
    uint256 locked = lockedForActiveDebt[msg.sender];
    // A hold can close after its debt was repaid. repay(0) releases that lock at zero debt.
    uint256 unlocked = amount == debtBefore ? locked : Math512.mulDiv(locked, amount, debtBefore);
    totalDebt[msg.sender] = debtBefore - amount;
    lockedForActiveDebt[msg.sender] = locked - unlocked;
    if (amount != 0 && !mUSDC.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
  }

  function borrow(uint256 amount) external {
    if (amount > smallBorrowLimit) revert UseAsyncRequestBorrow();
    if (amount == 0) revert InvalidAmount();
    uint256 collateral = _reserve(msg.sender, amount);
    lockedForActiveDebt[msg.sender] += collateral;
    totalDebt[msg.sender] += amount;
    if (!mUSDC.transfer(msg.sender, amount)) revert TransferFailed();
  }

  function requestBorrow(uint256 requestedAmount, uint256 minAcceptableAmount, uint64 deadline)
    external
    returns (bytes32 requestId)
  {
    uint256 timestamp = block.timestamp;
    if (
      requestedAmount <= smallBorrowLimit || minAcceptableAmount > requestedAmount || deadline <= timestamp
        || deadline - timestamp > maxRequestTtl
    ) revert InvalidRequest();
    if (activePendingCount >= MAX_ACTIVE_HOLDS) revert HoldLimitReached();
    uint256 collateral = _reserve(msg.sender, requestedAmount);
    lockedForPendingRequests[msg.sender] += collateral;
    ++activePendingCount;
    requestId = keccak256(abi.encode(block.chainid, address(this), msg.sender, ++requestNonce));

    Request storage req = requests[requestId];
    req.borrower = msg.sender;
    req.requestedAmount = requestedAmount;
    req.minAcceptableAmount = minAcceptableAmount;
    req.reservedCollateral = collateral;
    // forge-lint: disable-next-line(unsafe-typecast)
    req.createdAt = uint64(timestamp);
    req.deadline = deadline;
    req.status = Status.PENDING;
    emit BorrowRequested(requestId, msg.sender, requestedAmount, minAcceptableAmount, req.createdAt, deadline);
  }

  function onWitnessVerdict(
    address reactive_,
    bytes32 requestId,
    uint32 revision,
    uint256 refPriceE18,
    uint64 refTradedAt,
    uint64,
    uint32 freshTradeCount,
    bytes32,
    uint32
  ) external onlyServiceProvider onlyCallbackSender(reactive_) {
    Request storage req = requests[requestId];
    if (!_isOpen(req.status) || revision <= req.lastRevision || block.timestamp >= req.deadline) {
      _emitOutcome(requestId, req, revision, REASON_NOOP_STALE_OR_CLOSED, 0, 0);
      return;
    }
    req.lastRevision = revision;
    (uint256 delta, uint8 reason) = _applyVerdict(req, refPriceE18, refTradedAt);
    uint32 missing = 0;
    if (req.disbursedAmount == req.requestedAmount) {
      _close(requestId, req, Status.SETTLED, req.reservedCollateral);
    } else {
      req.status = Status.HELD;
      missing = freshTradeCount < requiredFreshTrades ? requiredFreshTrades - freshTradeCount : 0;
    }
    _emitOutcome(requestId, req, revision, reason, delta, missing);
    if (delta != 0 && !mUSDC.transfer(req.borrower, delta)) revert TransferFailed();
  }

  function cancelRequest(bytes32 requestId) external {
    Request storage req = requests[requestId];
    if (!_isOpen(req.status)) revert RequestNotOpen();
    if (req.borrower != msg.sender) revert NotBorrower();
    _close(requestId, req, Status.CANCELLED, _keepOnEarlyClose(req));
    _emitOutcome(requestId, req, req.lastRevision, REASON_CANCELLED, 0, 0);
  }

  function expireRequest(bytes32 requestId) external {
    Request storage req = requests[requestId];
    if (!_isOpen(req.status)) revert RequestNotOpen();
    if (block.timestamp < req.deadline) revert NotExpired();
    _close(requestId, req, Status.EXPIRED, _keepOnEarlyClose(req));
    _emitOutcome(requestId, req, req.lastRevision, REASON_EXPIRED, 0, 0);
  }

  function _applyVerdict(Request storage req, uint256 refPriceE18, uint64 refTradedAt)
    private
    returns (uint256 delta, uint8 reason)
  {
    uint256 timestamp = block.timestamp;
    bool fresh =
      refTradedAt > timestamp ? refTradedAt - timestamp <= maxClockSkew : timestamp - refTradedAt <= maxEvidenceAge;
    if (!fresh || refPriceE18 == 0) return (0, REASON_STALE_REFERENCE);

    uint256 effectivePrice = _min(spotPool.priceE18(), refPriceE18);
    uint256 approved = Math512.mulDivCapped(req.reservedCollateral, effectivePrice, LTV_SCALE, req.requestedAmount);
    if (approved < req.minAcceptableAmount) return (0, REASON_BELOW_MIN_ACCEPTABLE);
    if (approved <= req.disbursedAmount) return (0, REASON_DIVERGENT_PRICE_HOLD);
    delta = approved - req.disbursedAmount;
    if (mUSDC.balanceOf(address(this)) < delta) return (0, REASON_INSUFFICIENT_LIQUIDITY);

    req.disbursedAmount = approved;
    req.lastEffectivePrice = effectivePrice;
    totalDebt[req.borrower] += delta;
    return (delta, REASON_DISBURSED);
  }

  function _reserve(address borrower, uint256 amount) private view returns (uint256 collateral) {
    uint256 price = spotPool.priceE18();
    if (price == 0) revert UnavailablePrice();
    collateral = Math512.mulDivUp(amount, LTV_SCALE, price);
    if (collateral > freeCollateral(borrower)) revert InsufficientCollateral();
  }

  function _keepOnEarlyClose(Request storage req) private view returns (uint256) {
    if (req.disbursedAmount == 0) return 0;
    return _min(req.reservedCollateral, Math512.mulDivUp(req.disbursedAmount, LTV_SCALE, req.lastEffectivePrice));
  }

  function _close(bytes32 requestId, Request storage req, Status status, uint256 kept) private {
    req.status = status;
    req.keptCollateral = kept;
    lockedForPendingRequests[req.borrower] -= req.reservedCollateral;
    lockedForActiveDebt[req.borrower] += kept;
    --activePendingCount;
    emit BorrowClosed(requestId, status);
  }

  function _emitOutcome(
    bytes32 requestId,
    Request storage req,
    uint32 revision,
    uint8 reason,
    uint256 delta,
    uint32 missing
  ) private {
    uint256 disbursed = req.disbursedAmount;
    emit BorrowOutcome(
      requestId, revision, req.status, reason, delta, disbursed, req.requestedAmount - disbursed, missing
    );
  }

  function _isOpen(Status status) private pure returns (bool) {
    return status == Status.PENDING || status == Status.HELD;
  }

  function _min(uint256 a, uint256 b) private pure returns (uint256) {
    return a < b ? a : b;
  }
}
