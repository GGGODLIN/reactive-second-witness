# Base Sepolia → Reactive Lasna → Base Sepolia 探針

## 本機測試

```sh
forge test -vvv --gas-report
```

本機測試以 mock 取代 Lasna SYSTEM 與 Base CallbackProxy。Mock 依票據的 `130,000` gas 預留模擬轉送，並驗證回呼要求至少 `350,000` gas。實際費用、gas 分配與延遲以測試網結果為準。

Foundry 使用 Solidity `0.8.29`。`lib/` 收錄兩份上游 Solidity 原始碼，版本如下。

- [forge-std](https://github.com/foundry-rs/forge-std/tree/15b2df92a05d4d2f76a06653872fefb287e0e01c) `15b2df92a05d4d2f76a06653872fefb287e0e01c`
- [reactive-lib-omni](https://github.com/Reactive-Network/reactive-lib-omni/tree/3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8) `v0.1.0` (`3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8`)

## 測試幣到位後執行

以安全方式提供 `DEPLOYER_PRIVATE_KEY`、`BASE_SEPOLIA_RPC` 與 `REACTIVE_LASNA_RPC`。用 `PROBE_BASE_FUND_WEI` 和 `PROBE_LASNA_FUND_WEI` 指定各合約的初始餘額，兩個值都以 wei 為單位。錢包還須另有 Base Sepolia ETH 與 Lasna lREACT 支付部署和設定交易。

依序執行下列命令。每次部署成功後，把輸出的合約地址存成下一步使用的 `ORIGIN`、`REACTIVE` 或 `RECEIVER` shell 變數。

```sh
forge script script/ProbeLive.s.sol:ProbeLive --sig 'deployOrigin()' --broadcast
forge script script/ProbeLive.s.sol:ProbeLive --sig 'deployReactive(address)' "$ORIGIN" --broadcast
forge script script/ProbeLive.s.sol:ProbeLive --sig 'deployReceiver(address)' "$REACTIVE" --broadcast
forge script script/ProbeLive.s.sol:ProbeLive --sig 'subscribe(address,address)' "$REACTIVE" "$RECEIVER" --broadcast
```

用 Python 3 與 Cast 在第一個終端啟動觀察器。它會用 `rnk_getFilters` 取得 filter ID，再用 `rnk_getFilterById` 確認指定合約的訂閱已啟用。如果 Lasna 還沒索引訂閱，等訂閱出現後重跑。

```sh
python3 script/observe_probe.py "$ORIGIN" "$REACTIVE" "$RECEIVER"
```

等觀察器印出 `Ready. Send one ping now.`，再在第二個終端以部署 ProbeOrigin 的錢包發送一筆 ping。

```sh
forge script script/ProbeLive.s.sol:ProbeLive --sig 'ping(address)' "$ORIGIN" --broadcast
```

每次成功觀察會輸出一筆 JSON，包含 filter ID、ping ID、三筆交易 hash、兩個 debt 值、接收狀態與各段秒數。觀察器核對三筆成功收據、Base 交易的 CallbackProxy 目的地，以及 [SYSTEM 回呼紀錄](https://github.com/Reactive-Network/documentation/blob/main/docs/docs/economy.mdx) 的目的交易 hash 和空白錯誤欄位。它也會透過 RPC 確認 `received(pingId)` 為真且兩側 `debt(address)` 都為零。

依票據收集 5–10 筆樣本，每次先啟動觀察器再送 ping。秒數來自同一台機器的 monotonic clock，從各事件首次被 RPC 讀到的時間計算，會受索引、輪詢及 RPC 延遲影響。若到期仍缺事件，保留已有交易 hash 並用區塊瀏覽器查對 Lasna `ReactiveContractReverted` 或 Base `CallbackFailure`。
