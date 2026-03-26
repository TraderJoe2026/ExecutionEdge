# ExecutionEdge Analyzer

An open-source MetaTrader 5 Expert Advisor that benchmarks your broker's real execution quality — measuring lag, slippage, fill accuracy, and order handling across all order types. It generates detailed PDF and HTML reports showing exactly where your live execution differs from what the strategy tester assumes.

**Version 1.00 — First Public Release (March 2026)**

[![Downloads](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2FTraderJoe2026.github.io%2FExecutionEdge%2Fdl-count.json&query=%24.message&label=downloads&color=blue)](https://TraderJoe2026.github.io/ExecutionEdge/download-binary.html)

> **[Download Binary (.ex5)](https://TraderJoe2026.github.io/ExecutionEdge/download-binary.html)** | **[Download Source (.mq5)](https://TraderJoe2026.github.io/ExecutionEdge/download-source.html)**

## The Problem Every EA Trader Faces

Your EA shows great results in backtesting. You go live — and it bleeds money.

The strategy tester assumes instant fills, fixed spreads, and zero processing delay. Your broker's real execution has none of these. The gap between "tester execution" and "real execution" is invisible — until you measure it.

ExecutionEdge Analyzer places controlled test trades at minimum lot size, timestamps every event to the millisecond, and compares what your broker *actually does* against industry execution standards. The output is a comprehensive report showing you exactly where execution quality falls short — and by how much.

**Cost:** Uses the smallest possible lot size (0.01). On a demo account the cost is zero. On a live account, typical cost is ~$2–6 total (3 cycles on most instruments).

**Time:** ~45–120 minutes depending on market movement.

## Quick Start

1. Copy `ExecutionEdgeAnalyzer.mq5` to your MT5 `MQL5/Experts/` folder
2. Open MetaEditor, open the file, and press **F7** to compile
3. In MetaTrader 5, attach the EA to any chart of the instrument you want to test
4. Ensure **AutoTrading** is enabled (green button in toolbar)
5. Click **OK** — the EA starts automatically with sensible defaults

### Requirements
- MetaTrader 5 (Build 5000+)
- A live or demo account
- AutoTrading enabled
- Sufficient margin for minimum lot size trades (~$1–50 depending on instrument)

### Pre-compiled Binary
A pre-compiled `.ex5` is included for convenience. Copy it to `MQL5/Experts/` and attach to a chart — no compilation needed. The `.mq5` source is provided for transparency and verification.

## What It Measures

### How Order Types Actually Work

The analyzer respects a fundamental fact of how all order matching works:

- **Stops and SL** trigger a market order when price crosses the level. They fill at **whatever price exists after the trigger**. Imperfect fills on stops are expected market mechanics.
- **Limits and TP** are resting orders with a **price guarantee** — they should fill at the trigger price or better.

This means the tool evaluates each type on its own terms:
- **Stops/SL** are judged on **processing speed** — is there unnecessary delay adding to natural slippage?
- **Limits/TP** are judged on **fill accuracy** — is the price guarantee being honoured?
- **Fast symmetric processing (<10ms) = GOOD** regardless of fill accuracy on any type
- **Asymmetric processing (>2x ratio between order types)** = a significant finding worth investigating

### Measurement Units — Pip Normalization

All distance measurements (lag, slippage, spread, stops level) are expressed in **standardized pips** — not broker-specific points. This ensures fair comparison across brokers regardless of their decimal precision.

| | 2-digit broker | 3-digit broker |
|---|---|---|
| Quote example | 3021.45 | 3021.453 |
| 1 pip | $0.01 = 1 point | $0.01 = 10 points |
| "5 pip slippage" | 5 points | 50 points |

### Execution Quality Model

The EA measures execution quality by linking **processing time** to its **financial consequence**:

1. **Broker processing time** — how long the broker held the instruction before executing (network lag excluded via 2-pass calibration)
2. **Execution drift** — the price difference between what the broker received and what it actually filled at

Client-server network latency is infrastructure — excluded from all measurements.

### What the Report Reveals

| Test | What It Checks |
|------|----------------|
| **Stop/Limit processing ratio** | Are stops processed slower than limits? |
| **TP/SL processing ratio** | Are stop-losses processed slower than take-profits? |
| **Dealer intervention patterns** | Whole-second clustering, flat distribution, delay magnitude, order-type discrimination |
| **Profit/Loss close asymmetry** | Are winning trades closed slower than losing trades? |
| **Time clustering** | Fills grouped into fixed-lag windows |
| **Price batching** | Multiple fills at identical prices despite different trigger levels |
| **Order rejection analysis** | Are certain order types rejected more than others? |
| **Fill rejection tracking** | Orders accepted but cancelled when price triggers |
| **Price spike detection** | Artificial price spikes (spread >3x median) that trigger stop-losses |
| **Margin verification** | Theoretical vs actual margin — detects hidden markup |
| **Order capacity stress test** | Are certain order types blocked under load? |
| **Buy/Sell direction bias** | Is one direction consistently processed slower? |
| **Close price verification** | Deal prices verified against tick buffer at claimed execution time |

### Dealer Intervention Detection

The EA runs 5 tests to detect MetaTrader's Virtual Dealer Plugin or similar intervention tools:

1. **Adverse vs Favorable processing ratio** — broker-profitable orders delayed >2x longer
2. **Delay magnitude** — adverse delays >500ms
3. **Whole-second clustering** — >40% of adverse lags cluster at 1000ms boundaries (±50ms)
4. **Distribution shape** — low IQR/median ratio with >500ms delays
5. **Order-type discrimination** — >50% difference between stop and SL delays

### Rejection Retry Verification

When the broker rejects an order, the EA automatically retries (configurable: default 2 retries, 3-second delay). This distinguishes between:

- **Transient rejections** — retry succeeds, indicating a momentary server issue (not counted)
- **Persistent rejections** — all retries fail, indicating consistent behavior

This prevents false readings from temporary server glitches while ensuring genuine patterns are still detected.

### Stops Level Assessment

The EA reads the broker's `SYMBOL_TRADE_STOPS_LEVEL` and evaluates it against ECN benchmarks:

- **0 pips** — Excellent, consistent with true ECN execution
- **0.1–5 pips** — Good, within top-tier range
- **5–20 pips** — Acceptable but traders using tight stops should be aware
- **20+ pips** — Restrictive, associated with dealing desk execution

### Stress Test

Fires async bursts of orders at the broker's stated capacity limit to detect:
- **Selective blocking** — certain order types blocked under load
- **Asymmetric rejection rates** — order types rejected unevenly
- **Recovery time** — how long the broker blocks new placements after activity

## Execution Grades

The report classifies your broker's execution quality:

**When asymmetric processing is detected:**

| Grade | Criteria |
|-------|----------|
| **FAIR EXECUTION** | Fast symmetric processing, no asymmetry between order types |
| **EXECUTION CONCERNS — ASYMMETRIC PROCESSING DETECTED** | 2+ issues with asymmetric processing |
| **SIGNIFICANT EXECUTION ISSUES** | 4+ issues with asymmetric processing |
| **CRITICAL EXECUTION ISSUES — CONSIDER ALTERNATIVES** | 6+ issues with asymmetric processing |

**When processing is slow but symmetric:**

| Grade | Criteria |
|-------|----------|
| **FAIR EXECUTION** | Within top-tier standards |
| **SLOW EXECUTION — EXCEEDS SOME BENCHMARKS** | 1–3 issues, but symmetric |
| **SLOW EXECUTION — SIGNIFICANTLY EXCEEDS** | 4+ issues, but symmetric |

Symmetric slow execution is an infrastructure concern — not an integrity issue. The report clearly distinguishes between "slow broker" and something more concerning.

## Output Files

All files are written to the MT5 Common Files folder. Default location on Windows:
`[Drive]:\Users\[USERNAME]\AppData\Roaming\MetaQuotes\Terminal\Common\Files\`

| File | Format | Purpose |
|------|--------|---------|
| `ForensicReport.*.pdf` | PDF | Full report with grades, bar charts, analysis, and benchmark references |
| `ForensicReport.*.htm` | HTML | Interactive report with color-coded tables and proportional bars |
| `ForensicData.*.toml` | TOML | Machine-readable results for automated analysis |
| `ForensicEvidence.*.csv` | CSV | Every fill event with millisecond timestamps |
| `ForensicTicks.*.csv` | CSV | Every market tick recorded during the test |
| `ForensicBrokerLog.*.csv` | CSV | All trade events including rejections |
| `ForensicHistory.*.csv` | CSV | MT5 account history export for cross-verification |

## How It Works

### Phase 1: Network Calibration
Two-pass measurement of network round-trip time to separate internet latency from broker processing time.

### Phase 2: Market Order Baseline
Places a market buy and sell, measures sync execution times, establishes a baseline.

### Phase 3: Grid Cycles (Main Test)
For each cycle:
1. Places a matched-pair grid of pending orders — 50% buy stops + 50% buy limits (equal count, symmetric distances from price)
2. Waits for price to trigger fills, recording exact timestamps via server tick history
3. Places TP/SL on filled positions
4. Waits for minimum TP and SL triggers before proceeding
5. Batch-closes all positions
6. Records every fill's processing time and drift

**Statistical auto-extension:** After completing configured cycles (default 3), the EA checks whether it has collected at least 30 stop fills and 30 limit fills — the Central Limit Theorem minimum for a valid comparison. If not, additional cycles are added automatically.

### Phase 4: Stress Test
Fires async bursts at the broker's stated order capacity to compare handling of different order types under load.

### Phase 5: Analysis
Calculates per-type median/mean processing times, runs pattern detection engine, identifies asymmetric execution patterns, classifies overall quality.

### Phase 6: Report Generation
Generates all output files with grades, charts, and benchmark references.

## Input Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMagicNumber` | 777999 | Unique EA identifier — change if running other EAs |
| `InpLotSize` | 0.0 | Lot size (0 = auto-detect minimum lot) |
| `InpTotalCycles` | 3 | Grid cycles to run (auto-extends for statistical validity) |
| `InpGridStartMult` | 1.0 | Grid start distance as multiple of spread |
| `InpGridSpacingPct` | 20.0 | Grid spacing as % of spread |
| `InpWriteHTML` | true | Generate HTML report |
| `InpDwellSeconds` | 30 | Wait after fills before close (sec) |
| `InpCycleTimeoutSec` | 180 | Minimum dwell time per cycle (sec) |
| `InpMinTPSLTriggers` | 3 | Minimum TP and SL triggers before cycle close |
| `InpSyncTPSLCount` | 10 | Number of fills to place TP/SL synchronously |
| `InpStressMaxCycles` | 2 | Stress test cycles per order type |
| `InpShowEATuning` | false | Show EA tuning recommendations in reports |
| `InpRejRetryMax` | 2 | Rejection retry attempts (0 = disabled) |
| `InpRejRetryDelayMs` | 3000 | Delay between retries in ms |

## Report Sections

1. **Executive Summary** — overall grade, detection results, stat boxes, execution time comparison chart
2. **Execution Processing vs Industry Benchmark** — per-type bar chart scaled to top-tier benchmarks
3. **Methodology** — grid configuration, order type distribution, timing approach
4. **Network Environment** — calibration results, account settings, sync execution baseline
5. **Detailed Findings** — per-type execution audit, asymmetry detection, close price verification, time clustering, price batching
6. **Financial Impact Assessment** — measured impact breakdown, per-lot rate, annual projections
7. **Industry Benchmark Reference** — MiFID II, FCA COBS, ESMA, FAIS Act, ASIC thresholds
8. **Grade and Recommendations** — final grade, findings summary
9. **Regulatory Contacts** — regulator contact details per jurisdiction
10. **Industry Precedents** — notable enforcement cases for context
11. **Pattern Analysis** — detection tests with expected vs anomalous comparison
12. **Appendices** — evidence file manifest, raw trade data, grid config, glossary

## Interpreting Results

| Metric | Good | Concerning | Critical |
|--------|------|------------|----------|
| Stop/Limit processing ratio | <1.2x | 1.2–2.0x | >2.0x |
| Limit/TP fill accuracy | >90% | 70–90% (with slow processing) | <70% (with slow processing) |
| Dealer intervention probability | 0–24% | 25–49% | ≥50% |
| Overall processing time | <100ms | 100–500ms | >500ms |
| Rejection asymmetry | Symmetric | Directional >10% | Systematic |

## Data Integrity

- **SHA-256 hashes** of all output files recorded in the TOML `[integrity]` section
- **Measurement fingerprint** — hash of key numeric values for tamper detection
- **Server-side timestamps** — all measurements use `DEAL_TIME_MSC` (broker's own millisecond timestamp)
- **Trigger time detection** — primary via `CopyTicksRange` (server tick history, ms precision)
- **Verification protocol** — step-by-step guide for independent reproduction

## Important Notes

- **This EA trades real orders.** Use a demo account first. On live accounts it uses minimum lot size.
- **No external connections.** The EA runs entirely within MT5 — no data sent anywhere.
- **Reports are generated locally.** All files stay on your machine in the MT5 data folder.
- **The EA cleans up after itself.** All test positions and pending orders are closed/deleted before generating reports.

## Mirror Downloads

This project is available on multiple platforms:

| Platform | Link |
|----------|------|
| **GitHub** | [github.com/TraderJoe2026/ExecutionEdge](https://github.com/TraderJoe2026/ExecutionEdge) |
| **SourceForge** | [sourceforge.net/projects/executionedge](https://sourceforge.net/projects/executionedge/) |

## File Integrity (SHA-256 Checksums)

Verify your download has not been tampered with:

```
ExecutionEdgeAnalyzer.ex5  c56e4454ce5ce7242b63abc19bbe7ae13be324637486668149c8e6805aea22d4
ExecutionEdgeAnalyzer.mq5  4211e99104334cba7c758a92fd1eaf718400f61b9ac8ae0aac82e00ded909bb0
```

**How to verify:**
- **Windows:** `certutil -hashfile ExecutionEdgeAnalyzer.ex5 SHA256`
- **Mac/Linux:** `shasum -a 256 ExecutionEdgeAnalyzer.ex5`

## License

This project is open source. You are free to use, modify, and distribute it. The goal is to give every trader visibility into what happens between clicking "trade" and getting a fill.

## Contact

For bug reports, feature requests, or to share your results:

**Email:** toolsfortraders.2026@gmail.com

---

*Built for MetaTrader 5. Single-file EA — no external dependencies, no DLLs, no libraries beyond the standard MQL5 Trade include.*
