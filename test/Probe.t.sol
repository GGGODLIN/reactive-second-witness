// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AbstractCallback} from "reactive-lib-omni/base/AbstractCallback.sol";
import {AbstractPayer} from "reactive-lib-omni/base/AbstractPayer.sol";
import {IPayable} from "reactive-lib-omni/interfaces/IPayable.sol";
import {IReactive} from "reactive-lib-omni/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib-omni/interfaces/ISystemContract.sol";
import {ProbeOrigin} from "../src/probe/ProbeOrigin.sol";
import {ProbeReactive} from "../src/probe/ProbeReactive.sol";
import {ProbeReceiver} from "../src/probe/ProbeReceiver.sol";
import {MockSystemContract} from "./mocks/MockSystemContract.sol";
import {MockCallbackProxy} from "./mocks/MockCallbackProxy.sol";

contract ProbeTest is Test {
  uint256 private constant BASE_SEPOLIA = 84_532;
  uint256 private constant PING_TOPIC = uint256(keccak256("Ping(uint256)"));
  uint256 private constant ANY_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
  address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
  address private constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
  address private constant OUTSIDER = address(0xCAFE);

  MockSystemContract private system = MockSystemContract(SYSTEM);
  MockCallbackProxy private proxy = MockCallbackProxy(PROXY);
  ProbeOrigin private origin;
  ProbeReactive private reactiveContract;
  ProbeReceiver private receiver;

  function setUp() public {
    vm.etch(SYSTEM, type(MockSystemContract).runtimeCode);
    vm.etch(PROXY, type(MockCallbackProxy).runtimeCode);
    origin = new ProbeOrigin();
    reactiveContract = new ProbeReactive(address(origin));
    receiver = new ProbeReceiver(IPayable(payable(PROXY)), address(reactiveContract));
  }

  function testEmitPingPublishesSequentialIds() public {
    vm.expectEmit(address(origin));
    emit ProbeOrigin.Ping(1);
    origin.emitPing();

    vm.expectEmit(address(origin));
    emit ProbeOrigin.Ping(2);
    origin.emitPing();
  }

  function testDirectCallerWithCorrectReactiveAddressReverts() public {
    vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, OUTSIDER, PROXY));
    vm.prank(OUTSIDER);
    receiver.onPong(address(reactiveContract), 1);
  }

  function testProxyWithForgedReactiveAddressReverts() public {
    vm.expectRevert(
      abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, OUTSIDER, address(reactiveContract))
    );
    vm.prank(PROXY);
    receiver.onPong(OUTSIDER, 1);
  }

  function testNonSystemCannotTriggerReactiveCallback() public {
    IReactive.LogRecord memory log;
    vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, OUTSIDER, SYSTEM));
    vm.prank(OUTSIDER);
    reactiveContract.react(log);
  }

  function testSubscribedPingRequestsOmniCallbackAndMutatesReceiver() public {
    reactiveContract.subscribeToPing(address(receiver));
    assertEq(
      system.subscription(),
      abi.encode(address(reactiveContract), BASE_SEPOLIA, address(origin), PING_TOPIC, ANY_TOPIC, ANY_TOPIC, ANY_TOPIC)
    );

    vm.recordLogs();
    origin.emitPing();
    Vm.Log memory ping = vm.getRecordedLogs()[0];
    IReactive.LogRecord memory log;
    log.chainId = BASE_SEPOLIA;
    log.contractAddress = ping.emitter;
    log.topic0 = uint256(ping.topics[0]);
    log.topic1 = uint256(ping.topics[1]);
    log.data = ping.data;
    system.react(reactiveContract, log);

    ISystemContract.CallbackConfiguration_V_1_0 memory request = system.callbackRequest();
    assertEq(request.chainId, BASE_SEPOLIA);
    assertEq(request.recipient, address(receiver));
    assertGe(request.gasLimit, 350_000);
    assertEq(request.payload, abi.encodeCall(ProbeReceiver.onPong, (address(0), 1)));
    assertFalse(receiver.received(1));

    vm.expectEmit(address(receiver));
    emit ProbeReceiver.Pong(1);
    proxy.deliver(request.recipient, request.gasLimit, system.requestingContract(), request.payload);
    assertTrue(receiver.received(1));
  }
}
