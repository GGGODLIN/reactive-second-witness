#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import Request, urlopen

BASE_CHAIN = 84_532
LASNA_CHAIN = 5_318_007
SYSTEM = "0x8888888888888888888888888888888888888888"
BASE_PROXY = "0x476f44b11f5c942c58f4c8e3d0300e5710743585"
CALLBACKS_ABI = "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])"


def rpc(url, method, *params):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  request = Request(url, data=body, headers={"Content-Type": "application/json"})
  try:
    with urlopen(request, timeout=10) as response:
      reply = json.load(response)
  except (URLError, OSError, ValueError) as error:
    raise RuntimeError(f"{method} request failed ({type(error).__name__})") from None
  if "error" in reply or "result" not in reply:
    raise RuntimeError(f"{method} returned no result (code {reply.get('error', {}).get('code')})")
  return reply["result"]


def cast(*args):
  return subprocess.check_output(["cast", *args], text=True).strip()


def address(value):
  if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
    raise argparse.ArgumentTypeError("expected an EVM address")
  return value.lower()


def active_filter(lasna_rpc, origin, reactive, ping_topic):
  def matches(item):
    return (
      item.get("ChainId") == BASE_CHAIN
      and (item.get("Contract") or "").lower() == origin
      and (item.get("Topics") or [None])[0] == ping_topic
      and any(
        config.get("Contract", "").lower() == reactive and config.get("Active") is True
        for config in item.get("Configs", [])
      )
    )

  filters = rpc(lasna_rpc, "rnk_getFilters")
  for item in filters.get("TopicFilters") or filters.get("topicFilters") or []:
    if matches(item):
      filter_info = rpc(lasna_rpc, "rnk_getFilterById", item["Uid"])
      if filter_info and matches(filter_info):
        return filter_info
  raise RuntimeError("No active Ping subscription for these deployments. Wait for Lasna indexing and retry.")


def wait_for_log(url, emitter, topics, start_block, deadline):
  while time.monotonic() < deadline:
    tip = int(rpc(url, "eth_blockNumber"), 16)
    if tip >= start_block:
      logs = rpc(url, "eth_getLogs", {
        "address": emitter, "topics": topics, "fromBlock": hex(start_block), "toBlock": hex(tip),
      })
      if logs:
        return logs[0], time.monotonic()
      start_block = tip + 1
    time.sleep(0.25)
  raise RuntimeError(f"Timed out waiting for {emitter} topic {topics[0]}")


def checked_receipt(url, log):
  tx = log["transactionHash"]
  receipt = rpc(url, "eth_getTransactionReceipt", tx)
  if not receipt or int(receipt["status"], 16) != 1 or receipt["blockHash"] != log["blockHash"]:
    raise RuntimeError(f"Missing or unsuccessful receipt for {tx}")
  return receipt


def check_delivery(lasna_rpc, reactive, relay_tx, pong_tx, deadline):
  data = cast("calldata", "getCallbacks(uint256)", str(int(relay_tx, 16)))
  while time.monotonic() < deadline:
    raw = rpc(lasna_rpc, "eth_call", {"to": SYSTEM, "data": data}, "latest")
    decoded = json.loads(cast("abi-decode", "--json", CALLBACKS_ABI, raw))
    records = decoded["data"] if isinstance(decoded, dict) else decoded
    for _, sender, _, chain, tx_hash, error_data in records[0]:
      if sender.lower() != reactive or int(chain) != BASE_CHAIN:
        continue
      if error_data != "0x":
        raise RuntimeError(f"Callback from {relay_tx} recorded a destination error")
      if int(tx_hash) == int(pong_tx, 16):
        return
    time.sleep(1)
  raise RuntimeError(f"No successful SYSTEM callback record linking {relay_tx} to {pong_tx}")


def read_uint(url, contract, signature, argument):
  data = cast("calldata", signature, argument)
  return int(rpc(url, "eth_call", {"to": contract, "data": data}, "latest"), 16)


def main():
  parser = argparse.ArgumentParser(description="Observe one new Base Sepolia → Lasna → Base Sepolia probe.")
  parser.add_argument("origin", type=address)
  parser.add_argument("reactive", type=address)
  parser.add_argument("receiver", type=address)
  parser.add_argument("--timeout", type=int, default=300, help="overall timeout in seconds after arming")
  args = parser.parse_args()
  if args.timeout <= 0:
    parser.error("--timeout must be positive")

  base_rpc = os.environ["BASE_SEPOLIA_RPC"]
  lasna_rpc = os.environ["REACTIVE_LASNA_RPC"]
  if int(rpc(base_rpc, "eth_chainId"), 16) != BASE_CHAIN or int(rpc(lasna_rpc, "eth_chainId"), 16) != LASNA_CHAIN:
    raise RuntimeError("Unexpected RPC chain ID")

  ping_topic = cast("keccak", "Ping(uint256)")
  relay_topic = cast("keccak", "PingRelayed(uint256)")
  pong_topic = cast("keccak", "Pong(uint256)")
  filter_info = active_filter(lasna_rpc, args.origin, args.reactive, ping_topic)
  base_start = int(rpc(base_rpc, "eth_blockNumber"), 16) + 1
  lasna_start = int(rpc(lasna_rpc, "eth_blockNumber"), 16) + 1
  deadline = time.monotonic() + args.timeout
  print("Active subscription: " + json.dumps(filter_info), flush=True)
  print("Ready. Send one ping now.", flush=True)

  ping, origin_time = wait_for_log(base_rpc, args.origin, [ping_topic], base_start, deadline)
  ping_id = ping["topics"][1]
  print(f"Origin tx {ping['transactionHash']}", file=sys.stderr)
  relay, relay_time = wait_for_log(lasna_rpc, args.reactive, [relay_topic, ping_id], lasna_start, deadline)
  print(f"Lasna tx {relay['transactionHash']}", file=sys.stderr)
  pong, callback_time = wait_for_log(base_rpc, args.receiver, [pong_topic, ping_id], int(ping["blockNumber"], 16), deadline)
  print(f"Base callback tx {pong['transactionHash']}", file=sys.stderr)
  checked_receipt(base_rpc, ping)
  checked_receipt(lasna_rpc, relay)
  callback_receipt = checked_receipt(base_rpc, pong)
  if callback_receipt["to"].lower() != BASE_PROXY:
    raise RuntimeError("Destination receipt did not target the Base CallbackProxy")

  lasna_debt = read_uint(lasna_rpc, SYSTEM, "debt(address)", args.reactive)
  base_debt = read_uint(base_rpc, BASE_PROXY, "debt(address)", args.receiver)
  received = read_uint(base_rpc, args.receiver, "received(uint256)", str(int(ping_id, 16)))
  if lasna_debt or base_debt or received != 1:
    raise RuntimeError(f"Unexpected probe state: Lasna debt={lasna_debt}, Base debt={base_debt}, received={received}")

  # These are first-observed wall-clock deltas, so polling and RPC delay affect the readings.
  print(json.dumps({
    "filter_id": filter_info["Uid"], "ping_id": int(ping_id, 16),
    "origin_tx": ping["transactionHash"], "lasna_tx": relay["transactionHash"], "base_callback_tx": pong["transactionHash"],
    "lasna_debt": lasna_debt, "base_debt": base_debt, "received": bool(received),
    "origin_to_lasna_s": round(relay_time - origin_time, 3),
    "lasna_to_base_s": round(callback_time - relay_time, 3),
    "origin_to_base_s": round(callback_time - origin_time, 3),
  }))


if __name__ == "__main__":
  try:
    main()
  except (KeyError, RuntimeError, subprocess.CalledProcessError) as error:
    raise SystemExit(str(error)) from None
