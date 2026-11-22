// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {AbstractReactive} from "reactive-lib-omni/base/AbstractReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {BorrowGate} from "./BorrowGate.sol";
import {ReferencePoolWitness} from "./ReferencePoolWitness.sol";

contract SecondWitnessReactive is AbstractReactive {
  struct HoldSlot {
    bytes32 requestId;
    uint64 deadline;
    uint32 revision;
    uint32 tradesSeenSinceHold;
    bool active;
  }

  error InvalidConfiguration();
  error NotOwner();
  error AlreadyConfigured();

  event WitnessVerdict(
    bytes32 indexed requestId,
    uint32 revision,
    uint256 refPriceE18,
    uint64 refTradedAt,
    uint64 refTradeSeq,
    uint32 freshTradeCount,
    bytes32 refTxHash,
    uint32 refLogIndex
  );

  uint256 public constant MAX_ACTIVE_HOLDS = 4;
  uint256 public constant LASNA_EVICT_BUFFER = 75 seconds;
  address public immutable owner = msg.sender;
  uint256 public immutable unichainId;
  address public immutable referencePool;
  uint256 public immutable baseChainId;
  uint32 public immutable requiredFreshTrades;
  uint64 public immutable callbackGasLimit;

  address public borrowGate;
  uint256 public latestPriceE18;
  uint64 public latestTradedAt;
  uint64 public latestTradeSeq;
  bytes32 public latestTxHash;
  uint32 public latestLogIndex;
  HoldSlot[MAX_ACTIVE_HOLDS] private holdSlots;

  modifier onlyOwner() {
    if (msg.sender != owner) revert NotOwner();
    _;
  }

  constructor(
    uint256 unichainId_,
    address referencePool_,
    uint256 baseChainId_,
    uint32 requiredFreshTrades_,
    uint64 callbackGasLimit_
  ) payable {
    if (
      unichainId_ == 0 || referencePool_ == address(0) || baseChainId_ == 0 || requiredFreshTrades_ == 0
        || callbackGasLimit_ < 350_000
    ) revert InvalidConfiguration();
    unichainId = unichainId_;
    referencePool = referencePool_;
    baseChainId = baseChainId_;
    requiredFreshTrades = requiredFreshTrades_;
    callbackGasLimit = callbackGasLimit_;
    _subscribe(unichainId_, referencePool_, ReferencePoolWitness.ReferenceTrade.selector);
  }

  function configureBorrowGate(address borrowGate_) external onlyOwner {
    if (borrowGate_ == address(0)) revert InvalidConfiguration();
    if (borrowGate != address(0)) revert AlreadyConfigured();
    // Base needs the Lasna address at deployment to authenticate Omni callbacks.
    borrowGate = borrowGate_;
    _subscribe(baseChainId, borrowGate_, BorrowGate.BorrowRequested.selector);
    _subscribe(baseChainId, borrowGate_, BorrowGate.BorrowClosed.selector);
  }

  function holdSlot(uint256 index) external view returns (HoldSlot memory) {
    return holdSlots[index];
  }

  function activeHoldCount() external view returns (uint256 count) {
    for (uint256 i = 0; i < MAX_ACTIVE_HOLDS; ++i) {
      if (holdSlots[i].active) ++count;
    }
  }

  function react(LogRecord calldata log_) external override onlySystem {
    if (
      log_.chainId == unichainId && log_.contractAddress == referencePool
        && log_.topic0 == uint256(ReferencePoolWitness.ReferenceTrade.selector)
    ) {
      _onReferenceTrade(log_);
      return;
    }
    if (borrowGate == address(0) || log_.chainId != baseChainId || log_.contractAddress != borrowGate) return;

    if (log_.topic0 == uint256(BorrowGate.BorrowRequested.selector)) {
      _onBorrowRequested(log_);
    } else if (log_.topic0 == uint256(BorrowGate.BorrowClosed.selector)) {
      if (log_.data.length != 32 || abi.decode(log_.data, (uint256)) > uint256(type(BorrowGate.Status).max)) return;
      _onBorrowClosed(bytes32(log_.topic1));
    }
  }

  function _onReferenceTrade(LogRecord calldata log_) private {
    bytes calldata data = log_.data;
    if (data.length != 96) return;
    // The narrow ABI decoder would revert on noncanonical words even when the length matches.
    if (uint256(bytes32(data[32:64])) > type(uint64).max || uint256(bytes32(data[64:96])) > type(uint64).max) return;
    (uint256 priceE18, uint64 tradedAt, uint64 tradeSeq) = abi.decode(data, (uint256, uint64, uint64));
    if (tradeSeq <= latestTradeSeq) return;

    latestPriceE18 = priceE18;
    latestTradedAt = tradedAt;
    latestTradeSeq = tradeSeq;
    latestTxHash = bytes32(log_.txHash);
    // The verdict ABI carries the low 32 bits of the Omni receipt log index.
    // forge-lint: disable-next-line(unsafe-typecast)
    latestLogIndex = uint32(log_.logIndex);

    for (uint256 i = 0; i < MAX_ACTIVE_HOLDS; ++i) {
      HoldSlot storage slot = holdSlots[i];
      if (!slot.active) continue;
      if (_isExpired(slot)) {
        slot.active = false;
        continue;
      }
      if (slot.revision == type(uint32).max) continue;
      uint32 freshCount = slot.tradesSeenSinceHold + 1;
      if (freshCount < requiredFreshTrades) {
        slot.tradesSeenSinceHold = freshCount;
        continue;
      }
      slot.tradesSeenSinceHold = 0;
      uint32 nextRevision = ++slot.revision;
      _sendVerdict(slot.requestId, nextRevision, freshCount);
    }
  }

  function _onBorrowRequested(LogRecord calldata log_) private {
    bytes calldata data = log_.data;
    if (data.length != 128) return;
    if (uint256(bytes32(data[64:96])) > type(uint64).max || uint256(bytes32(data[96:128])) > type(uint64).max) return;
    (,,, uint64 deadline) = abi.decode(data, (uint256, uint256, uint64, uint64));
    bytes32 requestId = bytes32(log_.topic1);
    for (uint256 i = 0; i < MAX_ACTIVE_HOLDS; ++i) {
      HoldSlot storage slot = holdSlots[i];
      if (slot.active && slot.requestId == requestId) return;
    }

    _sendVerdict(requestId, 1, 0);
    uint256 firstFree = MAX_ACTIVE_HOLDS;
    for (uint256 i = 0; i < MAX_ACTIVE_HOLDS; ++i) {
      HoldSlot storage slot = holdSlots[i];
      if (slot.active && _isExpired(slot)) slot.active = false;
      if (!slot.active && firstFree == MAX_ACTIVE_HOLDS) firstFree = i;
    }
    if (firstFree < MAX_ACTIVE_HOLDS) holdSlots[firstFree] = HoldSlot(requestId, deadline, 1, 0, true);
  }

  function _onBorrowClosed(bytes32 requestId) private {
    for (uint256 i = 0; i < MAX_ACTIVE_HOLDS; ++i) {
      HoldSlot storage slot = holdSlots[i];
      if (slot.active && slot.requestId == requestId) {
        delete holdSlots[i];
        return;
      }
    }
  }

  function _isExpired(HoldSlot storage slot) private view returns (bool) {
    // Lasna keeps the slot through the buffer to accommodate Base's clock and log delivery.
    // forge-lint: disable-next-line(block-timestamp)
    return block.timestamp > uint256(slot.deadline) + LASNA_EVICT_BUFFER;
  }

  function _subscribe(uint256 chainId, address origin, bytes32 topic) private {
    SYSTEM.subscribe(chainId, origin, uint256(topic), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
  }

  // Only SYSTEM can enter react and it queues delivery on Base. Fan-out is bounded to four requests.
  // forge-lint: disable-start(reentrancy-events, reentrancy-no-eth, calls-loop)
  function _sendVerdict(bytes32 requestId, uint32 revision, uint32 freshCount) private {
    emit WitnessVerdict(
      requestId, revision, latestPriceE18, latestTradedAt, latestTradeSeq, freshCount, latestTxHash, latestLogIndex
    );
    SYSTEM.requestCallbackV_1_0(
      ISystemContract.CallbackConfiguration_V_1_0({
        chainId: baseChainId,
        recipient: borrowGate,
        gasLimit: callbackGasLimit,
        payload: abi.encodeCall(
          BorrowGate.onWitnessVerdict,
          (
            address(0),
            requestId,
            revision,
            latestPriceE18,
            latestTradedAt,
            latestTradeSeq,
            freshCount,
            latestTxHash,
            latestLogIndex
          )
        )
      })
    );
  }
  // forge-lint: disable-end(reentrancy-events, reentrancy-no-eth, calls-loop)
}
