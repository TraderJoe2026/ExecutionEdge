//+------------------------------------------------------------------+
//|                                          ExecutionEdgeAnalyzer.mq5 |
//|     ExecutionEdge Analyzer — Execution Quality Benchmark Tool      |
//|     Measures real vs expected fill quality across all order types   |
//+------------------------------------------------------------------+
//|  Version: 1.00 — First Public Release (March 2026)                |
//|  License: Open Source — Free Distribution                          |
//+------------------------------------------------------------------+
//|  PURPOSE:                                                          |
//|  This EA places controlled test trades (minimum lot size) to       |
//|  benchmark your broker's real execution quality across ALL order   |
//|  types: market orders, pending stops, pending limits, take-profit, |
//|  stop-loss, and batch close. It compares each measurement to       |
//|  2026 industry benchmarks and generates a detailed report          |
//|  showing where live execution differs from strategy tester         |
//|  assumptions — helping you understand why backtest ≠ live.        |
//|                                                                    |
//|  COST: Uses 0.01 lot. ~$1-4 on demo, ~$2-6 on live.             |
//|  TIME: ~45-120 minutes depending on market movement               |
//|                                                                    |
//|  OUTPUT FILES (in MT5 Common Files folder):                        |
//|  - ForensicReport.*.pdf  — PDF report (Letter size, print-ready) |
//|  - ForensicReport.*.htm  — HTML report (visual, color-coded)      |
//|  - ForensicEvidence.*.csv — Every trade event with ms timestamps  |
//|  - ForensicTicks.*.csv   — Tick data during entire test           |
//|  - ForensicData.*.toml   — Machine-readable results               |
//+------------------------------------------------------------------+
#property copyright "ExecutionEdge Analyzer — Open Source, Free Distribution"
#property link      "https://github.com/TraderJoe2026/ExecutionEdge"
#property version   "1.00"
#property strict
//+------------------------------------------------------------------+
//| Download Mirrors                                                  |
//+------------------------------------------------------------------+
// GitHub:      https://github.com/TraderJoe2026/ExecutionEdge
// SourceForge: https://sourceforge.net/projects/executionedge/

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                             |
//+------------------------------------------------------------------+
input int    InpMagicNumber    = 777999;    // Magic number (unique to this EA)
input double InpLotSize        = 0.0;       // Lot size (0 = auto-detect minimum)
input int    InpTotalCycles    = 3;         // Total grid cycles to run
input double InpGridStartMult  = 1.0;       // Grid start distance (× spread)
input double InpGridSpacingPct = 20.0;      // Grid spacing (% of spread)
#define GRID_LEVELS_PER_SIDE   40           // 40 stops + 40 limits per side → 80 fills per cycle = CLT compliant
input bool   InpWriteHTML      = true;      // Generate HTML report
input int    InpDwellSeconds   = 30;        // Wait after fills before close (sec)
input int    InpCycleTimeoutSec  = 180;     // Minimum dwell (sec) — cycle only closes after this AND TP/SL gate met
input int    InpMinTPSLTriggers  = 3;       // Minimum TP and SL triggers before cycle close (no hard timeout)
input int    InpSyncTPSLCount   = 10;       // Number of fills to place TP/SL synchronously
input int    InpStressMaxCycles = 2;        // Stress test cycles per order type (stops + limits)
input bool   InpShowEATuning   = false;    // Show EA tuning recommendations in reports
input int    InpRejRetryMax     = 2;        // Rejection retry attempts (0=disabled)
input int    InpRejRetryDelayMs = 3000;     // Delay between retries (ms)

//+------------------------------------------------------------------+
//| CONSTANTS — 2026 Industry Standards                                |
//+------------------------------------------------------------------+
//  Source: 2026 A-book benchmarks (IC Markets/Pepperstone/Global Prime), MiFID II RTS 27/28, FCA COBS 11.2, FX Global Code Principle 17
#define FA_VERSION          "1.00"

// Fill execution (pending trigger → fill, broker_exec component)
// 2026 reality: top A-book brokers (IC Markets, Pepperstone, Global Prime) execute in 10-50ms
#define STD_MARKET_GOOD_MS      50    // Market: A-book STP (top brokers 10-50ms)
#define STD_MARKET_SLOW_MS     100    // Last-look / hold suspect
#define STD_MARKET_MANIP_MS    200    // Deliberate hold

#define STD_FILL_GOOD_MS       100    // Pending: true A-book STP
#define STD_FILL_SLOW_MS       200    // Last-look / hold
#define STD_FILL_MANIP_MS      500    // B-book order holding

// Async batch close (trigger → majority of fills confirmed)
#define STD_CLOSE_GOOD_MS      200    // Async batch close
#define STD_CLOSE_SLOW_MS      400    // Hold / last-look
#define STD_CLOSE_MANIP_MS     800    // Deliberate close delay

// Sync individual close (single round-trip, same expectation as market order)
#define STD_SYNC_CLOSE_GOOD_MS    50  // Single position close RT (same as market)
#define STD_SYNC_CLOSE_SLOW_MS   150  // Hold / last-look
#define STD_SYNC_CLOSE_MANIP_MS  300  // Deliberate delay on individual close

// TP/SL execution (broker-side trigger → fill)
#define STD_TPSL_GOOD_MS        50    // Server-side, near-instant
#define STD_TPSL_SLOW_MS       150    // Delay
#define STD_TPSL_MANIP_MS      300    // Manipulation

// Minimum TP/SL triggers needed per cycle for valid asymmetry measurement
// (MIN_TPSL_TRIGGERS replaced by InpMinTPSLTriggers input parameter)

// Batch close majority threshold (0.0-1.0)
// Stragglers beyond this % are excluded from close lag measurement
#define CLOSE_MAJORITY_PCT     0.60

// 2026 A-Book Clustering Standards
// Source: FX Global Code Principle 17, MiFID II RTS 27/28, ESMA Feb 2026 Supervisory Briefing,
//         industry TCA (EBS 30ms last-look, Northern Trust 3ms, XTX 0ms hold)
// A genuine A-book broker passes orders to LP individually — clustering indicates internalization
#define STD_CLUSTER_FAIR_PCT     10.0   // ≤10% fills clustered = normal market batching
#define STD_CLUSTER_CAUTION_PCT  25.0   // 10-25% = suspicious batch window
#define STD_MAX_CLUSTER_FAIR     3      // Max cluster size ≤3 = normal fast-market sweep
#define STD_MAX_CLUSTER_MANIP    5      // >5 fills in one cluster = batching confirmed
#define STD_BATCH_FAIR_PCT       5.0    // ≤5% fills at same price from different levels = normal
#define STD_BATCH_CAUTION_PCT   15.0    // 5-15% = suspicious price rounding
#define STD_FILL_RATIO_MIN      95.0   // <95% fill ratio = systematic issues (BrokerXray benchmark)
#define STD_SLIPPAGE_ASYM_MAX    1.5   // Adverse/favorable slippage ratio >1.5 = asymmetric

// Tick buffer for trigger detection
#define TICK_BUF_SIZE          2000

// Stress test: order capacity
// InpStressMaxCycles replaced by InpStressMaxCycles input parameter
// STRESS_BATCH_SIZE removed — stress test now uses measured g_orderLimit (ACCOUNT_LIMIT_ORDERS)

// Grid order types for distribution
#define GRID_STOP_CLEAN        0     // Stop order, no TP/SL
#define GRID_STOP_TP           1     // Stop order with TP
#define GRID_STOP_SL           2     // Stop order with SL
#define GRID_LIMIT_CLEAN       3     // Limit order, no TP/SL
#define GRID_LIMIT_TPSL        4     // Limit order with TP+SL

//+------------------------------------------------------------------+
//| ENUMS                                                              |
//+------------------------------------------------------------------+
// Start button
#define  BTN_START_NAME  "FA_StartBtn"

enum ENUM_FA_STATE
{
   STATE_WAIT_START,     // Waiting for user to press START
   STATE_INIT,
   STATE_CS_CALIBRATE,              // CS lag measurement via pending order place+delete
   STATE_MARKET_BUY,
   STATE_MARKET_BUY_WAIT,
   STATE_MARKET_BUY_SLTP,       // Place SL+TP on buy position (sync)
   STATE_MARKET_SELL,
   STATE_MARKET_SELL_WAIT,
   STATE_MARKET_SELL_SLTP,       // Place SL+TP on sell position (sync), measure margin
   STATE_MARKET_WAIT_PROFIT,     // Wait for one position to be in profit, then close both
   STATE_MARKET_CLOSE_BUY,       // Close buy position (sync, isolated)
   STATE_MARKET_CLOSE_BUY_WAIT,  // Waiting for buy close fill
   STATE_MARKET_CLOSE_SELL,      // Close sell position (sync, isolated)
   STATE_MARKET_CLOSE_SELL_WAIT, // Waiting for sell close fill
   STATE_GRID_PLACE,
   STATE_GRID_WAIT,
   STATE_GRID_CLOSE,
   STATE_GRID_ASYNC_WAIT,        // Waiting for async close fills (non-blocking, event-loop driven)
   STATE_GRID_VERIFY,
   STATE_STRESS_PLACE,           // Async bulk place orders
   STATE_STRESS_ASYNC_WAIT,      // Wait for async ORDER_ADD confirmations
   STATE_STRESS_VERIFY_PLACED,   // Verify all placed
   STATE_STRESS_CLOSE,           // Async close all
   STATE_STRESS_VERIFY_CLOSED,   // Verify all closed, then next cycle or switch to limits
   STATE_STRESS_STOP_PROBE,      // Single sync stop order to check if stops are accepted
   STATE_STRESS_LIMIT_PLACE,     // Bulk place limit orders (unused — STATE_STRESS_PLACE handles both)
   STATE_STRESS_LIMIT_VERIFY,    // Verify limit orders placed
   STATE_STRESS_LIMIT_CLOSE,     // Async close limit orders
   STATE_STRESS_LIMIT_CLOSED,    // Verify limit close, next cycle
   STATE_STRESS_FINAL_CLEANUP,   // Persistent cleanup: delete ALL stress orders/positions before report
   STATE_REPORT,
   STATE_DONE
};

enum ENUM_FILL_TYPE
{
   FILL_MARKET_BUY,
   FILL_MARKET_SELL,
   FILL_BUYSTOP,
   FILL_SELLSTOP,
   FILL_BUYLIMIT,
   FILL_SELLLIMIT,
   FILL_TP,
   FILL_SL,
   FILL_ASYNC_CLOSE,
   FILL_SYNC_CLOSE
};

//+------------------------------------------------------------------+
//| STRUCTS                                                            |
//+------------------------------------------------------------------+
struct TickRecord
{
   ulong    timeMs;      // GetTickCount64()
   double   bid;
   double   ask;
};

struct GridOrder
{
   ulong    ticket;             // Order ticket
   double   price;              // Trigger/limit price
   bool     isBuy;              // Direction
   int      gridType;           // GRID_STOP_CLEAN, GRID_STOP_TP, etc.
   double   tpPrice;            // Take profit (0 if none)
   double   slPrice;            // Stop loss (0 if none)
   ulong    placeTimeMs;        // GetTickCount64() when placed
   bool     filled;             // Has been filled
   bool     priceCrossed;       // Price has crossed trigger level
   ulong    triggerTimeMs;      // When price first crossed level
   double   fillPrice;          // Actual fill price
   ulong    fillTimeMs;         // When fill was detected (EA-side GetTickCount64)
   long     entryDealTimeMsc;   // Broker's DEAL_TIME_MSC when parent order filled
   ulong    positionId;         // Position ID from fill (for TP/SL matching)
   bool     tpslProcessed;      // TP or SL fill already matched to this order
   bool     tpslModified;       // TP/SL levels have been placed on the position via PositionModify
   bool     isLimit;            // true=limit, false=stop
   int      cycleNum;           // Which cycle this belongs to
};

struct FillRecord
{
   int            cycleNum;
   ENUM_FILL_TYPE fillType;
   ulong          orderTicket;
   ulong          dealTicket;
   double         requestedPrice;    // Grid level / TP / SL price
   double         fillPrice;         // Actual fill price
   double         bidAtFill;         // Market bid at fill moment
   double         askAtFill;         // Market ask at fill moment
   double         spreadAtFill;      // Spread at fill
   ulong          sendTimeMs;        // When order was sent
   ulong          triggerTimeMs;     // When price crossed level
   ulong          fillTimeMs;        // When fill was detected
   double         lagMs;             // fillTime - triggerTime (or sendTime for market)
   double         brokerExecMs;      // broker processing time (DEAL_TIME_MSC based or lag - CS_lag)
   double         slippagePts;       // Signed: positive=favorable, negative=adverse
   double         slippageUSD;       // $ value of slippage
   double         volume;            // Lots
   bool           isBuy;             // Direction
   bool           isStraggler;       // Close fill after async window (sync close)
   bool           lagValid;          // true if trigger tick was found (lag measurement reliable)
   long           dealTimeMsc;       // Broker's deal timestamp (DEAL_TIME_MSC) for close fills
   double         tickPriceAtDeal;   // Tick bid/ask from our buffer at deal execution time
   double         priceVerifyDelta;  // dealPrice - tickPrice in points (0 = perfect correlation)
   double         brokerReceiptPrice; // Market price when broker received instruction (market/close fills)
   double         clientSendPrice;   // Client-side price at instruction send (for audit trail)
   double         driftLagMs;        // Time for market to reach deal price from receipt (-1=unmeasured, 0=perfect)
   string         notes;             // Additional info
};

struct CloseRequest
{
   ulong    posTicket;     // Position ticket
   ulong    sendTimeMs;    // When close was sent (updated for sync retries)
   double   sendPrice;     // Market price at send
   double   entryPrice;    // Position entry price
   double   lots;          // Volume
   bool     isBuy;         // Direction
   bool     filled;        // Close fill received
   ulong    fillTimeMs;    // When close fill arrived
   double   fillPrice;     // Close fill price
   double   brokerProfit;  // DEAL_PROFIT from broker
   double   exactProfit;   // Our exact calculation
   bool     isSyncClose;   // true if closed via sync sweep (Phase 2 / VerifyAllClosed)
   ulong    syncRoundTripMs; // Measured directly: after PositionClose() - before (sync only)
};

struct CycleRecord
{
   int      cycleNum;
   double   spreadAtPlace;       // Spread when grid was placed
   double   spacingPts;          // Actual spacing in points
   int      levelsPerSide;       // Orders per side
   int      totalPlaced;         // Orders placed
   int      totalFilled;         // Fills received
   int      stopFills;           // Stop order fills
   int      limitFills;          // Limit order fills
   int      tpTriggers;          // TP triggered
   int      slTriggers;          // SL triggered
   int      closeFills;          // Batch close fills
   double   preCloseEquity;      // Equity before close
   double   postCloseBalance;    // Balance after close
   double   financialDelta;      // post - pre ($ impact of close lag)
   ulong    closeTriggerMs;      // When close was triggered
   ulong    lastCloseFillMs;     // When absolute last close fill arrived (incl stragglers)
   ulong    majorityCloseFillMs; // When CLOSE_MAJORITY_PCT of async fills confirmed
   int      asyncFillCount;      // Fills received during async window (before sync sweep)
   double   closeLagMs;          // majorityCloseFill - closeTrigger
   double   closeBrokerExecMs;   // median of per-fill DEAL_TIME_MSC broker exec
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                   |
//+------------------------------------------------------------------+

//--- State
ENUM_FA_STATE g_state = STATE_INIT;
bool     g_started    = false;
int      g_cycleNum   = 0;
int      g_effectiveCycles = 0;  // Adaptive: may exceed InpTotalCycles on low-order-limit accounts

//--- Trade object
CTrade   g_trade;

//--- Environment
string   g_brokerName;          // Display name (original)
string   g_brokerNameFile;      // Sanitized for filenames (no dots, spaces, slashes, etc.)
string   g_symbolFile;          // Sanitized Symbol() for filenames (strips dots etc.)
string   g_serverName;
long     g_accountNumber;
string   g_accountCurrency;
string   g_displayCurrency;    // Always "USD" for standardized reporting (user converts for cent/micro accounts)
long     g_accountLeverage;
double   g_startingEquity;
double   g_startingBalance;
double   g_tickValue;
double   g_tickSize;
double   g_point;
double   g_contractSize;
int      g_digits;
double   g_lotSize;         // Actual lot size used
double   g_minLot;
ENUM_ORDER_TYPE_FILLING g_fillType; // Auto-detected fill mode (FOK/IOC/RETURN)
long     g_orderLimit;      // ACCOUNT_LIMIT_ORDERS (0 = unlimited)
int      g_mt5Build;
string   g_unitLabel;       // "pts" or "pips"
double   g_pipSize;         // Standardized pip size (0.01 for gold regardless of digits)
int      g_pipMult;         // Points per pip (10 for 3-digit, 1 for 2-digit)
string   g_baseSymbol;      // Chart symbol stripped of broker suffixes (e.g., "XAUUSD")
int      g_stdDigits;       // Standard digit count for this instrument class
int      g_currencyDigits;  // Decimals in account currency (2 for USD, 0 for JPY)
int      g_stopsLevel;     // SYMBOL_TRADE_STOPS_LEVEL (min SL/TP distance in points)
int      g_freezeLevel;    // SYMBOL_TRADE_FREEZE_LEVEL (freeze zone in points)

//--- Timing
ulong    g_epochMsOffset;          // GetTickCount64() → epoch ms
ulong    g_clientServerRoundTripMs;
ulong    g_clientServerLagMs;      // One-way = roundtrip / 2
bool     g_csCalibrated = false;   // true after pending-order CS calibration complete
ulong    g_csCalibPlaceRtMs = 0;   // Round-trip of BuyStop placement
ulong    g_csCalibDeleteRtMs = 0;  // Round-trip of OrderDelete

//--- Two-pass calibration: run CS calibrate + market test twice, then average
int      g_calibPass = 0;          // 0 = not started, 1 = first pass done, 2 = both done
ulong    g_csPass1EpochOffset = 0;
ulong    g_csPass1LagMs = 0;
ulong    g_csPass1RoundTripMs = 0;
ulong    g_csPass1PlaceRtMs = 0;
ulong    g_csPass1DeleteRtMs = 0;
ulong    g_csPass2LagMs = 0;
ulong    g_csPass2RoundTripMs = 0;
// Pass 1 baseline measurements (sync open/close + SL/TP placements)
double   g_pass1SyncOpenBuyMs = 0;
double   g_pass1SyncOpenSellMs = 0;
double   g_pass1SyncSLBuyMs = 0;
double   g_pass1SyncSLSellMs = 0;
double   g_pass1SyncTPBuyMs = 0;
double   g_pass1SyncTPSellMs = 0;
double   g_pass1SyncCloseBuyMs = 0;
double   g_pass1SyncCloseSellMs = 0;
datetime g_collectionStartTime;
datetime g_collectionEndTime;

//--- Tick buffer (circular)
TickRecord g_tickBuf[];
int      g_tickBufHead = 0;
int      g_tickBufCount = 0;
long     g_tickCount = 0;

//--- Grid tracking
GridOrder g_grid[];
int      g_gridSize = 0;
int      g_gridFillsExpected = 0;
int      g_gridFillsReceived = 0;
ulong    g_lastFillMs = 0;        // For dwell timeout
ulong    g_gridPlacedMs = 0;      // When grid was placed (fallback timeout)
long     g_gridEarliestSetupMsc = 0;  // Earliest ORDER_TIME_SETUP_MSC in the batch
ulong    g_gridFirstOrderAddBootMs = 0; // Boot time of first ORDER_ADD callback (for batch RT)
int      g_gridOrdersConfirmed = 0;    // Count of ORDER_ADD confirmations received

//--- TP/SL placement lag tracking
// Sync: first filled position per cycle, individual round-trip measurement
double   g_syncSLPlaceLags[];   // Sync SL placement broker exec (1 per cycle)
double   g_syncTPPlaceLags[];   // Sync TP placement broker exec (1 per cycle)
int      g_syncSLPlaceCount = 0;
int      g_syncTPPlaceCount = 0;
bool     g_tpslSyncDone = false;  // Sync phase complete (10 positions modified)
int      g_tpslSyncModified = 0; // How many positions got sync TP/SL this cycle

// Async: remaining positions, batch PositionModify with EA-side ack timing
bool     g_tpslAsyncSent = false;
ulong    g_tpslAsyncSendMs = 0;   // When async batch started
ulong    g_slAsyncFirstAckMs = 0; // First SL ack (EA-side GetTickCount64)
ulong    g_tpAsyncFirstAckMs = 0; // First TP ack (EA-side GetTickCount64)
int      g_slAsyncCount = 0;      // Async SL modifications sent
int      g_tpAsyncCount = 0;      // Async TP modifications sent
double   g_asyncSLPlaceLags[];    // Async SL batch broker exec per cycle
double   g_asyncTPPlaceLags[];    // Async TP batch broker exec per cycle
int      g_asyncSLPlaceCount = 0;
int      g_asyncTPPlaceCount = 0;

//--- Close tracking
CloseRequest g_closeReqs[];
int      g_closeReqCount = 0;
int      g_closeFillsExpected = 0;
int      g_closeFillsReceived = 0;
ulong    g_closeTriggerMs = 0;
ulong    g_orderDeleteSendMs = 0;      // When EA started sending OrderDelete batch
ulong    g_posCloseSendMs = 0;         // When EA started sending PositionClose batch
long     g_orderDeleteEarliestMsc = 0; // Broker's earliest ORDER_TIME_DONE_MSC (order deletion ack)
long     g_posCloseEarliestMsc = 0;    // Broker's earliest close DEAL_TIME_MSC (position closed)
ulong    g_posCloseFirstFillBootMs = 0; // Boot time of first close fill callback (for batch RT)
int      g_orderDeleteCount = 0;       // Pending orders sent for deletion
int      g_posCloseCount = 0;          // Positions sent for close
bool     g_asyncCloseComplete = false;  // true after Phase 1 async window ends
double   g_closeBrokerExecLags[];      // Per-fill ASYNC close broker exec ms (for cycle median)
int      g_closeBrokerExecCount = 0;
double   g_closeSyncExecLags[];       // Per-fill SYNC close broker exec ms (for cycle median)
int      g_closeSyncExecCount = 0;
ulong    g_closeEaSendDurationMs = 0;  // EA-side: time from first OrderDelete to last PositionClose send

//--- Market test tracking
ulong    g_marketSendMs = 0;
double   g_marketSendPrice = 0;
ulong    g_marketOrderTicket = 0;
ulong    g_marketPosTicket = 0;
double   g_marketEntryPrice = 0;
bool     g_marketFillReceived = false;
double   g_measuredMarginBuy = 0;
double   g_measuredMarginSell = 0;
double   g_measuredMarginBoth = 0;   // Margin with BOTH positions open
double   g_measuredEquityBuy = 0;
double   g_measuredEquityBoth = 0;   // Equity with BOTH positions open
double   g_verifiedLeverage = 0;
double   g_verifiedLeverageBoth = 0; // Leverage with both open (true leverage test)
double   g_calculatedHedgingRatio = -1; // -1 = not measured yet
long     g_accountMarginMode = 0;    // ACCOUNT_MARGIN_MODE

//--- V1.17: Max positions/pending order tracking
int      g_maxPositionsObserved;    // High watermark of simultaneous open positions
int      g_maxPendingObserved;      // High watermark of simultaneous pending orders
int      g_maxTotalObserved;        // High watermark of positions + pending combined

//--- Market test: separate position tracking for buy and sell
ulong    g_mktBuyPosTicket = 0;      // Buy position kept open until sell also opens
ulong    g_mktSellPosTicket = 0;     // Sell position
double   g_mktBuyEntryPrice = 0;
double   g_mktSellEntryPrice = 0;
ulong    g_mktCloseBuySendMs = 0;   // When close buy was sent
ulong    g_mktCloseSellSendMs = 0;  // When close sell was sent

//--- Market test: 8 sync measurements (ms)
double   g_mktSyncOpenBuyMs = 0;     // 1. Open buy
double   g_mktSyncOpenSellMs = 0;    // 2. Open sell
double   g_mktSyncSLBuyMs = 0;      // 3. Place SL on buy
double   g_mktSyncSLSellMs = 0;     // 4. Place SL on sell
double   g_mktSyncTPBuyMs = 0;      // 5. Place TP on buy
double   g_mktSyncTPSellMs = 0;     // 6. Place TP on sell
double   g_mktSyncCloseBuyMs = 0;   // 7. Close buy
double   g_mktSyncCloseSellMs = 0;  // 8. Close sell
bool     g_mktCloseBuyInProfit = false;   // Was buy position profitable when closed?
bool     g_mktCloseSellInProfit = false;  // Was sell position profitable when closed?
double   g_mktCloseBuyPnL = 0;            // Unrealized PnL at close time
double   g_mktCloseSellPnL = 0;
double   g_mktBuyCommission = 0;         // Commission charged on buy test trade (per lot per side)
double   g_mktSellCommission = 0;        // Commission charged on sell test trade

//--- Close profit vs loss tracking (async batch + sync straggler)
double   g_closeProfitLags[];    // Broker exec for closes in profit
double   g_closeLossLags[];      // Broker exec for closes in loss
int      g_closeProfitCount = 0;
int      g_closeLossCount = 0;
double   g_stragProfitLags[];    // Straggler (sync) closes in profit
double   g_stragLossLags[];      // Straggler (sync) closes in loss
int      g_stragProfitCount = 0;
int      g_stragLossCount = 0;

//--- Fill records (all fills across all cycles)
FillRecord g_fills[];
int      g_fillCount = 0;

//--- Cycle records
CycleRecord g_cycles[];

//--- Aggregate statistics (computed at report time)
//    Per fill type: [FILL_MARKET_BUY..FILL_SYNC_CLOSE] = 10 types
double   g_medianLag[10];
double   g_meanLag[10];
double   g_minLag[10];
double   g_maxLag[10];
int      g_countByType[10];
int      g_lagValidCount[10];     // Fills with valid lag measurement (trigger found)
double   g_meanSlipSigned[10];    // Signed mean: positive=favor, negative=adverse
double   g_meanSlipAbs[10];       // Absolute mean
double   g_totalSlipUSD[10];      // Total $ slippage
double   g_driftLagSum[10];       // Sum of drift lag times (ms) for mean calculation
double   g_driftLagMedianArr[];   // All drift lag values for median calculation
int      g_driftLagCount[10];     // Count of measured drift lags per type
int      g_driftLagTotalCount = 0;// Total drift lag measurements (for median array)

//--- Trigger/market fill classification per type (server-side triggers only)
//    triggerFill = |dealPrice - triggerPrice| < threshold → filled at trigger price
//    marketFill  = |dealPrice - triggerPrice| > threshold → filled at market price
//    NOTE: Stops/SL naturally fill at market (structural). Low trigger % is expected.
//          Limits/TP have price guarantee. Low trigger % = broker violation.
//          Verdict: stops/SL on LAG speed, limits/TP on trigger fill %.
int      g_triggerFillCount[10];  // Fills where dealPrice ≈ triggerPrice
int      g_marketFillCount[10];   // Fills where dealPrice away from triggerPrice (market fill)

//--- Async vs Sync close statistics (computed at report time)
double   g_asyncCloseMedianLag = 0;  // Median broker exec for async batch close fills
double   g_asyncCloseMeanLag   = 0;
int      g_asyncCloseCount     = 0;
double   g_syncCloseMedianLag  = 0;  // Median broker exec for sync straggler close fills
double   g_syncCloseMeanLag    = 0;
int      g_syncCloseCount      = 0;

//--- Rounding tracking
double   g_roundingErrorSum;
double   g_roundingErrorAbsSum;
double   g_roundingErrorMax;
long     g_roundingErrorCount;
double   g_brokerProfitSum;
double   g_exactProfitSum;

//--- Financial totals
double   g_totalLotsTraded;
double   g_totalAdverseSlipUSD;
double   g_totalAdverseSlipPips;
int      g_adverseFillCount;
double   g_stopAdverseSlipUSD;    // Adverse slippage on stop orders only
double   g_stopAdverseSlipPips;
int      g_stopAdverseFillCount;
double   g_limitAdverseSlipUSD;   // Adverse slippage on limit orders only
double   g_limitAdverseSlipPips;
int      g_limitAdverseFillCount;
double   g_totalFinancialDelta;   // Sum of cycle close deltas

//--- Previous Day Tick-Based Damage Projection (v1.17)
//    Pulls full previous trading day tick data, slides a window equal to
//    the measured broker lag, calculates average OHLC range during that
//    window = average slippage per trade caused by the lag.
datetime g_prevDayStart = 0;
datetime g_prevDayEnd = 0;
int      g_prevDayTickCount = 0;
int      g_prevDayWindowCount = 0;         // Number of sliding windows sampled
double   g_prevDayAvgRangePoints = 0;      // Avg high-low in points over lag window
double   g_prevDayAvgRangePips = 0;        // Avg high-low in standardized pips over lag window
double   g_prevDayAvgRangePrice = 0;       // Avg high-low in price units over lag window
double   g_prevDaySlippagePerLot = 0;      // Avg range × tick_value ($ per lot per trade)
double   g_prevDayAnnualDamage1 = 0;       // Annual @ 1 lot/day
double   g_prevDayAnnualDamage10 = 0;      // Annual @ 10 lots/day
double   g_prevDayLagUsedMs = 0;           // Which measured lag was used for the window
bool     g_prevDayDataValid = false;

//--- Close price verification (deal price vs tick at broker execution time)
int      g_closePriceVerifyCount;      // Close fills with tick cross-validation
double   g_closePriceVerifyAbsSum;     // Sum of |delta| in points
double   g_closePriceVerifyMaxAbs;     // Max |delta| in points
int      g_closePriceMismatchCount;    // Fills where |delta| > 0.5 points

//--- Fill clustering analysis (exact-match: same price + timestamp + direction + order category)
//    A cluster = 2+ fills sharing ALL of: same fillPrice, same DEAL_TIME_MSC,
//    same direction (buy/sell), same order category (stop vs limit).
//    Detects broker batch processing / internalization.
#define  CLUSTER_GAP_MS    100   // Legacy — kept for TOML export compatibility
int      g_clusterCount;         // Number of fill clusters detected
int      g_isolatedFills;        // Fills NOT in a cluster (individually processed)
double   g_avgClusterSize;       // Average fills per cluster
double   g_maxClusterSize;       // Largest cluster (most fills sharing same price/time/dir)
double   g_avgInterClusterGap;   // Average gap between clusters (ms) — legacy metric
double   g_clusterRatio;         // clustered_fills / total_fills

//--- Fill batch analysis (PRICE-based: did fills land at trigger prices or not?)
//    Cross-referenced with fill clustering to classify broker behavior:
//    - No clustering + fills at trigger → FAIR (genuinely no manipulation)
//    - Time lag + fills at trigger → LUCKY (lag exists but low vol saved client)
//    - Time lag + fills NOT at trigger → MANIPULATION (lag caused batching/slippage)
//    Includes stops, limits, SL, and TP fills in the price comparison.
int      g_batchCount;           // Number of batches (>1 fill at same fillPrice from different levels)
int      g_individualFills;      // Fills NOT in a price batch
double   g_avgBatchSize;         // Average fills per price batch
int      g_maxBatchSize;         // Largest price batch
double   g_batchRatio;           // batched_fills / total_fills (price-based)
double   g_batchAdvantagePts;    // Total broker advantage: sum |fillPrice - requestedPrice| in batches
double   g_avgBatchAdvantagePts; // Average broker advantage per batched fill (points)
int      g_totalBatchedFills;    // Total fills part of a price batch
int      g_fairFills;            // Fills where fillPrice == requestedPrice (within tolerance)
int      g_fairFillsStop;       // Fair fills for stop orders only
int      g_fairFillsLimit;      // Fair fills for limit orders only
int      g_totalStopPriced;     // Total priced stop fills
int      g_totalLimitPriced;    // Total priced limit fills
int      g_totalPricedFills;     // Total fills analyzed for price accuracy (grid + SL + TP)
double   g_batchTimeSpanMs;      // Sum of time spans across all batches
double   g_avgBatchTimeSpanMs;   // Average time span per batch (broker hold window)
double   g_maxBatchTimeSpanMs;   // Longest single batch time span
double   g_medBatchTimeSpanMs;   // Median batch time span
string   g_batchClassification;  // "FAIR" / "CAUTION" / "MANIPULATION"

//--- Virtual Dealer Plugin (VDP) detection
//    Analyzes lag distribution for signatures of configured dealer delays.
//    VDP uses integer-second delays, separate per order type, with price recheck.
//    Natural ECN/STP lag is continuous log-normal, symmetric, and volatile-correlated.
double   g_vdpScore;              // 0-100 probability score of VDP use
string   g_vdpVerdict;            // "NOT DETECTED" / "POSSIBLE" / "PROBABLE" / "CONFIRMED"
bool     g_vdpWholeSecCluster;    // True if adverse lags cluster at whole-second boundaries
double   g_vdpWholeSecPct;        // % of adverse fills within 50ms of a whole second
bool     g_vdpDelayRange;         // True if adverse delays in VDP typical range (>500ms)
double   g_vdpAdverseMedian;      // Median lag of adverse types (stops+SL)
double   g_vdpFavorMedian;        // Median lag of favorable types (limits+TP)
double   g_vdpLagRatio;           // Adverse/favorable lag ratio (>2 = asymmetric)
bool     g_vdpFlatDistribution;   // True if lag distribution is flat (uniform) not log-normal
double   g_vdpIQRatio;            // IQR/median — low = tight band (VDP), high = spread (natural)
bool     g_vdpOrderTypeDiscrim;   // True if each adverse type has distinctly different delay
int      g_vdpFlagsTriggered;     // Count of VDP indicators triggered
int      g_vdpAdverseCount;       // Total adverse fills analyzed
int      g_vdpFavorCount;         // Total favorable fills analyzed

//--- TP/SL Market Trigger Direction Analysis
//    When TP triggers → favorable for trader (hit target)
//    When SL triggers → adverse for trader (hit stop)
//    Additionally: slippage direction on each trigger fill
int      g_tpslTotalTriggers;      // Total TP + SL triggers
int      g_tpslFavorTriggers;      // TP fills (favorable — hit target)
int      g_tpslAdverseTriggers;    // SL fills (adverse — hit stop)
double   g_tpslFavorPct;           // % favorable of total triggers
double   g_tpslAdversePct;         // % adverse of total triggers
int      g_tpslFavorSlip;          // TP fills with favorable slippage (price improvement)
int      g_tpslAdverseSlip;        // SL fills with adverse slippage (worse than trigger)
int      g_tpslNeutralSlip;        // Fills at exact trigger price (no slippage)
double   g_tpslSlipAsymRatio;      // Adverse slip % / Favorable slip % (should be ~1.0)

//--- Per-Order-Type Clustering (which pending types appear in fill clusters)
int      g_clusterByType[10];      // Per-type count of fills that were in a cluster
double   g_clusterByTypePct[10];   // Per-type % of fills in clusters
double   g_maxClusterPct;          // Largest cluster as % of all grid fills
string   g_clusterVerdict;         // "FAIR" / "CAUTION" / "MANIPULATION" based on 2026 benchmarks

//--- Per-Cluster Detail Data (for broker.rs fill model solver)
//    Each cluster exports: fill price, timestamp, member trigger levels, tick-at-deal,
//    lag, and model residuals so broker.rs can determine the fill pricing formula.
#define MAX_CLUSTER_DETAILS 200

struct ClusterDetail
{
   int      memberCount;
   double   fillPrice;           // Shared fill price (cluster key)
   long     dealTimeMsc;         // Shared broker timestamp (cluster key)
   bool     isBuy;               // Shared direction (cluster key)
   bool     isLimit;             // Shared category: true=limit, false=stop (cluster key)
   int      distinctReqPrices;   // How many unique trigger levels in this cluster
   bool     isSameLevelCluster;  // true = all members had same requestedPrice (true cluster vs batch)
   // Model residuals (in points — lower = better fit)
   double   residualLastTick;    // mean |fillPrice - tickPriceAtDeal|
   double   residualTrigger;     // mean |fillPrice - requestedPrice|
   double   residualLagInterp;   // mean |fillPrice - interpolatedPrice|
   double   residualWorstPrice;  // mean |fillPrice - worstOf(req,tick)|
   string   bestFitModel;        // "last_tick" / "trigger_price" / "lag_interpolated" / "worst_price"
   // Cluster-level aggregates
   double   meanLagMs;
   double   meanSlippagePts;
   double   meanTickDeltaPts;    // mean |fillPrice - tickPriceAtDeal|
   double   tickDriftRate;       // (tick - requested) / lagMs, averaged (pts/ms)
   // Raw member arrays (exported to TOML for broker.rs regression)
   double   memReqPrices[];      // Each member's requestedPrice
   double   memLagMs[];          // Each member's lagMs
   double   memSlipPts[];        // Each member's slippagePts
   double   memTickAtDeal[];     // Each member's tickPriceAtDeal
   double   memVerifyDelta[];    // Each member's priceVerifyDelta (fillPrice - tickAtDeal)
};

ClusterDetail g_clusterDetails[];
int           g_clusterDetailCount;

// Fill model aggregate classification (across all clustered fills)
int    g_fmLastTick;        // Fills best matching last_tick model
int    g_fmTrigger;         // Fills best matching trigger_price model
int    g_fmLagInterp;       // Fills best matching lag_interpolated model
int    g_fmWorstPrice;      // Fills best matching worst_price model
int    g_fmUnclassifiable;  // Fills where tickPriceAtDeal was unavailable
int    g_fmTotal;           // Total classified fills
string g_fmDominantModel;   // Model with most fills
double g_fmAlpha;           // Regression weight: trigger_price component
double g_fmBeta;            // Regression weight: tick_at_deal component
// fill_price ~ alpha * requested_price + beta * tick_at_deal

//--- Order rejection tracking (#4)
// Rejection classification — assigned post-analysis using measured broker asymmetry
#define REJ_CLASS_UNCLASSIFIED     0  // Not yet classified (pre-statistics)
#define REJ_CLASS_SUSPICIOUS       1  // Price well away from order — no legitimate reason
#define REJ_CLASS_ASYMMETRIC_DELAY 2  // Price passed BUT broker has measured asymmetric delay
#define REJ_CLASS_ASYMMETRIC_REQUOTE 3 // Requote applied asymmetrically (stops >> limits)
#define REJ_CLASS_LEGITIMATE       4  // Price genuinely passed during symmetric processing
#define REJ_CLASS_SYMMETRIC_REQUOTE 5  // Both stops & limits requoted at similar rates
#define REJ_CLASS_TRANSIENT        6  // Retry succeeded — transient server issue, not manipulation

struct RejectionRecord
{
   int      retcode;        // MT5 return code
   string   orderType;      // "BuyStop", "SellLimit", etc.
   datetime time;           // When rejection occurred
   double   orderPrice;     // Intended order price
   double   bidAtReject;    // Bid at time of rejection
   double   askAtReject;    // Ask at time of rejection
   double   spreadAtReject; // Spread at time of rejection
   double   distPoints;     // Distance from nearest price in points
   double   distSpreads;    // Distance from nearest price in spreads
   bool     pricePassed;    // true = price moved past order level at time of rejection
   int      classification; // REJ_CLASS_* — set by ClassifyRejections() after statistics
   string   brokerReason;   // Reason provided by the broker (from retcode)
   string   measuredReason; // Reason determined by our forensic analysis
   int      retryAttempts;  // Number of retry attempts made (0 = no retry)
   bool     retrySucceeded; // true = retry worked (TRANSIENT), false = all retries failed (PERSISTENT)
   int      retryRetcode;   // Retcode from last retry attempt (0 if no retry)
};
RejectionRecord g_rejections[];
int      g_rejectionCount = 0;
int      g_rejByType[10];           // Rejections per ENUM_FILL_TYPE
int      g_rejStopTotal = 0;        // Total stop order rejections
int      g_rejLimitTotal = 0;       // Total limit order rejections
int      g_rejMarketTotal = 0;      // Total market order rejections
// Post-classification counts (set by ClassifyRejections)
int      g_rejStopManipulation = 0;  // Stop rejections classified as manipulation (any type)
int      g_rejStopLegitimate = 0;    // Stop rejections classified as legitimate
int      g_rejLimitManipulation = 0; // Limit rejections classified as manipulation
int      g_rejLimitLegitimate = 0;   // Limit rejections classified as legitimate
string   g_rejectionVerdict = "";     // Overall rejection verdict string
int      g_rejTransientCount = 0;    // Rejections where retry succeeded (server glitch)
int      g_rejPersistentCount = 0;   // Rejections where all retries failed (confirmed blocking)

//--- Fill rejection tracking (broker cancels pending order at trigger time)
// Classification for fill rejections
#define FILLREJ_CLASS_UNCLASSIFIED    0  // Not yet classified
#define FILLREJ_CLASS_PRICE_TRIGGERED 1  // Price crossed level AND broker cancelled — smoking gun
#define FILLREJ_CLASS_PREEMPTIVE      2  // Broker cancelled BEFORE price reached level
#define FILLREJ_CLASS_EA_INITIATED    3  // EA requested deletion (not broker fault)

struct FillRejectionRecord
{
   ulong    orderTicket;     // Original order ticket
   string   orderType;       // "BuyStop", "SellLimit", etc.
   double   orderPrice;      // Requested fill price
   bool     isLimit;         // true=limit, false=stop
   bool     isBuy;           // Direction
   bool     priceCrossed;    // Price had crossed trigger level before cancellation
   ulong    placeTimeMs;     // When order was placed (GetTickCount64)
   ulong    triggerTimeMs;   // When price first crossed level (0 if never)
   ulong    cancelTimeMs;    // When broker cancelled (GetTickCount64)
   long     cancelTimeMsc;   // Broker's ORDER_TIME_DONE_MSC
   long     orderState;      // MT5 ORDER_STATE at cancellation
   long     orderReason;     // MT5 ORDER_REASON
   double   bidAtCancel;     // Bid when cancelled
   double   askAtCancel;     // Ask when cancelled
   double   spreadAtCancel;  // Spread when cancelled
   double   distPoints;      // Distance from price at cancellation
   int      classification;  // FILLREJ_CLASS_*
   string   brokerReason;    // Broker's stated reason (from ORDER_STATE)
   string   measuredReason;  // Our forensic finding
   int      cycleNum;        // Which cycle
};
FillRejectionRecord g_fillRejections[];
int      g_fillRejectionCount = 0;
int      g_fillRejStopTotal = 0;       // Fill rejections of stop orders
int      g_fillRejLimitTotal = 0;      // Fill rejections of limit orders
int      g_fillRejStopTriggered = 0;   // Stops cancelled AFTER price triggered (manipulation)
int      g_fillRejLimitTriggered = 0;  // Limits cancelled AFTER price triggered
int      g_fillRejStopPreemptive = 0;  // Stops cancelled before price reached
int      g_fillRejLimitPreemptive = 0; // Limits cancelled before price reached
string   g_fillRejVerdict = "";        // Overall fill rejection verdict

//--- Phantom spike detection (#5)
struct PhantomSpike
{
   ulong    timeMs;
   double   bid;
   double   ask;
   double   spread;
   double   medianSpread;   // Median spread at time of spike
   double   zScore;         // Standard deviations from rolling mean
   bool     triggeredSL;    // Did this spike trigger an SL?
};
PhantomSpike g_phantomSpikes[];
int      g_phantomSpikeCount = 0;
double   g_medianSpread = 0;        // Computed during analysis
double   g_meanSpread = 0;

//--- Margin verification (#10)
double   g_theoreticalMarginBuy = 0;   // (lots × contract × price) / leverage
double   g_theoreticalMarginBoth = 0;  // Both sides open
double   g_marginDiscrepancyBuy = 0;   // actual - theoretical (positive = broker charges more)
double   g_marginDiscrepancyBoth = 0;
double   g_marginMarkupPctBuy = 0;     // % markup over theoretical
double   g_marginMarkupPctBoth = 0;

//--- Order capacity stress test
int      g_stressCycleStop = 0;        // Completed stop-order cycles
int      g_stressCycleLimit = 0;       // Completed limit-order cycles
bool     g_stressStopBlocked = false;  // Broker blocked stop placement
bool     g_stressLimitBlocked = false; // Broker blocked limit placement
int      g_stressStopBlockedAt = 0;    // Cycle number when stops blocked
int      g_stressLimitBlockedAt = 0;   // Cycle number when limits blocked
int      g_stressPlacedCount = 0;      // Orders placed in current batch
int      g_stressVerifiedCount = 0;    // Orders verified open
ulong    g_stressTickets[];            // Tickets of stress test orders
int      g_stressTicketCount = 0;
int      g_stressPlaceAttempts = 0;    // Total placement attempts this cycle
int      g_stressPlaceRejects = 0;     // Rejections this cycle
int      g_stressMaxVerifiedStop = 0;  // Max orders verified open (stops)
int      g_stressMaxVerifiedLimit = 0; // Max orders verified open (limits)
int      g_stressLastRetcode = 0;      // Last rejection retcode
bool     g_stressInLimitPhase = false; // Currently testing limits
ulong    g_stressCloseStartMs = 0;     // When close started
ulong    g_stressPlaceStartMs = 0;     // When placement started
int      g_stressAsyncSent = 0;        // Async placement requests sent
int      g_stressAsyncConfirmed = 0;   // ORDER_ADD confirmations received
int      g_stressAsyncRejected = 0;    // Async placement rejections (from REQUEST callback)
ulong    g_stressAsyncWaitStartMs = 0; // When we started waiting for confirmations
ulong    g_gridPhaseEndMs = 0;          // GetTickCount64() when grid phase ended (before stress test)
ulong    g_stressFinalCleanupStartMs = 0; // When final cleanup started
int      g_stressFinalCleanupAttempts = 0; // Retry counter for final cleanup
int      g_stressStopTotalAttempts = 0;   // Cumulative placement attempts (stop cycles)
int      g_stressStopTotalRejects = 0;    // Cumulative rejections (stop cycles)
int      g_stressLimitTotalAttempts = 0;  // Cumulative placement attempts (limit cycles)
int      g_stressLimitTotalRejects = 0;   // Cumulative rejections (limit cycles)

//--- Throttle recovery measurement (time broker takes to accept new orders after heavy activity)
#define  THROTTLE_MAX_SAMPLES  20        // Max recovery measurements to store
double   g_throttleRecoveryMs[];          // Recovery time per measurement (ms)
int      g_throttleRecoveryAttempts[];    // Probe attempts per measurement
int      g_throttleRecoveryCount = 0;     // Number of measurements taken
double   g_throttleStopMaxMs = 0;         // Worst-case recovery (stop phase)
double   g_throttleLimitMaxMs = 0;        // Worst-case recovery (limit phase)
double   g_throttleStopTotalMs = 0;       // Sum for average (stop phase)
double   g_throttleLimitTotalMs = 0;      // Sum for average (limit phase)
int      g_throttleStopMeasurements = 0;  // Count (stop phase)
int      g_throttleLimitMeasurements = 0; // Count (limit phase)

//--- Buffer flush measurement (sync place+delete round-trip for EA tuning)
double   g_bufferFlushMs[];              // Individual flush measurements
int      g_bufferFlushCount = 0;
double   g_bufferFlushAvgMs = 0;
double   g_bufferFlushMaxMs = 0;
int      g_safeAsyncBatchStop = 0;       // Recommended: floor(0.9 × max verified stops)
int      g_safeAsyncBatchLimit = 0;      // Recommended: floor(0.9 × max verified limits)

//--- File handles
int      g_evidenceCsvHandle = INVALID_HANDLE;
int      g_tickCsvHandle     = INVALID_HANDLE;
int      g_brokerLogHandle   = INVALID_HANDLE;
int      g_calibCsvHandle    = INVALID_HANDLE;
string   g_evidenceCsvName;
string   g_tickCsvName;
string   g_brokerLogName;
string   g_calibCsvName;
string   g_histCsvName;
string   g_reportPdfName;
string   g_reportHtmName;
string   g_tomlName;
string   g_outputFolder;    // Full path to output folder
long     g_lastCalibLogMs  = 0;   // Throttle: last calibration snapshot epoch ms

//--- Panel
string   g_panelLabels[];
string   g_panelRightLabels[];  // Right-column labels for dual-column lines
string   g_panelBgName = "FA_PanelBG";
string   g_panelLeftBoxName  = "FA_LeftBox";
string   g_panelRightBoxName = "FA_RightBox";
#define  PANEL_LINES    50
#define  PANEL_X        10
#define  PANEL_Y        30
#define  PANEL_WIDTH    620
#define  PANEL_WIDTH_EX 1160      // Expanded width at summary (3 columns)
#define  PANEL_LINE_H   16
#define  PANEL_COL2_X   (PANEL_X + PANEL_WIDTH / 2 + 8)
#define  PANEL_COL3_X   (PANEL_X + PANEL_WIDTH + 4)   // Bar chart column start (tight to panel)
#define  PANEL_RCOL_COUNT 10  // Right-column labels (mapped to panel lines 3-12)

//--- Bar chart objects (created at summary)
#define  BAR_MAX_TYPES  10
#define  BAR_CHART_W    520     // Width of bar chart area
#define  BAR_CHART_H    300     // Height of bar chart area (bars grow upward)
#define  BAR_W          36      // Width of each bar
#define  BAR_GAP        8       // Gap between bars
bool     g_barChartDrawn = false;
#define  PANEL_RCOL_START 3   // First panel line with right column

//--- PDF builder state
string   g_pdfPages[];       // Completed page content streams
int      g_pdfPageCount;     // Pages built so far
double   g_pdfY;             // Current Y position on page
string   g_pdfCurStream;     // Current page stream being built

#define  PDF_W       595.0   // A4 width (points)
#define  PDF_H       842.0   // A4 height (points)
#define  PDF_ML       72.0   // Left margin
#define  PDF_CW      451.0   // Content width (595 - 72 - 72)
#define  PDF_TOP     770.0   // Top of content area
#define  PDF_BOT      68.0   // Bottom margin (footer line at 60, page# at 42)


//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS                                               |
//+------------------------------------------------------------------+
void     RunStateMachine();
void     DoCsCalibrate();
void     DoMarketBuy();
void     DoMarketBuySLTP();
void     DoMarketSell();
void     DoMarketSellSLTP();
void     DoMarketCloseBuy();
void     DoMarketCloseSell();
void     PlaceForensicGrid();
void     PlaceTPSLOnPositions();
void     CheckGridTriggers(double bid, double ask);
void     SendAsyncCloses();
void     DoSyncCloseSweep();
bool     VerifyAllClosed();
void     RecordFill(ENUM_FILL_TYPE type, ulong orderTicket, ulong dealTicket,
                    double reqPrice, double fillPrice, double bid, double ask,
                    ulong sendMs, ulong triggerMs, ulong fillMs,
                    double volume, bool isBuy, string notes);
void     CalcAllStatistics();
void     DetectVirtualDealer();
void     GeneratePDFReport();
int      PdfW(int fh, string s);
void     PdfInit();
void     PdfNewPage();
void     PdfFinishPage();
void     PdfCheckY(double needed);
string   PdfEsc(string s);
void     PdfCenterBold(string text, double sz, double r, double g2, double b);
void     PdfCenter(string text, double sz);
void     PdfSection(string text);
void     PdfSubSec(string text);
void     PdfBody(string text);
void     PdfBodyBold(string text);
void     PdfBodyColor(string text, double r, double g2, double b);
void     PdfHRule();
void     PdfSpace(double pts);
void     PdfKV(string key, string val);
void     PdfStatBox(double x, double w, double h, string value, string label, double vr, double vg2, double vb);
void     PdfTableRow(string col1, string col2, string col3, string col4, double cr, double cg, double cb);
void     PdfTableHeader(string col1, string col2, string col3, string col4);
void     PdfWriteFile(string filename);
void     GenerateHTMLReport();
void     GenerateTOML();
void     GenerateTradeHistory();
string   ComputeFileSHA256(string filename);
string   ComputeDataSHA256(string data);
void     WriteIntegrityHashes();
void     AnalyzePreviousDayDamage();
void     AnalyzePhantomSpikes();
void     ComputeMarginVerification();
void     RunStressTest();
double   MeasureThrottleRecovery(bool isLimitPhase);
void     MeasureBufferFlush();
void     TrackRejection(int retcode, string orderType, double orderPrice=0, double bidNow=0, double askNow=0);
void     ClassifyRejections(double medStopLag, double medLimitLag, double stopLimitRatio);
void     TrackFillRejection(ulong orderTicket, long orderState, long orderReason, long doneMsc);
void     ClassifyFillRejections(double medStopLag, double medLimitLag, double stopLimitRatio);
void     UpdatePanel();
void     SetPanelLine(int line, string text, color clr);
void     SetPanelRight(int panelLine, string text, color clr);
void     ClearPanelRight();
void     ShowAsymmetryBoxes(int headerLine, int numDataLines);
void     DrawSummaryBarChart();
void     CleanupBarChart();
void     LogEvidence(int cycle, string eventType, string orderType,
                     ulong ticket, double reqPrice, double fillPrice,
                     double bid, double ask, double slipPts, double lagMs,
                     double brokerExecMs, double volume, string notes);
void     LogTick(double bid, double ask);
double   CalcMedianFromArray(double &arr[], int count);
double   CalcPercentile(double &arr[], int count, double pct);
string   GetFillTypeName(ENUM_FILL_TYPE t);
string   FormatMs(double ms, bool hasData=false);
string   FormatMoney(double val);
int      GetAvailableSlots();
ulong    FindTriggerTick(double triggerPrice, int mode, ulong beforeMs, ulong afterMs);
long     FindTriggerTickMsc(double triggerPrice, int mode, long afterMsc, long beforeMsc);


//+------------------------------------------------------------------+
//| Strip broker suffix from symbol to get base instrument name.       |
//| Examples: "XAUUSD.r" → "XAUUSD", "EURUSDm" → "EURUSD",          |
//|           "EURUSD.pro" → "EURUSD", "XAUUSD_SB" → "XAUUSD"       |
//+------------------------------------------------------------------+
string StripSymbolSuffix(string sym)
{
   // Common suffix patterns: .xxx, _xxx, single trailing letter (m, r, c, etc.)
   // Strategy: try to match known base symbols from longest to shortest

   // Known base symbols (most common instruments)
   string bases[] = {
      // Forex majors & crosses
      "EURUSD","GBPUSD","USDJPY","USDCHF","AUDUSD","NZDUSD","USDCAD",
      "EURGBP","EURJPY","EURCHF","EURAUD","EURNZD","EURCAD",
      "GBPJPY","GBPCHF","GBPAUD","GBPNZD","GBPCAD",
      "AUDJPY","AUDCHF","AUDNZD","AUDCAD",
      "NZDJPY","NZDCHF","NZDCAD",
      "CADJPY","CADCHF","CHFJPY",
      // Metals
      "XAUUSD","XAGUSD","XPTUSD","XPDUSD","XAUEUR","XAGEUR",
      // Oil / Energy
      "USOIL","UKOIL","XTIUSD","XBRUSD","WTIUSD","BRENT","WTI","CL","NGAS",
      // Indices
      "US500","US30","US100","NAS100","SPX500","DJ30","USTEC",
      "UK100","DE40","DE30","DAX40","DAX30","FR40","EU50",
      "JP225","AU200","HK50","CN50",
      // Crypto
      "BTCUSD","ETHUSD","LTCUSD","XRPUSD","BCHUSD","DOTUSD","ADAUSD","SOLUSD",
      "BTCEUR","ETHEUR"
   };

   string symUpper = sym;
   StringToUpper(symUpper);

   // Try exact match first (no suffix)
   for(int i = 0; i < ArraySize(bases); i++)
   {
      if(symUpper == bases[i])
         return bases[i];
   }

   // Try prefix match (symbol starts with a known base, rest is suffix)
   string bestMatch = "";
   int bestLen = 0;
   for(int i = 0; i < ArraySize(bases); i++)
   {
      int bLen = StringLen(bases[i]);
      if(bLen > bestLen && StringLen(symUpper) > bLen)
      {
         if(StringSubstr(symUpper, 0, bLen) == bases[i])
         {
            bestMatch = bases[i];
            bestLen = bLen;
         }
      }
   }

   if(bestLen > 0)
      return bestMatch;

   // Fallback: strip common suffixes manually
   string result = symUpper;
   // Strip .xxx suffix (e.g., ".pro", ".r", ".std")
   int dotPos = StringFind(result, ".");
   if(dotPos > 0)
      result = StringSubstr(result, 0, dotPos);
   // Strip _xxx suffix (e.g., "_SB", "_STD")
   int usPos = StringFind(result, "_");
   if(usPos > 0)
      result = StringSubstr(result, 0, usPos);
   // Strip single trailing letter if result length > 5 and last char is alpha
   // (catches "EURUSDm" but not "US30")
   int rLen = StringLen(result);
   if(rLen > 5)
   {
      ushort lastChar = StringGetCharacter(result, rLen - 1);
      if((lastChar >= 'A' && lastChar <= 'Z') || (lastChar >= 'a' && lastChar <= 'z'))
      {
         // Check if removing last char gives a known base
         string trimmed = StringSubstr(result, 0, rLen - 1);
         for(int i = 0; i < ArraySize(bases); i++)
         {
            if(trimmed == bases[i])
               return bases[i];
         }
      }
   }

   return result;
}

//+------------------------------------------------------------------+
//| Get the standard (minimum) digit count for a base symbol.          |
//| This is the digit count used by brokers with standard pricing —    |
//| extra-precision brokers add 1 digit on top.                        |
//+------------------------------------------------------------------+
int GetStandardDigits(string baseSym)
{
   // Forex majors (non-JPY): 4 digits standard, 5 = extra
   // Forex JPY pairs: 2 digits standard, 3 = extra
   // Gold/Silver/Platinum/Palladium: 2 digits standard, 3 = extra
   // Oil: 2 digits standard, 3 = extra
   // Crypto: 2 digits standard, 3 = extra
   // Indices: varies, use broker's actual digits (no known standard)

   // JPY pairs: any pair containing "JPY"
   if(StringFind(baseSym, "JPY") >= 0)
      return 2;

   // Metals
   if(StringFind(baseSym, "XAU") >= 0) return 2;
   if(StringFind(baseSym, "XAG") >= 0) return 2;
   if(StringFind(baseSym, "XPT") >= 0) return 2;
   if(StringFind(baseSym, "XPD") >= 0) return 2;

   // Oil / Energy
   if(baseSym == "USOIL" || baseSym == "UKOIL" || baseSym == "WTI" ||
      baseSym == "BRENT" || baseSym == "CL" || baseSym == "NGAS" ||
      StringFind(baseSym, "XTI") >= 0 || StringFind(baseSym, "XBR") >= 0)
      return 2;

   // Crypto
   if(StringFind(baseSym, "BTC") >= 0 || StringFind(baseSym, "ETH") >= 0 ||
      StringFind(baseSym, "LTC") >= 0 || StringFind(baseSym, "XRP") >= 0 ||
      StringFind(baseSym, "SOL") >= 0 || StringFind(baseSym, "ADA") >= 0 ||
      StringFind(baseSym, "DOT") >= 0 || StringFind(baseSym, "BCH") >= 0)
      return 2;

   // Forex majors/crosses (6 chars, no JPY): 4 digits
   if(StringLen(baseSym) == 6)
      return 4;

   // Indices and everything else: use actual broker digits (no adjustment)
   return -1;  // -1 = unknown, use broker digits as-is
}

//+------------------------------------------------------------------+
//| Expert initialization                                              |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Collect environment info
   g_brokerName      = AccountInfoString(ACCOUNT_COMPANY);
   // Sanitize broker name for safe filenames (dots, spaces, slashes, colons, etc.)
   g_brokerNameFile  = g_brokerName;
   StringReplace(g_brokerNameFile, " ", "_");
   StringReplace(g_brokerNameFile, ".", "_");
   StringReplace(g_brokerNameFile, "/", "_");
   StringReplace(g_brokerNameFile, "\\", "_");
   StringReplace(g_brokerNameFile, ":", "_");
   StringReplace(g_brokerNameFile, ",", "_");
   // Sanitize symbol for filenames (e.g. "XAUUSD.c" → "XAUUSD_c")
   g_symbolFile = Symbol();
   StringReplace(g_symbolFile, ".", "_");
   StringReplace(g_symbolFile, "/", "_");
   StringReplace(g_symbolFile, "\\", "_");
   StringReplace(g_symbolFile, ":", "_");
   g_serverName      = AccountInfoString(ACCOUNT_SERVER);
   g_accountNumber   = AccountInfoInteger(ACCOUNT_LOGIN);
   g_accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);
   g_displayCurrency = "USD";  // Standardized — all reports show USD regardless of account denomination
   g_accountLeverage = AccountInfoInteger(ACCOUNT_LEVERAGE);
   g_accountMarginMode = (long)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   g_startingEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_tickValue       = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   g_tickSize        = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   g_point           = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   g_contractSize    = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
   g_digits          = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   g_minLot          = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   g_stopsLevel      = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
   g_freezeLevel     = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_FREEZE_LEVEL);
   g_mt5Build        = (int)TerminalInfoInteger(TERMINAL_BUILD);

   // Auto-detect lot size
   g_lotSize = (InpLotSize > 0) ? InpLotSize : g_minLot;

   // Broker order limit
   g_orderLimit = AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   if(g_orderLimit == 0) g_orderLimit = 500; // No limit reported
   g_maxPositionsObserved = 0;
   g_maxPendingObserved = 0;
   g_maxTotalObserved = 0;

   // Adaptive cycle count for low-order-limit accounts
   // Target: 60 fills minimum (30 per group — statistical significance threshold)
   // Conservative: assume 50% fill rate on placed orders
   // For court-grade evidence, user can increase InpTotalCycles in settings
   {
      int gridSlots = (int)MathMax(8, g_orderLimit - 4);  // Reserve 4 for market test
      int ordersPerCycle = (gridSlots / 4) * 4;            // Round down to multiple of 4
      int expectedFillsPerCycle = (int)(ordersPerCycle * 0.5); // Conservative 50% fill rate
      if(expectedFillsPerCycle < 4) expectedFillsPerCycle = 4;

      int minTotalFills = 60;  // 30 per group = CLT minimum for two-sample comparison
      int minCycles = (int)MathCeil((double)minTotalFills / expectedFillsPerCycle);
      g_effectiveCycles = MathMax(InpTotalCycles, minCycles);
      if(g_effectiveCycles > InpTotalCycles)
         PrintFormat("Cycles increased from %d to %d (order limit %d → ~%d fills/cycle, need %d+ total)",
            InpTotalCycles, g_effectiveCycles, (int)g_orderLimit, expectedFillsPerCycle, minTotalFills);
   }

   // Pip standardization — normalize to the lowest-digit broker's resolution
   // so that 1 pip = same value regardless of whether broker uses extra precision.
   //
   // Step 1: Strip broker suffix to identify base instrument
   g_baseSymbol = StripSymbolSuffix(Symbol());
   // Step 2: Look up standard digit count for this instrument class
   g_stdDigits = GetStandardDigits(g_baseSymbol);

   if(g_stdDigits > 0 && g_digits > g_stdDigits)
   {
      // Broker has extra precision digits beyond the standard
      // e.g., 3-digit gold (std=2), 5-digit forex (std=4)
      int extraDigits = g_digits - g_stdDigits;
      g_pipMult = (int)MathPow(10, extraDigits);
      g_pipSize = g_point * g_pipMult;
      g_unitLabel = "pts";
   }
   else if(g_stdDigits > 0 && g_digits < g_stdDigits)
   {
      // Broker has FEWER digits than standard (e.g., 1-digit gold when std=2)
      // Pip size must still be based on standard, not the broker's reduced precision
      // g_point is larger than a pip — 1 point = multiple pips
      g_pipMult = 1;
      g_pipSize = MathPow(10, -g_stdDigits);  // 10^(-2) = 0.01 for gold, 10^(-4) = 0.0001 for forex
      g_unitLabel = "pips";
      PrintFormat("WARNING: Broker uses %d digits (standard=%d) — reduced precision. Pip=%.5f Point=%.5f",
         g_digits, g_stdDigits, g_pipSize, g_point);
   }
   else
   {
      // Standard precision or unknown instrument — pip = point
      g_pipMult = 1;
      g_pipSize = g_point;
      g_unitLabel = "pips";
      if(g_stdDigits < 0) g_stdDigits = g_digits;  // unknown, use actual
   }

   // Currency digits (2 for USD/EUR/GBP, 0 for JPY, etc.)
   g_currencyDigits = 2;
   if(g_accountCurrency == "JPY" || g_accountCurrency == "HUF") g_currencyDigits = 0;

   //--- Calibrate epoch offset: GetTickCount64() → epoch milliseconds
   ulong nowBoot = GetTickCount64();
   ulong nowEpoch = (ulong)TimeCurrent() * 1000;
   g_epochMsOffset = nowEpoch - nowBoot;

   //--- Setup trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(100); // Wide deviation to avoid requotes

   // Auto-detect fill mode from broker's supported filling policies
   int fillMode = (int)SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_FOK) != 0)
      g_fillType = ORDER_FILLING_FOK;
   else if((fillMode & SYMBOL_FILLING_IOC) != 0)
      g_fillType = ORDER_FILLING_IOC;
   else
      g_fillType = ORDER_FILLING_RETURN;
   g_trade.SetTypeFilling(g_fillType);
   PrintFormat("  Fill mode: %s (broker flags: %d)",
      (g_fillType == ORDER_FILLING_FOK) ? "FOK" : (g_fillType == ORDER_FILLING_IOC) ? "IOC" : "RETURN",
      fillMode);

   //--- Allocate tick buffer
   ArrayResize(g_tickBuf, TICK_BUF_SIZE);

   //--- Init throttle recovery arrays
   ArrayResize(g_throttleRecoveryMs, 0);
   ArrayResize(g_throttleRecoveryAttempts, 0);

   //--- Init fill records
   ArrayResize(g_fills, 0);
   ArrayResize(g_cycles, g_effectiveCycles);
   g_fillCount = 0;

   //--- Init stats
   g_roundingErrorSum    = 0;
   g_roundingErrorAbsSum = 0;
   g_roundingErrorMax    = 0;
   g_roundingErrorCount  = 0;
   g_brokerProfitSum     = 0;
   g_exactProfitSum      = 0;
   g_clusterCount        = 0;
   g_isolatedFills       = 0;
   g_avgClusterSize      = 0;
   g_maxClusterSize      = 0;
   g_avgInterClusterGap  = 0;
   g_clusterRatio        = 0;
   g_batchCount          = 0;
   g_individualFills     = 0;
   g_avgBatchSize        = 0;
   g_maxBatchSize        = 0;
   g_batchRatio          = 0;
   g_batchAdvantagePts   = 0;
   g_avgBatchAdvantagePts = 0;
   g_totalBatchedFills   = 0;
   g_fairFills           = 0;
   g_fairFillsStop       = 0;
   g_fairFillsLimit      = 0;
   g_totalStopPriced     = 0;
   g_totalLimitPriced    = 0;
   g_totalPricedFills    = 0;
   g_batchTimeSpanMs     = 0;
   g_avgBatchTimeSpanMs  = 0;
   g_maxBatchTimeSpanMs  = 0;
   g_medBatchTimeSpanMs  = 0;
   g_batchClassification = "FAIR";
   g_totalLotsTraded     = 0;
   g_totalAdverseSlipUSD = 0;
   g_totalAdverseSlipPips = 0;
   g_adverseFillCount = 0;
   g_stopAdverseSlipUSD = 0;
   g_stopAdverseSlipPips = 0;
   g_stopAdverseFillCount = 0;
   g_limitAdverseSlipUSD = 0;
   g_limitAdverseSlipPips = 0;
   g_limitAdverseFillCount = 0;
   g_totalFinancialDelta = 0;
   for(int i = 0; i < 10; i++)
   {
      g_medianLag[i] = 0; g_meanLag[i] = 0; g_minLag[i] = 0; g_maxLag[i] = 0;
      g_countByType[i] = 0; g_lagValidCount[i] = 0;
      g_meanSlipSigned[i] = 0; g_meanSlipAbs[i] = 0; g_totalSlipUSD[i] = 0;
      g_driftLagSum[i] = 0; g_driftLagCount[i] = 0;
      g_triggerFillCount[i] = 0; g_marketFillCount[i] = 0;
   }
   // Per-cluster detail + fill model globals
   ArrayResize(g_clusterDetails, 0);
   g_clusterDetailCount = 0;
   g_fmLastTick = 0; g_fmTrigger = 0; g_fmLagInterp = 0; g_fmWorstPrice = 0;
   g_fmUnclassifiable = 0; g_fmTotal = 0;
   g_fmDominantModel = "";
   g_fmAlpha = 0; g_fmBeta = 0;

   //--- Open evidence CSV
   string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
   StringReplace(dateStr, ".", "");
   string prefix = StringFormat("ForensicEvidence.%s.%d.%s.%s",
                   g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
   g_evidenceCsvName = prefix + ".csv";
   g_evidenceCsvHandle = FileOpen(g_evidenceCsvName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(g_evidenceCsvHandle != INVALID_HANDLE)
   {
      FileWriteString(g_evidenceCsvHandle,
         "Cycle,EventType,OrderType,Ticket,RequestedPrice,FillPrice,Bid,Ask,Spread," +
         "PriceDriftPts,PriceDriftUSD,LagMs,BrokerExecMs,Volume,TimestampMs,EpochMs,Notes\n");
   }

   //--- Open tick CSV
   string tickPrefix = StringFormat("ForensicTicks.%s.%d.%s.%s",
                       g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
   g_tickCsvName = tickPrefix + ".csv";
   g_tickCsvHandle = FileOpen(g_tickCsvName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(g_tickCsvHandle != INVALID_HANDLE)
      FileWriteString(g_tickCsvHandle, "TimestampMs,EpochMs,Bid,Ask,Spread\n");

   //--- Open broker transaction log CSV
   string logPrefix = StringFormat("ForensicBrokerLog.%s.%d.%s.%s",
                      g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
   g_brokerLogName = logPrefix + ".csv";
   g_brokerLogHandle = FileOpen(g_brokerLogName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(g_brokerLogHandle != INVALID_HANDLE)
      FileWriteString(g_brokerLogHandle,
         "TimestampMs,EpochMs,DateTime,TransType,Deal,Order,Symbol,DealType,"
         "Entry,Reason,Price,Volume,Profit,Commission,Swap,PositionID,"
         "Magic,Comment\n");

   //--- Open calibration snapshot CSV (broker.rs validation ground truth)
   //    Only when EA tuning is enabled — this data is for personal solver calibration,
   //    not needed for forensic reporting
   if(InpShowEATuning)
   {
      string calibPrefix = StringFormat("ForensicCalibration.%s.%d.%s.%s",
                           g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
      g_calibCsvName = calibPrefix + ".csv";
      g_calibCsvHandle = FileOpen(g_calibCsvName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
      if(g_calibCsvHandle != INVALID_HANDLE)
         FileWriteString(g_calibCsvHandle,
            "EpochMs,Event,Cycle,Bid,Ask,Balance,Equity,Margin,MarginLevel,"
            "FreeMargin,Positions,LongLots,ShortLots,SwapAccum,LongAvgEntry,ShortAvgEntry\n");
   }

   //--- Trade history filename (written at report time)
   string histPrefix = StringFormat("ForensicHistory.%s.%d.%s.%s",
                       g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
   g_histCsvName = histPrefix + ".csv";

   //--- Report filenames
   string rptPrefix = StringFormat("ForensicReport.%s.%d.%s.%s",
                      g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);
   g_reportPdfName = rptPrefix + ".pdf";
   g_reportHtmName = rptPrefix + ".htm";
   g_tomlName = StringFormat("ForensicData.%s.%d.%s.%s.toml",
                g_brokerNameFile, g_accountNumber, g_symbolFile, dateStr);

   //--- Resolve full output path (MT5 Common Files folder)
   g_outputFolder = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files";

   //--- Create panel
   ArrayResize(g_panelLabels, PANEL_LINES);
   ObjectCreate(0, g_panelBgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_XDISTANCE, PANEL_X);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_YDISTANCE, PANEL_Y);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_XSIZE, PANEL_WIDTH);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_YSIZE, PANEL_LINES * PANEL_LINE_H + 10);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_BORDER_COLOR, clrCyan);
   ObjectSetInteger(0, g_panelBgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);

   for(int i = 0; i < PANEL_LINES; i++)
   {
      g_panelLabels[i] = "FA_Line_" + IntegerToString(i);
      ObjectCreate(0, g_panelLabels[i], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_panelLabels[i], OBJPROP_XDISTANCE, PANEL_X + 8);
      ObjectSetInteger(0, g_panelLabels[i], OBJPROP_YDISTANCE, PANEL_Y + 5 + i * PANEL_LINE_H);
      ObjectSetInteger(0, g_panelLabels[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, g_panelLabels[i], OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, g_panelLabels[i], OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, g_panelLabels[i], OBJPROP_COLOR, clrWhite);
      ObjectSetString(0, g_panelLabels[i], OBJPROP_TEXT, " ");
   }

   //--- Right-column labels for dual-column display
   ArrayResize(g_panelRightLabels, PANEL_RCOL_COUNT);
   for(int i = 0; i < PANEL_RCOL_COUNT; i++)
   {
      g_panelRightLabels[i] = "FA_RCol_" + IntegerToString(i);
      ObjectCreate(0, g_panelRightLabels[i], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, g_panelRightLabels[i], OBJPROP_XDISTANCE, PANEL_COL2_X);
      ObjectSetInteger(0, g_panelRightLabels[i], OBJPROP_YDISTANCE, PANEL_Y + 5 + (i + PANEL_RCOL_START) * PANEL_LINE_H);
      ObjectSetInteger(0, g_panelRightLabels[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, g_panelRightLabels[i], OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, g_panelRightLabels[i], OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, g_panelRightLabels[i], OBJPROP_COLOR, clrWhite);
      ObjectSetString(0, g_panelRightLabels[i], OBJPROP_TEXT, " ");
   }

   //--- Two boxes for asymmetry section (BROKER PROFITS / BROKER PAYS)
   //    Left box: red border (adverse to client)
   ObjectCreate(0, g_panelLeftBoxName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_BGCOLOR, C'30,10,10');
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_BORDER_COLOR, clrTomato);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_BACK, true);  // Render behind labels
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);

   //    Right box: green border (favorable to client)
   ObjectCreate(0, g_panelRightBoxName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_BGCOLOR, C'10,30,10');
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_BORDER_COLOR, clrLime);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_BACK, true);  // Render behind labels
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);

   //--- Log startup
   Print("═══════════════════════════════════════════════════════════");
   Print("  EXECUTIONEDGE ANALYZER v" + FA_VERSION);
   Print("  Open Source — https://github.com/TraderJoe2026/ExecutionEdge");
   Print("  Mirror: https://sourceforge.net/projects/executionedge/");
   Print("═══════════════════════════════════════════════════════════");
   PrintFormat("  Broker:    %s", g_brokerName);
   PrintFormat("  Server:    %s", g_serverName);
   PrintFormat("  Account:   %d (%s, 1:%d)", g_accountNumber, g_accountCurrency, g_accountLeverage);
   PrintFormat("  Symbol:    %s (%d digits)", Symbol(), g_digits);
   PrintFormat("  Lot size:  %.4f (min=%.4f)", g_lotSize, g_minLot);
   PrintFormat("  Tick val:  %.6f  Tick size: %.10f", g_tickValue, g_tickSize);
   PrintFormat("  Base sym:  %s (from %s)  Std digits: %d  Broker digits: %d",
               g_baseSymbol, Symbol(), g_stdDigits, g_digits);
   PrintFormat("  Pip size:  %.5f  Pip mult: %d (%s)", g_pipSize, g_pipMult, g_unitLabel);
   PrintFormat("  Stops lvl: %d pts (%.1f pips)  Freeze lvl: %d pts", g_stopsLevel, g_stopsLevel * g_point / g_pipSize, g_freezeLevel);
   PrintFormat("  Order lim: %d", g_orderLimit);
   PrintFormat("  Cycles:    %d%s", g_effectiveCycles,
      (g_effectiveCycles > InpTotalCycles) ? StringFormat(" (auto-increased from %d for statistical significance)", InpTotalCycles) : "");
   PrintFormat("  MT5 Build: %d", g_mt5Build);
   PrintFormat("  Output:    %s", g_outputFolder);
   Print("═══════════════════════════════════════════════════════════");

   //--- Show environment on panel and wait for START button
   g_state = STATE_WAIT_START;
   g_started = false;

   SetPanelLine(0, "══ BROKER FORENSIC ANALYZER v" + FA_VERSION + " ══", clrCyan);
   SetPanelLine(1, " ", clrBlack);
   SetPanelLine(2, StringFormat("Broker:  %s", g_brokerName), clrWhite);
   SetPanelLine(3, StringFormat("Server:  %s", g_serverName), clrSilver);
   SetPanelLine(4, StringFormat("Account: %d (%s, 1:%d)",
      (int)g_accountNumber, g_displayCurrency, (int)g_accountLeverage), clrSilver);
   SetPanelLine(5, StringFormat("Symbol:  %s → %s (%dd, std %dd, pip=%.5f)",
      Symbol(), g_baseSymbol, g_digits, g_stdDigits, g_pipSize), clrSilver);
   SetPanelLine(6, StringFormat("Lot:     %.4f | Cycles: %d", g_lotSize, g_effectiveCycles), clrSilver);
   SetPanelLine(7, " ", clrBlack);
   SetPanelLine(8, "Click this button to start:", clrYellow);

   //--- Create START button
   ObjectCreate(0, BTN_START_NAME, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_XDISTANCE, PANEL_X + 200);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_YDISTANCE, PANEL_Y + 160);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_XSIZE, 200);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_YSIZE, 40);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_BGCOLOR, clrForestGreen);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_BORDER_COLOR, clrLime);
   ObjectSetString(0, BTN_START_NAME, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_FONTSIZE, 14);
   ObjectSetString(0, BTN_START_NAME, OBJPROP_TEXT, "▶  START");
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_STATE, false);
   ObjectSetInteger(0, BTN_START_NAME, OBJPROP_ZORDER, 100);

   ChartRedraw(0);
   return INIT_SUCCEEDED;
}


//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // All CSV file handles are closed in STATE_REPORT after writing completes.
   // No file cleanup needed here — EA always runs to completion.

   // Clean up panel + button
   ObjectDelete(0, BTN_START_NAME);
   ObjectDelete(0, g_panelBgName);
   ObjectDelete(0, g_panelLeftBoxName);
   ObjectDelete(0, g_panelRightBoxName);
   for(int i = 0; i < PANEL_LINES; i++)
      ObjectDelete(0, g_panelLabels[i]);
   for(int i = 0; i < PANEL_RCOL_COUNT; i++)
      ObjectDelete(0, g_panelRightLabels[i]);
   CleanupBarChart();
}


//+------------------------------------------------------------------+
//| Chart event handler — START button                                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_START_NAME)
   {
      if(g_state != STATE_WAIT_START) return;  // Already started

      // Remove the button
      ObjectDelete(0, BTN_START_NAME);

      // Start the analysis
      g_collectionStartTime = TimeCurrent();
      g_state = STATE_INIT;
      g_started = true;

      // Clear pre-start panel lines
      for(int i = 1; i < PANEL_LINES; i++) SetPanelLine(i, " ", clrBlack);
      SetPanelLine(1, "Starting analysis...", clrYellow);

      Print("═══ START BUTTON PRESSED — Beginning execution benchmark ═══");
      ChartRedraw(0);
   }
}


//+------------------------------------------------------------------+
//| Expert tick function — state machine driver                        |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_started) return;

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   //--- Always log ticks and check triggers
   LogTick(bid, ask);

   // Record in circular buffer
   g_tickBuf[g_tickBufHead].timeMs = GetTickCount64();
   g_tickBuf[g_tickBufHead].bid    = bid;
   g_tickBuf[g_tickBufHead].ask    = ask;
   g_tickBufHead = (g_tickBufHead + 1) % TICK_BUF_SIZE;
   if(g_tickBufCount < TICK_BUF_SIZE) g_tickBufCount++;
   g_tickCount++;

   //--- V1.17: Track max positions/pending/total high watermarks
   {
      int curPos = PositionsTotal();
      int curPend = OrdersTotal();
      int curTot = curPos + curPend;
      if(curPos > g_maxPositionsObserved) g_maxPositionsObserved = curPos;
      if(curPend > g_maxPendingObserved)  g_maxPendingObserved = curPend;
      if(curTot > g_maxTotalObserved)     g_maxTotalObserved = curTot;
   }

   //--- Check trigger crossings for active grid
   if(g_state == STATE_GRID_WAIT)
      CheckGridTriggers(bid, ask);

   //--- Run state machine
   RunStateMachine();

   //--- Update panel every tick (spread, leverage, account info, execution stats)
   if(g_state != STATE_WAIT_START)
      UpdatePanel();
}


//+------------------------------------------------------------------+
//| State machine                                                      |
//+------------------------------------------------------------------+
void RunStateMachine()
{
   switch(g_state)
   {
      case STATE_INIT:
         g_calibPass = 0;
         SetPanelLine(1, "Phase 0: Calibrating CS latency (pass 1 of 2)...", clrYellow);
         g_state = STATE_CS_CALIBRATE;
         break;

      case STATE_CS_CALIBRATE:
         DoCsCalibrate();
         break;

      case STATE_MARKET_BUY:
         DoMarketBuy();
         break;

      case STATE_MARKET_BUY_WAIT:
         // Waiting for buy fill via OnTradeTransaction
         break;

      case STATE_MARKET_BUY_SLTP:
         DoMarketBuySLTP();
         break;

      case STATE_MARKET_SELL:
         DoMarketSell();
         break;

      case STATE_MARKET_SELL_WAIT:
         // Waiting for sell fill via OnTradeTransaction
         break;

      case STATE_MARKET_SELL_SLTP:
         DoMarketSellSLTP();
         break;

      case STATE_MARKET_WAIT_PROFIT:
         CheckWaitProfit();
         break;

      case STATE_MARKET_CLOSE_BUY:
         DoMarketCloseBuy();
         break;

      case STATE_MARKET_CLOSE_BUY_WAIT:
         // Waiting for buy close fill
         break;

      case STATE_MARKET_CLOSE_SELL:
         DoMarketCloseSell();
         break;

      case STATE_MARKET_CLOSE_SELL_WAIT:
         // Waiting for sell close fill
         break;

      case STATE_GRID_PLACE:
         g_cycleNum++;
         SetPanelLine(1, StringFormat("Cycle %d of %d: Placing grid...", g_cycleNum, g_effectiveCycles), clrYellow);
         PlaceForensicGrid();
         g_state = STATE_GRID_WAIT;
         break;

      case STATE_GRID_WAIT:
      {
         // Place TP/SL on any newly filled positions (sync, measures placement lag)
         PlaceTPSLOnPositions();

         // Calibration snapshot: log MT5 account state every 1 second (broker.rs ground truth)
         {
            ulong calibEpoch = g_epochMsOffset + GetTickCount64();
            if((long)calibEpoch - g_lastCalibLogMs >= 1000)
            {
               LogCalibrationSnapshot("TICK", g_cycleNum);
               g_lastCalibLogMs = (long)calibEpoch;
            }
         }

         // Timers
         ulong nowMs = GetTickCount64();
         ulong elapsedMs = (g_gridPlacedMs > 0) ? (nowMs - g_gridPlacedMs) : 0;
         bool dwellReached = (elapsedMs > (ulong)InpCycleTimeoutSec * 1000);

         // TP/SL trigger gate: need minimum triggers for valid asymmetry measurement
         int curTP = 0, curSL = 0;
         if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
         {
            curTP = g_cycles[g_cycleNum - 1].tpTriggers;
            curSL = g_cycles[g_cycleNum - 1].slTriggers;
         }
         bool tpslSufficient = (curTP >= InpMinTPSLTriggers && curSL >= InpMinTPSLTriggers);

         // --- Early close: price moved far beyond grid, remaining orders won't trigger ---
         bool priceExhausted = false;
         if(g_gridSize > 0 && g_gridFillsReceived >= 2)
         {
            double gridHigh = 0, gridLow = 999999;
            for(int gi = 0; gi < g_gridSize; gi++)
            {
               if(g_grid[gi].price > gridHigh) gridHigh = g_grid[gi].price;
               if(g_grid[gi].price < gridLow)  gridLow  = g_grid[gi].price;
            }
            double curBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
            double curAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            double curSpread = curAsk - curBid;
            double escapeThreshold = curSpread * 5.0;
            if(curBid > gridHigh + escapeThreshold || curAsk < gridLow - escapeThreshold)
               priceExhausted = true;
         }

         // Close ONLY when BOTH conditions are met: minimum dwell time AND TP/SL gate
         // OR early close: price exhausted the grid (remaining orders won't fill)
         if((dwellReached && tpslSufficient) || (dwellReached && priceExhausted))
         {
            if(priceExhausted && !tpslSufficient)
               PrintFormat("Cycle %d: Price escaped grid (>5 spreads beyond) — early close with %d fills, TP:%d SL:%d",
                  g_cycleNum, g_gridFillsReceived, curTP, curSL);
            else
               PrintFormat("Cycle %d: %ds dwell + TP:%d SL:%d — closing grid",
                  g_cycleNum, InpCycleTimeoutSec, curTP, curSL);
            g_state = STATE_GRID_CLOSE;
         }
         else if(dwellReached && !tpslSufficient)
         {
            // Dwell reached but waiting for TP/SL triggers — show status
            int elapsedSec = (int)(elapsedMs / 1000);
            if(priceExhausted)
               SetPanelLine(1, StringFormat("Cycle %d: Price escaped grid — closing at dwell timeout (%ds)...",
                  g_cycleNum, elapsedSec), clrOrange);
            else
               SetPanelLine(1, StringFormat("Cycle %d: Waiting for TP/SL (TP:%d SL:%d, need %d each) — %ds elapsed...",
                  g_cycleNum, curTP, curSL, InpMinTPSLTriggers, elapsedSec), clrYellow);
         }

         // UpdatePanel() now called from OnTick after RunStateMachine()
         break;
      }

      case STATE_GRID_CLOSE:
         // Calibration: snapshot account state just before closing all positions
         LogCalibrationSnapshot("PRE_CLOSE", g_cycleNum);
         SetPanelLine(1, StringFormat("Cycle %d: Closing positions...", g_cycleNum), clrYellow);
         SendAsyncCloses();    // Phase 1: fire all close requests, return immediately
         g_state = STATE_GRID_ASYNC_WAIT;
         break;

      case STATE_GRID_ASYNC_WAIT:
      {
         // Non-blocking wait: OnTradeTransaction fires between ticks, incrementing g_closeFillsReceived
         ulong elapsedMs = GetTickCount64() - g_closeTriggerMs;
         bool allReceived = (g_closeFillsExpected > 0 && g_closeFillsReceived >= g_closeFillsExpected);
         bool timeoutReached = (elapsedMs >= 5000);

         if(allReceived || timeoutReached)
         {
            // Mark async window closed — fills after this are stragglers
            g_asyncCloseComplete = true;
            if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
               g_cycles[g_cycleNum - 1].asyncFillCount = g_closeFillsReceived;

            PrintFormat("ASYNC WAIT: %d/%d fills in %dms%s",
               g_closeFillsReceived, g_closeFillsExpected, (int)elapsedMs,
               allReceived ? " (all received)" : " (timeout)");

            // Phase 2: sync sweep of anything still remaining
            DoSyncCloseSweep();
            g_state = STATE_GRID_VERIFY;
         }
         else
         {
            SetPanelLine(1, StringFormat("Cycle %d: Async close %d/%d (%.1fs)...",
               g_cycleNum, g_closeFillsReceived, g_closeFillsExpected, elapsedMs / 1000.0), clrYellow);
         }
         break;
      }

      case STATE_GRID_VERIFY:
         if(VerifyAllClosed())
         {
            // Calibration: snapshot after all positions confirmed closed
            LogCalibrationSnapshot("POST_CLOSE", g_cycleNum);

            // Record cycle financial delta
            if(g_cycleNum <= ArraySize(g_cycles))
            {
               int ci = g_cycleNum - 1;
               g_cycles[ci].postCloseBalance = AccountInfoDouble(ACCOUNT_BALANCE);
               g_cycles[ci].financialDelta = g_cycles[ci].postCloseBalance - g_cycles[ci].preCloseEquity;
               g_totalFinancialDelta += g_cycles[ci].financialDelta;

               // Cycle close lag: median of per-fill broker exec times (DEAL_TIME_MSC based)
               // This is authoritative — uses broker server timestamps, not EA-side GetTickCount64
               // Use async fills if available; if all fills were sync (stragglers), use sync median
               g_cycles[ci].closeFills = g_closeFillsReceived;
               if(g_closeBrokerExecCount > 0)
                  g_cycles[ci].closeBrokerExecMs = CalcMedianFromArray(g_closeBrokerExecLags, g_closeBrokerExecCount);
               else if(g_closeSyncExecCount > 0)
                  g_cycles[ci].closeBrokerExecMs = CalcMedianFromArray(g_closeSyncExecLags, g_closeSyncExecCount);
               else
                  g_cycles[ci].closeBrokerExecMs = 0;
               g_cycles[ci].closeLagMs = g_cycles[ci].closeBrokerExecMs + (double)g_clientServerLagMs;
            }

            PrintFormat("Cycle %d complete: %d fills, %d closes",
                        g_cycleNum, g_gridFillsReceived, g_closeFillsReceived);

            // Check if we have enough pending fills for statistical validity
            // Count stop and limit fills across ALL cycles
            int totalStopFills = 0, totalLimitFills = 0;
            for(int fi = 0; fi < g_fillCount; fi++)
            {
               if(g_fills[fi].fillType == FILL_BUYSTOP || g_fills[fi].fillType == FILL_SELLSTOP)
                  totalStopFills++;
               else if(g_fills[fi].fillType == FILL_BUYLIMIT || g_fills[fi].fillType == FILL_SELLLIMIT)
                  totalLimitFills++;
            }
            bool statsValid = (totalStopFills >= 30 && totalLimitFills >= 30);
            if(statsValid && g_cycleNum < g_effectiveCycles)
            {
               PrintFormat("═══ STATISTICAL VALIDITY REACHED: %d stops + %d limits (need 30 each) — skipping remaining %d cycles ═══",
                  totalStopFills, totalLimitFills, g_effectiveCycles - g_cycleNum);
               g_effectiveCycles = g_cycleNum;  // Truncate to current cycle count
            }
            // If we've completed the planned cycles but haven't met CLT minimums, extend
            // Safety cap: max 3x original cycles to prevent infinite looping on very sparse fills
            else if(!statsValid && g_cycleNum >= g_effectiveCycles && g_cycleNum < InpTotalCycles * 3)
            {
               g_effectiveCycles++;
               ArrayResize(g_cycles, g_effectiveCycles);
               PrintFormat("═══ EXTENDING: %d stops + %d limits (need 30 each) — adding cycle %d for statistical validity ═══",
                  totalStopFills, totalLimitFills, g_effectiveCycles);
               SetPanelLine(2, StringFormat("Extending to cycle %d (need 30 stops + 30 limits, have %d + %d)",
                  g_effectiveCycles, totalStopFills, totalLimitFills), clrOrange);
            }
            else if(!statsValid && g_cycleNum >= InpTotalCycles * 3)
            {
               PrintFormat("═══ SAFETY CAP: %d stops + %d limits after %d cycles (3x max) — proceeding with available data ═══",
                  totalStopFills, totalLimitFills, g_cycleNum);
            }

            if(g_cycleNum >= g_effectiveCycles)
            {
               g_collectionEndTime = TimeCurrent();
               g_gridPhaseEndMs = GetTickCount64();  // Snapshot for phantom spike analysis (exclude stress ticks)
               g_state = STATE_STRESS_PLACE;  // Run stress test before report
               g_stressInLimitPhase = true;    // Start with LIMITS (broker-favorable = should pass)
               g_stressCycleStop = 0;
               g_stressCycleLimit = 0;
               g_stressStopTotalAttempts = 0;
               g_stressStopTotalRejects = 0;
               g_stressLimitTotalAttempts = 0;
               g_stressLimitTotalRejects = 0;
               SetPanelLine(1, "Starting order capacity stress test (LIMIT orders first)...", clrYellow);
               PrintFormat("═══ STRESS TEST: Starting LIMIT-order capacity test (baseline) ═══");
            }
            else
            {
               Sleep(2000); // Brief pause between cycles
               g_state = STATE_GRID_PLACE;
            }
         }
         break;

      // ═══════════════════════════════════════════════════════════════
      // ORDER CAPACITY STRESS TEST — STOP ORDERS
      // ═══════════════════════════════════════════════════════════════
      case STATE_STRESS_PLACE:
      {
         int cycleNum = g_stressInLimitPhase ? g_stressCycleLimit + 1 : g_stressCycleStop + 1;
         string typeStr = g_stressInLimitPhase ? "LIMIT" : "STOP";
         int batchSize = (int)g_orderLimit;  // Use measured max order slots (not hardcoded)
         if(batchSize <= 0) batchSize = 500;  // Safety fallback

         SetPanelLine(1, StringFormat("Stress test %s cycle %d: Async placing %d orders...",
            typeStr, cycleNum, batchSize), clrYellow);

         // Clean slate for this batch
         g_stressPlacedCount = 0;
         g_stressPlaceRejects = 0;
         g_stressPlaceAttempts = 0;
         g_stressTicketCount = 0;
         g_stressAsyncSent = 0;
         g_stressAsyncConfirmed = 0;
         g_stressAsyncRejected = 0;
         ArrayResize(g_stressTickets, batchSize);
         g_stressPlaceStartMs = GetTickCount64();

         double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
         double minDist = 50000 * point;  // $500 away from price to prevent accidental fills

         // ═══ ASYNC PLACEMENT — fire all orders without waiting ═══
         g_trade.SetAsyncMode(true);
         int sendFailCount = 0;
         for(int i = 0; i < batchSize; i++)
         {
            g_stressPlaceAttempts++;
            double offset = minDist + (i * 10 * point);
            double price;
            ENUM_ORDER_TYPE otype;

            if(!g_stressInLimitPhase)
            {
               // Stop orders: BuyStop above ask, SellStop below bid (alternating)
               if(i % 2 == 0)
               {
                  price = NormalizeDouble(ask + offset, digits);
                  otype = ORDER_TYPE_BUY_STOP;
               }
               else
               {
                  price = NormalizeDouble(bid - offset, digits);
                  otype = ORDER_TYPE_SELL_STOP;
               }
            }
            else
            {
               // Limit orders: BuyLimit below bid, SellLimit above ask (alternating)
               if(i % 2 == 0)
               {
                  price = NormalizeDouble(bid - offset, digits);
                  otype = ORDER_TYPE_BUY_LIMIT;
               }
               else
               {
                  price = NormalizeDouble(ask + offset, digits);
                  otype = ORDER_TYPE_SELL_LIMIT;
               }
            }

            MqlTradeRequest req = {};
            MqlTradeResult  res = {};
            req.action    = TRADE_ACTION_PENDING;
            req.symbol    = Symbol();
            req.volume    = g_lotSize;
            req.price     = price;
            req.type      = otype;
            req.magic     = InpMagicNumber + 9000;  // Distinct magic for stress test
            req.comment   = StringFormat("FA_STRESS_%s_%d", typeStr, cycleNum);
            req.type_filling = g_fillType;

            // OrderSendAsync — returns immediately, confirmation via OnTradeTransaction
            if(!OrderSendAsync(req, res))
            {
               sendFailCount++;
               g_stressPlaceRejects++;
               g_stressLastRetcode = (int)res.retcode;
               TrackRejection((int)res.retcode, StringFormat("%s_STRESS",
                  g_stressInLimitPhase ? "Limit" : "Stop"));

               // If first 3 all fail at send level, broker is blocking immediately
               if(sendFailCount >= 3 && g_stressAsyncSent == 0)
                  break;
            }
            else
            {
               g_stressAsyncSent++;
               sendFailCount = 0; // Reset consecutive fail counter
            }
         }
         g_trade.SetAsyncMode(false);

         if(g_stressAsyncSent == 0)
         {
            // Accumulate rejection totals even for blocked cycles
            if(g_stressInLimitPhase)
            {
               g_stressLimitTotalAttempts += g_stressPlaceAttempts;
               g_stressLimitTotalRejects  += g_stressPlaceRejects;
            }
            else
            {
               g_stressStopTotalAttempts += g_stressPlaceAttempts;
               g_stressStopTotalRejects  += g_stressPlaceRejects;
            }

            // All sends failed — broker blocking at protocol level
            if(g_stressInLimitPhase)
            {
               g_stressLimitBlocked = true;
               g_stressLimitBlockedAt = cycleNum;
               PrintFormat("═══ STRESS TEST: LIMIT orders BLOCKED at cycle %d (all sends failed, retcode: %d) ═══",
                  cycleNum, g_stressLastRetcode);
               g_stressInLimitPhase = false;
               g_state = STATE_STRESS_STOP_PROBE;
            }
            else
            {
               g_stressStopBlocked = true;
               g_stressStopBlockedAt = cycleNum;
               PrintFormat("═══ STRESS TEST: STOP orders BLOCKED at cycle %d (all sends failed, retcode: %d) ═══",
                  cycleNum, g_stressLastRetcode);
               g_state = STATE_STRESS_FINAL_CLEANUP;
            }
         }
         else
         {
            // Sent N orders async — now wait for ORDER_ADD confirmations
            g_stressAsyncWaitStartMs = GetTickCount64();
            PrintFormat("Stress %s cycle %d: fired %d async orders (%d send failures) — waiting for confirmations...",
               typeStr, cycleNum, g_stressAsyncSent, sendFailCount);
            g_state = STATE_STRESS_ASYNC_WAIT;
         }
         break;
      }

      case STATE_STRESS_ASYNC_WAIT:
      {
         // Non-blocking wait: ORDER_ADD callbacks fire between ticks via OnTradeTransaction
         ulong elapsedMs = GetTickCount64() - g_stressAsyncWaitStartMs;
         int totalResponses = g_stressAsyncConfirmed + g_stressAsyncRejected;
         bool allReceived = (totalResponses >= g_stressAsyncSent);
         bool timeoutReached = (elapsedMs >= 10000);  // 10s timeout for async confirmations

         if(allReceived || timeoutReached)
         {
            int cycleNum2 = g_stressInLimitPhase ? g_stressCycleLimit + 1 : g_stressCycleStop + 1;
            string typeStr2 = g_stressInLimitPhase ? "LIMIT" : "STOP";

            PrintFormat("Stress %s cycle %d: async complete in %dms — %d confirmed, %d rejected, %d sent%s",
               typeStr2, cycleNum2, (int)elapsedMs,
               g_stressAsyncConfirmed, g_stressAsyncRejected, g_stressAsyncSent,
               timeoutReached ? " (TIMEOUT)" : "");

            // Accumulate per-phase rejection totals
            if(g_stressInLimitPhase)
            {
               g_stressLimitTotalAttempts += g_stressPlaceAttempts;
               g_stressLimitTotalRejects  += g_stressPlaceRejects;
            }
            else
            {
               g_stressStopTotalAttempts += g_stressPlaceAttempts;
               g_stressStopTotalRejects  += g_stressPlaceRejects;
            }

            // Check if broker blocked (too many rejections or no confirmations)
            bool blocked = (g_stressPlacedCount == 0) ||
                           (g_stressAsyncRejected >= 3 && g_stressPlacedCount == 0);

            if(blocked)
            {
               if(g_stressInLimitPhase)
               {
                  g_stressLimitBlocked = true;
                  g_stressLimitBlockedAt = cycleNum2;
                  PrintFormat("═══ STRESS TEST: LIMIT orders BLOCKED at cycle %d (retcode: %d) ═══",
                     cycleNum2, g_stressLastRetcode);
                  if(g_stressPlacedCount > 0)
                     g_state = STATE_STRESS_LIMIT_CLOSE;
                  else
                  {
                     g_stressInLimitPhase = false;
                     g_state = STATE_STRESS_STOP_PROBE;
                  }
               }
               else
               {
                  g_stressStopBlocked = true;
                  g_stressStopBlockedAt = cycleNum2;
                  PrintFormat("═══ STRESS TEST: STOP orders BLOCKED at cycle %d (retcode: %d) ═══",
                     cycleNum2, g_stressLastRetcode);
                  if(g_stressPlacedCount > 0)
                     g_state = STATE_STRESS_CLOSE;
                  else
                     g_state = STATE_STRESS_FINAL_CLEANUP;
               }
            }
            else
            {
               PrintFormat("Stress %s cycle %d: %d orders confirmed on server (%d rejects)",
                  typeStr2, cycleNum2, g_stressPlacedCount, g_stressPlaceRejects);
               g_state = g_stressInLimitPhase ? STATE_STRESS_LIMIT_VERIFY : STATE_STRESS_VERIFY_PLACED;
            }
         }
         else
         {
            int batchSz = (int)g_orderLimit;
            if(batchSz <= 0) batchSz = 500;
            int totalRej = (batchSz - g_stressAsyncSent) + g_stressAsyncRejected; // Send failures + async rejections
            SetPanelLine(1, StringFormat("Stress: %d/%d accepted (%d rejected) %.1fs...",
               g_stressAsyncConfirmed, batchSz, totalRej, elapsedMs / 1000.0), clrYellow);
         }
         break;
      }

      case STATE_STRESS_VERIFY_PLACED:
      case STATE_STRESS_LIMIT_VERIFY:
      {
         // Verify orders are actually pending on server
         int verified = 0;
         for(int i = 0; i < g_stressTicketCount; i++)
         {
            if(OrderSelect(g_stressTickets[i]))
               verified++;
         }

         string typeStr2 = g_stressInLimitPhase ? "LIMIT" : "STOP";
         int cycleNum2 = g_stressInLimitPhase ? g_stressCycleLimit + 1 : g_stressCycleStop + 1;

         if(!g_stressInLimitPhase)
         {
            if(verified > g_stressMaxVerifiedStop)
               g_stressMaxVerifiedStop = verified;
         }
         else
         {
            if(verified > g_stressMaxVerifiedLimit)
               g_stressMaxVerifiedLimit = verified;
         }

         SetPanelLine(1, StringFormat("Stress %s cycle %d: %d/%d verified on server — closing...",
            typeStr2, cycleNum2, verified, g_stressPlacedCount), clrYellow);
         PrintFormat("Stress %s cycle %d: %d orders verified on server", typeStr2, cycleNum2, verified);

         g_stressCloseStartMs = GetTickCount64();
         g_state = g_stressInLimitPhase ? STATE_STRESS_LIMIT_CLOSE : STATE_STRESS_CLOSE;
         break;
      }

      case STATE_STRESS_CLOSE:
      case STATE_STRESS_LIMIT_CLOSE:
      {
         // ═══ ASYNC DELETION — fire all delete requests without waiting ═══
         // Scan ALL pending orders with stress magic (not just tracked tickets)
         int deleteSent = 0;
         long stressMagicDel = InpMagicNumber + 9000;
         for(int o = OrdersTotal() - 1; o >= 0; o--)
         {
            ulong oTicket = OrderGetTicket(o);
            if(oTicket == 0) continue;
            if(OrderGetInteger(ORDER_MAGIC) != stressMagicDel) continue;
            if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;

            MqlTradeRequest dreq = {};
            MqlTradeResult  dres = {};
            dreq.action = TRADE_ACTION_REMOVE;
            dreq.order  = oTicket;
            if(OrderSendAsync(dreq, dres))
               deleteSent++;
         }

         // Close any positions from accidentally triggered stress orders (async)
         int closeSent = 0;
         long stressMagic = InpMagicNumber + 9000;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong ticket = PositionGetTicket(p);
            if(ticket == 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != stressMagic) continue;
            if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

            MqlTradeRequest creq = {};
            MqlTradeResult  cres = {};
            creq.action    = TRADE_ACTION_DEAL;
            creq.symbol    = Symbol();
            creq.volume    = PositionGetDouble(POSITION_VOLUME);
            creq.position  = ticket;
            creq.type      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                             ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            creq.price     = (creq.type == ORDER_TYPE_SELL)
                             ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                             : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            creq.type_filling = g_fillType;
            creq.comment   = "FA_STRESS_CLEANUP";
            if(OrderSendAsync(creq, cres))
               closeSent++;
         }

         string typeStr3 = g_stressInLimitPhase ? "LIMIT" : "STOP";
         int cycleNum3 = g_stressInLimitPhase ? g_stressCycleLimit + 1 : g_stressCycleStop + 1;
         PrintFormat("Stress %s cycle %d: fired %d async deletes + %d position closes — waiting for confirmation...",
            typeStr3, cycleNum3, deleteSent, closeSent);

         g_stressCloseStartMs = GetTickCount64();
         g_state = g_stressInLimitPhase ? STATE_STRESS_LIMIT_CLOSED : STATE_STRESS_VERIFY_CLOSED;
         break;
      }

      // ═══════════════════════════════════════════════════════════════
      // LIMIT CLOSE VERIFICATION — limits tested first (baseline)
      // ═══════════════════════════════════════════════════════════════
      case STATE_STRESS_LIMIT_CLOSED:
      {
         long stressMagic2 = InpMagicNumber + 9000;

         // Count remaining pending orders (scan ALL orders, not just tracked tickets)
         int remainOrd2 = 0;
         for(int o = OrdersTotal() - 1; o >= 0; o--)
         {
            ulong oTicket = OrderGetTicket(o);
            if(oTicket == 0) continue;
            if(OrderGetInteger(ORDER_MAGIC) != stressMagic2) continue;
            if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
            remainOrd2++;
         }

         // Count remaining positions from accidentally triggered stress orders
         int remainPos2 = 0;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt == 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != stressMagic2) continue;
            if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
            remainPos2++;
         }

         int totalRemain2 = remainOrd2 + remainPos2;
         if(totalRemain2 > 0)
         {
            ulong elapsed2 = GetTickCount64() - g_stressCloseStartMs;
            if(elapsed2 < 5000)
            {
               SetPanelLine(1, StringFormat("Stress LIMIT cleanup: %d orders + %d positions remaining (%.1fs)...",
                  remainOrd2, remainPos2, elapsed2 / 1000.0), clrYellow);
               break;
            }
            // Timeout — fire async deletes first (fast burst), then sync fallback
            int delOK = 0, delFail = 0;
            for(int o = OrdersTotal() - 1; o >= 0; o--)
            {
               ulong oTicket = OrderGetTicket(o);
               if(oTicket == 0) continue;
               if(OrderGetInteger(ORDER_MAGIC) != stressMagic2) continue;
               if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;

               MqlTradeRequest dreq4 = {};
               MqlTradeResult  dres4 = {};
               dreq4.action = TRADE_ACTION_REMOVE;
               dreq4.order  = oTicket;
               if(OrderSendAsync(dreq4, dres4))
                  delOK++;
               else
                  delFail++;
            }
            // Async close all remaining positions
            int clsOK = 0, clsFail = 0;
            for(int p = PositionsTotal() - 1; p >= 0; p--)
            {
               ulong pt = PositionGetTicket(p);
               if(pt == 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != stressMagic2) continue;
               if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

               MqlTradeRequest creq2 = {};
               MqlTradeResult  cres2 = {};
               creq2.action    = TRADE_ACTION_DEAL;
               creq2.symbol    = Symbol();
               creq2.volume    = PositionGetDouble(POSITION_VOLUME);
               creq2.position  = pt;
               creq2.type      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                                 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               creq2.price     = (creq2.type == ORDER_TYPE_SELL)
                                 ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                                 : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
               creq2.type_filling = g_fillType;
               creq2.comment   = "FA_STRESS_CLEANUP";
               if(OrderSendAsync(creq2, cres2))
                  clsOK++;
               else
                  clsFail++;
            }
            PrintFormat("Stress LIMIT cleanup: %d orders (%d del OK, %d fail) + %d positions (%d cls OK, %d fail)",
               remainOrd2, delOK, delFail, remainPos2, clsOK, clsFail);
            SetPanelLine(1, StringFormat("Stress LIMIT cleanup: fired %d async deletes + %d closes (retrying)...",
               delOK, clsOK), clrOrange);
            // Re-check after short wait
            g_stressCloseStartMs = GetTickCount64();
            break;
         }

         // All clean — proceed
         g_stressCycleLimit++;
         PrintFormat("═══ STRESS TEST: LIMIT cycle %d complete — all orders and positions cleared ═══", g_stressCycleLimit);

         // Measure throttle recovery time (how long broker locks you out after heavy activity)
         MeasureThrottleRecovery(true);

         if(g_stressLimitBlocked)
         {
            g_stressInLimitPhase = false;
            g_state = STATE_STRESS_STOP_PROBE;
         }
         else if(g_stressCycleLimit >= InpStressMaxCycles)
         {
            PrintFormat("═══ STRESS TEST: LIMIT baseline — %d cycles OK, no block ═══", g_stressCycleLimit);
            g_stressInLimitPhase = false;
            g_state = STATE_STRESS_STOP_PROBE;
         }
         else
         {
            g_state = STATE_STRESS_PLACE;  // Throttle probe already measured — no extra Sleep needed
         }
         break;
      }

      // ═══════════════════════════════════════════════════════════════
      // STOP PROBE — single stop order to check if stops are accepted
      // ═══════════════════════════════════════════════════════════════
      case STATE_STRESS_STOP_PROBE:
      {
         SetPanelLine(1, "Stress test: Probing STOP order acceptance...", clrYellow);
         double ask2 = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         double point2 = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
         int digits2 = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
         double probePrice = NormalizeDouble(ask2 + 50000 * point2, digits2);  // $500 away

         MqlTradeRequest preq = {};
         MqlTradeResult  pres = {};
         preq.action    = TRADE_ACTION_PENDING;
         preq.symbol    = Symbol();
         preq.volume    = g_lotSize;
         preq.price     = probePrice;
         preq.type      = ORDER_TYPE_BUY_STOP;
         preq.magic     = InpMagicNumber + 9000;
         preq.comment   = "FA_STRESS_STOP_PROBE";
         preq.type_filling = g_fillType;

         if(OrderSend(preq, pres) && pres.retcode == TRADE_RETCODE_DONE)
         {
            // Stop accepted — delete probe and start stop stress cycles
            PrintFormat("Stress: STOP probe accepted (ticket %d) — starting stop cycles", (int)pres.order);
            MqlTradeRequest dreq3 = {};
            MqlTradeResult  dres3 = {};
            dreq3.action = TRADE_ACTION_REMOVE;
            dreq3.order  = pres.order;
            if(!OrderSend(dreq3, dres3)) {} // Best-effort probe cleanup
            Sleep(500);
            PrintFormat("═══ STRESS TEST: Starting STOP-order capacity test ═══");
            g_state = STATE_STRESS_PLACE;
         }
         else
         {
            // Stops blocked from the start
            g_stressStopBlocked = true;
            g_stressStopBlockedAt = 0;
            g_stressLastRetcode = (int)pres.retcode;
            PrintFormat("═══ STRESS TEST: STOP orders BLOCKED at probe (retcode: %d) ═══", pres.retcode);
            TrackRejection((int)pres.retcode, "BuyStop_STRESS_PROBE");
            g_state = STATE_STRESS_FINAL_CLEANUP;
         }
         break;
      }

      // ═══════════════════════════════════════════════════════════════
      // STOP CLOSE VERIFICATION — tested after limits (comparison)
      // ═══════════════════════════════════════════════════════════════
      case STATE_STRESS_VERIFY_CLOSED:
      {
         long stressMagic3 = InpMagicNumber + 9000;

         // Count remaining pending orders (scan ALL orders, not just tracked tickets)
         int remainOrd3 = 0;
         for(int o = OrdersTotal() - 1; o >= 0; o--)
         {
            ulong oTicket = OrderGetTicket(o);
            if(oTicket == 0) continue;
            if(OrderGetInteger(ORDER_MAGIC) != stressMagic3) continue;
            if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
            remainOrd3++;
         }

         // Count remaining positions from accidentally triggered stress orders
         int remainPos3 = 0;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pt = PositionGetTicket(p);
            if(pt == 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != stressMagic3) continue;
            if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
            remainPos3++;
         }

         int totalRemain3 = remainOrd3 + remainPos3;
         if(totalRemain3 > 0)
         {
            ulong elapsed = GetTickCount64() - g_stressCloseStartMs;
            if(elapsed < 5000)
            {
               SetPanelLine(1, StringFormat("Stress STOP cleanup: %d orders + %d positions remaining (%.1fs)...",
                  remainOrd3, remainPos3, elapsed / 1000.0), clrYellow);
               break;
            }
            // Timeout — fire async deletes (fast burst), then retry
            int delOK3 = 0, delFail3 = 0;
            for(int o = OrdersTotal() - 1; o >= 0; o--)
            {
               ulong oTicket = OrderGetTicket(o);
               if(oTicket == 0) continue;
               if(OrderGetInteger(ORDER_MAGIC) != stressMagic3) continue;
               if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;

               MqlTradeRequest dreq2 = {};
               MqlTradeResult  dres2 = {};
               dreq2.action = TRADE_ACTION_REMOVE;
               dreq2.order  = oTicket;
               if(OrderSendAsync(dreq2, dres2))
                  delOK3++;
               else
                  delFail3++;
            }
            // Async close all remaining positions
            int clsOK3 = 0, clsFail3 = 0;
            for(int p = PositionsTotal() - 1; p >= 0; p--)
            {
               ulong pt = PositionGetTicket(p);
               if(pt == 0) continue;
               if(PositionGetInteger(POSITION_MAGIC) != stressMagic3) continue;
               if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

               MqlTradeRequest creq3 = {};
               MqlTradeResult  cres3 = {};
               creq3.action    = TRADE_ACTION_DEAL;
               creq3.symbol    = Symbol();
               creq3.volume    = PositionGetDouble(POSITION_VOLUME);
               creq3.position  = pt;
               creq3.type      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                                 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               creq3.price     = (creq3.type == ORDER_TYPE_SELL)
                                 ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                                 : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
               creq3.type_filling = g_fillType;
               creq3.comment   = "FA_STRESS_CLEANUP";
               if(OrderSendAsync(creq3, cres3))
                  clsOK3++;
               else
                  clsFail3++;
            }
            PrintFormat("Stress STOP cleanup: %d orders (%d del OK, %d fail) + %d positions (%d cls OK, %d fail)",
               remainOrd3, delOK3, delFail3, remainPos3, clsOK3, clsFail3);
            SetPanelLine(1, StringFormat("Stress STOP cleanup: fired %d async deletes + %d closes (retrying)...",
               delOK3, clsOK3), clrOrange);
            // Re-check after short wait
            g_stressCloseStartMs = GetTickCount64();
            break;
         }

         // All clean — proceed
         g_stressCycleStop++;
         PrintFormat("═══ STRESS TEST: STOP cycle %d complete — all orders and positions cleared ═══", g_stressCycleStop);

         // Measure throttle recovery time (how long broker locks you out after heavy activity)
         MeasureThrottleRecovery(false);

         if(g_stressStopBlocked)
         {
            g_state = STATE_STRESS_FINAL_CLEANUP;
         }
         else if(g_stressCycleStop >= InpStressMaxCycles)
         {
            PrintFormat("═══ STRESS TEST: STOP orders — %d cycles completed, no block detected ═══", g_stressCycleStop);
            g_state = STATE_STRESS_FINAL_CLEANUP;
         }
         else
         {
            g_state = STATE_STRESS_PLACE;  // Throttle probe already measured — no extra Sleep needed
         }
         break;
      }

      // ═══════════════════════════════════════════════════════════════
      // FINAL CLEANUP — delete ALL stress orders/positions before report
      // Scans ALL orders (not just tracked tickets) to catch any strays.
      // Retries persistently every tick until completely clean.
      // ═══════════════════════════════════════════════════════════════
      case STATE_STRESS_FINAL_CLEANUP:
      {
         long stressMagicFC = InpMagicNumber + 9000;

         // First attempt: fire ASYNC deletes for speed (burst all at once)
         // Subsequent attempts: use SYNC deletes for reliability
         bool useAsync = (g_stressFinalCleanupAttempts == 0);

         // Phase 1: Scan ALL pending orders (not just tracked tickets)
         int remainOrdFC = 0;
         int deletedOrdFC = 0;
         for(int o = OrdersTotal() - 1; o >= 0; o--)
         {
            ulong oTicket = OrderGetTicket(o);
            if(oTicket == 0) continue;
            if(OrderGetInteger(ORDER_MAGIC) != stressMagicFC) continue;
            if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
            remainOrdFC++;

            MqlTradeRequest dreqFC = {};
            MqlTradeResult  dresFC = {};
            dreqFC.action = TRADE_ACTION_REMOVE;
            dreqFC.order  = oTicket;
            if(useAsync)
            {
               if(OrderSendAsync(dreqFC, dresFC)) deletedOrdFC++;
            }
            else
            {
               if(OrderSend(dreqFC, dresFC)) deletedOrdFC++;
            }
         }

         // Phase 2: Scan ALL positions with stress magic
         int remainPosFC = 0;
         int closedPosFC = 0;
         for(int p = PositionsTotal() - 1; p >= 0; p--)
         {
            ulong pTicket = PositionGetTicket(p);
            if(pTicket == 0) continue;
            if(PositionGetInteger(POSITION_MAGIC) != stressMagicFC) continue;
            if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
            remainPosFC++;

            MqlTradeRequest creqFC = {};
            MqlTradeResult  cresFC = {};
            creqFC.action    = TRADE_ACTION_DEAL;
            creqFC.symbol    = Symbol();
            creqFC.volume    = PositionGetDouble(POSITION_VOLUME);
            creqFC.position  = pTicket;
            creqFC.type      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                               ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            creqFC.price     = (creqFC.type == ORDER_TYPE_SELL)
                               ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                               : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            creqFC.type_filling = g_fillType;
            creqFC.comment   = "FA_STRESS_FINAL_CLEANUP";
            if(useAsync)
            {
               if(OrderSendAsync(creqFC, cresFC)) closedPosFC++;
            }
            else
            {
               if(OrderSend(creqFC, cresFC)) closedPosFC++;
            }
         }

         int totalRemainFC = remainOrdFC + remainPosFC;
         if(totalRemainFC > 0)
         {
            g_stressFinalCleanupAttempts++;
            SetPanelLine(1, StringFormat("Final cleanup: %d orders + %d positions remaining (%s attempt %d, deleted %d/%d)...",
               remainOrdFC, remainPosFC, useAsync ? "async" : "sync",
               g_stressFinalCleanupAttempts, deletedOrdFC + closedPosFC, totalRemainFC), clrOrange);

            PrintFormat("STRESS FINAL CLEANUP attempt %d: %d orders + %d positions remaining — %s deleted %d/%d",
               g_stressFinalCleanupAttempts, remainOrdFC, remainPosFC,
               useAsync ? "async" : "sync", deletedOrdFC + closedPosFC, totalRemainFC);
            break;  // Come back next tick and try again
         }

         // All clean
         if(g_stressFinalCleanupAttempts > 0)
            PrintFormat("═══ STRESS FINAL CLEANUP: All cleared after %d attempts ═══",
               g_stressFinalCleanupAttempts);
         else
            PrintFormat("═══ STRESS FINAL CLEANUP: No remnants found ═══");

         // Measure buffer flush cost (sync place+delete round-trip for EA tuning data)
         SetPanelLine(1, "Measuring buffer flush cost...", clrYellow);
         MeasureBufferFlush();

         g_state = STATE_REPORT;
         break;
      }

      case STATE_REPORT:
         g_state = STATE_DONE; // Set DONE immediately — prevent any re-activation
         SetPanelLine(1, "Calculating statistics...", clrYellow);
         CalcAllStatistics();
         DetectVirtualDealer();
         SetPanelLine(1, "Analyzing phantom spikes...", clrYellow);
         AnalyzePhantomSpikes();
         ComputeMarginVerification();
         SetPanelLine(1, "Analyzing previous day tick history for damage projection...", clrYellow);
         AnalyzePreviousDayDamage();
         if(g_prevDayDataValid)
            SetPanelLine(1, StringFormat("Previous day history: %d ticks — included in loss projections", g_prevDayTickCount), clrLime);
         else
            SetPanelLine(1, "Previous day history: not available — projections use test session only", clrOrange);
         Sleep(2000);  // Let the user see the message before report generation overwrites it
         SetPanelLine(1, "Generating execution report...", clrYellow);
         GeneratePDFReport();
         if(InpWriteHTML) GenerateHTMLReport();
         GenerateTOML();
         GenerateTradeHistory();
         WriteIntegrityHashes();  // SHA-256 hashes of all files → appended to TOML

         //--- Close all streaming CSV file handles — all writing is complete
         if(g_evidenceCsvHandle != INVALID_HANDLE)
         { FileClose(g_evidenceCsvHandle); g_evidenceCsvHandle = INVALID_HANDLE; }
         if(g_tickCsvHandle != INVALID_HANDLE)
         { FileClose(g_tickCsvHandle); g_tickCsvHandle = INVALID_HANDLE; }
         if(g_brokerLogHandle != INVALID_HANDLE)
         { FileClose(g_brokerLogHandle); g_brokerLogHandle = INVALID_HANDLE; }
         if(g_calibCsvHandle != INVALID_HANDLE)
         { FileClose(g_calibCsvHandle); g_calibCsvHandle = INVALID_HANDLE; }

         g_state = STATE_DONE;
         Print("═══════════════════════════════════════════════════════════");
         Print("  FORENSIC ANALYSIS COMPLETE");
         Print("  Files saved to:");
         PrintFormat("    %s", g_outputFolder);
         PrintFormat("    %s", g_reportPdfName);
         if(InpWriteHTML) PrintFormat("    %s", g_reportHtmName);
         PrintFormat("    %s", g_evidenceCsvName);
         PrintFormat("    %s", g_tickCsvName);
         PrintFormat("    %s", g_brokerLogName);
         PrintFormat("    %s", g_histCsvName);
         PrintFormat("    %s", g_tomlName);
         if(InpShowEATuning && g_calibCsvName != "")
            PrintFormat("    %s", g_calibCsvName);
         Print("═══════════════════════════════════════════════════════════");

         // Show alert with full path so user can easily find files
         Alert("Forensic Analysis Complete!\n\nFiles saved to:\n" + g_outputFolder +
               "\n\nReport: " + g_reportPdfName);
         UpdatePanel();
         break;

      case STATE_DONE:
         // Sit idle
         break;
   }
}


//+------------------------------------------------------------------+
//| OnTradeTransaction — detect fills and closes                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   //--- Log ALL broker transaction events for forensic record
   if(g_brokerLogHandle != INVALID_HANDLE)
   {
      ulong logMs = GetTickCount64();
      ulong logEpoch = g_epochMsOffset + logMs;

      // For DEAL_ADD events, include full deal details
      if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal > 0 && HistoryDealSelect(trans.deal))
      {
         long dType   = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         long dEntry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         long dReason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
         long dMagic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         long dPosId  = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         double dPrice  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
         double dVol    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
         double dProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
         double dComm   = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
         double dSwap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
         string dSym    = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         string dCmt    = HistoryDealGetString(trans.deal, DEAL_COMMENT);
         StringReplace(dCmt, ",", ";"); // Sanitize commas

         string dtStr = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
         FileWriteString(g_brokerLogHandle, StringFormat(
            "%I64u,%I64u,%s,DEAL_ADD,%I64u,%I64u,%s,%d,%d,%d,%.5f,%.4f,%.4f,%.4f,%.4f,%d,%d,%s\n",
            logMs, logEpoch, dtStr, trans.deal, trans.order, dSym, (int)dType,
            (int)dEntry, (int)dReason, dPrice, dVol, dProfit, dComm, dSwap,
            (int)dPosId, (int)dMagic, dCmt));
      }
      else
      {
         // Non-deal events: order changes, history additions, etc.
         string ttype;
         switch(trans.type)
         {
            case TRADE_TRANSACTION_ORDER_ADD:     ttype = "ORDER_ADD";    break;
            case TRADE_TRANSACTION_ORDER_UPDATE:  ttype = "ORDER_UPD";   break;
            case TRADE_TRANSACTION_ORDER_DELETE:  ttype = "ORDER_DEL";   break;
            case TRADE_TRANSACTION_HISTORY_ADD:   ttype = "HIST_ADD";    break;
            case TRADE_TRANSACTION_HISTORY_UPDATE:ttype = "HIST_UPD";    break;
            case TRADE_TRANSACTION_HISTORY_DELETE:ttype = "HIST_DEL";    break;
            case TRADE_TRANSACTION_POSITION:      ttype = "POSITION";    break;
            case TRADE_TRANSACTION_REQUEST:       ttype = "REQUEST";     break;
            default: ttype = StringFormat("TYPE_%d", (int)trans.type);   break;
         }
         string dtStr2 = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
         FileWriteString(g_brokerLogHandle, StringFormat(
            "%I64u,%I64u,%s,%s,%I64u,%I64u,%s,%d,,,%.5f,%.4f,,,,,,\n",
            logMs, logEpoch, dtStr2, ttype, trans.deal, trans.order, trans.symbol,
            (int)trans.deal_type, trans.price, trans.volume));
      }
   }

   // ═══ STRESS TEST ASYNC CONFIRMATIONS ═══
   // Capture ORDER_ADD for stress test orders placed asynchronously
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD && trans.order > 0 &&
      g_state == STATE_STRESS_ASYNC_WAIT)
   {
      // Check if this order has our stress magic
      if(OrderSelect(trans.order) &&
         OrderGetInteger(ORDER_MAGIC) == (long)(InpMagicNumber + 9000) &&
         OrderGetString(ORDER_SYMBOL) == Symbol())
      {
         // Record confirmed ticket
         if(g_stressTicketCount < ArraySize(g_stressTickets))
         {
            g_stressTickets[g_stressTicketCount++] = trans.order;
            g_stressPlacedCount++;
         }
         g_stressAsyncConfirmed++;
      }
   }

   // Capture async stress placement rejections via REQUEST callback
   if(trans.type == TRADE_TRANSACTION_REQUEST &&
      g_state == STATE_STRESS_ASYNC_WAIT &&
      result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
   {
      // Check if this was a stress order request (magic + 9000)
      if(request.magic == (ulong)(InpMagicNumber + 9000))
      {
         g_stressAsyncRejected++;
         g_stressPlaceRejects++;
         g_stressLastRetcode = (int)result.retcode;
         TrackRejection((int)result.retcode, StringFormat("%s_STRESS",
            g_stressInLimitPhase ? "Limit" : "Stop"));
      }
   }

   // Capture real order tickets and broker setup timestamps from ORDER_ADD
   // (async mode returns 0 from ResultOrder, so we grab real tickets here)
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD && trans.order > 0 &&
      (g_state == STATE_GRID_PLACE || g_state == STATE_GRID_WAIT))
   {
      // Get broker's authoritative setup timestamp
      long setupMsc = 0;
      if(OrderSelect(trans.order))
         setupMsc = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);

      // Match by price — the grid order was placed with this price but ticket was 0
      for(int gi = 0; gi < g_gridSize; gi++)
      {
         if(g_grid[gi].ticket == 0 &&
            MathAbs(g_grid[gi].price - trans.price) < g_point * 2)
         {
            g_grid[gi].ticket = trans.order;
            break;
         }
      }

      // Track earliest broker timestamp in this batch for async open measurement
      if(setupMsc > 0)
      {
         g_gridOrdersConfirmed++;
         if(g_gridEarliestSetupMsc == 0 || setupMsc < g_gridEarliestSetupMsc)
            g_gridEarliestSetupMsc = setupMsc;
         // Capture boot time of first ORDER_ADD callback (for batch round-trip calculation)
         if(g_gridFirstOrderAddBootMs == 0)
            g_gridFirstOrderAddBootMs = GetTickCount64();
      }
   }

   // ═══ FILL REJECTION DETECTION ═══
   // During grid wait: if a pending grid order is DELETED by the broker (not by us),
   // it means the broker refused to fill it. This is a fill rejection.
   // ORDER_DELETE fires when the order is removed; HISTORY_ADD fires when it enters history.
   // We use HISTORY_ADD because HistoryOrderSelect gives us ORDER_STATE and ORDER_REASON.
   if(trans.type == TRADE_TRANSACTION_HISTORY_ADD && trans.order > 0 &&
      g_state == STATE_GRID_WAIT)
   {
      // Check if this order belongs to our grid (match by ticket)
      for(int gi = 0; gi < g_gridSize; gi++)
      {
         if(g_grid[gi].ticket == trans.order && !g_grid[gi].filled)
         {
            // This grid order was removed from the server without filling
            if(HistoryOrderSelect(trans.order))
            {
               long oState  = (long)HistoryOrderGetInteger(trans.order, ORDER_STATE);
               long oReason = (long)HistoryOrderGetInteger(trans.order, ORDER_REASON);
               long doneMsc = (long)HistoryOrderGetInteger(trans.order, ORDER_TIME_DONE_MSC);

               // Skip if this was filled (state=FILLED means DEAL_ADD will handle it)
               // Only track CANCELED, REJECTED, EXPIRED — broker refused to honor the order
               if(oState == ORDER_STATE_CANCELED || oState == ORDER_STATE_REJECTED ||
                  oState == ORDER_STATE_EXPIRED)
               {
                  TrackFillRejection(trans.order, oState, oReason, doneMsc);
                  PrintFormat("FILL REJECTION: grid[%d] ticket=%I64u %s price=%.5f state=%d reason=%d priceCrossed=%s",
                     gi, trans.order, g_grid[gi].isLimit ? "LIMIT" : "STOP",
                     g_grid[gi].price, (int)oState, (int)oReason,
                     g_grid[gi].priceCrossed ? "YES" : "NO");
               }
            }
            break;
         }
      }
   }

   // Capture async TP/SL PositionModify acknowledgments
   // TRADE_TRANSACTION_REQUEST fires when broker processes our TRADE_ACTION_SLTP request
   if(trans.type == TRADE_TRANSACTION_REQUEST &&
      request.action == TRADE_ACTION_SLTP &&
      result.retcode == TRADE_RETCODE_DONE &&
      g_state == STATE_GRID_WAIT && g_tpslAsyncSent)
   {
      ulong ackMs = GetTickCount64();
      // TP modification: request.tp > 0 (may also include SL)
      // SL-only modification: request.sl > 0, request.tp == 0
      // Async: try POSITION_TIME_UPDATE_MSC first, fall back to EA round-trip
      long asyncSendEpoch = (long)(g_epochMsOffset + g_tpslAsyncSendMs);
      if(request.tp > 0 && g_tpAsyncFirstAckMs == 0)
      {
         g_tpAsyncFirstAckMs = ackMs;
         double placeLag = 0;
         bool usedBrokerTs = false;
         if(request.position > 0 && PositionSelectByTicket(request.position))
         {
            long brokerAckMsc = (long)PositionGetInteger(POSITION_TIME_UPDATE_MSC);
            double tryLag = (double)(brokerAckMsc - asyncSendEpoch - (long)g_clientServerLagMs);
            if(tryLag > 0)
            {
               placeLag = tryLag;
               usedBrokerTs = true;
            }
         }
         if(!usedBrokerTs)
         {
            // Fallback: EA round-trip (no broker stamp) — subtract full CS round-trip (2 legs)
            placeLag = (double)((long)(ackMs - g_tpslAsyncSendMs) - (long)g_clientServerRoundTripMs);
            if(placeLag < 0) placeLag = 0;
         }
         ArrayResize(g_asyncTPPlaceLags, g_asyncTPPlaceCount + 1);
         g_asyncTPPlaceLags[g_asyncTPPlaceCount++] = placeLag;
         PrintFormat("ASYNC TP ACK [%s]: exec=%.0fms (first of %d)",
            usedBrokerTs ? "broker_ts" : "round_trip", placeLag, g_tpAsyncCount);
      }
      else if(request.sl > 0 && request.tp == 0 && g_slAsyncFirstAckMs == 0)
      {
         g_slAsyncFirstAckMs = ackMs;
         double placeLag = 0;
         bool usedBrokerTs = false;
         if(request.position > 0 && PositionSelectByTicket(request.position))
         {
            long brokerAckMsc = (long)PositionGetInteger(POSITION_TIME_UPDATE_MSC);
            double tryLag = (double)(brokerAckMsc - asyncSendEpoch - (long)g_clientServerLagMs);
            if(tryLag > 0)
            {
               placeLag = tryLag;
               usedBrokerTs = true;
            }
         }
         if(!usedBrokerTs)
         {
            // Fallback: EA round-trip (no broker stamp) — subtract full CS round-trip (2 legs)
            placeLag = (double)((long)(ackMs - g_tpslAsyncSendMs) - (long)g_clientServerRoundTripMs);
            if(placeLag < 0) placeLag = 0;
         }
         ArrayResize(g_asyncSLPlaceLags, g_asyncSLPlaceCount + 1);
         g_asyncSLPlaceLags[g_asyncSLPlaceCount++] = placeLag;
         PrintFormat("ASYNC SL ACK [%s]: lag=%.0fms (first of %d)",
            usedBrokerTs ? "broker_ts" : "round_trip", placeLag, g_slAsyncCount);
      }
   }

   // Capture order deletion acknowledgments (pending order closed by broker)
   // ORDER goes to history when deleted — broker's ORDER_TIME_DONE_MSC = authoritative timestamp
   if(trans.type == TRADE_TRANSACTION_HISTORY_ADD && trans.order > 0 &&
      g_state == STATE_GRID_VERIFY && g_orderDeleteCount > 0)
   {
      if(HistoryOrderSelect(trans.order))
      {
         long doneMsc = (long)HistoryOrderGetInteger(trans.order, ORDER_TIME_DONE_MSC);
         if(doneMsc > 0 &&
            (g_orderDeleteEarliestMsc == 0 || doneMsc < g_orderDeleteEarliestMsc))
            g_orderDeleteEarliestMsc = doneMsc;
      }
   }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0) return;
   if(!HistoryDealSelect(dealTicket)) return;

   long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(dealMagic != (long)InpMagicNumber) return;

   string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(dealSymbol != Symbol()) return;

   long      dealType   = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   double    dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double    dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   long      dealEntry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long      dealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
   double    dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   ulong     dealOrder  = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   ulong     nowMs      = GetTickCount64();
   double    bid        = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double    ask        = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double    spread     = (ask - bid) / g_point;

   // Log every deal callback with state (diagnostic)
   if(false) // Disabled — enable for debugging
      PrintFormat("OTT DEAL: ticket=%d type=%d entry=%d state=%d magic=%d",
         (int)dealTicket, (int)dealType, (int)dealEntry, (int)g_state, (int)dealMagic);

   //=== MARKET TEST FILLS ===
   if(g_state == STATE_MARKET_BUY_WAIT && dealEntry == DEAL_ENTRY_IN && dealType == DEAL_TYPE_BUY)
   {
      ulong roundTripMs = (g_marketSendMs > 0) ? nowMs - g_marketSendMs : 0;
      g_mktBuyEntryPrice = dealPrice;
      g_marketEntryPrice = dealPrice;
      g_mktBuyPosTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      g_marketPosTicket = g_mktBuyPosTicket;
      g_mktBuyCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

      // Measure margin with only buy open
      g_measuredMarginBuy = AccountInfoDouble(ACCOUNT_MARGIN);
      g_measuredEquityBuy = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_measuredMarginBuy > 0 && g_tickSize > 0 && g_tickValue > 0)
      {
         double notional = g_lotSize * (dealPrice / g_tickSize) * g_tickValue;
         g_verifiedLeverage = notional / g_measuredMarginBuy;
      }

      // Broker exec from DEAL_TIME_MSC: broker_stamp - send_epoch - CS_one_way
      // Epoch + CS were both calibrated from the pending order in DoCsCalibrate()
      // so this formula gives a real, non-circular broker exec value.
      long mktBuyDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      double brokerExecMs = 0;
      double mktBuyLagMs = 0;
      if(mktBuyDealTimeMsc > 0 && g_csCalibrated)
      {
         long sendEpoch = (long)(g_epochMsOffset + g_marketSendMs);
         mktBuyLagMs = (double)(mktBuyDealTimeMsc - sendEpoch);
         if(mktBuyLagMs < 0) mktBuyLagMs = 0;
         brokerExecMs = (double)(mktBuyDealTimeMsc - sendEpoch - (long)g_clientServerLagMs);
         if(brokerExecMs < 0) brokerExecMs = 0;
      }
      else if(!g_csCalibrated)
      {
         // Fallback: CS calibration failed, calibrate from this trade
         g_clientServerRoundTripMs = roundTripMs;
         g_clientServerLagMs = roundTripMs / 2;
         if(mktBuyDealTimeMsc > 0)
         {
            g_epochMsOffset = (ulong)(mktBuyDealTimeMsc - (long)(roundTripMs / 2) - (long)g_marketSendMs);
         }
         brokerExecMs = 0;  // Circular — can't separate broker exec from CS
      }
      g_mktSyncOpenBuyMs = brokerExecMs;

      // Execution drift: measure from broker receipt price (what broker had when instruction arrived)
      // CS lag is network infrastructure, not broker behavior — exclude it from drift measurement
      ulong rcptBootMs = g_marketSendMs + g_clientServerLagMs;
      double rcptBid = 0, rcptAsk = 0;
      double brokerReceiptPrice = g_marketSendPrice; // Fallback if tick lookup fails
      if(GetTickAtTime(rcptBootMs, rcptBid, rcptAsk) && rcptAsk > 0)
         brokerReceiptPrice = rcptAsk; // Buy fills at ask
      double slipPts = dealPrice - brokerReceiptPrice; // Drift from broker receipt price

      RecordFill(FILL_MARKET_BUY, dealOrder, dealTicket,
                 brokerReceiptPrice, dealPrice, bid, ask,
                 g_marketSendMs, g_marketSendMs, nowMs,
                 dealVolume, true, StringFormat("RT=%dms CS=%dms send=%.5f rcpt=%.5f", (int)roundTripMs, (int)g_clientServerLagMs, g_marketSendPrice, brokerReceiptPrice));
      g_fills[g_fillCount - 1].lagMs              = mktBuyLagMs;
      g_fills[g_fillCount - 1].brokerExecMs        = brokerExecMs;
      g_fills[g_fillCount - 1].dealTimeMsc          = mktBuyDealTimeMsc;
      g_fills[g_fillCount - 1].brokerReceiptPrice   = brokerReceiptPrice;
      g_fills[g_fillCount - 1].clientSendPrice      = g_marketSendPrice;

      // Drift lag: time for ask to reach deal price from receipt (buy fills at ask, adverse = higher)
      double driftLag = (dealPrice > brokerReceiptPrice)
         ? FindDriftLagMs(dealPrice, 2, rcptBootMs)  // mode 2: ask >= dealPrice
         : 0;  // Deal at or below receipt → no adverse drift
      g_fills[g_fillCount - 1].driftLagMs = driftLag;

      LogEvidence(0, "MARKET_BUY", "MARKET", dealTicket, brokerReceiptPrice, dealPrice,
                  bid, ask, slipPts, mktBuyLagMs, brokerExecMs, dealVolume,
                  StringFormat("roundtrip=%d cs_lag=%d broker_exec=%.0f send=%.5f rcpt=%.5f drift_lag=%.0f", (int)roundTripMs, (int)g_clientServerLagMs, brokerExecMs, g_marketSendPrice, brokerReceiptPrice, driftLag));

      PrintFormat("MARKET BUY FILL: price=%.5f drift=%.1f%s RT=%dms CS=%dms broker_exec=%.0fms drift_lag=%.0fms margin=%.2f lev=%.1f",
                  dealPrice, slipPts, g_unitLabel, (int)roundTripMs, (int)g_clientServerLagMs,
                  brokerExecMs, driftLag, g_measuredMarginBuy, g_verifiedLeverage);

      g_totalLotsTraded += dealVolume;
      g_marketFillReceived = true;
      SetPanelLine(1, "Phase 1: Opening sell (buy open)...", clrYellow);
      g_state = STATE_MARKET_SELL;  // Next: open sell (both open simultaneously)
      return;
   }

   // Accept DEAL_ENTRY_IN (hedging) or DEAL_ENTRY_OUT (netting — sell closes the buy)
   if(g_state == STATE_MARKET_SELL_WAIT && (dealEntry == DEAL_ENTRY_IN || dealEntry == DEAL_ENTRY_OUT) && dealType == DEAL_TYPE_SELL)
   {
      g_mktSellEntryPrice = dealPrice;
      g_marketEntryPrice = dealPrice;
      g_mktSellPosTicket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      g_mktSellCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      // Measure margin with BOTH positions open (the real leverage/margin test)
      g_measuredMarginSell = AccountInfoDouble(ACCOUNT_MARGIN);
      g_measuredMarginBoth = AccountInfoDouble(ACCOUNT_MARGIN);
      g_measuredEquityBoth = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_measuredMarginBoth > 0 && g_tickSize > 0 && g_tickValue > 0)
      {
         // Notional = both positions
         double notionalBuy = g_lotSize * (g_mktBuyEntryPrice / g_tickSize) * g_tickValue;
         double notionalSell = g_lotSize * (dealPrice / g_tickSize) * g_tickValue;
         g_verifiedLeverageBoth = (notionalBuy + notionalSell) / g_measuredMarginBoth;

         // Calculate hedging ratio: how the broker margins hedged positions
         // gross_margin = sum of individual legs (margin_buy is single-leg margin)
         // hedging_ratio = actual_margin_both / gross_margin
         //   0.0 = NET (hedged positions cancel, zero margin)
         //   0.5 = larger-leg only (common retail hedging)
         //   1.0 = GROSS (both legs fully margined)
         // We estimate margin_sell ≈ margin_buy * (sell_price / buy_price) for accuracy
         double estMarginSell = g_measuredMarginBuy * (dealPrice / g_mktBuyEntryPrice);
         double grossMargin = g_measuredMarginBuy + estMarginSell;
         if(grossMargin > 0)
            g_calculatedHedgingRatio = g_measuredMarginBoth / grossMargin;
      }
      else if(g_measuredMarginBoth == 0 && g_measuredMarginBuy > 0)
      {
         // Zero margin with both open = pure netting (hedged positions cancel)
         g_calculatedHedgingRatio = 0.0;
      }

      // Save to universal GlobalVariable — shared with SaddleTrader EA
      if(g_calculatedHedgingRatio >= 0)
      {
         string gvKey = "HedgingRatio_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol;
         GlobalVariableSet(gvKey, g_calculatedHedgingRatio);
         PrintFormat("HEDGING RATIO: Saved %.4f to GlobalVariable '%s'", g_calculatedHedgingRatio, gvKey);
      }

      // Broker exec from DEAL_TIME_MSC (epoch calibrated from pending order in DoCsCalibrate)
      long mktSellDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      long mktSellSendEpoch = (long)(g_epochMsOffset + g_marketSendMs);
      double mktSellLagMs = (double)(mktSellDealTimeMsc - mktSellSendEpoch);
      if(mktSellLagMs < 0) mktSellLagMs = 0;
      double brokerExecMs = (double)(mktSellDealTimeMsc - mktSellSendEpoch - (long)g_clientServerLagMs);
      if(brokerExecMs < 0) brokerExecMs = 0;
      g_mktSyncOpenSellMs = brokerExecMs;  // Sync baseline from MSC-based broker exec

      // Execution drift: measure from broker receipt price (what broker had when instruction arrived)
      ulong rcptBootMs = g_marketSendMs + g_clientServerLagMs;
      double rcptBid = 0, rcptAsk = 0;
      double brokerReceiptPrice = g_marketSendPrice; // Fallback
      if(GetTickAtTime(rcptBootMs, rcptBid, rcptAsk) && rcptBid > 0)
         brokerReceiptPrice = rcptBid; // Sell fills at bid
      double slipPts = brokerReceiptPrice - dealPrice; // Drift from broker receipt price

      RecordFill(FILL_MARKET_SELL, dealOrder, dealTicket,
                 brokerReceiptPrice, dealPrice, bid, ask,
                 g_marketSendMs, g_marketSendMs, nowMs,
                 dealVolume, false, StringFormat("RT=%dms send=%.5f rcpt=%.5f", (int)(nowMs - g_marketSendMs), g_marketSendPrice, brokerReceiptPrice));
      g_fills[g_fillCount - 1].lagMs              = mktSellLagMs;
      g_fills[g_fillCount - 1].brokerExecMs        = brokerExecMs;
      g_fills[g_fillCount - 1].dealTimeMsc          = mktSellDealTimeMsc;
      g_fills[g_fillCount - 1].brokerReceiptPrice   = brokerReceiptPrice;
      g_fills[g_fillCount - 1].clientSendPrice      = g_marketSendPrice;

      // Drift lag: time for bid to reach deal price from receipt (sell fills at bid, adverse = lower)
      double driftLag = (dealPrice < brokerReceiptPrice)
         ? FindDriftLagMs(dealPrice, 0, rcptBootMs)  // mode 0: bid <= dealPrice
         : 0;  // Deal at or above receipt → no adverse drift
      g_fills[g_fillCount - 1].driftLagMs = driftLag;

      LogEvidence(0, "MARKET_SELL", "MARKET", dealTicket, brokerReceiptPrice, dealPrice,
                  bid, ask, slipPts, mktSellLagMs, brokerExecMs, dealVolume,
                  StringFormat("margin_both=%.2f lev_both=%.1f send=%.5f rcpt=%.5f drift_lag=%.0f", g_measuredMarginBoth, g_verifiedLeverageBoth, g_marketSendPrice, brokerReceiptPrice, driftLag));

      PrintFormat("MARKET SELL FILL: price=%.5f drift=%.1f%s broker_exec=%.0fms drift_lag=%.0fms margin_both=%.2f lev_both=%.1f",
                  dealPrice, slipPts, g_unitLabel, brokerExecMs, driftLag, g_measuredMarginBoth, g_verifiedLeverageBoth);

      g_totalLotsTraded += dealVolume;
      g_marketFillReceived = true;

      //--- NETTING ACCOUNT: sell closed the buy — no positions remain ---
      if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      {
         PrintFormat("NETTING ACCOUNT: Sell closed buy (DEAL_ENTRY_OUT) — skipping TP/SL and close phases");
         // The sell execution IS the buy close on netting — use as close baseline
         g_mktSyncCloseBuyMs = brokerExecMs;

         if(g_calibPass < 2)
         {
            // Save pass 1 baselines (SL/TP not measurable on netting market test)
            g_pass1SyncOpenBuyMs   = g_mktSyncOpenBuyMs;
            g_pass1SyncOpenSellMs  = g_mktSyncOpenSellMs;
            g_pass1SyncSLBuyMs     = 0;
            g_pass1SyncSLSellMs    = 0;
            g_pass1SyncTPBuyMs     = 0;
            g_pass1SyncTPSellMs    = 0;
            g_pass1SyncCloseBuyMs  = g_mktSyncCloseBuyMs;
            g_pass1SyncCloseSellMs = 0;

            PrintFormat("═══ CALIBRATION PASS %d COMPLETE (netting) — starting pass 2 ═══", g_calibPass);
            SetPanelLine(1, "Phase 0: Calibrating CS latency (pass 2 of 2)...", clrYellow);
            g_state = STATE_CS_CALIBRATE;
         }
         else
         {
            // Average CS calibration values from both passes
            g_csPass2LagMs       = g_clientServerLagMs;
            g_csPass2RoundTripMs = g_clientServerRoundTripMs;

            ulong avgLag = (g_csPass1LagMs + g_csPass2LagMs) / 2;
            ulong avgRT  = (g_csPass1RoundTripMs + g_csPass2RoundTripMs) / 2;
            ulong avgEpoch = (g_csPass1EpochOffset + g_epochMsOffset) / 2;

            PrintFormat("═══ CS CALIBRATION FINAL (netting): pass1=%dms pass2=%dms → avg=%dms ═══",
               (int)g_csPass1LagMs, (int)g_csPass2LagMs, (int)avgLag);

            g_clientServerLagMs       = avgLag;
            g_clientServerRoundTripMs = avgRT;
            g_epochMsOffset           = avgEpoch;
            g_csCalibPlaceRtMs        = (g_csPass1PlaceRtMs + g_csCalibPlaceRtMs) / 2;
            g_csCalibDeleteRtMs       = (g_csPass1DeleteRtMs + g_csCalibDeleteRtMs) / 2;

            // Average market baselines (SL/TP stay 0 — measured during grid phase)
            g_mktSyncOpenBuyMs   = (g_pass1SyncOpenBuyMs   + g_mktSyncOpenBuyMs)   / 2;
            g_mktSyncOpenSellMs  = (g_pass1SyncOpenSellMs  + g_mktSyncOpenSellMs)  / 2;
            g_mktSyncCloseBuyMs  = (g_pass1SyncCloseBuyMs  + g_mktSyncCloseBuyMs)  / 2;
            // SL/TP and close-sell baselines remain 0 — will be populated during grid phase

            // Empty SL/TP arrays — grid phase will populate them
            g_syncSLPlaceCount = 0;
            ArrayResize(g_syncSLPlaceLags, 0);
            g_syncTPPlaceCount = 0;
            ArrayResize(g_syncTPPlaceLags, 0);

            PrintFormat("═══ BASELINE AVERAGES (netting): OpenBuy=%.0f OpenSell=%.0f CloseBuy=%.0f ═══",
               g_mktSyncOpenBuyMs, g_mktSyncOpenSellMs, g_mktSyncCloseBuyMs);

            SetPanelLine(1, StringFormat("CS Lag: %dms one-way (netting) — Starting grid...",
               (int)g_clientServerLagMs), clrYellow);

            g_state = STATE_GRID_PLACE;
         }
         return;
      }

      //--- HEDGING ACCOUNT: both positions remain open — proceed with TP/SL ---
      SetPanelLine(1, "Phase 1: Both open — placing SL/TP on buy...", clrYellow);
      g_state = STATE_MARKET_BUY_SLTP;
      return;
   }

   //=== MARKET CLOSE BUY FILL (isolated) ===
   if(g_state == STATE_MARKET_CLOSE_BUY_WAIT && dealEntry == DEAL_ENTRY_OUT)
   {
      double entryP = g_mktBuyEntryPrice;
      double priceDiff = dealPrice - entryP;
      double exactProfit = (priceDiff / g_tickSize) * g_tickValue * dealVolume;
      double roundingErr = dealProfit - exactProfit;
      g_roundingErrorSum    += roundingErr;
      g_roundingErrorAbsSum += MathAbs(roundingErr);
      if(MathAbs(roundingErr) > g_roundingErrorMax) g_roundingErrorMax = MathAbs(roundingErr);
      g_roundingErrorCount++;
      g_brokerProfitSum += dealProfit;
      g_exactProfitSum  += exactProfit;

      long mktDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      long mktSendEpoch = (long)(g_epochMsOffset + g_mktCloseBuySendMs);
      double closeLagMs = (double)(mktDealTimeMsc - mktSendEpoch);
      if(closeLagMs < 0) closeLagMs = 0;
      double brokerExecMs = (double)(mktDealTimeMsc - mktSendEpoch - (long)g_clientServerLagMs);
      if(brokerExecMs < 0) brokerExecMs = 0;

      g_mktSyncCloseBuyMs = brokerExecMs;

      // Execution drift: broker receipt price for closing buy position (sells at bid)
      ulong rcptBootMs = g_mktCloseBuySendMs + g_clientServerLagMs;
      double rcptBid = 0, rcptAsk = 0;
      double brokerReceiptPrice = g_marketSendPrice; // Fallback
      if(GetTickAtTime(rcptBootMs, rcptBid, rcptAsk) && rcptBid > 0)
         brokerReceiptPrice = rcptBid; // Closing buy sells at bid
      double slipPts = dealPrice - brokerReceiptPrice;

      RecordFill(FILL_SYNC_CLOSE, dealOrder, dealTicket,
                 brokerReceiptPrice, dealPrice, bid, ask,
                 g_mktCloseBuySendMs, g_mktCloseBuySendMs, nowMs,
                 dealVolume, true, StringFormat("close_buy_sync pnl=%.2f %s rounding=%.6f send=%.5f rcpt=%.5f",
                    g_mktCloseBuyPnL, g_mktCloseBuyInProfit ? "PROFIT" : "LOSS", roundingErr, g_marketSendPrice, brokerReceiptPrice));
      g_fills[g_fillCount - 1].lagMs              = closeLagMs;
      g_fills[g_fillCount - 1].brokerExecMs        = brokerExecMs;
      g_fills[g_fillCount - 1].isStraggler          = true;
      g_fills[g_fillCount - 1].dealTimeMsc          = mktDealTimeMsc;
      g_fills[g_fillCount - 1].brokerReceiptPrice   = brokerReceiptPrice;
      g_fills[g_fillCount - 1].clientSendPrice      = g_marketSendPrice;

      // Drift lag: closing buy sells at bid (adverse = lower bid)
      {
         double driftLag = 0;
         if(MathAbs(dealPrice - brokerReceiptPrice) > 0.5 * g_point)
            driftLag = (dealPrice < brokerReceiptPrice)
               ? FindDriftLagMs(dealPrice, 0, rcptBootMs)   // bid <= dealPrice (adverse)
               : FindDriftLagMs(dealPrice, 1, rcptBootMs);  // bid >= dealPrice (favorable)
         g_fills[g_fillCount - 1].driftLagMs = driftLag;
      }

      // Timestamp verification: deal price vs tick at DEAL_TIME_MSC (validates broker timestamp honesty)
      ulong mktDealBootMs = (ulong)((long)mktDealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;
      double mktTickBid = 0, mktTickAsk = 0;
      if(GetTickAtTime(mktDealBootMs, mktTickBid, mktTickAsk))
      {
         double pDelta = (dealPrice - mktTickBid) / g_point;
         g_fills[g_fillCount - 1].tickPriceAtDeal  = mktTickBid;
         g_fills[g_fillCount - 1].priceVerifyDelta = pDelta;
         g_closePriceVerifyCount++;
         g_closePriceVerifyAbsSum += MathAbs(pDelta);
         if(MathAbs(pDelta) > g_closePriceVerifyMaxAbs)
            g_closePriceVerifyMaxAbs = MathAbs(pDelta);
         if(MathAbs(pDelta) > 0.5)
            g_closePriceMismatchCount++;
      }

      LogEvidence(0, "CLOSE", "MKT_BUY_CLOSE_SYNC", dealTicket,
                  brokerReceiptPrice, dealPrice, bid, ask, slipPts,
                  closeLagMs, brokerExecMs, dealVolume,
                  StringFormat("profit=%.2f pnl=%.2f %s", dealProfit, g_mktCloseBuyPnL,
                     g_mktCloseBuyInProfit ? "PROFIT" : "LOSS"));

      PrintFormat("MARKET CLOSE BUY: exec=%.0fms pnl=%.2f (%s)",
         brokerExecMs, g_mktCloseBuyPnL, g_mktCloseBuyInProfit ? "PROFIT" : "LOSS");

      SetPanelLine(1, "Phase 1: Closing sell position...", clrYellow);
      g_state = STATE_MARKET_CLOSE_SELL;
      return;
   }

   //=== MARKET CLOSE SELL FILL (isolated) ===
   if(g_state == STATE_MARKET_CLOSE_SELL_WAIT && dealEntry == DEAL_ENTRY_OUT)
   {
      double entryP = g_mktSellEntryPrice;
      double priceDiff = entryP - dealPrice;
      double exactProfit = (priceDiff / g_tickSize) * g_tickValue * dealVolume;
      double roundingErr = dealProfit - exactProfit;
      g_roundingErrorSum    += roundingErr;
      g_roundingErrorAbsSum += MathAbs(roundingErr);
      if(MathAbs(roundingErr) > g_roundingErrorMax) g_roundingErrorMax = MathAbs(roundingErr);
      g_roundingErrorCount++;
      g_brokerProfitSum += dealProfit;
      g_exactProfitSum  += exactProfit;

      long mktDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      long mktSendEpoch = (long)(g_epochMsOffset + g_mktCloseSellSendMs);
      double closeLagMs = (double)(mktDealTimeMsc - mktSendEpoch);
      if(closeLagMs < 0) closeLagMs = 0;
      double brokerExecMs = (double)(mktDealTimeMsc - mktSendEpoch - (long)g_clientServerLagMs);
      if(brokerExecMs < 0) brokerExecMs = 0;

      g_mktSyncCloseSellMs = brokerExecMs;

      // Execution drift: broker receipt price for closing sell position (buys at ask)
      ulong rcptBootMs = g_mktCloseSellSendMs + g_clientServerLagMs;
      double rcptBid = 0, rcptAsk = 0;
      double brokerReceiptPrice = g_marketSendPrice; // Fallback
      if(GetTickAtTime(rcptBootMs, rcptBid, rcptAsk) && rcptAsk > 0)
         brokerReceiptPrice = rcptAsk; // Closing sell buys at ask
      double slipPts = brokerReceiptPrice - dealPrice;

      RecordFill(FILL_SYNC_CLOSE, dealOrder, dealTicket,
                 brokerReceiptPrice, dealPrice, bid, ask,
                 g_mktCloseSellSendMs, g_mktCloseSellSendMs, nowMs,
                 dealVolume, false, StringFormat("close_sell_sync pnl=%.2f %s rounding=%.6f send=%.5f rcpt=%.5f",
                    g_mktCloseSellPnL, g_mktCloseSellInProfit ? "PROFIT" : "LOSS", roundingErr, g_marketSendPrice, brokerReceiptPrice));
      g_fills[g_fillCount - 1].lagMs              = closeLagMs;
      g_fills[g_fillCount - 1].brokerExecMs        = brokerExecMs;
      g_fills[g_fillCount - 1].isStraggler          = true;
      g_fills[g_fillCount - 1].dealTimeMsc          = mktDealTimeMsc;
      g_fills[g_fillCount - 1].brokerReceiptPrice   = brokerReceiptPrice;
      g_fills[g_fillCount - 1].clientSendPrice      = g_marketSendPrice;

      // Drift lag: closing sell buys at ask (adverse = higher ask)
      {
         double driftLag = 0;
         if(MathAbs(dealPrice - brokerReceiptPrice) > 0.5 * g_point)
            driftLag = (dealPrice > brokerReceiptPrice)
               ? FindDriftLagMs(dealPrice, 2, rcptBootMs)   // ask >= dealPrice (adverse)
               : FindDriftLagMs(dealPrice, 3, rcptBootMs);  // ask <= dealPrice (favorable)
         g_fills[g_fillCount - 1].driftLagMs = driftLag;
      }

      // Timestamp verification: deal price vs tick at DEAL_TIME_MSC
      ulong mktDealBootMs = (ulong)((long)mktDealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;
      double mktTickBid = 0, mktTickAsk = 0;
      if(GetTickAtTime(mktDealBootMs, mktTickBid, mktTickAsk))
      {
         double pDelta = (dealPrice - mktTickAsk) / g_point;
         g_fills[g_fillCount - 1].tickPriceAtDeal  = mktTickAsk;
         g_fills[g_fillCount - 1].priceVerifyDelta = pDelta;
         g_closePriceVerifyCount++;
         g_closePriceVerifyAbsSum += MathAbs(pDelta);
         if(MathAbs(pDelta) > g_closePriceVerifyMaxAbs)
            g_closePriceVerifyMaxAbs = MathAbs(pDelta);
         if(MathAbs(pDelta) > 0.5)
            g_closePriceMismatchCount++;
      }

      LogEvidence(0, "CLOSE", "MKT_SELL_CLOSE_SYNC", dealTicket,
                  brokerReceiptPrice, dealPrice, bid, ask, slipPts,
                  closeLagMs, brokerExecMs, dealVolume,
                  StringFormat("profit=%.2f pnl=%.2f %s", dealProfit, g_mktCloseSellPnL,
                     g_mktCloseSellInProfit ? "PROFIT" : "LOSS"));

      PrintFormat("MARKET CLOSE SELL: exec=%.0fms pnl=%.2f (%s)",
         brokerExecMs, g_mktCloseSellPnL, g_mktCloseSellInProfit ? "PROFIT" : "LOSS");

      // After close sell: if calibration pass 1, run pass 2; else average and start grid
      if(g_calibPass < 2)
      {
         // Save pass 1 baseline measurements before looping back
         g_pass1SyncOpenBuyMs   = g_mktSyncOpenBuyMs;
         g_pass1SyncOpenSellMs  = g_mktSyncOpenSellMs;
         g_pass1SyncSLBuyMs     = g_mktSyncSLBuyMs;
         g_pass1SyncSLSellMs    = g_mktSyncSLSellMs;
         g_pass1SyncTPBuyMs     = g_mktSyncTPBuyMs;
         g_pass1SyncTPSellMs    = g_mktSyncTPSellMs;
         g_pass1SyncCloseBuyMs  = g_mktSyncCloseBuyMs;
         g_pass1SyncCloseSellMs = g_mktSyncCloseSellMs;

         PrintFormat("═══ CALIBRATION PASS %d COMPLETE — starting pass 2 ═══", g_calibPass);
         PrintFormat("  Pass 1 baselines: OpenBuy=%.0f OpenSell=%.0f SLBuy=%.0f SLSell=%.0f TPBuy=%.0f TPSell=%.0f CloseBuy=%.0f CloseSell=%.0f",
            g_pass1SyncOpenBuyMs, g_pass1SyncOpenSellMs,
            g_pass1SyncSLBuyMs, g_pass1SyncSLSellMs,
            g_pass1SyncTPBuyMs, g_pass1SyncTPSellMs,
            g_pass1SyncCloseBuyMs, g_pass1SyncCloseSellMs);
         SetPanelLine(1, "Phase 0: Calibrating CS latency (pass 2 of 2)...", clrYellow);
         g_state = STATE_CS_CALIBRATE;
      }
      else
      {
         // Save pass 2 values, then average both passes
         g_csPass2LagMs       = g_clientServerLagMs;
         g_csPass2RoundTripMs = g_clientServerRoundTripMs;

         ulong avgLag = (g_csPass1LagMs + g_csPass2LagMs) / 2;
         ulong avgRT  = (g_csPass1RoundTripMs + g_csPass2RoundTripMs) / 2;
         ulong avgEpoch = (g_csPass1EpochOffset + g_epochMsOffset) / 2;

         PrintFormat("═══ CS CALIBRATION FINAL: pass1=%dms pass2=%dms → avg=%dms (RT: %d+%d→%d) ═══",
            (int)g_csPass1LagMs, (int)g_csPass2LagMs, (int)avgLag,
            (int)g_csPass1RoundTripMs, (int)g_csPass2RoundTripMs, (int)avgRT);

         g_clientServerLagMs       = avgLag;
         g_clientServerRoundTripMs = avgRT;
         g_epochMsOffset           = avgEpoch;
         g_csCalibPlaceRtMs        = (g_csPass1PlaceRtMs + g_csCalibPlaceRtMs) / 2;
         g_csCalibDeleteRtMs       = (g_csPass1DeleteRtMs + g_csCalibDeleteRtMs) / 2;

         // Average all baseline measurements (sync open/close + SL/TP placements)
         g_mktSyncOpenBuyMs   = (g_pass1SyncOpenBuyMs   + g_mktSyncOpenBuyMs)   / 2;
         g_mktSyncOpenSellMs  = (g_pass1SyncOpenSellMs  + g_mktSyncOpenSellMs)  / 2;
         g_mktSyncSLBuyMs     = (g_pass1SyncSLBuyMs     + g_mktSyncSLBuyMs)     / 2;
         g_mktSyncSLSellMs    = (g_pass1SyncSLSellMs    + g_mktSyncSLSellMs)    / 2;
         g_mktSyncTPBuyMs     = (g_pass1SyncTPBuyMs     + g_mktSyncTPBuyMs)     / 2;
         g_mktSyncTPSellMs    = (g_pass1SyncTPSellMs    + g_mktSyncTPSellMs)    / 2;
         g_mktSyncCloseBuyMs  = (g_pass1SyncCloseBuyMs  + g_mktSyncCloseBuyMs)  / 2;
         g_mktSyncCloseSellMs = (g_pass1SyncCloseSellMs + g_mktSyncCloseSellMs) / 2;

         // Rebuild SL/TP placement arrays with averaged values only
         g_syncSLPlaceCount = 0;
         ArrayResize(g_syncSLPlaceLags, 2);
         if(g_mktSyncSLBuyMs > 0)  g_syncSLPlaceLags[g_syncSLPlaceCount++] = g_mktSyncSLBuyMs;
         if(g_mktSyncSLSellMs > 0) g_syncSLPlaceLags[g_syncSLPlaceCount++] = g_mktSyncSLSellMs;
         ArrayResize(g_syncSLPlaceLags, g_syncSLPlaceCount);

         g_syncTPPlaceCount = 0;
         ArrayResize(g_syncTPPlaceLags, 2);
         if(g_mktSyncTPBuyMs > 0)  g_syncTPPlaceLags[g_syncTPPlaceCount++] = g_mktSyncTPBuyMs;
         if(g_mktSyncTPSellMs > 0) g_syncTPPlaceLags[g_syncTPPlaceCount++] = g_mktSyncTPSellMs;
         ArrayResize(g_syncTPPlaceLags, g_syncTPPlaceCount);

         PrintFormat("═══ BASELINE AVERAGES: OpenBuy=%.0f OpenSell=%.0f SLBuy=%.0f SLSell=%.0f TPBuy=%.0f TPSell=%.0f CloseBuy=%.0f CloseSell=%.0f ═══",
            g_mktSyncOpenBuyMs, g_mktSyncOpenSellMs,
            g_mktSyncSLBuyMs, g_mktSyncSLSellMs,
            g_mktSyncTPBuyMs, g_mktSyncTPSellMs,
            g_mktSyncCloseBuyMs, g_mktSyncCloseSellMs);

         SetPanelLine(1, StringFormat("CS Lag: %dms one-way (avg of 2 passes) — Starting grid...",
            (int)g_clientServerLagMs), clrYellow);

         g_state = STATE_GRID_PLACE;
      }
      return;
   }

   //=== WAIT_PROFIT: SL/TP triggered on market test position (safety) ===
   if(g_state == STATE_MARKET_WAIT_PROFIT && dealEntry == DEAL_ENTRY_OUT)
   {
      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(posId == g_mktBuyPosTicket)
      {
         PrintFormat("WARNING: Buy position SL/TP triggered during WAIT_PROFIT — closing sell only");
         g_mktCloseBuyPnL = dealProfit;
         g_mktCloseBuyInProfit = (dealProfit > 0);
         g_mktSyncCloseBuyMs = 0; // Can't measure — broker closed it
         // Remove SL/TP from sell before closing
         g_trade.SetAsyncMode(false);
         if(PositionSelectByTicket(g_mktSellPosTicket))
            g_trade.PositionModify(g_mktSellPosTicket, 0, 0);
         g_state = STATE_MARKET_CLOSE_SELL;
         return;
      }
      if(posId == g_mktSellPosTicket)
      {
         PrintFormat("WARNING: Sell position SL/TP triggered during WAIT_PROFIT — closing buy only");
         g_mktCloseSellPnL = dealProfit;
         g_mktCloseSellInProfit = (dealProfit > 0);
         g_mktSyncCloseSellMs = 0; // Can't measure — broker closed it
         // Remove SL/TP from buy before closing
         g_trade.SetAsyncMode(false);
         if(PositionSelectByTicket(g_mktBuyPosTicket))
            g_trade.PositionModify(g_mktBuyPosTicket, 0, 0);
         g_state = STATE_MARKET_CLOSE_BUY;
         return;
      }
   }

   //=== GRID ENTRY FILLS (pending orders triggered) ===
   if(g_state == STATE_GRID_WAIT && dealEntry == DEAL_ENTRY_IN)
   {
      // Match to grid order: try ticket first, then fallback to price+direction
      // (In async mode, g_trade.ResultOrder() may return 0, so ticket match can fail)
      int matchIdx = -1;
      for(int i = 0; i < g_gridSize; i++)
      {
         if(!g_grid[i].filled && g_grid[i].ticket == dealOrder && dealOrder > 0)
         { matchIdx = i; break; }
      }
      if(matchIdx < 0)
      {
         // Fallback: match by requested price and direction
         bool dealIsBuy = (dealType == DEAL_TYPE_BUY);
         for(int i = 0; i < g_gridSize; i++)
         {
            if(!g_grid[i].filled && g_grid[i].isBuy == dealIsBuy &&
               MathAbs(g_grid[i].price - dealPrice) < g_point * 50)  // within 50 points
            { matchIdx = i; break; }
         }
      }
      if(matchIdx >= 0)
      {
         int i = matchIdx;
         g_grid[i].filled = true;
         g_grid[i].fillPrice = dealPrice;
         g_grid[i].fillTimeMs = nowMs;
         g_grid[i].positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
         g_grid[i].tpslProcessed = false;
         g_gridFillsReceived++;
         g_lastFillMs = nowMs;

         // Update cycle record
         if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
         {
            g_cycles[g_cycleNum - 1].totalFilled++;
            if(g_grid[i].isLimit) g_cycles[g_cycleNum - 1].limitFills++;
            else                  g_cycles[g_cycleNum - 1].stopFills++;
         }

         // Determine fill type
         ENUM_FILL_TYPE ftype;
         string ftypeStr;
         if(g_grid[i].isLimit)
         {
            ftype = g_grid[i].isBuy ? FILL_BUYLIMIT : FILL_SELLLIMIT;
            ftypeStr = g_grid[i].isBuy ? "BUYLIMIT" : "SELLLIMIT";
         }
         else
         {
            ftype = g_grid[i].isBuy ? FILL_BUYSTOP : FILL_SELLSTOP;
            ftypeStr = g_grid[i].isBuy ? "BUYSTOP" : "SELLSTOP";
         }

         // Server-side triggers: slippage in points is volatility noise, not broker-caused.
         // The only broker-dependent metric is drift lag (trigger-to-fill time).
         // Set slipPts=0 — price impact during the broker's processing window is a function
         // of market conditions, not broker intent. The lag itself is what we measure.
         double slipPts = 0;

         // Broker trigger-to-fill lag from server timestamps:
         // Primary: CopyTicksRange (server tick history, ms precision, no CS_lag needed)
         // Fallback: EA tick buffer (boot-relative, requires CS_lag conversion)
         long entryDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
         g_grid[i].entryDealTimeMsc = entryDealTimeMsc;
         double lagMs = 0;
         double brokerExecMs = 0;

         int trigMode;
         if(g_grid[i].isLimit)
            trigMode = g_grid[i].isBuy ? 2 : 1;  // BuyLimit: ask<=price, SellLimit: bid>=price
         else
            trigMode = g_grid[i].isBuy ? 3 : 0;  // BuyStop: ask>=price, SellStop: bid<=price

         // Primary: server tick history — both timestamps are server-side, pure broker holding time
         long placeMsc = (long)(g_epochMsOffset + g_grid[i].placeTimeMs);
         long triggerMsc = FindTriggerTickMsc(g_grid[i].price, trigMode, placeMsc, entryDealTimeMsc);
         if(triggerMsc > 0)
         {
            brokerExecMs = (double)(entryDealTimeMsc - triggerMsc);
            lagMs = brokerExecMs;
            if(brokerExecMs < 1) brokerExecMs = 1;  // Floor: no order executes in 0ms
            if(lagMs < 1) lagMs = 1;
            PrintFormat("TRIGGER[%s] PRIMARY: price=%.5f mode=%d trigMsc=%I64d dealMsc=%I64d lag=%.0fms ticks_range=%I64d-%I64d",
               ftypeStr, g_grid[i].price, trigMode, triggerMsc, entryDealTimeMsc, lagMs, placeMsc, entryDealTimeMsc);
         }
         else if(g_grid[i].triggerTimeMs > 0)
         {
            // Fallback 1: CheckGridTriggers detected the trigger via OnTick
            long triggerEpoch = (long)(g_epochMsOffset + g_grid[i].triggerTimeMs);
            lagMs = (double)(entryDealTimeMsc - triggerEpoch);
            brokerExecMs = (double)(entryDealTimeMsc - triggerEpoch + (long)g_clientServerLagMs);
            if(brokerExecMs < 1) brokerExecMs = 1;  // Floor: no order executes in 0ms
            if(lagMs < 1) lagMs = 1;
            PrintFormat("TRIGGER[%s] FALLBACK1: price=%.5f mode=%d trigEpoch=%I64d dealMsc=%I64d lag=%.0fms",
               ftypeStr, g_grid[i].price, trigMode, triggerEpoch, entryDealTimeMsc, lagMs);
         }
         else
         {
            // Fallback 2: EA tick buffer scan
            ulong dealBootMs = (ulong)((long)entryDealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;
            ulong trigMs = FindTriggerTick(g_grid[i].price, trigMode, dealBootMs, g_grid[i].placeTimeMs);
            if(trigMs > 0)
            {
               long triggerEpoch = (long)(g_epochMsOffset + trigMs);
               lagMs = (double)(entryDealTimeMsc - triggerEpoch);
               brokerExecMs = (double)(entryDealTimeMsc - triggerEpoch + (long)g_clientServerLagMs);
               if(brokerExecMs < 1) brokerExecMs = 1;  // Floor: no order executes in 0ms
               if(lagMs < 1) lagMs = 1;
               g_grid[i].triggerTimeMs = trigMs;
               g_grid[i].priceCrossed = true;
               PrintFormat("TRIGGER[%s] FALLBACK2: price=%.5f mode=%d lag=%.0fms", ftypeStr, g_grid[i].price, trigMode, lagMs);
            }
            else
            {
               PrintFormat("TRIGGER[%s] FAILED: price=%.5f mode=%d placeMsc=%I64d dealMsc=%I64d range=%I64dms isLimit=%d",
                  ftypeStr, g_grid[i].price, trigMode, placeMsc, entryDealTimeMsc,
                  (entryDealTimeMsc - placeMsc), (int)g_grid[i].isLimit);
            }
         }

         double slipUSD = (slipPts / g_tickSize) * g_tickValue * dealVolume;

         RecordFill(ftype, dealOrder, dealTicket,
                    g_grid[i].price, dealPrice, bid, ask,
                    g_grid[i].placeTimeMs, g_grid[i].triggerTimeMs, nowMs,
                    dealVolume, g_grid[i].isBuy,
                    StringFormat("grid_%s type=%d", ftypeStr, g_grid[i].gridType));
         g_fills[g_fillCount - 1].lagMs       = lagMs;
         g_fills[g_fillCount - 1].brokerExecMs = brokerExecMs;
         g_fills[g_fillCount - 1].dealTimeMsc  = entryDealTimeMsc;
         g_fills[g_fillCount - 1].lagValid     = (lagMs > 0 || brokerExecMs > 0 || triggerMsc > 0);
         g_fills[g_fillCount - 1].brokerReceiptPrice = g_grid[i].price;  // Trigger price IS the receipt price

         // Drift lag for server-side triggers = broker exec time (trigger to deal).
         // The lag itself IS the broker-dependent metric. Price difference is volatility.
         // If trigger time detected: drift lag = broker exec time (trigger→deal).
         // If trigger detection failed: assume instant execution (<1ms) → drift lag = 0.
         g_fills[g_fillCount - 1].driftLagMs = (g_grid[i].triggerTimeMs > 0) ? MathMax(brokerExecMs, 0.0) : 0;

         // Cross-validate fill price against tick at execution time
         ulong entryDealBootMs = (ulong)((long)entryDealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;
         double entryTickBid = 0, entryTickAsk = 0;
         if(GetTickAtTime(entryDealBootMs, entryTickBid, entryTickAsk))
         {
            // For trigger/market classification: tickPriceAtDeal = actual market price at deal time
            // Limits: BuyLimit fills at ask, SellLimit fills at bid (market side at execution)
            // Stops:  BuyStop fills at ask, SellStop fills at bid
            double expectedP = g_grid[i].isBuy ? entryTickAsk : entryTickBid;
            g_fills[g_fillCount - 1].tickPriceAtDeal  = expectedP;

            if(g_grid[i].isLimit)
            {
               // Cross-validation: limit should fill AT trigger price or better
               double limitVerifyDelta = g_grid[i].isBuy
                  ? -(dealPrice - g_grid[i].price)   // Buy: filled higher = adverse = negative
                  : -(g_grid[i].price - dealPrice);   // Sell: filled lower = adverse = negative
               g_fills[g_fillCount - 1].priceVerifyDelta = limitVerifyDelta;
            }
            else
            {
               double pDelta = (dealPrice - expectedP) / g_point;
               g_fills[g_fillCount - 1].priceVerifyDelta = pDelta;
            }
         }

         LogEvidence(g_cycleNum, ftypeStr, ftypeStr, dealTicket,
                     g_grid[i].price, dealPrice, bid, ask,
                     slipPts, lagMs, brokerExecMs, dealVolume,
                     StringFormat("type=%d tp=%.5f sl=%.5f", g_grid[i].gridType,
                                  g_grid[i].tpPrice, g_grid[i].slPrice));

         // Calibration: snapshot account state immediately after fill
         LogCalibrationSnapshot("FILL", g_cycleNum);

         g_totalLotsTraded += dealVolume;

         // === SYNC SL/TP PLACEMENT on first fill ===
         // Immediately place SL and TP at ±3 spreads from fill price
         // This gives a clean sync round-trip measurement
         if(g_gridFillsReceived == 1 && g_grid[i].positionId > 0)
         {
            double curSpread = (ask - bid);
            double tpslDist = curSpread * 3.0;
            // Ensure distance meets broker's STOPS_LEVEL minimum
            int stopsLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
            double minStopDist = stopsLevel * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
            if(tpslDist < minStopDist * 1.1)
               tpslDist = minStopDist * 1.1;  // 10% margin above broker minimum
            double syncSL, syncTP;
            if(g_grid[i].isBuy)
            {
               syncSL = NormalizeDouble(dealPrice - tpslDist, g_digits);
               syncTP = NormalizeDouble(dealPrice + tpslDist, g_digits);
            }
            else
            {
               syncSL = NormalizeDouble(dealPrice + tpslDist, g_digits);
               syncTP = NormalizeDouble(dealPrice - tpslDist, g_digits);
            }

            g_trade.SetAsyncMode(false);

            // Sync SL placement
            if(PositionSelectByTicket(g_grid[i].positionId))
            {
               ulong slSendMs = GetTickCount64();
               bool slOk = g_trade.PositionModify(g_grid[i].positionId, syncSL, 0);
               ulong slAckMs = GetTickCount64();
               if(slOk)
               {
                  long rt = (long)(slAckMs - slSendMs);
                  double slLag = (double)(rt - (long)g_clientServerRoundTripMs);
                  if(slLag < 0) slLag = 0;
                  ArrayResize(g_syncSLPlaceLags, g_syncSLPlaceCount + 1);
                  g_syncSLPlaceLags[g_syncSLPlaceCount++] = slLag;
                  PrintFormat("SYNC SL PLACED (1st fill): pos=%I64u exec=%.0fms RT=%ldms CS_RT=%ldms sl=%.5f",
                     g_grid[i].positionId, slLag, rt, (long)g_clientServerRoundTripMs, syncSL);
               }
               else
                  PrintFormat("SYNC SL FAILED (1st fill): pos=%I64u sl=%.5f err=%d",
                     g_grid[i].positionId, syncSL, (int)GetLastError());
            }

            // Sync TP placement (keep SL)
            if(PositionSelectByTicket(g_grid[i].positionId))
            {
               double keepSL = PositionGetDouble(POSITION_SL);
               ulong tpSendMs = GetTickCount64();
               bool tpOk = g_trade.PositionModify(g_grid[i].positionId, keepSL, syncTP);
               ulong tpAckMs = GetTickCount64();
               if(tpOk)
               {
                  long rt = (long)(tpAckMs - tpSendMs);
                  double tpLag = (double)(rt - (long)g_clientServerRoundTripMs);
                  if(tpLag < 0) tpLag = 0;
                  ArrayResize(g_syncTPPlaceLags, g_syncTPPlaceCount + 1);
                  g_syncTPPlaceLags[g_syncTPPlaceCount++] = tpLag;
                  PrintFormat("SYNC TP PLACED (1st fill): pos=%I64u exec=%.0fms RT=%ldms CS_RT=%ldms tp=%.5f",
                     g_grid[i].positionId, tpLag, rt, (long)g_clientServerRoundTripMs, syncTP);
               }
               else
                  PrintFormat("SYNC TP FAILED (1st fill): pos=%I64u tp=%.5f err=%d",
                     g_grid[i].positionId, syncTP, (int)GetLastError());
            }

            // Store the SL/TP on the grid entry so TP/SL trigger measurement works
            g_grid[i].slPrice = syncSL;
            g_grid[i].tpPrice = syncTP;
            g_grid[i].tpslModified = true;

            g_trade.SetAsyncMode(true);
         }
      }
      return;
   }

   //=== TP/SL TRIGGERS (broker-side closes) ===
   if(g_state == STATE_GRID_WAIT && dealEntry == DEAL_ENTRY_OUT &&
      (dealReason == DEAL_REASON_TP || dealReason == DEAL_REASON_SL))
   {
      bool isTP = (dealReason == DEAL_REASON_TP);
      ENUM_FILL_TYPE ftype = isTP ? FILL_TP : FILL_SL;
      string ftypeStr = isTP ? "TP" : "SL";
      bool wasBuy = (dealType == DEAL_TYPE_SELL); // Closing a buy = sell deal

      // Find matching grid order via position ID (broker assigns new ticket on fill)
      ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double requestedPrice = 0;
      int gridIdx = -1;

      // Match by position ID stored at grid entry fill time
      for(int i = 0; i < g_gridSize; i++)
      {
         if(g_grid[i].filled && !g_grid[i].tpslProcessed && g_grid[i].positionId == posId)
         {
            requestedPrice = isTP ? g_grid[i].tpPrice : g_grid[i].slPrice;
            gridIdx = i;
            g_grid[i].tpslProcessed = true;
            break;
         }
      }
      // Fallback: if posId match failed, try any unprocessed grid order with matching TP/SL
      if(gridIdx < 0)
      {
         for(int i = 0; i < g_gridSize; i++)
         {
            if(g_grid[i].filled && !g_grid[i].tpslProcessed)
            {
               double price = isTP ? g_grid[i].tpPrice : g_grid[i].slPrice;
               if(price > 0)
               {
                  requestedPrice = price;
                  gridIdx = i;
                  g_grid[i].tpslProcessed = true;
                  break;
               }
            }
         }
      }

      // Server-side triggers: slippage in points is volatility noise, not broker-caused.
      // The only broker-dependent metric is drift lag (trigger-to-fill time).
      double slipPts = 0;

      // Rounding
      if(gridIdx >= 0)
      {
         double entryP = g_grid[gridIdx].fillPrice;
         double pDiff = wasBuy ? (dealPrice - entryP) : (entryP - dealPrice);
         double exact = (pDiff / g_tickSize) * g_tickValue * dealVolume;
         double rErr = dealProfit - exact;
         g_roundingErrorSum += rErr;
         g_roundingErrorAbsSum += MathAbs(rErr);
         if(MathAbs(rErr) > g_roundingErrorMax) g_roundingErrorMax = MathAbs(rErr);
         g_roundingErrorCount++;
         g_brokerProfitSum += dealProfit;
         g_exactProfitSum += exact;
      }

      // Update cycle stats
      if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
      {
         int ci = g_cycleNum - 1;
         if(isTP) g_cycles[ci].tpTriggers++;
         else     g_cycles[ci].slTriggers++;
      }

      // TP/SL broker trigger-to-fill lag:
      // Primary: CopyTicksRange (server tick history, ms precision, no CS_lag conversion)
      // Fallback: EA tick buffer (boot-relative, requires CS_lag conversion)
      //
      // SL = stop-like: triggers at market, slippage expected
      // TP = limit-like: should fill at TP price or better, adverse slippage = red flag
      long tpslDealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);
      ulong tpslDealBootMs = (ulong)((long)tpslDealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;

      // Trigger modes:
      // SL on BUY:  bid <= SL_price (mode 0)
      // TP on BUY:  bid >= TP_price (mode 1)
      // TP on SELL: ask <= TP_price (mode 2)
      // SL on SELL: ask >= SL_price (mode 3)
      int trigMode = -1;
      if(isTP && wasBuy)       trigMode = 1;  // bid >= TP
      else if(isTP && !wasBuy) trigMode = 2;  // ask <= TP
      else if(!isTP && wasBuy) trigMode = 0;  // bid <= SL
      else                     trigMode = 3;  // ask >= SL

      double tpslLagMs = 0;
      double tpslBrokerExecMs = 0;
      ulong  triggerTickMs = 0;

      // Lower bound: TP/SL only active after parent order filled on BROKER side
      long tpslAfterMsc = 0;
      if(gridIdx >= 0 && g_grid[gridIdx].entryDealTimeMsc > 0)
         tpslAfterMsc = g_grid[gridIdx].entryDealTimeMsc;

      // Primary: server tick history — pure server-side timestamps
      long triggerMsc = FindTriggerTickMsc(requestedPrice, trigMode, tpslAfterMsc, tpslDealTimeMsc);
      if(triggerMsc > 0)
      {
         tpslBrokerExecMs = (double)(tpslDealTimeMsc - triggerMsc);
         tpslLagMs = tpslBrokerExecMs;
         if(tpslBrokerExecMs < 1) tpslBrokerExecMs = 1;  // Floor: no order executes in 0ms
         if(tpslLagMs < 1) tpslLagMs = 1;
         // Convert server-epoch trigger to boot-relative for RecordFill/LogEvidence
         triggerTickMs = (ulong)((long)triggerMsc - (long)g_epochMsOffset + (long)g_clientServerLagMs);
         PrintFormat("TPSL_TRIG[%s] PRIMARY: price=%.5f mode=%d trigMsc=%I64d dealMsc=%I64d lag=%.0fms afterMsc=%I64d",
            ftypeStr, requestedPrice, trigMode, triggerMsc, tpslDealTimeMsc, tpslLagMs, tpslAfterMsc);
      }
      else
      {
         // Fallback: EA tick buffer
         ulong tpslAfterBootMs = 0;
         if(gridIdx >= 0 && g_grid[gridIdx].entryDealTimeMsc > 0)
            tpslAfterBootMs = (ulong)((long)g_grid[gridIdx].entryDealTimeMsc - (long)g_epochMsOffset + (long)g_clientServerLagMs);
         triggerTickMs = FindTriggerTick(requestedPrice, trigMode, tpslDealBootMs, tpslAfterBootMs);
         if(triggerTickMs > 0)
         {
            long brokerTriggerEpoch = (long)(g_epochMsOffset + triggerTickMs) - (long)g_clientServerLagMs;
            tpslBrokerExecMs = (double)(tpslDealTimeMsc - brokerTriggerEpoch);
            if(tpslBrokerExecMs < 1) tpslBrokerExecMs = 1;  // Floor: no order executes in 0ms
            tpslLagMs = (double)(tpslDealTimeMsc - (long)(g_epochMsOffset + triggerTickMs));
            if(tpslLagMs < 1) tpslLagMs = 1;
            PrintFormat("TPSL_TRIG[%s] FALLBACK: price=%.5f mode=%d lag=%.0fms", ftypeStr, requestedPrice, trigMode, tpslLagMs);
         }
         else
         {
            PrintFormat("TPSL_TRIG[%s] FAILED: price=%.5f mode=%d afterMsc=%I64d dealMsc=%I64d range=%I64dms gridIdx=%d",
               ftypeStr, requestedPrice, trigMode, tpslAfterMsc, tpslDealTimeMsc,
               (tpslDealTimeMsc - tpslAfterMsc), gridIdx);
         }
      }

      RecordFill(ftype, dealOrder, dealTicket,
                 requestedPrice, dealPrice, bid, ask,
                 0, triggerTickMs, nowMs,
                 dealVolume, wasBuy,
                 StringFormat("%s_trigger", ftypeStr));
      g_fills[g_fillCount - 1].dealTimeMsc  = tpslDealTimeMsc;
      g_fills[g_fillCount - 1].lagMs        = tpslLagMs;
      g_fills[g_fillCount - 1].brokerExecMs = tpslBrokerExecMs;
      g_fills[g_fillCount - 1].lagValid     = (triggerTickMs > 0);
      g_fills[g_fillCount - 1].brokerReceiptPrice = requestedPrice;  // TP/SL trigger price IS the receipt price

      // Drift lag for server-side triggers = broker exec time (trigger to deal).
      // The time window [trigger, deal] is the ONLY valid window.
      // Price movement during that window is volatility, not broker manipulation.
      // The lag itself IS the broker-dependent metric.
      g_fills[g_fillCount - 1].driftLagMs = (triggerTickMs > 0) ? MathMax(tpslBrokerExecMs, 0.0) : -1;

      // Cross-validate TP/SL fill price against tick at execution time
      double tpslTickBid = 0, tpslTickAsk = 0;
      if(GetTickAtTime(tpslDealBootMs, tpslTickBid, tpslTickAsk))
      {
         if(isTP)
         {
            // TP = limit-like: fill should be AT the TP price or better
            // Use actual market price at deal time for fair trigger/market classification
            double expectedTP = wasBuy ? tpslTickBid : tpslTickAsk;
            g_fills[g_fillCount - 1].tickPriceAtDeal  = expectedTP;
            // Cross-validation: actual price difference for verification (separate from drift reporting)
            double tpVerifyDelta = wasBuy ? (dealPrice - requestedPrice) : (requestedPrice - dealPrice);
            g_fills[g_fillCount - 1].priceVerifyDelta = tpVerifyDelta;
         }
         else
         {
            // SL = stop-like: triggers at market. Deal price should match bid/ask at execution time
            double expectedSL = wasBuy ? tpslTickBid : tpslTickAsk;
            double slDelta = (dealPrice - expectedSL) / g_point;
            g_fills[g_fillCount - 1].tickPriceAtDeal  = expectedSL;
            g_fills[g_fillCount - 1].priceVerifyDelta = slDelta;

            if(MathAbs(slDelta) > 1.0)
               PrintFormat("SL VERIFY: deal=%.5f tick_%s=%.5f delta=%.1f pts broker_exec=%.0fms",
                  dealPrice, wasBuy ? "bid" : "ask", expectedSL, slDelta, tpslBrokerExecMs);
         }
      }

      LogEvidence(g_cycleNum, ftypeStr, ftypeStr, dealTicket,
                  requestedPrice, dealPrice, bid, ask,
                  slipPts, tpslLagMs, tpslBrokerExecMs, dealVolume,
                  StringFormat("profit=%.2f DEAL_TIME_MSC=%I64d trigger_tick=%I64u",
                     dealProfit, tpslDealTimeMsc, triggerTickMs));
      LogCalibrationSnapshot("TPSL", g_cycleNum);

      g_lastFillMs = nowMs;
      return;
   }

   //=== BATCH CLOSE FILLS ===
   if((g_state == STATE_GRID_ASYNC_WAIT || g_state == STATE_GRID_VERIFY) && dealEntry == DEAL_ENTRY_OUT)
   {
      g_closeFillsReceived++;

      // Match to close request
      for(int i = 0; i < g_closeReqCount; i++)
      {
         if(!g_closeReqs[i].filled)
         {
            // Match by approximate price/direction
            g_closeReqs[i].filled = true;
            g_closeReqs[i].fillTimeMs = nowMs;
            g_closeReqs[i].fillPrice = dealPrice;
            g_closeReqs[i].brokerProfit = dealProfit;

            double pDiff;
            if(g_closeReqs[i].isBuy)
               pDiff = dealPrice - g_closeReqs[i].entryPrice;
            else
               pDiff = g_closeReqs[i].entryPrice - dealPrice;
            double exact = (pDiff / g_tickSize) * g_tickValue * g_closeReqs[i].lots;
            g_closeReqs[i].exactProfit = exact;

            double rErr = dealProfit - exact;
            g_roundingErrorSum += rErr;
            g_roundingErrorAbsSum += MathAbs(rErr);
            if(MathAbs(rErr) > g_roundingErrorMax) g_roundingErrorMax = MathAbs(rErr);
            g_roundingErrorCount++;
            g_brokerProfitSum += dealProfit;
            g_exactProfitSum += exact;

            bool straggler = g_asyncCloseComplete || g_closeReqs[i].isSyncClose;

            double closeLagMs = 0;
            double brokerExecMs = 0;

            // Broker close lag uses DEAL_TIME_MSC (broker's recorded close timestamp)
            // Formula (same for async and sync):
            //   send_epoch     = g_epochMsOffset + send_tickcount
            //   broker_receive = send_epoch + CS_lag (one leg)
            //   broker_exec    = DEAL_TIME_MSC - broker_receive
            //                  = DEAL_TIME_MSC - send_epoch - CS_lag
            // Async: send_tickcount = g_closeTriggerMs (batch trigger)
            // Sync:  send_tickcount = g_closeReqs[i].sendTimeMs (individual send)
            long dealTimeMsc = (long)HistoryDealGetInteger(dealTicket, DEAL_TIME_MSC);

            // Track earliest broker close timestamp in this batch
            // (regardless of straggler classification — first DEAL_TIME_MSC = broker's first response)
            if(dealTimeMsc > 0 &&
               (g_posCloseEarliestMsc == 0 || dealTimeMsc < g_posCloseEarliestMsc))
               g_posCloseEarliestMsc = dealTimeMsc;
            // Capture boot time of first close fill callback (for batch round-trip)
            if(g_posCloseFirstFillBootMs == 0)
               g_posCloseFirstFillBootMs = nowMs;

            ulong sendTickCount = straggler ? g_closeReqs[i].sendTimeMs : g_closeTriggerMs;
            long sendEpoch = (long)(g_epochMsOffset + sendTickCount);
            long brokerReceiveEpoch = sendEpoch + (long)g_clientServerLagMs;

            closeLagMs = (double)(dealTimeMsc - sendEpoch);      // EA send → broker close
            if(closeLagMs < 0) closeLagMs = 0;
            brokerExecMs = (double)(dealTimeMsc - brokerReceiveEpoch); // broker receive → broker close
            if(brokerExecMs < 0) brokerExecMs = 0;

            // Execution drift: broker receipt price (market price when broker received close instruction)
            // For async: instruction sent at g_closeTriggerMs, arrives at broker CS_lag later
            // For sync/straggler: instruction sent at individual sendTimeMs, arrives CS_lag later
            ulong closeRefMs = straggler ? g_closeReqs[i].sendTimeMs : g_closeTriggerMs;
            ulong rcptBootMs = closeRefMs + g_clientServerLagMs;
            double rcptBid = 0, rcptAsk = 0;
            double brokerReceiptPrice = g_closeReqs[i].sendPrice; // Fallback: client send price
            if(GetTickAtTime(rcptBootMs, rcptBid, rcptAsk))
            {
               if(g_closeReqs[i].isBuy && rcptBid > 0)
                  brokerReceiptPrice = rcptBid;   // Closing buy sells at bid
               else if(!g_closeReqs[i].isBuy && rcptAsk > 0)
                  brokerReceiptPrice = rcptAsk;   // Closing sell buys at ask
            }

            double slipPts;
            if(g_closeReqs[i].isBuy)
               slipPts = dealPrice - brokerReceiptPrice;   // Closing buy: higher deal = favorable
            else
               slipPts = brokerReceiptPrice - dealPrice;   // Closing sell: lower deal = favorable

            RecordFill(straggler ? FILL_SYNC_CLOSE : FILL_ASYNC_CLOSE, dealOrder, dealTicket,
                       brokerReceiptPrice, dealPrice, bid, ask,
                       closeRefMs, closeRefMs, nowMs,
                       g_closeReqs[i].lots, g_closeReqs[i].isBuy,
                       StringFormat("batch_close cycle=%d%s send=%.5f rcpt=%.5f", g_cycleNum, straggler ? " STRAGGLER" : "", g_closeReqs[i].sendPrice, brokerReceiptPrice));
            // Override the lag/brokerExec computed by RecordFill with our accurate values
            g_fills[g_fillCount - 1].lagMs              = closeLagMs;
            g_fills[g_fillCount - 1].brokerExecMs        = brokerExecMs;
            g_fills[g_fillCount - 1].isStraggler          = straggler;
            g_fills[g_fillCount - 1].brokerReceiptPrice   = brokerReceiptPrice;
            g_fills[g_fillCount - 1].clientSendPrice      = g_closeReqs[i].sendPrice;

            // Drift lag: time for market to reach deal price from broker receipt
            // Closing buy sells at bid (adverse = lower bid), closing sell buys at ask (adverse = higher ask)
            {
               double driftLag = 0;
               if(MathAbs(dealPrice - brokerReceiptPrice) > 0.5 * g_point)
               {
                  int driftMode;
                  if(g_closeReqs[i].isBuy)
                     driftMode = (dealPrice < brokerReceiptPrice) ? 0 : 1;  // bid <= deal (adverse) or bid >= deal
                  else
                     driftMode = (dealPrice > brokerReceiptPrice) ? 2 : 3;  // ask >= deal (adverse) or ask <= deal
                  driftLag = FindDriftLagMs(dealPrice, driftMode, rcptBootMs);
               }
               g_fills[g_fillCount - 1].driftLagMs = driftLag;
            }

            // Accumulate for cycle median — separate async vs sync
            if(brokerExecMs >= 0)
            {
               if(!straggler)
               {
                  ArrayResize(g_closeBrokerExecLags, g_closeBrokerExecCount + 1);
                  g_closeBrokerExecLags[g_closeBrokerExecCount++] = brokerExecMs;
               }
               else
               {
                  ArrayResize(g_closeSyncExecLags, g_closeSyncExecCount + 1);
                  g_closeSyncExecLags[g_closeSyncExecCount++] = brokerExecMs;
               }
            }

            // Track profit vs loss close exec times (B-book detection)
            bool closeInProfit = (dealProfit > 0);
            if(straggler)
            {
               if(closeInProfit)
               {
                  ArrayResize(g_stragProfitLags, g_stragProfitCount + 1);
                  g_stragProfitLags[g_stragProfitCount++] = brokerExecMs;
               }
               else
               {
                  ArrayResize(g_stragLossLags, g_stragLossCount + 1);
                  g_stragLossLags[g_stragLossCount++] = brokerExecMs;
               }
            }
            else
            {
               if(closeInProfit)
               {
                  ArrayResize(g_closeProfitLags, g_closeProfitCount + 1);
                  g_closeProfitLags[g_closeProfitCount++] = brokerExecMs;
               }
               else
               {
                  ArrayResize(g_closeLossLags, g_closeLossCount + 1);
                  g_closeLossLags[g_closeLossCount++] = brokerExecMs;
               }
            }

            LogEvidence(g_cycleNum, "CLOSE",
                        straggler ? "BATCH_CLOSE_STRAGGLER" : "BATCH_CLOSE", dealTicket,
                        brokerReceiptPrice, dealPrice, bid, ask,
                        slipPts, closeLagMs, brokerExecMs, g_closeReqs[i].lots,
                        StringFormat("profit=%.2f exact=%.2f %s send=%.5f rcpt=%.5f",
                           dealProfit, exact, closeInProfit ? "IN_PROFIT" : "IN_LOSS",
                           g_closeReqs[i].sendPrice, brokerReceiptPrice));

            // Calibration: snapshot account state after each close fill
            LogCalibrationSnapshot("CLOSE", g_cycleNum);

            // Timestamp verification: deal price vs tick at broker's claimed execution time (DEAL_TIME_MSC)
            // Validates broker doesn't fake timestamps — separate from execution drift measurement
            ulong dealBootMs = (ulong)((long)dealTimeMsc - (long)g_epochMsOffset) + g_clientServerLagMs;
            double tickBid = 0, tickAsk = 0;
            g_fills[g_fillCount - 1].dealTimeMsc = dealTimeMsc;
            if(GetTickAtTime(dealBootMs, tickBid, tickAsk))
            {
               // Buy position closes at bid, sell position closes at ask
               double expectedPrice = g_closeReqs[i].isBuy ? tickBid : tickAsk;
               double priceDelta = (dealPrice - expectedPrice) / g_point;

               g_fills[g_fillCount - 1].tickPriceAtDeal   = expectedPrice;
               g_fills[g_fillCount - 1].priceVerifyDelta  = priceDelta;

               g_closePriceVerifyCount++;
               g_closePriceVerifyAbsSum += MathAbs(priceDelta);
               if(MathAbs(priceDelta) > g_closePriceVerifyMaxAbs)
                  g_closePriceVerifyMaxAbs = MathAbs(priceDelta);
               if(MathAbs(priceDelta) > 0.5)
               {
                  g_closePriceMismatchCount++;
                  PrintFormat("CLOSE VERIFY MISMATCH: deal=%.5f tick_%s=%.5f delta=%.1f pts (DEAL_TIME_MSC=%I64d) %s",
                     dealPrice, g_closeReqs[i].isBuy ? "bid" : "ask", expectedPrice,
                     priceDelta, dealTimeMsc, straggler ? "STRAGGLER" : "ASYNC");
               }
            }

            // Track close fill times for cycle record
            if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
            {
               g_cycles[g_cycleNum - 1].lastCloseFillMs = nowMs;

               // Record majority fill time: when CLOSE_MAJORITY_PCT of expected fills confirmed
               if(g_cycles[g_cycleNum - 1].majorityCloseFillMs == 0 &&
                  g_closeFillsExpected > 0 &&
                  g_closeFillsReceived >= (int)MathCeil(CLOSE_MAJORITY_PCT * g_closeFillsExpected))
               {
                  g_cycles[g_cycleNum - 1].majorityCloseFillMs = nowMs;
               }
            }

            break;
         }
      }
      return;
   }
}


//+------------------------------------------------------------------+
//| Log tick to CSV                                                    |
//+------------------------------------------------------------------+
void LogTick(double bid, double ask)
{
   if(g_tickCsvHandle == INVALID_HANDLE) return;
   ulong nowMs = GetTickCount64();
   ulong epochMs = g_epochMsOffset + nowMs;
   double spread = (ask - bid) / g_point;
   FileWriteString(g_tickCsvHandle, StringFormat("%I64u,%I64u,%.5f,%.5f,%.1f\n",
                   nowMs, epochMs, bid, ask, spread));
}


//+------------------------------------------------------------------+
//| Log calibration snapshot to CSV (broker.rs ground truth)           |
//| Records MT5's account state at this instant for replay validation. |
//| event: "TICK", "FILL", "CLOSE", "SWAP", "PRE_CLOSE", "POST_CLOSE"|
//+------------------------------------------------------------------+
void LogCalibrationSnapshot(string event, int cycle)
{
   if(g_calibCsvHandle == INVALID_HANDLE) return;

   ulong epochMs = g_epochMsOffset + GetTickCount64();
   double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   // All values from MT5's own calculations (read-only, cannot be faked)
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin      = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double freeMargin  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   // Position counts, lots, and weighted average entry prices from MT5
   int posCount = PositionsTotal();
   double longLots = 0, shortLots = 0, swapAccum = 0;
   double longWeightedSum = 0, shortWeightedSum = 0;
   for(int i = 0; i < posCount; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      double lots  = PositionGetDouble(POSITION_VOLUME);
      double swap  = PositionGetDouble(POSITION_SWAP);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      swapAccum += swap;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         longLots += lots;
         longWeightedSum += entry * lots;
      }
      else
      {
         shortLots += lots;
         shortWeightedSum += entry * lots;
      }
   }

   double longAvgEntry  = (longLots  > 0.0001) ? longWeightedSum  / longLots  : 0.0;
   double shortAvgEntry = (shortLots > 0.0001) ? shortWeightedSum / shortLots : 0.0;

   FileWriteString(g_calibCsvHandle, StringFormat(
      "%I64u,%s,%d,%.5f,%.5f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.2f,%.2f,%.2f,%.5f,%.5f\n",
      epochMs, event, cycle, bid, ask,
      balance, equity, margin, marginLevel, freeMargin,
      posCount, longLots, shortLots, swapAccum, longAvgEntry, shortAvgEntry));
}


//+------------------------------------------------------------------+
//| Log evidence row to CSV                                            |
//+------------------------------------------------------------------+
void LogEvidence(int cycle, string eventType, string orderType,
                 ulong ticket, double reqPrice, double fillPrice,
                 double bid, double ask, double slipPts, double lagMs,
                 double brokerExecMs, double volume, string notes)
{
   if(g_evidenceCsvHandle == INVALID_HANDLE) return;
   ulong nowMs = GetTickCount64();
   ulong epochMs = g_epochMsOffset + nowMs;
   double spread = (ask - bid) / g_point;
   double slipUSD = (MathAbs(slipPts) / g_tickSize) * g_tickValue * volume;

   FileWriteString(g_evidenceCsvHandle, StringFormat(
      "%d,%s,%s,%I64u,%.5f,%.5f,%.5f,%.5f,%.1f,%.2f,%.4f,%.1f,%.1f,%.4f,%I64u,%I64u,%s\n",
      cycle, eventType, orderType, ticket, reqPrice, fillPrice, bid, ask, spread,
      slipPts, slipUSD, lagMs, brokerExecMs, volume, nowMs, epochMs, notes));
}


//+------------------------------------------------------------------+
//| Record fill into g_fills array                                     |
//+------------------------------------------------------------------+
void RecordFill(ENUM_FILL_TYPE type, ulong orderTicket, ulong dealTicket,
                double reqPrice, double fillPrice, double bid, double ask,
                ulong sendMs, ulong triggerMs, ulong fillMs,
                double volume, bool isBuy, string notes)
{
   int idx = g_fillCount;
   ArrayResize(g_fills, idx + 1);

   g_fills[idx].cycleNum       = g_cycleNum;
   g_fills[idx].fillType       = type;
   g_fills[idx].orderTicket    = orderTicket;
   g_fills[idx].dealTicket     = dealTicket;
   g_fills[idx].requestedPrice = reqPrice;
   g_fills[idx].fillPrice      = fillPrice;
   g_fills[idx].bidAtFill      = bid;
   g_fills[idx].askAtFill      = ask;
   g_fills[idx].spreadAtFill   = (ask - bid) / g_point;
   g_fills[idx].sendTimeMs     = sendMs;
   g_fills[idx].triggerTimeMs  = triggerMs;
   g_fills[idx].fillTimeMs     = fillMs;
   g_fills[idx].volume         = volume;
   g_fills[idx].isBuy          = isBuy;
   g_fills[idx].notes          = notes;
   g_fills[idx].driftLagMs     = 0;  // Default: no drift (perfect). Override after call for grid/TP/SL (-1 if unmeasured).

   // Lag
   if(triggerMs > 0 && fillMs > triggerMs)
      g_fills[idx].lagMs = (double)(fillMs - triggerMs);
   else if(sendMs > 0 && fillMs > sendMs)
      g_fills[idx].lagMs = (double)(fillMs - sendMs);
   else
      g_fills[idx].lagMs = 0;

   g_fills[idx].brokerExecMs = g_fills[idx].lagMs - (double)g_clientServerRoundTripMs;
   if(g_fills[idx].brokerExecMs < 0) g_fills[idx].brokerExecMs = 0;
   g_fills[idx].lagValid = true;  // Default: valid (overridden for grid/TP/SL if trigger not found)

   // Execution drift (signed: positive = favorable for client, negative = adverse)
   // reqPrice = broker receipt price:
   //   Pending orders: trigger price (broker's execution obligation)
   //   Market/close orders: market bid/ask at broker receipt time (send + CS_lag)
   //   CS lag excluded — measures only broker-caused price impact
   if(reqPrice > 0)
   {
      if(type == FILL_ASYNC_CLOSE || type == FILL_SYNC_CLOSE || type == FILL_TP || type == FILL_SL)
      {
         // Close: for buy position close (sell deal), higher fill = better
         // For sell position close (buy deal), lower fill = better
         if(isBuy) // was a buy position being closed
            g_fills[idx].slippagePts = fillPrice - reqPrice;
         else
            g_fills[idx].slippagePts = reqPrice - fillPrice;
      }
      else
      {
         // Entry: for buy, lower fill = better; for sell, higher fill = better
         if(isBuy)
            g_fills[idx].slippagePts = -(fillPrice - reqPrice); // negative if filled higher
         else
            g_fills[idx].slippagePts = -(reqPrice - fillPrice); // negative if filled lower
      }
   }
   else
      g_fills[idx].slippagePts = 0;

   g_fills[idx].slippageUSD = (g_fills[idx].slippagePts / g_tickSize) * g_tickValue * volume;

   // Track adverse slippage (total + by order type)
   if(g_fills[idx].slippagePts < 0)
   {
      double absUSD = MathAbs(g_fills[idx].slippageUSD);
      double absPips = MathAbs(g_fills[idx].slippagePts) / g_pipSize;
      g_totalAdverseSlipUSD += absUSD;
      g_totalAdverseSlipPips += absPips;
      g_adverseFillCount++;
      // Split by stop-like vs limit-like
      if(type == FILL_BUYSTOP || type == FILL_SELLSTOP || type == FILL_SL)
      {
         g_stopAdverseSlipUSD += absUSD;
         g_stopAdverseSlipPips += absPips;
         g_stopAdverseFillCount++;
      }
      else if(type == FILL_BUYLIMIT || type == FILL_SELLLIMIT || type == FILL_TP)
      {
         g_limitAdverseSlipUSD += absUSD;
         g_limitAdverseSlipPips += absPips;
         g_limitAdverseFillCount++;
      }
   }

   g_fillCount++;
}


//+------------------------------------------------------------------+
//| CS LATENCY CALIBRATION — via pending order placement               |
//|                                                                     |
//| Timeline:                                                           |
//|   EA sends (sendMs) → [CS one-way] → broker stamps ORDER_TIME_     |
//|   SETUP_MSC → [CS one-way] → EA receives ack (ackMs)               |
//|                                                                     |
//| Broker processing for a far-away pending order ≈ 0ms, so:          |
//|   round_trip = ackMs - sendMs ≈ 2 × CS_one_way                     |
//|   CS_one_way = (epoch + ackMs) - ORDER_TIME_SETUP_MSC (return leg) |
//|                                                                     |
//| This also calibrates the epoch offset to ms precision using the     |
//| broker's MSC stamp (replaces TimeCurrent's 1-second resolution).    |
//+------------------------------------------------------------------+
void DoCsCalibrate()
{
   g_trade.SetAsyncMode(false);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   // Place BuyStop 5000 points above ask — will never trigger
   double farPrice = NormalizeDouble(ask + 5000 * g_point, g_digits);

   // --- Step 1: Place the pending order (sync) and measure round-trip ---
   ulong placeSendMs = GetTickCount64();
   bool placed = g_trade.BuyStop(g_lotSize, farPrice, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "FA_CS_CALIB");
   ulong placeAckMs = GetTickCount64();

   if(!placed)
   {
      PrintFormat("CS CALIBRATE: BuyStop failed (%d %s) — will calibrate from market buy instead",
         g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      g_state = STATE_MARKET_BUY;
      SetPanelLine(1, "Phase 1: Market order test...", clrYellow);
      return;
   }

   ulong orderTicket = g_trade.ResultOrder();
   g_csCalibPlaceRtMs = placeAckMs - placeSendMs;

   // --- Step 2: Get broker's authoritative stamp ---
   long setupMsc = 0;
   if(OrderSelect(orderTicket))
      setupMsc = (long)OrderGetInteger(ORDER_TIME_SETUP_MSC);

   if(setupMsc == 0)
   {
      // Fallback: if broker doesn't provide MSC, check history
      if(HistoryOrderSelect(orderTicket))
         setupMsc = (long)HistoryOrderGetInteger(orderTicket, ORDER_TIME_SETUP_MSC);
   }

   PrintFormat("CS CALIBRATE: BuyStop placed @ %.5f ticket=%d RT=%dms SETUP_MSC=%I64d",
      farPrice, (int)orderTicket, (int)g_csCalibPlaceRtMs, setupMsc);

   // --- Step 3: Calibrate epoch offset from broker's MSC stamp ---
   // Broker processing ≈ 0 for far-away pending order, so:
   //   ORDER_TIME_SETUP_MSC ≈ send_epoch + CS_one_way ≈ send_epoch + round_trip/2
   //   send_epoch = ORDER_TIME_SETUP_MSC - round_trip/2
   //   g_epochMsOffset = send_epoch - placeSendMs
   if(setupMsc > 0)
   {
      ulong oldOffset = g_epochMsOffset;
      g_epochMsOffset = (ulong)(setupMsc - (long)(g_csCalibPlaceRtMs / 2) - (long)placeSendMs);

      // CS one-way = return leg = (epoch + ackMs) - ORDER_TIME_SETUP_MSC
      long eaAckEpoch = (long)(g_epochMsOffset + placeAckMs);
      g_clientServerLagMs = (ulong)(eaAckEpoch - setupMsc);
      g_clientServerRoundTripMs = g_clientServerLagMs * 2;

      PrintFormat("CS CALIBRATE: epoch %I64u → %I64u (delta=%dms)",
         oldOffset, g_epochMsOffset, (int)((long)g_epochMsOffset - (long)oldOffset));
      PrintFormat("CS CALIBRATE: CS_one_way=%dms (return leg: eaAckEpoch=%I64d - setupMsc=%I64d)",
         (int)g_clientServerLagMs, eaAckEpoch, setupMsc);
   }
   else
   {
      // No MSC available — fall back to round_trip/2
      g_clientServerRoundTripMs = g_csCalibPlaceRtMs;
      g_clientServerLagMs = g_csCalibPlaceRtMs / 2;
      PrintFormat("CS CALIBRATE: no SETUP_MSC — using RT/2=%dms", (int)g_clientServerLagMs);
   }

   g_csCalibrated = true;

   // --- Step 4: Delete the order (cleanup) ---
   ulong deleteSendMs = GetTickCount64();
   bool deleted = g_trade.OrderDelete(orderTicket);
   ulong deleteAckMs = GetTickCount64();
   g_csCalibDeleteRtMs = deleted ? (deleteAckMs - deleteSendMs) : 0;

   if(!deleted)
      PrintFormat("CS CALIBRATE: OrderDelete failed (%d) — order may still exist", g_trade.ResultRetcode());
   else
      PrintFormat("CS CALIBRATE: OrderDelete RT=%dms", (int)g_csCalibDeleteRtMs);

   g_calibPass++;

   PrintFormat("═══ CS LATENCY CALIBRATED (pass %d): one-way=%dms RT=%dms (place_RT=%dms delete_RT=%dms) ═══",
      g_calibPass, (int)g_clientServerLagMs, (int)g_clientServerRoundTripMs,
      (int)g_csCalibPlaceRtMs, (int)g_csCalibDeleteRtMs);

   if(g_calibPass == 1)
   {
      // Save pass 1 values for averaging later
      g_csPass1EpochOffset  = g_epochMsOffset;
      g_csPass1LagMs        = g_clientServerLagMs;
      g_csPass1RoundTripMs  = g_clientServerRoundTripMs;
      g_csPass1PlaceRtMs    = g_csCalibPlaceRtMs;
      g_csPass1DeleteRtMs   = g_csCalibDeleteRtMs;
   }

   SetPanelLine(1, StringFormat("CS Lag: %dms one-way (pass %d) — Market test %d...",
      (int)g_clientServerLagMs, g_calibPass, g_calibPass), clrYellow);
   g_state = STATE_MARKET_BUY;
}


//+------------------------------------------------------------------+
//| MARKET TEST FUNCTIONS                                              |
//+------------------------------------------------------------------+
void DoMarketBuy()
{
   g_trade.SetAsyncMode(false); // Sync for round-trip measurement
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   g_marketSendPrice = ask;
   g_marketFillReceived = false;
   g_marketSendMs = GetTickCount64();

   // Set state BEFORE sync send — OnTradeTransaction fires during g_trade.Buy()
   g_state = STATE_MARKET_BUY_WAIT;

   if(g_trade.Buy(g_lotSize, Symbol(), ask, 0, 0, "FA_MKT_BUY"))
   {
      g_marketOrderTicket = g_trade.ResultOrder();
      PrintFormat("MARKET BUY sent @ %.5f ticket=%d", ask, (int)g_marketOrderTicket);
   }
   else
   {
      PrintFormat("MARKET BUY FAILED: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      SetPanelLine(2, StringFormat("BUY ERROR: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()), clrRed);
      g_state = STATE_MARKET_BUY;  // Revert to retry on next tick
   }
}

void DoMarketBuySLTP()
{
   // Place SL and TP on the buy position (sync, timed)
   g_trade.SetAsyncMode(false);
   double curBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double curAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double curSpread = curAsk - curBid;
   double dist = curSpread * 3.0;
   {
      int stopsLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
      double minStopDist = stopsLevel * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      if(dist < minStopDist * 1.1) dist = minStopDist * 1.1;
   }

   double slBuy = NormalizeDouble(g_mktBuyEntryPrice - dist, g_digits);
   double tpBuy = NormalizeDouble(g_mktBuyEntryPrice + dist, g_digits);

   // 1. Sync SL placement on buy
   if(PositionSelectByTicket(g_mktBuyPosTicket))
   {
      ulong sendMs = GetTickCount64();
      bool ok = g_trade.PositionModify(g_mktBuyPosTicket, slBuy, 0);
      ulong ackMs = GetTickCount64();
      if(ok)
      {
         long rt = (long)(ackMs - sendMs);
         g_mktSyncSLBuyMs = (double)(rt - (long)g_clientServerRoundTripMs);
         if(g_mktSyncSLBuyMs < 0) g_mktSyncSLBuyMs = 0;
         ArrayResize(g_syncSLPlaceLags, g_syncSLPlaceCount + 1);
         g_syncSLPlaceLags[g_syncSLPlaceCount++] = g_mktSyncSLBuyMs;
         PrintFormat("MKT BUY SL PLACED: exec=%.0fms RT=%ldms sl=%.5f", g_mktSyncSLBuyMs, rt, slBuy);
      }
      else
         PrintFormat("MKT BUY SL FAILED: err=%d", (int)GetLastError());
   }

   // 2. Sync TP placement on buy (keep SL)
   if(PositionSelectByTicket(g_mktBuyPosTicket))
   {
      double keepSL = PositionGetDouble(POSITION_SL);
      ulong sendMs = GetTickCount64();
      bool ok = g_trade.PositionModify(g_mktBuyPosTicket, keepSL, tpBuy);
      ulong ackMs = GetTickCount64();
      if(ok)
      {
         long rt = (long)(ackMs - sendMs);
         g_mktSyncTPBuyMs = (double)(rt - (long)g_clientServerRoundTripMs);
         if(g_mktSyncTPBuyMs < 0) g_mktSyncTPBuyMs = 0;
         ArrayResize(g_syncTPPlaceLags, g_syncTPPlaceCount + 1);
         g_syncTPPlaceLags[g_syncTPPlaceCount++] = g_mktSyncTPBuyMs;
         PrintFormat("MKT BUY TP PLACED: exec=%.0fms RT=%ldms tp=%.5f", g_mktSyncTPBuyMs, rt, tpBuy);
      }
      else
         PrintFormat("MKT BUY TP FAILED: err=%d", (int)GetLastError());
   }

   // Keep SL/TP as protection — they're 3 spreads away, won't trigger before profit detected
   SetPanelLine(1, "Phase 1: Placing SL/TP on sell...", clrYellow);
   g_state = STATE_MARKET_SELL_SLTP;
}

void DoMarketSell()
{
   g_trade.SetAsyncMode(false);
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   g_marketSendPrice = bid;
   g_marketFillReceived = false;
   g_marketSendMs = GetTickCount64();

   // Set state BEFORE sync send — OnTradeTransaction fires during g_trade.Sell()
   g_state = STATE_MARKET_SELL_WAIT;

   if(g_trade.Sell(g_lotSize, Symbol(), bid, 0, 0, "FA_MKT_SELL"))
   {
      g_marketOrderTicket = g_trade.ResultOrder();
      PrintFormat("MARKET SELL sent @ %.5f ticket=%d", bid, (int)g_marketOrderTicket);
   }
   else
   {
      PrintFormat("MARKET SELL FAILED: %d (%s)", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      SetPanelLine(2, StringFormat("SELL ERROR: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()), clrRed);
      g_state = STATE_MARKET_SELL;  // Revert to retry on next tick
   }
}

void DoMarketSellSLTP()
{
   // Place SL and TP on the sell position (sync, timed)
   // At this point BOTH buy and sell are open — margin/leverage already measured in fill handler
   g_trade.SetAsyncMode(false);
   double curBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double curAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double curSpread = curAsk - curBid;
   double dist = curSpread * 3.0;
   {
      int stopsLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
      double minStopDist = stopsLevel * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      if(dist < minStopDist * 1.1) dist = minStopDist * 1.1;
   }

   double slSell = NormalizeDouble(g_mktSellEntryPrice + dist, g_digits);
   double tpSell = NormalizeDouble(g_mktSellEntryPrice - dist, g_digits);

   // 3. Sync SL placement on sell
   if(PositionSelectByTicket(g_mktSellPosTicket))
   {
      ulong sendMs = GetTickCount64();
      bool ok = g_trade.PositionModify(g_mktSellPosTicket, slSell, 0);
      ulong ackMs = GetTickCount64();
      if(ok)
      {
         long rt = (long)(ackMs - sendMs);
         g_mktSyncSLSellMs = (double)(rt - (long)g_clientServerRoundTripMs);
         if(g_mktSyncSLSellMs < 0) g_mktSyncSLSellMs = 0;
         ArrayResize(g_syncSLPlaceLags, g_syncSLPlaceCount + 1);
         g_syncSLPlaceLags[g_syncSLPlaceCount++] = g_mktSyncSLSellMs;
         PrintFormat("MKT SELL SL PLACED: exec=%.0fms RT=%ldms sl=%.5f", g_mktSyncSLSellMs, rt, slSell);
      }
      else
         PrintFormat("MKT SELL SL FAILED: err=%d", (int)GetLastError());
   }

   // 4. Sync TP placement on sell (keep SL)
   if(PositionSelectByTicket(g_mktSellPosTicket))
   {
      double keepSL = PositionGetDouble(POSITION_SL);
      ulong sendMs = GetTickCount64();
      bool ok = g_trade.PositionModify(g_mktSellPosTicket, keepSL, tpSell);
      ulong ackMs = GetTickCount64();
      if(ok)
      {
         long rt = (long)(ackMs - sendMs);
         g_mktSyncTPSellMs = (double)(rt - (long)g_clientServerRoundTripMs);
         if(g_mktSyncTPSellMs < 0) g_mktSyncTPSellMs = 0;
         ArrayResize(g_syncTPPlaceLags, g_syncTPPlaceCount + 1);
         g_syncTPPlaceLags[g_syncTPPlaceCount++] = g_mktSyncTPSellMs;
         PrintFormat("MKT SELL TP PLACED: exec=%.0fms RT=%ldms tp=%.5f", g_mktSyncTPSellMs, rt, tpSell);
      }
      else
         PrintFormat("MKT SELL TP FAILED: err=%d", (int)GetLastError());
   }

   // Keep SL/TP as protection — 3 spreads away, won't trigger before profit detected

   PrintFormat("MARGIN TEST: buy_margin=%.2f both_margin=%.2f equity_both=%.2f lev_buy=%.1f lev_both=%.1f hedging_ratio=%.4f mode=%d",
      g_measuredMarginBuy, g_measuredMarginBoth, g_measuredEquityBoth,
      g_verifiedLeverage, g_verifiedLeverageBoth, g_calculatedHedgingRatio, (int)g_accountMarginMode);

   SetPanelLine(1, "Phase 1: Waiting for profit...", clrYellow);
   g_state = STATE_MARKET_WAIT_PROFIT;
}

void CheckWaitProfit()
{
   // Wait for price to move so one position is in profit
   // Both buy and sell are open with SL/TP as protection (3 spreads)
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   double buyPnL  = (bid - g_mktBuyEntryPrice)  / g_tickSize * g_tickValue * g_lotSize;
   double sellPnL = (g_mktSellEntryPrice - ask)  / g_tickSize * g_tickValue * g_lotSize;

   // Need at least one position meaningfully in profit (> 1 spread worth)
   double spread = ask - bid;
   double minProfit = (spread / g_tickSize) * g_tickValue * g_lotSize * 0.5; // half a spread

   if(buyPnL > minProfit || sellPnL > minProfit)
   {
      PrintFormat("PROFIT DETECTED: buyPnL=%.2f sellPnL=%.2f (threshold=%.2f)", buyPnL, sellPnL, minProfit);

      // Remove SL/TP from both positions before closing
      g_trade.SetAsyncMode(false);
      if(PositionSelectByTicket(g_mktBuyPosTicket))
         g_trade.PositionModify(g_mktBuyPosTicket, 0, 0);
      if(PositionSelectByTicket(g_mktSellPosTicket))
         g_trade.PositionModify(g_mktSellPosTicket, 0, 0);

      SetPanelLine(1, StringFormat("Phase 1: Profit! buyPnL=%.2f sellPnL=%.2f — closing...", buyPnL, sellPnL), clrLime);
      g_state = STATE_MARKET_CLOSE_BUY;
   }
   // else: keep waiting, SL/TP protects against runaway loss
}

void DoMarketCloseBuy()
{
   // Check if position still exists (SL/TP may have triggered during wait)
   if(!PositionSelectByTicket(g_mktBuyPosTicket))
   {
      PrintFormat("Buy position %d already closed (SL/TP triggered) — skipping to sell close", (int)g_mktBuyPosTicket);
      g_state = STATE_MARKET_CLOSE_SELL;
      return;
   }

   // Close buy in total isolation — set state BEFORE call (OnTradeTransaction fires during blocking call)
   g_trade.SetAsyncMode(false);
   g_state = STATE_MARKET_CLOSE_BUY_WAIT;
   g_marketFillReceived = false;

   // Record unrealized PnL before closing
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   g_mktCloseBuyPnL = (bid - g_mktBuyEntryPrice) / g_tickSize * g_tickValue * g_lotSize;
   g_mktCloseBuyInProfit = (g_mktCloseBuyPnL > 0);

   g_marketSendPrice = bid;
   g_mktCloseBuySendMs = GetTickCount64();
   g_marketSendMs = g_mktCloseBuySendMs;

   PrintFormat("MARKET BUY CLOSE: entry=%.5f bid=%.5f unrealizedPnL=%.2f (%s)",
      g_mktBuyEntryPrice, bid, g_mktCloseBuyPnL, g_mktCloseBuyInProfit ? "PROFIT" : "LOSS");

   int retries = 0;
   while(retries < 5)
   {
      if(g_trade.PositionClose(g_mktBuyPosTicket))
      {
         PrintFormat("MARKET BUY CLOSE sent @ %.5f pos=%d%s", bid, (int)g_mktBuyPosTicket, retries > 0 ? StringFormat(" (retry %d)", retries) : "");
         return;
      }
      uint retcode = g_trade.ResultRetcode();
      PrintFormat("MARKET BUY CLOSE attempt %d FAILED: %d — retrying...", retries + 1, retcode);
      if(retcode != 10004 && retcode != 10006 && retcode != 10013 && retcode != 10014 && retcode != 10021)
         break;  // Only retry on requote/reject/price-changed/off-quotes errors
      Sleep(200);
      retries++;
      // Refresh price for next attempt
      bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      g_marketSendPrice = bid;
      g_mktCloseBuySendMs = GetTickCount64();
      g_marketSendMs = g_mktCloseBuySendMs;
   }
   // All retries exhausted — reset state and skip to sell close
   PrintFormat("MARKET BUY CLOSE FAILED after %d attempts — skipping to sell close", retries + 1);
   g_state = STATE_MARKET_CLOSE_SELL;
}

void DoMarketCloseSell()
{
   // Check if position still exists (SL/TP may have triggered during wait)
   if(!PositionSelectByTicket(g_mktSellPosTicket))
   {
      PrintFormat("Sell position %d already closed (SL/TP triggered)", (int)g_mktSellPosTicket);
      if(g_calibPass < 2)
      {
         // Save pass 1 baselines (close sell wasn't measured — keep whatever we have)
         g_pass1SyncOpenBuyMs   = g_mktSyncOpenBuyMs;
         g_pass1SyncOpenSellMs  = g_mktSyncOpenSellMs;
         g_pass1SyncSLBuyMs     = g_mktSyncSLBuyMs;
         g_pass1SyncSLSellMs    = g_mktSyncSLSellMs;
         g_pass1SyncTPBuyMs     = g_mktSyncTPBuyMs;
         g_pass1SyncTPSellMs    = g_mktSyncTPSellMs;
         g_pass1SyncCloseBuyMs  = g_mktSyncCloseBuyMs;
         g_pass1SyncCloseSellMs = g_mktSyncCloseSellMs;
         PrintFormat("═══ CALIBRATION PASS %d COMPLETE (sell SL/TP) — starting pass 2 ═══", g_calibPass);
         g_state = STATE_CS_CALIBRATE;
      }
      else
      {
         // Average baselines even on this edge-case path
         g_mktSyncOpenBuyMs   = (g_pass1SyncOpenBuyMs   + g_mktSyncOpenBuyMs)   / 2;
         g_mktSyncOpenSellMs  = (g_pass1SyncOpenSellMs  + g_mktSyncOpenSellMs)  / 2;
         g_mktSyncSLBuyMs     = (g_pass1SyncSLBuyMs     + g_mktSyncSLBuyMs)     / 2;
         g_mktSyncSLSellMs    = (g_pass1SyncSLSellMs    + g_mktSyncSLSellMs)    / 2;
         g_mktSyncTPBuyMs     = (g_pass1SyncTPBuyMs     + g_mktSyncTPBuyMs)     / 2;
         g_mktSyncTPSellMs    = (g_pass1SyncTPSellMs    + g_mktSyncTPSellMs)    / 2;
         g_mktSyncCloseBuyMs  = (g_pass1SyncCloseBuyMs  + g_mktSyncCloseBuyMs)  / 2;
         g_mktSyncCloseSellMs = (g_pass1SyncCloseSellMs + g_mktSyncCloseSellMs) / 2;
         g_state = STATE_GRID_PLACE;
      }
      return;
   }

   // Close sell in total isolation — set state BEFORE call (OnTradeTransaction fires during blocking call)
   g_trade.SetAsyncMode(false);
   g_state = STATE_MARKET_CLOSE_SELL_WAIT;
   g_marketFillReceived = false;

   // Record unrealized PnL before closing
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   g_mktCloseSellPnL = (g_mktSellEntryPrice - ask) / g_tickSize * g_tickValue * g_lotSize;
   g_mktCloseSellInProfit = (g_mktCloseSellPnL > 0);

   g_marketSendPrice = ask;
   g_mktCloseSellSendMs = GetTickCount64();
   g_marketSendMs = g_mktCloseSellSendMs;

   PrintFormat("MARKET SELL CLOSE: entry=%.5f ask=%.5f unrealizedPnL=%.2f (%s)",
      g_mktSellEntryPrice, ask, g_mktCloseSellPnL, g_mktCloseSellInProfit ? "PROFIT" : "LOSS");

   int retries = 0;
   while(retries < 5)
   {
      if(g_trade.PositionClose(g_mktSellPosTicket))
      {
         PrintFormat("MARKET SELL CLOSE sent @ %.5f pos=%d%s", ask, (int)g_mktSellPosTicket, retries > 0 ? StringFormat(" (retry %d)", retries) : "");
         return;
      }
      uint retcode = g_trade.ResultRetcode();
      PrintFormat("MARKET SELL CLOSE attempt %d FAILED: %d — retrying...", retries + 1, retcode);
      if(retcode != 10004 && retcode != 10006 && retcode != 10013 && retcode != 10014 && retcode != 10021)
         break;  // Only retry on requote/reject/price-changed/off-quotes errors
      Sleep(200);
      retries++;
      // Refresh price for next attempt
      ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      g_marketSendPrice = ask;
      g_mktCloseSellSendMs = GetTickCount64();
      g_marketSendMs = g_mktCloseSellSendMs;
   }
   // All retries exhausted — advance state to avoid hang
   PrintFormat("MARKET SELL CLOSE FAILED after %d attempts — advancing state", retries + 1);
   if(g_calibPass < 2)
   {
      g_pass1SyncOpenBuyMs   = g_mktSyncOpenBuyMs;
      g_pass1SyncOpenSellMs  = g_mktSyncOpenSellMs;
      g_pass1SyncSLBuyMs     = g_mktSyncSLBuyMs;
      g_pass1SyncSLSellMs    = g_mktSyncSLSellMs;
      g_pass1SyncTPBuyMs     = g_mktSyncTPBuyMs;
      g_pass1SyncTPSellMs    = g_mktSyncTPSellMs;
      g_pass1SyncCloseBuyMs  = g_mktSyncCloseBuyMs;
      g_pass1SyncCloseSellMs = g_mktSyncCloseSellMs;
      PrintFormat("═══ CALIBRATION PASS %d COMPLETE (sell close failed) — starting pass 2 ═══", g_calibPass);
      g_state = STATE_CS_CALIBRATE;
   }
   else
   {
      g_mktSyncOpenBuyMs   = (g_pass1SyncOpenBuyMs   + g_mktSyncOpenBuyMs)   / 2;
      g_mktSyncOpenSellMs  = (g_pass1SyncOpenSellMs  + g_mktSyncOpenSellMs)  / 2;
      g_mktSyncSLBuyMs     = (g_pass1SyncSLBuyMs     + g_mktSyncSLBuyMs)     / 2;
      g_mktSyncSLSellMs    = (g_pass1SyncSLSellMs    + g_mktSyncSLSellMs)    / 2;
      g_mktSyncTPBuyMs     = (g_pass1SyncTPBuyMs     + g_mktSyncTPBuyMs)     / 2;
      g_mktSyncTPSellMs    = (g_pass1SyncTPSellMs    + g_mktSyncTPSellMs)    / 2;
      g_mktSyncCloseBuyMs  = (g_pass1SyncCloseBuyMs  + g_mktSyncCloseBuyMs)  / 2;
      g_mktSyncCloseSellMs = (g_pass1SyncCloseSellMs + g_mktSyncCloseSellMs) / 2;
      g_state = STATE_GRID_PLACE;
   }
}


//+------------------------------------------------------------------+
//| GRID PLACEMENT — Mixed order types per plan                        |
//+------------------------------------------------------------------+
void PlaceForensicGrid()
{
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spread = ask - bid;
   double spreadPts = spread / g_point;

   if(spread <= 0 || spreadPts < 1)
   {
      Print("ERROR: Invalid spread — cannot place grid");
      return;
   }

   // Grid parameters: spacing first, then auto-derive max distance
   double startDist   = InpGridStartMult * spread;            // 1 spread default

   double spacing     = (InpGridSpacingPct / 100.0) * spread; // 20% of spread default
   // Minimum spacing: 1 pip (ensures broker accepts order, tight enough for EURUSD)
   double minSpacing = 1.0 * g_pipSize;
   if(spacing < minSpacing) spacing = minSpacing;
   spacing = MathRound(spacing / g_pipSize) * g_pipSize;  // round to whole pips
   spacing = NormalizeDouble(spacing, g_digits);

   // Auto-derive max distance: 40 levels per side (40 stops + 40 limits = 80 fills per cycle)
   int levelsPerSide = GRID_LEVELS_PER_SIDE;
   double maxDist = startDist + (levelsPerSide * spacing);

   // Cap to broker order limit — 4 orders per level (stop+limit above, stop+limit below)
   int totalNeeded = levelsPerSide * 4;
   int availSlots = GetAvailableSlots();
   if(availSlots < totalNeeded)
   {
      levelsPerSide = (availSlots / 4);
      if(levelsPerSide < 1)
      {
         PrintFormat("Grid BLOCKED: only %d broker slots available", availSlots);
         return;
      }
      totalNeeded = levelsPerSide * 4;
      PrintFormat("Grid capped to %d levels/side (%d slots)", levelsPerSide, availSlots);
   }

   // TP/SL distance: 3 spreads, but respect broker's STOPS_LEVEL minimum
   double tpslDist = 3.0 * spread;
   {
      int stopsLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
      double minStopDist = stopsLevel * SymbolInfoDouble(Symbol(), SYMBOL_POINT);
      if(tpslDist < minStopDist * 1.1)
         tpslDist = minStopDist * 1.1;  // 10% margin above broker minimum
   }

   // Record cycle info
   ArrayResize(g_cycles, g_cycleNum);
   int ci = g_cycleNum - 1;
   g_cycles[ci].cycleNum       = g_cycleNum;
   g_cycles[ci].spreadAtPlace  = spreadPts;
   g_cycles[ci].spacingPts     = spacing / g_point;
   g_cycles[ci].levelsPerSide  = levelsPerSide;
   g_cycles[ci].totalPlaced    = 0;
   g_cycles[ci].totalFilled    = 0;
   g_cycles[ci].stopFills      = 0;
   g_cycles[ci].limitFills     = 0;
   g_cycles[ci].tpTriggers     = 0;
   g_cycles[ci].slTriggers     = 0;
   g_cycles[ci].closeFills     = 0;
   g_cycles[ci].asyncFillCount = 0;
   g_cycles[ci].preCloseEquity = 0;
   g_cycles[ci].postCloseBalance = 0;
   g_cycles[ci].financialDelta = 0;
   g_cycles[ci].closeTriggerMs = 0;
   g_cycles[ci].lastCloseFillMs = 0;
   g_cycles[ci].majorityCloseFillMs = 0;
   g_cycles[ci].closeLagMs = 0;
   g_cycles[ci].closeBrokerExecMs = 0;

   // Allocate grid array
   ArrayResize(g_grid, totalNeeded);
   g_gridSize = 0;
   g_gridFillsReceived = 0;
   g_gridFillsExpected = 0;
   g_lastFillMs = 0;
   g_gridEarliestSetupMsc = 0;
   g_gridOrdersConfirmed = 0;
   g_gridFirstOrderAddBootMs = 0;
   g_tpslSyncDone = false;
   g_tpslSyncModified = 0;
   g_tpslAsyncSent = false;
   g_tpslAsyncSendMs = 0;
   g_slAsyncFirstAckMs = 0;
   g_tpAsyncFirstAckMs = 0;
   g_slAsyncCount = 0;
   g_tpAsyncCount = 0;

   // Enable async mode for batch placement — ALL orders placed CLEAN (no TP/SL)
   // TP/SL will be added later via sync OrderModify to measure placement lag
   g_trade.SetAsyncMode(true);
   g_gridPlacedMs = GetTickCount64();

   int sent = 0;

   // === 50/50 MATCHED-PAIR GRID ===
   // At each distance level: one stop + one limit (matched pair)
   // Above price: BuyStop + SellLimit at same price → if price reaches level, both fill, P&L offsets
   // Below price: SellStop + BuyLimit at same price → same offset logic
   // Result: ~equal stop and limit measurements, net P&L approaches zero
   //
   // Grid type rotation for TP/SL — guarantee minimum 3 TP + 3 SL for asymmetry:
   //   Stops:  TP → SL → TP → SL → TP → SL → clean → TP → SL → ...
   //   Limits: TPSL → TPSL → TPSL → clean → TPSL → clean → ...
   //   First 6 stops: 3 with TP, 3 with SL (guaranteed)
   //   First 3 limits: all TPSL (provides 3 TP + 3 SL from limits alone)

   int stopTypeIdx = 0;  // Rotates through TP/SL/TP/SL/.../clean/TP/SL
   int limitTypeIdx = 0; // Rotates through TPSL/.../clean/TPSL

   // === ABOVE PRICE: BuyStop + SellLimit at each level ===
   for(int i = 0; i < levelsPerSide; i++)
   {
      double price = NormalizeDouble(ask + startDist + spacing * i, g_digits);
      ulong placeMs = GetTickCount64();

      // --- BuyStop at this level ---
      {
         int gridType;
         double tp = 0, sl = 0;
         if(stopTypeIdx < 6)
         {
            // First 6 stops: alternate TP/SL (3 of each guaranteed)
            if(stopTypeIdx % 2 == 0) { gridType = GRID_STOP_TP; tp = NormalizeDouble(price + tpslDist, g_digits); }
            else                     { gridType = GRID_STOP_SL; sl = NormalizeDouble(price - tpslDist, g_digits); }
         }
         else
         {
            // Remaining: clean → TP → SL → clean → ...
            int mod = (stopTypeIdx - 6) % 3;
            if(mod == 0)      gridType = GRID_STOP_CLEAN;
            else if(mod == 1) { gridType = GRID_STOP_TP; tp = NormalizeDouble(price + tpslDist, g_digits); }
            else              { gridType = GRID_STOP_SL; sl = NormalizeDouble(price - tpslDist, g_digits); }
         }
         stopTypeIdx++;

         bool ok = g_trade.BuyStop(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
         if(ok)
         {
            int idx = g_gridSize;
            g_grid[idx].ticket       = g_trade.ResultOrder();
            g_grid[idx].price        = price;
            g_grid[idx].isBuy        = true;
            g_grid[idx].gridType     = gridType;
            g_grid[idx].tpPrice      = tp;
            g_grid[idx].slPrice      = sl;
            g_grid[idx].placeTimeMs  = placeMs;
            g_grid[idx].filled       = false;
            g_grid[idx].priceCrossed = false;
            g_grid[idx].triggerTimeMs = 0;
            g_grid[idx].tpslModified = false;
            g_grid[idx].isLimit      = false;
            g_grid[idx].cycleNum     = g_cycleNum;
            g_gridSize++;
            sent++;
         }
         else
         {
            int origRc = (int)g_trade.ResultRetcode();
            bool retryOk = false;
            int retryCnt = 0, lastRc = origRc;
            if(InpRejRetryMax > 0)
            {
               g_trade.SetAsyncMode(false);
               for(int rt = 0; rt < InpRejRetryMax; rt++)
               {
                  Sleep(InpRejRetryDelayMs);
                  retryCnt++;
                  bool rok = g_trade.BuyStop(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
                  lastRc = (int)g_trade.ResultRetcode();
                  if(rok) { ulong vt = g_trade.ResultOrder(); g_trade.OrderDelete(vt); retryOk = true; break; }
               }
               g_trade.SetAsyncMode(true);
            }
            TrackRejection(origRc, "BuyStop", price, bid, ask);
            int ri = g_rejectionCount - 1;
            g_rejections[ri].retryAttempts = retryCnt;
            g_rejections[ri].retrySucceeded = retryOk;
            g_rejections[ri].retryRetcode = lastRc;
            if(retryOk) PrintFormat("RETRY OK: BuyStop at %s — transient (retry #%d)", DoubleToString(price, g_digits), retryCnt);
            else if(retryCnt > 0) PrintFormat("RETRY FAIL: BuyStop at %s — persistent (%d retries, last rc=%d)", DoubleToString(price, g_digits), retryCnt, lastRc);
         }
      }

      // --- SellLimit at same level (matched pair) ---
      {
         int gridType;
         double tp = 0, sl = 0;
         if(limitTypeIdx < 3)
         {
            // First 3 limits: all TPSL (guaranteed TP+SL source)
            gridType = GRID_LIMIT_TPSL;
            tp = NormalizeDouble(price - tpslDist, g_digits);
            sl = NormalizeDouble(price + tpslDist, g_digits);
         }
         else
         {
            int mod = (limitTypeIdx - 3) % 2;
            if(mod == 0) gridType = GRID_LIMIT_CLEAN;
            else         { gridType = GRID_LIMIT_TPSL; tp = NormalizeDouble(price - tpslDist, g_digits); sl = NormalizeDouble(price + tpslDist, g_digits); }
         }
         limitTypeIdx++;

         bool ok = g_trade.SellLimit(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
         if(ok)
         {
            int idx = g_gridSize;
            g_grid[idx].ticket       = g_trade.ResultOrder();
            g_grid[idx].price        = price;
            g_grid[idx].isBuy        = false;
            g_grid[idx].gridType     = gridType;
            g_grid[idx].tpPrice      = tp;
            g_grid[idx].slPrice      = sl;
            g_grid[idx].placeTimeMs  = placeMs;
            g_grid[idx].filled       = false;
            g_grid[idx].priceCrossed = false;
            g_grid[idx].triggerTimeMs = 0;
            g_grid[idx].tpslModified = false;
            g_grid[idx].isLimit      = true;
            g_grid[idx].cycleNum     = g_cycleNum;
            g_gridSize++;
            sent++;
         }
         else
         {
            int origRc = (int)g_trade.ResultRetcode();
            bool retryOk = false;
            int retryCnt = 0, lastRc = origRc;
            if(InpRejRetryMax > 0)
            {
               g_trade.SetAsyncMode(false);
               for(int rt = 0; rt < InpRejRetryMax; rt++)
               {
                  Sleep(InpRejRetryDelayMs);
                  retryCnt++;
                  bool rok = g_trade.SellLimit(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
                  lastRc = (int)g_trade.ResultRetcode();
                  if(rok) { ulong vt = g_trade.ResultOrder(); g_trade.OrderDelete(vt); retryOk = true; break; }
               }
               g_trade.SetAsyncMode(true);
            }
            TrackRejection(origRc, "SellLimit", price, bid, ask);
            int ri = g_rejectionCount - 1;
            g_rejections[ri].retryAttempts = retryCnt;
            g_rejections[ri].retrySucceeded = retryOk;
            g_rejections[ri].retryRetcode = lastRc;
            if(retryOk) PrintFormat("RETRY OK: SellLimit at %s — transient (retry #%d)", DoubleToString(price, g_digits), retryCnt);
            else if(retryCnt > 0) PrintFormat("RETRY FAIL: SellLimit at %s — persistent (%d retries, last rc=%d)", DoubleToString(price, g_digits), retryCnt, lastRc);
         }
      }
   }

   // === BELOW PRICE: SellStop + BuyLimit at each level ===
   for(int i = 0; i < levelsPerSide; i++)
   {
      double price = NormalizeDouble(bid - startDist - spacing * i, g_digits);
      ulong placeMs = GetTickCount64();

      // --- SellStop at this level ---
      {
         int gridType;
         double tp = 0, sl = 0;
         if(stopTypeIdx < 6)
         {
            if(stopTypeIdx % 2 == 0) { gridType = GRID_STOP_TP; tp = NormalizeDouble(price - tpslDist, g_digits); }
            else                     { gridType = GRID_STOP_SL; sl = NormalizeDouble(price + tpslDist, g_digits); }
         }
         else
         {
            int mod = (stopTypeIdx - 6) % 3;
            if(mod == 0)      gridType = GRID_STOP_CLEAN;
            else if(mod == 1) { gridType = GRID_STOP_TP; tp = NormalizeDouble(price - tpslDist, g_digits); }
            else              { gridType = GRID_STOP_SL; sl = NormalizeDouble(price + tpslDist, g_digits); }
         }
         stopTypeIdx++;

         bool ok = g_trade.SellStop(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
         if(ok)
         {
            int idx = g_gridSize;
            g_grid[idx].ticket       = g_trade.ResultOrder();
            g_grid[idx].price        = price;
            g_grid[idx].isBuy        = false;
            g_grid[idx].gridType     = gridType;
            g_grid[idx].tpPrice      = tp;
            g_grid[idx].slPrice      = sl;
            g_grid[idx].placeTimeMs  = placeMs;
            g_grid[idx].filled       = false;
            g_grid[idx].priceCrossed = false;
            g_grid[idx].triggerTimeMs = 0;
            g_grid[idx].tpslModified = false;
            g_grid[idx].isLimit      = false;
            g_grid[idx].cycleNum     = g_cycleNum;
            g_gridSize++;
            sent++;
         }
         else
         {
            int origRc = (int)g_trade.ResultRetcode();
            bool retryOk = false;
            int retryCnt = 0, lastRc = origRc;
            if(InpRejRetryMax > 0)
            {
               g_trade.SetAsyncMode(false);
               for(int rt = 0; rt < InpRejRetryMax; rt++)
               {
                  Sleep(InpRejRetryDelayMs);
                  retryCnt++;
                  bool rok = g_trade.SellStop(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
                  lastRc = (int)g_trade.ResultRetcode();
                  if(rok) { ulong vt = g_trade.ResultOrder(); g_trade.OrderDelete(vt); retryOk = true; break; }
               }
               g_trade.SetAsyncMode(true);
            }
            TrackRejection(origRc, "SellStop", price, bid, ask);
            int ri = g_rejectionCount - 1;
            g_rejections[ri].retryAttempts = retryCnt;
            g_rejections[ri].retrySucceeded = retryOk;
            g_rejections[ri].retryRetcode = lastRc;
            if(retryOk) PrintFormat("RETRY OK: SellStop at %s — transient (retry #%d)", DoubleToString(price, g_digits), retryCnt);
            else if(retryCnt > 0) PrintFormat("RETRY FAIL: SellStop at %s — persistent (%d retries, last rc=%d)", DoubleToString(price, g_digits), retryCnt, lastRc);
         }
      }

      // --- BuyLimit at same level (matched pair) ---
      {
         int gridType;
         double tp = 0, sl = 0;
         if(limitTypeIdx < 3)
         {
            gridType = GRID_LIMIT_TPSL;
            tp = NormalizeDouble(price + tpslDist, g_digits);
            sl = NormalizeDouble(price - tpslDist, g_digits);
         }
         else
         {
            int mod = (limitTypeIdx - 3) % 2;
            if(mod == 0) gridType = GRID_LIMIT_CLEAN;
            else         { gridType = GRID_LIMIT_TPSL; tp = NormalizeDouble(price + tpslDist, g_digits); sl = NormalizeDouble(price - tpslDist, g_digits); }
         }
         limitTypeIdx++;

         bool ok = g_trade.BuyLimit(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
         if(ok)
         {
            int idx = g_gridSize;
            g_grid[idx].ticket       = g_trade.ResultOrder();
            g_grid[idx].price        = price;
            g_grid[idx].isBuy        = true;
            g_grid[idx].gridType     = gridType;
            g_grid[idx].tpPrice      = tp;
            g_grid[idx].slPrice      = sl;
            g_grid[idx].placeTimeMs  = placeMs;
            g_grid[idx].filled       = false;
            g_grid[idx].priceCrossed = false;
            g_grid[idx].triggerTimeMs = 0;
            g_grid[idx].tpslModified = false;
            g_grid[idx].isLimit      = true;
            g_grid[idx].cycleNum     = g_cycleNum;
            g_gridSize++;
            sent++;
         }
         else
         {
            int origRc = (int)g_trade.ResultRetcode();
            bool retryOk = false;
            int retryCnt = 0, lastRc = origRc;
            if(InpRejRetryMax > 0)
            {
               g_trade.SetAsyncMode(false);
               for(int rt = 0; rt < InpRejRetryMax; rt++)
               {
                  Sleep(InpRejRetryDelayMs);
                  retryCnt++;
                  bool rok = g_trade.BuyLimit(g_lotSize, price, Symbol(), 0, 0, ORDER_TIME_GTC, 0, "");
                  lastRc = (int)g_trade.ResultRetcode();
                  if(rok) { ulong vt = g_trade.ResultOrder(); g_trade.OrderDelete(vt); retryOk = true; break; }
               }
               g_trade.SetAsyncMode(true);
            }
            TrackRejection(origRc, "BuyLimit", price, bid, ask);
            int ri = g_rejectionCount - 1;
            g_rejections[ri].retryAttempts = retryCnt;
            g_rejections[ri].retrySucceeded = retryOk;
            g_rejections[ri].retryRetcode = lastRc;
            if(retryOk) PrintFormat("RETRY OK: BuyLimit at %s — transient (retry #%d)", DoubleToString(price, g_digits), retryCnt);
            else if(retryCnt > 0) PrintFormat("RETRY FAIL: BuyLimit at %s — persistent (%d retries, last rc=%d)", DoubleToString(price, g_digits), retryCnt, lastRc);
         }
      }
   }

   g_gridFillsExpected = g_gridSize; // All could potentially fill
   g_cycles[ci].totalPlaced = sent;

   // Record pre-close equity now (before any fills change it)
   g_cycles[ci].preCloseEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   PrintFormat("GRID PLACED: cycle=%d levels=%d/side (50/50 matched pairs) spread=%.1f%s spacing=%.1f%s sent=%d",
               g_cycleNum, levelsPerSide, spreadPts, g_unitLabel,
               spacing / g_point, g_unitLabel, sent);

   // Reset to sync after placement
   g_trade.SetAsyncMode(false);
}


//+------------------------------------------------------------------+
//| PLACE TP/SL ON POSITIONS — sync + async PositionModify             |
//|   Called from STATE_GRID_WAIT on each OnTick.                      |
//|                                                                    |
//|   Phase 1 (SYNC): First filled position with TP/SL —              |
//|     sync PositionModify to add SL, then TP, measure each RT.       |
//|                                                                    |
//|   Phase 2 (ASYNC): After fills stabilize (3s since last fill),     |
//|     batch async PositionModify all remaining positions.             |
//|     Ack timing captured in OnTradeTransaction.                     |
//+------------------------------------------------------------------+
void PlaceTPSLOnPositions()
{
   // Mark clean orders as done (no TP/SL to add)
   for(int i = 0; i < g_gridSize; i++)
   {
      if(g_grid[i].filled && !g_grid[i].tpslModified &&
         g_grid[i].tpPrice == 0 && g_grid[i].slPrice == 0)
         g_grid[i].tpslModified = true;
   }

   // Count unmodified filled positions that need TP/SL
   int pending = 0;
   for(int i = 0; i < g_gridSize; i++)
   {
      if(g_grid[i].filled && !g_grid[i].tpslModified && g_grid[i].positionId > 0 &&
         (g_grid[i].tpPrice > 0 || g_grid[i].slPrice > 0))
         pending++;
   }
   if(pending == 0) return;

   // --- Phase 1: SYNC — first 10 triggered fills get individual SL + TP placement ---
   // Each placement is measured (round_trip - CS_roundtrip = broker exec time)
   if(g_tpslSyncModified < InpSyncTPSLCount)
   {
      g_trade.SetAsyncMode(false);

      for(int i = 0; i < g_gridSize && g_tpslSyncModified < InpSyncTPSLCount; i++)
      {
         if(!g_grid[i].filled) continue;
         if(g_grid[i].tpslModified) continue;
         if(g_grid[i].positionId == 0) continue;
         if(g_grid[i].tpPrice == 0 && g_grid[i].slPrice == 0) continue;
         if(!PositionSelectByTicket(g_grid[i].positionId)) continue;

         // Sync SL placement
         if(g_grid[i].slPrice > 0)
         {
            ulong sendMs = GetTickCount64();
            bool ok = g_trade.PositionModify(g_grid[i].positionId, g_grid[i].slPrice, 0);
            ulong ackMs = GetTickCount64();
            if(ok)
            {
               long roundTrip = (long)(ackMs - sendMs);
               double placeLag = (double)(roundTrip - (long)g_clientServerRoundTripMs);
               if(placeLag < 0) placeLag = 0;
               ArrayResize(g_syncSLPlaceLags, g_syncSLPlaceCount + 1);
               g_syncSLPlaceLags[g_syncSLPlaceCount++] = placeLag;
               PrintFormat("SYNC SL [%d/%d]: pos=%I64u exec=%.0fms RT=%I64dms",
                  g_tpslSyncModified + 1, InpSyncTPSLCount, g_grid[i].positionId, placeLag, roundTrip);
            }
         }

         // Sync TP placement (keep SL just set)
         if(g_grid[i].tpPrice > 0)
         {
            double currentSL = 0;
            if(PositionSelectByTicket(g_grid[i].positionId))
               currentSL = PositionGetDouble(POSITION_SL);

            ulong sendMs = GetTickCount64();
            bool ok = g_trade.PositionModify(g_grid[i].positionId, currentSL, g_grid[i].tpPrice);
            ulong ackMs = GetTickCount64();
            if(ok)
            {
               long roundTrip = (long)(ackMs - sendMs);
               double placeLag = (double)(roundTrip - (long)g_clientServerRoundTripMs);
               if(placeLag < 0) placeLag = 0;
               ArrayResize(g_syncTPPlaceLags, g_syncTPPlaceCount + 1);
               g_syncTPPlaceLags[g_syncTPPlaceCount++] = placeLag;
               PrintFormat("SYNC TP [%d/%d]: pos=%I64u exec=%.0fms RT=%I64dms",
                  g_tpslSyncModified + 1, InpSyncTPSLCount, g_grid[i].positionId, placeLag, roundTrip);
            }
         }

         g_grid[i].tpslModified = true;
         g_tpslSyncModified++;
      }

      // Check if sync phase is complete
      if(g_tpslSyncModified >= InpSyncTPSLCount)
      {
         g_tpslSyncDone = true;
         PrintFormat("SYNC TPSL: %d positions modified — switching to async for remainder",
            g_tpslSyncModified);
      }
      return; // Don't proceed to async in the same tick
   }

   // --- Phase 2: ASYNC BATCH — remaining positions, in batches of 10+ ---
   // Wait until at least 10 unmodified fills accumulate, then fire async batch
   if(pending >= InpSyncTPSLCount || (pending > 0 && g_tpslAsyncSent))
   {
      // Either: 10+ pending (first async batch), or any pending after first batch sent
      g_trade.SetAsyncMode(true);
      g_tpslAsyncSendMs = GetTickCount64();
      int batchSL = 0, batchTP = 0;
      if(!g_tpslAsyncSent)
      {
         // First async batch — reset ack trackers
         g_slAsyncCount = 0;
         g_tpAsyncCount = 0;
         g_slAsyncFirstAckMs = 0;
         g_tpAsyncFirstAckMs = 0;
      }

      for(int i = 0; i < g_gridSize; i++)
      {
         if(!g_grid[i].filled || g_grid[i].tpslModified) continue;
         if(g_grid[i].tpPrice == 0 && g_grid[i].slPrice == 0)
         { g_grid[i].tpslModified = true; continue; }
         if(g_grid[i].positionId == 0) continue;
         if(!PositionSelectByTicket(g_grid[i].positionId)) continue;

         // Async SL placement
         if(g_grid[i].slPrice > 0)
         {
            if(g_trade.PositionModify(g_grid[i].positionId, g_grid[i].slPrice, 0))
            { g_slAsyncCount++; batchSL++; }
         }

         // Async TP placement (keep SL)
         if(g_grid[i].tpPrice > 0)
         {
            if(g_trade.PositionModify(g_grid[i].positionId, g_grid[i].slPrice, g_grid[i].tpPrice))
            { g_tpAsyncCount++; batchTP++; }
         }

         g_grid[i].tpslModified = true;
      }

      g_trade.SetAsyncMode(false);
      g_tpslAsyncSent = true;

      PrintFormat("ASYNC TPSL BATCH: sent %d SL + %d TP modifications (total async: %d SL + %d TP)",
         batchSL, batchTP, g_slAsyncCount, g_tpAsyncCount);
   }
}


//+------------------------------------------------------------------+
//| CHECK GRID TRIGGERS — called from OnTick                           |
//+------------------------------------------------------------------+
void CheckGridTriggers(double bid, double ask)
{
   ulong nowMs = GetTickCount64();

   for(int i = 0; i < g_gridSize; i++)
   {
      if(g_grid[i].filled || g_grid[i].priceCrossed) continue;

      double trigPrice = g_grid[i].price;

      if(g_grid[i].isLimit)
      {
         // Limit orders: Buy limit fills when ask <= price, Sell limit fills when bid >= price
         if(g_grid[i].isBuy && ask <= trigPrice)
         {
            g_grid[i].priceCrossed = true;
            g_grid[i].triggerTimeMs = nowMs;
         }
         else if(!g_grid[i].isBuy && bid >= trigPrice)
         {
            g_grid[i].priceCrossed = true;
            g_grid[i].triggerTimeMs = nowMs;
         }
      }
      else
      {
         // Stop orders: Buy stop fills when ask >= price, Sell stop fills when bid <= price
         if(g_grid[i].isBuy && ask >= trigPrice)
         {
            g_grid[i].priceCrossed = true;
            g_grid[i].triggerTimeMs = nowMs;
         }
         else if(!g_grid[i].isBuy && bid <= trigPrice)
         {
            g_grid[i].priceCrossed = true;
            g_grid[i].triggerTimeMs = nowMs;
         }
      }
   }
}


//+------------------------------------------------------------------+
//| PHASE 1: Send async close requests (non-blocking)                  |
//| Returns immediately — fills arrive via OnTradeTransaction           |
//+------------------------------------------------------------------+
void SendAsyncCloses()
{
   // Record pre-close equity
   if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
      g_cycles[g_cycleNum - 1].preCloseEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   g_trade.SetAsyncMode(true);
   g_closeReqCount = 0;
   g_closeFillsReceived = 0;
   g_closeFillsExpected = 0;
   g_asyncCloseComplete = false;
   g_orderDeleteEarliestMsc = 0;
   g_posCloseEarliestMsc = 0;
   g_posCloseFirstFillBootMs = 0;
   g_orderDeleteCount = 0;
   g_posCloseCount = 0;
   g_closeBrokerExecCount = 0;
   ArrayResize(g_closeBrokerExecLags, 0);
   g_closeSyncExecCount = 0;
   ArrayResize(g_closeSyncExecLags, 0);
   g_closeTriggerMs = GetTickCount64();

   if(g_cycleNum > 0 && g_cycleNum <= ArraySize(g_cycles))
      g_cycles[g_cycleNum - 1].closeTriggerMs = g_closeTriggerMs;

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);

   // Phase 1a: Delete remaining pending orders
   g_orderDeleteSendMs = GetTickCount64();
   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
      g_trade.OrderDelete(ticket);
      g_orderDeleteCount++;
   }

   // Phase 1b: Close all our positions (async — returns immediately)
   g_posCloseSendMs = GetTickCount64();
   int totalPos = PositionsTotal();
   ArrayResize(g_closeReqs, totalPos);

   for(int i = totalPos - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

      bool isBuy      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double entryP   = PositionGetDouble(POSITION_PRICE_OPEN);
      double posLots  = PositionGetDouble(POSITION_VOLUME);

      int idx = g_closeReqCount;
      g_closeReqs[idx].posTicket      = ticket;
      g_closeReqs[idx].sendTimeMs     = GetTickCount64();
      g_closeReqs[idx].sendPrice      = isBuy ? bid : ask;
      g_closeReqs[idx].entryPrice     = entryP;
      g_closeReqs[idx].lots           = posLots;
      g_closeReqs[idx].isBuy          = isBuy;
      g_closeReqs[idx].filled         = false;
      g_closeReqs[idx].isSyncClose    = false;   // Phase 1 = async
      g_closeReqs[idx].syncRoundTripMs = 0;
      g_closeReqCount++;

      g_trade.PositionClose(ticket);
   }

   g_closeFillsExpected = g_closeReqCount;
   g_closeEaSendDurationMs = GetTickCount64() - g_closeTriggerMs;

   PrintFormat("ASYNC CLOSE: sent %d deletes + %d closes in %dms (EA send time) — waiting for fills...",
      g_orderDeleteCount, g_closeReqCount, (int)g_closeEaSendDurationMs);
}

//+------------------------------------------------------------------+
//| PHASE 2: Sync sweep — close anything still remaining               |
//| Called after async window expires (5s or all fills received)        |
//+------------------------------------------------------------------+
void DoSyncCloseSweep()
{
   g_trade.SetAsyncMode(false);

   // Delete any remaining pending orders
   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
      g_trade.OrderDelete(ticket);
   }

   // Close any remaining positions (sync, individually timed)
   int totalPos = PositionsTotal();
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   for(int i = totalPos - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

      // Update close request with sync send time and mark as sync close
      int reqIdx = -1;
      for(int r = 0; r < g_closeReqCount; r++)
      {
         if(g_closeReqs[r].posTicket == ticket && !g_closeReqs[r].filled)
         {
            g_closeReqs[r].sendTimeMs = GetTickCount64();
            g_closeReqs[r].sendPrice  = g_closeReqs[r].isBuy ? bid : ask;
            g_closeReqs[r].isSyncClose = true;
            reqIdx = r;
            break;
         }
      }

      ulong beforeMs = GetTickCount64();
      g_trade.PositionClose(ticket);
      ulong afterMs = GetTickCount64();

      // Capture sync round-trip directly (PositionClose blocks until broker confirms)
      if(reqIdx >= 0)
         g_closeReqs[reqIdx].syncRoundTripMs = afterMs - beforeMs;
   }

   PrintFormat("SYNC SWEEP: cycle=%d async=%d/%d remaining=%d",
               g_cycleNum, g_closeFillsReceived, g_closeFillsExpected, totalPos);
}


//+------------------------------------------------------------------+
//| VERIFY ALL CLOSED                                                  |
//+------------------------------------------------------------------+
bool VerifyAllClosed()
{
   // Count our remaining positions and orders
   int ourPos = 0, ourOrd = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      ourPos++;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
      ourOrd++;
   }

   if(ourPos > 0 || ourOrd > 0)
   {
      // Still have stragglers — retry close
      static int retryCount = 0;
      retryCount++;
      if(retryCount > 10) // Safety valve
      {
         PrintFormat("WARNING: %d positions + %d orders stuck after 10 retries", ourPos, ourOrd);
         retryCount = 0;
         return true; // Force continue
      }

      // Try closing again — sync, individually timed
      g_trade.SetAsyncMode(false);
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0) continue;
         if(OrderGetInteger(ORDER_MAGIC) != (long)InpMagicNumber) continue;
         if(OrderGetString(ORDER_SYMBOL) != Symbol()) continue;
         g_trade.OrderDelete(ticket);
      }
      double retryBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double retryAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;

         // Update close request with fresh sync send time
         int reqIdx = -1;
         for(int r = 0; r < g_closeReqCount; r++)
         {
            if(g_closeReqs[r].posTicket == ticket && !g_closeReqs[r].filled)
            {
               g_closeReqs[r].sendTimeMs = GetTickCount64();
               g_closeReqs[r].sendPrice  = g_closeReqs[r].isBuy ? retryBid : retryAsk;
               g_closeReqs[r].isSyncClose = true;
               reqIdx = r;
               break;
            }
         }

         ulong beforeMs = GetTickCount64();
         g_trade.PositionClose(ticket);
         ulong afterMs = GetTickCount64();

         if(reqIdx >= 0)
            g_closeReqs[reqIdx].syncRoundTripMs = afterMs - beforeMs;
      }
      return false;
   }

   return true;
}


//+------------------------------------------------------------------+
//| HELPER: Find tick in circular buffer closest to target time        |
//|   targetMs = GetTickCount64() boot-relative timestamp              |
//|   Returns true if found, fills bid/ask with closest tick values    |
//+------------------------------------------------------------------+
bool GetTickAtTime(ulong targetMs, double &outBid, double &outAsk)
{
   if(g_tickBufCount == 0) return false;

   int bestIdx = -1;
   ulong bestDiff = ULONG_MAX;

   for(int n = 0; n < g_tickBufCount; n++)
   {
      int idx = (g_tickBufHead - 1 - n + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      ulong tickMs = g_tickBuf[idx].timeMs;
      ulong diff = (tickMs > targetMs) ? (tickMs - targetMs) : (targetMs - tickMs);
      if(diff < bestDiff)
      {
         bestDiff = diff;
         bestIdx = idx;
      }
      // Once we've passed the target going backwards, no need to continue
      if(tickMs < targetMs && diff > bestDiff) break;
   }

   if(bestIdx >= 0)
   {
      outBid = g_tickBuf[bestIdx].bid;
      outAsk = g_tickBuf[bestIdx].ask;
      return true;
   }
   return false;
}


//+------------------------------------------------------------------+
//| HELPER: Find drift lag — time for market to reach deal price       |
//|   Walks ticks FORWARD from receiptBootMs to find when market       |
//|   first reached dealPrice. Returns time delta in ms.               |
//|   driftMode: 0=bid<=dealPrice (sell/close-buy adverse)             |
//|              1=bid>=dealPrice (sell/close-buy favorable)            |
//|              2=ask>=dealPrice (buy/close-sell adverse)              |
//|              3=ask<=dealPrice (buy/close-sell favorable)            |
//|   Returns 0 if dealPrice already at receipt level (no drift)       |
//|   Returns -1 if deal price never reached in buffer (can't measure) |
//+------------------------------------------------------------------+
double FindDriftLagMs(double dealPrice, int driftMode, ulong receiptBootMs)
{
   if(g_tickBufCount == 0) return -1;

   // First, find the starting index (tick nearest to receiptBootMs)
   int startN = -1;
   ulong bestDiff = ULONG_MAX;
   for(int n = 0; n < g_tickBufCount; n++)
   {
      int idx = (g_tickBufHead - 1 - n + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      ulong tickMs = g_tickBuf[idx].timeMs;
      ulong diff = (tickMs > receiptBootMs) ? (tickMs - receiptBootMs) : (receiptBootMs - tickMs);
      if(diff < bestDiff)
      {
         bestDiff = diff;
         startN = n;
      }
      if(tickMs < receiptBootMs && diff > bestDiff) break;
   }
   if(startN < 0) return -1;

   // Check if the receipt tick itself already satisfies the condition
   // (meaning drift_lag = 0 — deal price equals receipt price)
   {
      int idx = (g_tickBufHead - 1 - startN + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      bool atReceipt = false;
      switch(driftMode)
      {
         case 0: atReceipt = (g_tickBuf[idx].bid <= dealPrice); break;
         case 1: atReceipt = (g_tickBuf[idx].bid >= dealPrice); break;
         case 2: atReceipt = (g_tickBuf[idx].ask >= dealPrice); break;
         case 3: atReceipt = (g_tickBuf[idx].ask <= dealPrice); break;
      }
      if(atReceipt) return 0;  // Deal price was at receipt level — zero drift lag
   }

   // Walk FORWARD from receipt time (backwards in our ring buffer indexing)
   // to find when market first reached the deal price
   for(int n = startN - 1; n >= 0; n--)
   {
      int idx = (g_tickBufHead - 1 - n + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      ulong tickMs = g_tickBuf[idx].timeMs;
      if(tickMs < receiptBootMs) continue;  // Skip ticks before receipt

      bool reached = false;
      switch(driftMode)
      {
         case 0: reached = (g_tickBuf[idx].bid <= dealPrice); break;
         case 1: reached = (g_tickBuf[idx].bid >= dealPrice); break;
         case 2: reached = (g_tickBuf[idx].ask >= dealPrice); break;
         case 3: reached = (g_tickBuf[idx].ask <= dealPrice); break;
      }
      if(reached)
         return (double)(tickMs - receiptBootMs);
   }

   return -1;  // Deal price level never reached in buffer
}


//+------------------------------------------------------------------+
//| HELPER: Find first tick where a price condition is met             |
//|   Scans backwards from beforeMs, finds the FIRST tick where the    |
//|   condition became true (last tick before it wasn't true + 1).     |
//|   mode: 0=bid<=price, 1=bid>=price, 2=ask<=price, 3=ask>=price    |
//|   Returns boot-relative timestamp of the triggering tick, or 0.    |
//+------------------------------------------------------------------+
ulong FindTriggerTick(double triggerPrice, int mode, ulong beforeMs, ulong afterMs = 0)
{
   if(g_tickBufCount == 0) return 0;

   // Walk backwards from most recent tick, find the first one satisfying the condition
   // Then continue backwards to find where it FIRST became true
   // afterMs = lower bound (e.g. parent order fill time for TP/SL searches)
   ulong firstTriggerMs = 0;
   bool foundTrigger = false;

   for(int n = 0; n < g_tickBufCount; n++)
   {
      int idx = (g_tickBufHead - 1 - n + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      ulong tickMs = g_tickBuf[idx].timeMs;

      // Only consider ticks before the deal time
      if(tickMs > beforeMs) continue;

      // Stop searching before the lower bound (TP/SL not active before parent filled)
      if(afterMs > 0 && tickMs < afterMs) break;

      bool triggered = false;
      switch(mode)
      {
         case 0: triggered = (g_tickBuf[idx].bid <= triggerPrice); break; // SL on buy (bid <= SL)
         case 1: triggered = (g_tickBuf[idx].bid >= triggerPrice); break; // TP on buy (bid >= TP)
         case 2: triggered = (g_tickBuf[idx].ask <= triggerPrice); break; // TP on sell (ask <= TP)
         case 3: triggered = (g_tickBuf[idx].ask >= triggerPrice); break; // SL on sell (ask >= SL)
      }

      if(triggered)
      {
         firstTriggerMs = tickMs;
         foundTrigger = true;
         // Keep going backwards to find the very first tick that triggered
      }
      else if(foundTrigger)
      {
         // Previous tick didn't trigger — so the one after this was the first
         break;
      }
   }

   return firstTriggerMs;
}


//+------------------------------------------------------------------+
//| HELPER: Find trigger tick using server-side tick history            |
//|   Uses CopyTicksRange for accurate server-time trigger detection    |
//|   Both afterMsc and beforeMsc are server epoch ms (DEAL_TIME_MSC)  |
//|   mode: 0=bid<=price, 1=bid>=price, 2=ask<=price, 3=ask>=price    |
//|   Returns server epoch msc of the FIRST triggering tick, or 0      |
//+------------------------------------------------------------------+
long FindTriggerTickMsc(double triggerPrice, int mode, long afterMsc, long beforeMsc)
{
   if(afterMsc <= 0 || beforeMsc <= 0 || beforeMsc <= afterMsc)
   {
      PrintFormat("FindTriggerTickMsc SKIP: afterMsc=%I64d beforeMsc=%I64d (invalid range)", afterMsc, beforeMsc);
      return 0;
   }

   MqlTick ticks[];
   int count = CopyTicksRange(Symbol(), ticks, COPY_TICKS_ALL, (ulong)afterMsc, (ulong)beforeMsc);
   if(count <= 0)
   {
      PrintFormat("FindTriggerTickMsc EMPTY: mode=%d price=%.5f range=%I64d-%I64d count=%d",
         mode, triggerPrice, afterMsc, beforeMsc, count);
      return 0;
   }

   long firstTriggerMsc = 0;
   bool foundTrigger = false;
   int triggerCount = 0;

   for(int i = count - 1; i >= 0; i--)
   {
      double bid = ticks[i].bid;
      double ask = ticks[i].ask;
      if(bid <= 0 && ask <= 0) continue;  // Skip info-only ticks

      bool triggered = false;
      switch(mode)
      {
         case 0: triggered = (bid > 0 && bid <= triggerPrice); break; // SellStop / SL on buy
         case 1: triggered = (bid > 0 && bid >= triggerPrice); break; // SellLimit / TP on buy
         case 2: triggered = (ask > 0 && ask <= triggerPrice); break; // BuyLimit / TP on sell
         case 3: triggered = (ask > 0 && ask >= triggerPrice); break; // BuyStop / SL on sell
      }

      if(triggered)
      {
         firstTriggerMsc = ticks[i].time_msc;
         foundTrigger = true;
         triggerCount++;
      }
      else if(foundTrigger)
      {
         break;  // Previous tick didn't trigger — found the boundary
      }
   }

   if(!foundTrigger)
   {
      // Log the first and last tick for debugging
      double b0 = ticks[0].bid, a0 = ticks[0].ask;
      double bN = ticks[count-1].bid, aN = ticks[count-1].ask;
      PrintFormat("FindTriggerTickMsc NONE: mode=%d price=%.5f count=%d first_bid=%.5f first_ask=%.5f last_bid=%.5f last_ask=%.5f",
         mode, triggerPrice, count, b0, a0, bN, aN);
   }

   return firstTriggerMsc;
}


//+------------------------------------------------------------------+
//| HELPER: Get available broker order slots                           |
//+------------------------------------------------------------------+
int GetAvailableSlots()
{
   if(g_orderLimit <= 0) return 1000; // No limit
   int used = PositionsTotal() + OrdersTotal();
   return MathMax(0, (int)g_orderLimit - used);
}


//+------------------------------------------------------------------+
//| HELPER: Calculate median from array                                |
//+------------------------------------------------------------------+
double CalcMedianFromArray(double &arr[], int count)
{
   if(count <= 0) return 0;
   if(count == 1) return arr[0];

   // Copy and sort
   double sorted[];
   ArrayResize(sorted, count);
   for(int i = 0; i < count; i++) sorted[i] = arr[i];
   ArraySort(sorted);

   if(count % 2 == 1)
      return sorted[count / 2];
   else
      return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0;
}


//+------------------------------------------------------------------+
//| HELPER: Calculate percentile from array                            |
//+------------------------------------------------------------------+
double CalcPercentile(double &arr[], int count, double pct)
{
   if(count <= 0) return 0;
   if(count == 1) return arr[0];

   double sorted[];
   ArrayResize(sorted, count);
   for(int i = 0; i < count; i++) sorted[i] = arr[i];
   ArraySort(sorted);

   double idx = (pct / 100.0) * (count - 1);
   int lo = (int)MathFloor(idx);
   int hi = (int)MathCeil(idx);
   if(lo == hi || hi >= count) return sorted[lo];

   double frac = idx - lo;
   return sorted[lo] + frac * (sorted[hi] - sorted[lo]);
}


//+------------------------------------------------------------------+
//| HELPER: Fill type name string                                      |
//+------------------------------------------------------------------+
string GetFillTypeName(ENUM_FILL_TYPE t)
{
   switch(t)
   {
      case FILL_MARKET_BUY:  return "Market Buy";
      case FILL_MARKET_SELL: return "Market Sell";
      case FILL_BUYSTOP:     return "Buy Stop";
      case FILL_SELLSTOP:    return "Sell Stop";
      case FILL_BUYLIMIT:    return "Buy Limit";
      case FILL_SELLLIMIT:   return "Sell Limit";
      case FILL_TP:          return "Take Profit";
      case FILL_SL:          return "Stop Loss";
      case FILL_ASYNC_CLOSE: return "Async Close";
      case FILL_SYNC_CLOSE:  return "Sync Close";
      default:               return "Unknown";
   }
}


//+------------------------------------------------------------------+
//| HELPER: Format milliseconds for display                            |
//+------------------------------------------------------------------+
string FormatMs(double ms, bool hasData)
{
   if(ms < 0) return "N/A";
   if(ms < 0.5 && hasData) return "<1ms";  // Sub-millisecond: trigger found but same ms as deal
   if(ms < 1000) return StringFormat("%.0fms", ms);
   return StringFormat("%.1fs", ms / 1000.0);
}

//+------------------------------------------------------------------+
//| Format dollar amount with commas: $1,234,567.89 or $1,234,567     |
//+------------------------------------------------------------------+
string FormatMoney(double val)
{
   double absVal = MathAbs(val);

   // Use more decimals for tiny non-zero values to avoid misleading "$ 0.00"
   string raw;
   if(absVal > 0 && absVal < 0.01)
      raw = StringFormat("%.4f", absVal);
   else
      raw = StringFormat("%.2f", absVal);

   // Split at decimal
   int dotPos = StringFind(raw, ".");
   string intPart = (dotPos >= 0) ? StringSubstr(raw, 0, dotPos) : raw;
   string decPart = (dotPos >= 0) ? StringSubstr(raw, dotPos) : ".00";

   // Insert commas from right
   string result = "";
   int len = StringLen(intPart);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0)
         result += ",";
      result += StringSubstr(intPart, i, 1);
   }
   string sign = (val < 0) ? "-" : "";
   return sign + "$ " + result + decPart;
}


//+------------------------------------------------------------------+
//| PANEL: Update chart display                                        |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   // Calculate running stats
   double medFillLag = 0, medCloseLag = 0;
   double stopLag = 0, limitLag = 0;
   double totalStopHoldMs = 0, totalLimitHoldMs = 0;

   // Quick median estimates from fills
   double fillLags[], closeLags[], stopLags[], limitLags[];
   double asyncCLags[], syncCLags[];
   int nFill = 0, nClose = 0, nStop = 0, nLimit = 0;
   int nAsyncC = 0, nSyncC = 0;
   ArrayResize(fillLags, g_fillCount);
   ArrayResize(closeLags, g_fillCount);
   ArrayResize(stopLags, g_fillCount);
   ArrayResize(limitLags, g_fillCount);
   ArrayResize(asyncCLags, g_fillCount);
   ArrayResize(syncCLags, g_fillCount);

   for(int i = 0; i < g_fillCount; i++)
   {
      if(g_fills[i].fillType == FILL_BUYSTOP || g_fills[i].fillType == FILL_SELLSTOP ||
         g_fills[i].fillType == FILL_BUYLIMIT || g_fills[i].fillType == FILL_SELLLIMIT)
      {
         fillLags[nFill++] = g_fills[i].brokerExecMs;
      }
      if(g_fills[i].fillType == FILL_ASYNC_CLOSE || g_fills[i].fillType == FILL_SYNC_CLOSE)
      {
         closeLags[nClose++] = g_fills[i].brokerExecMs;
         if(g_fills[i].fillType == FILL_SYNC_CLOSE)
            syncCLags[nSyncC++] = g_fills[i].brokerExecMs;
         else
            asyncCLags[nAsyncC++] = g_fills[i].brokerExecMs;
      }
      if(g_fills[i].fillType == FILL_BUYSTOP || g_fills[i].fillType == FILL_SELLSTOP)
      {
         stopLags[nStop++] = g_fills[i].brokerExecMs;
         totalStopHoldMs += g_fills[i].brokerExecMs;
      }
      if(g_fills[i].fillType == FILL_BUYLIMIT || g_fills[i].fillType == FILL_SELLLIMIT)
      {
         limitLags[nLimit++] = g_fills[i].brokerExecMs;
         totalLimitHoldMs += g_fills[i].brokerExecMs;
      }
   }

   medFillLag  = CalcMedianFromArray(fillLags, nFill);
   medCloseLag = CalcMedianFromArray(closeLags, nClose);
   stopLag     = CalcMedianFromArray(stopLags, nStop);
   limitLag    = CalcMedianFromArray(limitLags, nLimit);
   double medAsyncClose = CalcMedianFromArray(asyncCLags, nAsyncC);
   double medSyncClose  = CalcMedianFromArray(syncCLags, nSyncC);

   // Stop/Limit asymmetry: if limits fill instantly (<1ms) but stops are held, that's extreme asymmetry
   double stopLimitRatio = 0;
   if(nLimit > 0 && nStop > 0)
   {
      if(limitLag > 0.5)
         stopLimitRatio = stopLag / limitLag;
      else if(stopLag > 10)
         stopLimitRatio = stopLag;  // Treat as ratio vs 1ms baseline → stopLag/1 = stopLag
   }

   // Market order lag
   double marketLags[];
   int nMarket = 0;
   ArrayResize(marketLags, g_fillCount);
   for(int i = 0; i < g_fillCount; i++)
   {
      if(g_fills[i].fillType == FILL_MARKET_BUY || g_fills[i].fillType == FILL_MARKET_SELL)
         marketLags[nMarket++] = g_fills[i].brokerExecMs;
   }
   double medMarket = CalcMedianFromArray(marketLags, nMarket);

   // TP/SL execution lag
   double tpLags[], slLags[];
   int nTP = 0, nSL = 0;
   ArrayResize(tpLags, g_fillCount);
   ArrayResize(slLags, g_fillCount);
   for(int i = 0; i < g_fillCount; i++)
   {
      if(g_fills[i].fillType == FILL_TP)
         tpLags[nTP++] = g_fills[i].brokerExecMs;
      if(g_fills[i].fillType == FILL_SL)
         slLags[nSL++] = g_fills[i].brokerExecMs;
   }
   double medTP = CalcMedianFromArray(tpLags, nTP);
   double medSL = CalcMedianFromArray(slLags, nSL);
   int tpCount = nTP, slCount = nSL;

   // Asymmetry ratios (used for colors and cost attribution)
   double tpslExecRatio = 0;
   if(medTP > 10 && medSL > 10)
      tpslExecRatio = medSL / medTP;
   else if(medSL > 10 && medTP <= 10 && nTP > 0)
      tpslExecRatio = medSL;  // TP ~0ms, SL large = extreme asymmetry

   // Async open: EARLIEST_SETUP_MSC - send_epoch - CS_one_way = broker processing time
   double asyncOpenMs = 0;
   if(g_gridEarliestSetupMsc > 0 && g_gridPlacedMs > 0)
   {
      long sendEpoch = (long)(g_epochMsOffset + g_gridPlacedMs);
      asyncOpenMs = (double)(g_gridEarliestSetupMsc - sendEpoch - (long)g_clientServerLagMs);
      if(asyncOpenMs < 0) asyncOpenMs = 0;
   }

   // Async order close: MSC-based (order deletes don't have boot-time callback)
   double asyncOrdCloseMs = 0;
   if(g_orderDeleteEarliestMsc > 0 && g_orderDeleteSendMs > 0)
   {
      long ordSendEpoch = (long)(g_epochMsOffset + g_orderDeleteSendMs);
      asyncOrdCloseMs = (double)(g_orderDeleteEarliestMsc - ordSendEpoch - (long)g_clientServerLagMs);
      if(asyncOrdCloseMs < 0) asyncOrdCloseMs = 0;
   }

   // Async position close: EARLIEST_CLOSE_MSC - send_epoch - CS_one_way = broker processing time
   double asyncPosCloseMs = 0;
   if(g_posCloseEarliestMsc > 0 && g_posCloseSendMs > 0)
   {
      long posSendEpoch = (long)(g_epochMsOffset + g_posCloseSendMs);
      asyncPosCloseMs = (double)(g_posCloseEarliestMsc - posSendEpoch - (long)g_clientServerLagMs);
      if(asyncPosCloseMs < 0) asyncPosCloseMs = 0;
   }

   // Async close efficiency: % of positions closed during async window (not stragglers)
   int asyncCloseN = nClose - nSyncC;  // async = total closes - sync stragglers
   double asyncClosePct = (nClose > 0) ? (asyncCloseN * 100.0 / nClose) : 0;

   // Trigger fill accuracy per category (for panel display)
   // Stops (types 2+3), Limits (types 4+5), TP (type 6), SL (type 7)
   int stopTrigTotal  = g_triggerFillCount[2] + g_triggerFillCount[3];
   int stopMktTotal   = g_marketFillCount[2]  + g_marketFillCount[3];
   int limitTrigTotal = g_triggerFillCount[4] + g_triggerFillCount[5];
   int limitMktTotal  = g_marketFillCount[4]  + g_marketFillCount[5];
   int stopClassified  = stopTrigTotal + stopMktTotal;
   int limitClassified = limitTrigTotal + limitMktTotal;
   int tpClassified = g_triggerFillCount[6] + g_marketFillCount[6];
   int slClassified = g_triggerFillCount[7] + g_marketFillCount[7];
   double stopTrigPct  = (stopClassified > 0)  ? (double)stopTrigTotal / stopClassified * 100.0 : -1;
   double limitTrigPct = (limitClassified > 0) ? (double)limitTrigTotal / limitClassified * 100.0 : -1;
   double tpTrigPct    = (tpClassified > 0)    ? (double)g_triggerFillCount[6] / tpClassified * 100.0 : -1;
   double slTrigPct    = (slClassified > 0)    ? (double)g_triggerFillCount[7] / slClassified * 100.0 : -1;

   SetPanelLine(0, StringFormat("══ BROKER FORENSIC ANALYZER v%s ══", FA_VERSION), clrWhite);

   if(g_state == STATE_DONE)
   {
      // Expand panel to 3-column width for summary
      ObjectSetInteger(0, g_panelBgName, OBJPROP_XSIZE, PANEL_WIDTH_EX);

      // Draw vertical bar chart in 3rd column (once)
      if(!g_barChartDrawn)
      {
         DrawSummaryBarChart();
         g_barChartDrawn = true;
      }

      // Final display — verdict based on fill accuracy classification
      string verdict = g_batchClassification;
      color verdictClr = clrLime;
      if(g_batchClassification == "MANIPULATION")
         verdictClr = clrTomato;
      else if(g_batchClassification == "CAUTION")
         verdictClr = clrOrange;

      int ln = 1;
      SetPanelLine(ln++, "══ ANALYSIS COMPLETE ══", clrLime);
      SetPanelLine(ln++, StringFormat("Verdict: %s", verdict), verdictClr);
      SetPanelLine(ln++, " ", clrBlack);

      // --- EXECUTION SPEED (dual columns) ---
      SetPanelLine(ln, "─── Execution Speed ───", clrCyan);
      SetPanelRight(ln, " ", clrBlack);
      ln++;

      // Row: Sync Open / Sync Close
      color syncOpenClr = (medMarket > STD_MARKET_MANIP_MS) ? clrTomato : (medMarket > STD_MARKET_SLOW_MS) ? clrOrange : clrLime;
      color syncCloseClr = (nSyncC > 0 && medSyncClose > STD_SYNC_CLOSE_MANIP_MS) ? clrTomato :
         (nSyncC > 0 && medSyncClose > STD_SYNC_CLOSE_SLOW_MS) ? clrOrange : clrLime;
      SetPanelLine(ln, StringFormat("Sync Open: %s (%d)", FormatMs(medMarket), nMarket), syncOpenClr);
      SetPanelRight(ln, StringFormat("Sync Close: %s (%d)", FormatMs(medSyncClose), nSyncC), syncCloseClr);
      ln++;

      // Row: Async Open / Close
      color asyncOpenClr = (asyncOpenMs > STD_FILL_MANIP_MS) ? clrTomato : (asyncOpenMs > STD_FILL_SLOW_MS) ? clrOrange : clrLime;
      color asyncPosClr = (asyncPosCloseMs > STD_CLOSE_MANIP_MS) ? clrTomato : (asyncPosCloseMs > STD_CLOSE_SLOW_MS) ? clrOrange : clrLime;
      string ordCloseStr = (g_orderDeleteCount > 0) ? FormatMs(asyncOrdCloseMs) : "N/A";
      SetPanelLine(ln, StringFormat("Async Open: %s (%d)", FormatMs(asyncOpenMs), g_gridOrdersConfirmed), asyncOpenClr);
      SetPanelRight(ln, StringFormat("Close: ord %s pos %s", ordCloseStr, FormatMs(asyncPosCloseMs)), asyncPosClr);
      ln++;

      // Row: SL Place / TP Place
      double medSyncSL = CalcMedianFromArray(g_syncSLPlaceLags, g_syncSLPlaceCount);
      double medSyncTP = CalcMedianFromArray(g_syncTPPlaceLags, g_syncTPPlaceCount);
      double medAsyncSL = CalcMedianFromArray(g_asyncSLPlaceLags, g_asyncSLPlaceCount);
      double medAsyncTP = CalcMedianFromArray(g_asyncTPPlaceLags, g_asyncTPPlaceCount);
      color slpClr = (medSyncSL > STD_TPSL_MANIP_MS || medAsyncSL > STD_TPSL_MANIP_MS) ? clrTomato :
         (medSyncSL > STD_TPSL_SLOW_MS || medAsyncSL > STD_TPSL_SLOW_MS) ? clrOrange : clrLime;
      color tppClr = (medSyncTP > STD_TPSL_MANIP_MS || medAsyncTP > STD_TPSL_MANIP_MS) ? clrTomato :
         (medSyncTP > STD_TPSL_SLOW_MS || medAsyncTP > STD_TPSL_SLOW_MS) ? clrOrange : clrLime;
      SetPanelLine(ln, StringFormat("SL Place: s%s a%s",
         FormatMs(medSyncSL, g_syncSLPlaceCount>0), FormatMs(medAsyncSL, g_asyncSLPlaceCount>0)), slpClr);
      SetPanelRight(ln, StringFormat("TP Place: s%s a%s",
         FormatMs(medSyncTP, g_syncTPPlaceCount>0), FormatMs(medAsyncTP, g_asyncTPPlaceCount>0)), tppClr);
      ln++;

      // === Two-table asymmetry section ===
      int boxHeaderLine = ln;
      SetPanelLine(ln, "  BROKER PROFITS", clrTomato);
      SetPanelRight(ln, "  BROKER PAYS", clrLime);
      ln++;

      // Row: Stop (lag-based, fills at market) / Limit (trigger fill %, has price guarantee)
      // Asymmetry override: broker-profits = bright orange, broker-pays = bright green
      bool fillAsym = (nStop > 0 && nLimit > 0 && stopLimitRatio > 2.0);
      bool slTpAsym = (nSL > 0 && nTP > 0 && tpslExecRatio > 2.0);
      // Stops: color on LAG (market fill is normal, not a red flag)
      color stopClr = fillAsym ? clrOrange :
         (stopLag <= STD_FILL_GOOD_MS) ? clrLime : (stopLag <= STD_FILL_SLOW_MS) ? clrOrange : clrTomato;
      // Limits: color on TRIGGER FILL % (price guarantee)
      color limClr = fillAsym ? clrLime :
         (limitTrigPct >= 90.0) ? clrLime : (limitTrigPct >= 70.0) ? clrOrange : (limitTrigPct >= 0) ? clrTomato : clrGray;
      if(stopTrigPct >= 0)
         SetPanelLine(ln, StringFormat("  Stop: %.0f%% trig [%s] (%d)", stopTrigPct, FormatMs(stopLag), nStop), stopClr);
      else
         SetPanelLine(ln, StringFormat("  Stop: %s (%d)", FormatMs(stopLag, nStop>0), nStop), fillAsym ? clrOrange : clrGray);
      if(limitTrigPct >= 0)
         SetPanelRight(ln, StringFormat("  Limit: %.0f%% trig [%s] (%d)", limitTrigPct, FormatMs(limitLag), nLimit), limClr);
      else
         SetPanelRight(ln, StringFormat("  Limit: %s (%d)", FormatMs(limitLag, nLimit>0), nLimit), fillAsym ? clrLime : clrGray);
      ln++;

      // Row: SL (lag-based, stop-like) / TP (trigger fill %, limit-like)
      // SL: color on LAG (fills at market by design)
      color slTrigClr = slTpAsym ? clrOrange :
         (medSL <= STD_TPSL_GOOD_MS) ? clrLime : (medSL <= STD_TPSL_SLOW_MS) ? clrOrange : clrTomato;
      // TP: color on TRIGGER FILL % (price guarantee)
      color tpTrigClr = slTpAsym ? clrLime :
         (tpTrigPct >= 90.0) ? clrLime : (tpTrigPct >= 70.0) ? clrOrange : (tpTrigPct >= 0) ? clrTomato : clrGray;
      if(slTrigPct >= 0)
         SetPanelLine(ln, StringFormat("  SL: %.0f%% trig [%s] (%d)", slTrigPct, FormatMs(medSL), nSL), slTrigClr);
      else
         SetPanelLine(ln, StringFormat("  SL: %s (%d)", FormatMs(medSL, nSL>0), nSL), slTpAsym ? clrOrange : clrGray);
      if(tpTrigPct >= 0)
         SetPanelRight(ln, StringFormat("  TP: %.0f%% trig [%s] (%d)", tpTrigPct, FormatMs(medTP), nTP), tpTrigClr);
      else
         SetPanelRight(ln, StringFormat("  TP: %s (%d)", FormatMs(medTP, nTP>0), nTP), slTpAsym ? clrLime : clrGray);
      ln++;

      ShowAsymmetryBoxes(boxHeaderLine, 2);

      // Stop/Limit LAG RATIO — the forensic signal (not trigger fill % gap)
      {
         color slrClr = fillAsym ? clrRed : (stopLimitRatio > 1.5) ? clrOrange : clrLime;
         string slrVerdict = fillAsym ? "ASYMMETRIC" : (stopLimitRatio > 1.5) ? "NOTABLE" : "FAIR";
         SetPanelLine(ln, StringFormat("Stop/Limit lag: %.1fx = %s", stopLimitRatio, slrVerdict), slrClr);
         if(stopTrigPct >= 0 && limitTrigPct >= 0)
            SetPanelRight(ln, StringFormat("Trig: %.0f%% vs %.0f%% (structural)", stopTrigPct, limitTrigPct), clrGray);
      }
      ln++;

      SetPanelLine(ln++, " ", clrBlack);

      // Clear right-column labels for lines below the dual section
      for(int rc = ln - PANEL_RCOL_START; rc < PANEL_RCOL_COUNT; rc++)
         if(rc >= 0) SetPanelRight(rc + PANEL_RCOL_START, " ", clrBlack);

      // --- OTHER INDICATORS ---
      SetPanelLine(ln++, "─── Other Manipulation Indicators ───", clrCyan);

      // Overall fill accuracy summary
      double fairPct = (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0;
      color fairClr = (fairPct >= 90.0) ? clrLime : (fairPct >= 70.0) ? clrOrange : clrTomato;
      SetPanelLine(ln++, StringFormat("Overall Fill Accuracy: %.0f%% trigger (%d/%d)", fairPct, g_fairFills, g_totalPricedFills), fairClr);

      // Classification
      color classClr = (g_batchClassification == "MANIPULATION") ? clrTomato :
                     (g_batchClassification == "CAUTION") ? clrOrange : clrLime;
      SetPanelLine(ln++, StringFormat("Classification: %s", g_batchClassification), classClr);

      // Rounding — only flag as manipulation indicator if classification is MANIPULATION
      if(g_batchClassification == "MANIPULATION" && g_roundingErrorSum < -0.01)
      {
         SetPanelLine(ln++, StringFormat("Rounding Bias:   %+.4f %s", g_roundingErrorSum, g_displayCurrency), clrOrange);
      }
      else
      {
         SetPanelLine(ln++, StringFormat("Pricing Delta:   %+.4f %s (normal)", g_roundingErrorSum, g_displayCurrency), clrLime);
      }

      // --- VDP / ASYMMETRY DETECTION ---
      if(g_vdpAdverseCount >= 3)
      {
         SetPanelLine(ln++, " ", clrBlack);
         bool anyAsym = (g_vdpLagRatio > 2.0);
         if(g_vdpScore >= 50)
         {
            // VDP detected
            SetPanelLine(ln++, StringFormat("─── Virtual Dealer Plugin: %s (%.0f%%) ───", g_vdpVerdict, g_vdpScore), clrRed);
            SetPanelLine(ln++, StringFormat("  Adverse lag: %s  vs  Favorable: %s  (%.0fx)",
               FormatMs(g_vdpAdverseMedian), FormatMs(g_vdpFavorMedian), g_vdpLagRatio), clrRed);
            if(g_vdpWholeSecCluster)
               SetPanelLine(ln++, StringFormat("  Whole-second clustering: %.0f%% of fills", g_vdpWholeSecPct), clrRed);
            if(g_vdpFlatDistribution)
               SetPanelLine(ln++, StringFormat("  Flat lag distribution (IQR/med=%.2f) — configured delay band", g_vdpIQRatio), clrRed);
            if(g_vdpOrderTypeDiscrim)
               SetPanelLine(ln++, "  Per-order-type delay discrimination", clrRed);
         }
         else if(anyAsym)
         {
            // No VDP but asymmetry detected
            color asymClr = (g_vdpLagRatio > 5.0) ? clrRed : clrTomato;
            SetPanelLine(ln++, "─── Asymmetric Execution Detected ───", asymClr);
            SetPanelLine(ln++, StringFormat("  Adverse: %s  vs  Favorable: %s  (%.0fx asymmetry)",
               FormatMs(g_vdpAdverseMedian), FormatMs(g_vdpFavorMedian), g_vdpLagRatio), asymClr);
            SetPanelLine(ln++, "  Broker-profitable orders consistently delayed longer", asymClr);
         }
      }

      SetPanelLine(ln++, " ", clrBlack);

      // --- COST SUMMARY ---
      // Costs are broker-induced when:
      // 1. Absolute lag exceeds standard (excessive holding)
      // 2. Asymmetry detected (discriminatory execution — stops held longer than limits)
      // Per 2026 MiFID II / FCA best execution: asymmetry >2x = violation regardless of absolute values
      bool fillLagExcessive = (stopLag > STD_FILL_SLOW_MS) || (limitLag > STD_FILL_SLOW_MS);
      bool slTpLagExcessive = (medSL > STD_TPSL_SLOW_MS) || (medTP > STD_TPSL_SLOW_MS);
      bool closeLagExcessive = (asyncPosCloseMs > STD_CLOSE_SLOW_MS) ||
                               (nSyncC > 0 && medSyncClose > STD_SYNC_CLOSE_SLOW_MS);
      bool fillAsymmetry = (nStop > 0 && nLimit > 0 && stopLimitRatio > 2.0);
      bool slTpAsymmetry = (nSL > 0 && nTP > 0 && tpslExecRatio > 2.0);
      bool anyExcessiveCost = fillLagExcessive || slTpLagExcessive || closeLagExcessive
                              || fillAsymmetry || slTpAsymmetry;

      if(anyExcessiveCost)
      {
         SetPanelLine(ln++, "─── Broker-Induced Costs ───", clrTomato);
         double totalDmg = 0;

         // Fill lag costs (excessive lag or asymmetry)
         if(fillLagExcessive || fillAsymmetry)
         {
            double stopCostPerLot = (g_totalLotsTraded > 0) ? g_stopAdverseSlipUSD / g_totalLotsTraded : 0;
            if(fillAsymmetry && !fillLagExcessive)
            {
               // Asymmetry-only: stops are within standard but held longer than limits
               SetPanelLine(ln++, StringFormat("Asymmetry: stops %s vs limits %s (%.1fx)",
                  FormatMs(stopLag), FormatMs(limitLag), stopLimitRatio), clrOrange);
               SetPanelLine(ln++, StringFormat("  Stop slippage: %s/lot (%.1f pips, %d fills)",
                  FormatMoney(stopCostPerLot), g_stopAdverseSlipPips, g_stopAdverseFillCount), clrOrange);
            }
            else
            {
               SetPanelLine(ln++, StringFormat("Fill Lag: %s/%s  Cost: %s/lot (%.1f pips)",
                  FormatMs(stopLag), FormatMs(limitLag),
                  FormatMoney(stopCostPerLot), g_stopAdverseSlipPips), clrOrange);
            }
            totalDmg += g_stopAdverseSlipUSD;
         }

         // SL/TP asymmetry or excessive lag
         if(slTpLagExcessive || slTpAsymmetry)
         {
            if(slTpAsymmetry && !slTpLagExcessive)
            {
               SetPanelLine(ln++, StringFormat("SL/TP Asymmetry: SL %s vs TP %s (%.1fx)",
                  FormatMs(medSL), FormatMs(medTP), tpslExecRatio), clrOrange);
            }
            else
            {
               SetPanelLine(ln++, StringFormat("SL/TP Lag: SL %s / TP %s (above %dms standard)",
                  FormatMs(medSL), FormatMs(medTP), STD_TPSL_GOOD_MS), clrOrange);
            }
         }

         // Close lag costs (only if close lag exceeds standard)
         if(closeLagExcessive)
         {
            double closeCostPerLot = (g_totalLotsTraded > 0) ? MathAbs(g_totalFinancialDelta) / g_totalLotsTraded : 0;
            SetPanelLine(ln++, StringFormat("Close Lag: %s  Cost: %s/lot",
               FormatMs(MathMax(asyncPosCloseMs, medSyncClose)),
               FormatMoney(closeCostPerLot)), clrOrange);
            totalDmg += MathAbs(g_totalFinancialDelta);
         }

         double dmgPerLot = (g_totalLotsTraded > 0) ? totalDmg / g_totalLotsTraded : 0;
         if(totalDmg > 0)
         {
            SetPanelLine(ln++, StringFormat("Total Damage: %s  (%s/lot)",
               FormatMoney(totalDmg), FormatMoney(dmgPerLot)), clrTomato);
            SetPanelLine(ln++, StringFormat("Annual @ 1 lot/d: %s  @ 10: %s",
               FormatMoney(dmgPerLot * 252), FormatMoney(dmgPerLot * 10 * 252)), clrTomato);
         }
         if(g_prevDayDataValid)
         {
            SetPanelLine(ln++, StringFormat("PrevDay: %s/lot  @1: %s  @10: %s",
               FormatMoney(g_prevDaySlippagePerLot),
               FormatMoney(g_prevDayAnnualDamage1),
               FormatMoney(g_prevDayAnnualDamage10)), clrTomato);
         }
      }
      else
      {
         SetPanelLine(ln++, "─── Execution Quality ───", clrCyan);
         SetPanelLine(ln++, StringFormat("Fair execution (%d cycles, %.2f lots)",
            g_cycleNum, g_totalLotsTraded), clrLime);
         SetPanelLine(ln++, "No broker-induced costs — zero execution drift from receipt price", clrLime);
      }

      SetPanelLine(ln++, " ", clrBlack);

      // --- STRESS TEST RESULTS ---
      if(g_stressCycleLimit > 0 || g_stressCycleStop > 0)
      {
         SetPanelLine(ln++, "─── Order Capacity Stress Test ───", clrCyan);

         // Limit results with rejection rate
         double limRejPct = (g_stressLimitTotalAttempts > 0) ?
            (100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts) : 0;
         if(g_stressLimitBlocked)
            SetPanelLine(ln++, StringFormat("Limits: BLOCKED at cycle %d", g_stressLimitBlockedAt), clrOrange);
         else if(limRejPct > 10.0)
            SetPanelLine(ln++, StringFormat("Limits: %d cycles (%d max verified) — %.0f%% REJECTED (%d/%d)",
               g_stressCycleLimit, g_stressMaxVerifiedLimit, limRejPct,
               g_stressLimitTotalRejects, g_stressLimitTotalAttempts), clrTomato);
         else
            SetPanelLine(ln++, StringFormat("Limits: %d cycles OK (%d max verified)", g_stressCycleLimit, g_stressMaxVerifiedLimit), clrLime);

         // Stop results with rejection rate
         double stpRejPct = (g_stressStopTotalAttempts > 0) ?
            (100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts) : 0;
         if(g_stressStopBlocked)
            SetPanelLine(ln++, StringFormat("Stops:  BLOCKED at cycle %d", g_stressStopBlockedAt), clrTomato);
         else if(g_stressCycleStop > 0 && stpRejPct > 10.0)
            SetPanelLine(ln++, StringFormat("Stops:  %d cycles (%d max verified) — %.0f%% REJECTED (%d/%d)",
               g_stressCycleStop, g_stressMaxVerifiedStop, stpRejPct,
               g_stressStopTotalRejects, g_stressStopTotalAttempts), clrTomato);
         else if(g_stressCycleStop > 0)
            SetPanelLine(ln++, StringFormat("Stops:  %d cycles OK (%d max verified)", g_stressCycleStop, g_stressMaxVerifiedStop), clrLime);
         else
            SetPanelLine(ln++, "Stops:  not tested", clrGray);

         // Verdicts — only flag ASYMMETRY as manipulation (symmetric burst rejections are legitimate rate limiting)
         if(g_stressStopBlocked && !g_stressLimitBlocked)
            SetPanelLine(ln++, "SELECTIVE BLOCKING: stops blocked, limits allowed", clrTomato);
         if(limRejPct > 10.0 && stpRejPct > 10.0)
         {
            bool asymmetric = (stpRejPct > limRejPct * 1.5) || (limRejPct > stpRejPct * 1.5);
            if(asymmetric)
               SetPanelLine(ln++, StringFormat("ASYMMETRIC REJECTION: stop %.0f%% vs limit %.0f%%",
                  stpRejPct, limRejPct), clrTomato);
            else
               SetPanelLine(ln++, StringFormat("Rate limiting: %.0f%% burst rejection (symmetric — not manipulation)",
                  (100.0 * (g_stressStopTotalRejects + g_stressLimitTotalRejects) /
                   MathMax(1, g_stressStopTotalAttempts + g_stressLimitTotalAttempts))), clrOrange);
         }
         else if(limRejPct > 10.0 || stpRejPct > 10.0)
         {
            // Only one type has high rejection — could be asymmetric
            if(stpRejPct > 10.0 && limRejPct < 5.0)
               SetPanelLine(ln++, StringFormat("ASYMMETRIC REJECTION: stops %.0f%% vs limits %.0f%%",
                  stpRejPct, limRejPct), clrTomato);
            else if(limRejPct > 10.0 && stpRejPct < 5.0)
               SetPanelLine(ln++, StringFormat("ASYMMETRIC REJECTION: limits %.0f%% vs stops %.0f%%",
                  limRejPct, stpRejPct), clrTomato);
         }

         // Max verified vs advertised capacity
         if(g_orderLimit > 0)
         {
            double stopCapPct = (g_stressMaxVerifiedStop > 0) ? (100.0 * g_stressMaxVerifiedStop / g_orderLimit) : 0;
            double limCapPct  = (g_stressMaxVerifiedLimit > 0) ? (100.0 * g_stressMaxVerifiedLimit / g_orderLimit) : 0;
            if(stopCapPct > 0 && stopCapPct < 50.0)
               SetPanelLine(ln++, StringFormat("Capacity shortfall: stops only %.0f%% of advertised %d",
                  stopCapPct, (int)g_orderLimit), clrOrange);
            if(limCapPct > 0 && limCapPct < 50.0)
               SetPanelLine(ln++, StringFormat("Capacity shortfall: limits only %.0f%% of advertised %d",
                  limCapPct, (int)g_orderLimit), clrOrange);
         }

         // Throttle lockout display (only shows when broker actually rejected probes)
         if(g_throttleRecoveryCount > 0)
         {
            double limAvg = (g_throttleLimitMeasurements > 0) ? g_throttleLimitTotalMs / g_throttleLimitMeasurements : 0;
            double stpAvg = (g_throttleStopMeasurements > 0) ? g_throttleStopTotalMs / g_throttleStopMeasurements : 0;
            double worstMs = MathMax(g_throttleLimitMaxMs, g_throttleStopMaxMs);
            color recovClr = (worstMs > 1000) ? clrTomato : (worstMs > 200) ? clrOrange : clrLime;
            if(g_throttleLimitMeasurements > 0 && g_throttleStopMeasurements > 0)
               SetPanelLine(ln++, StringFormat("Throttle Lockout: lim %s (max %s) | stop %s (max %s)",
                  FormatMs(limAvg, true), FormatMs(g_throttleLimitMaxMs, true),
                  FormatMs(stpAvg, true), FormatMs(g_throttleStopMaxMs, true)), recovClr);
            else if(g_throttleLimitMeasurements > 0)
               SetPanelLine(ln++, StringFormat("Throttle Lockout: lim avg %s (max %s)",
                  FormatMs(limAvg, true), FormatMs(g_throttleLimitMaxMs, true)), recovClr);
            else
               SetPanelLine(ln++, StringFormat("Throttle Lockout: stop avg %s (max %s)",
                  FormatMs(stpAvg, true), FormatMs(g_throttleStopMaxMs, true)), recovClr);
         }
         else if(g_stressCycleLimit > 0 || g_stressCycleStop > 0)
         {
            SetPanelLine(ln++, "Throttle Lockout: none detected", clrLime);
         }

         // Safe async batch size (EA tuning data — only shown if InpShowEATuning)
         if(InpShowEATuning && (g_safeAsyncBatchStop > 0 || g_safeAsyncBatchLimit > 0))
         {
            SetPanelLine(ln++, StringFormat("Safe Async Batch: stop %d | limit %d (flush %s)",
               g_safeAsyncBatchStop, g_safeAsyncBatchLimit,
               FormatMs(g_bufferFlushAvgMs, true)), clrCyan);
         }
      }

      // --- REJECTIONS ---
      if(g_rejectionCount > 0)
      {
         color rejClr = (g_rejStopManipulation > 0) ? clrTomato : clrOrange;
         SetPanelLine(ln++, StringFormat("Rejections: %d (stop:%d lim:%d mkt:%d)",
            g_rejectionCount, g_rejStopTotal, g_rejLimitTotal, g_rejMarketTotal), rejClr);
         if(g_rejStopManipulation > 0 || g_rejLimitManipulation > 0)
            SetPanelLine(ln++, StringFormat("  Manipulation: stop:%d lim:%d | Legit: stop:%d lim:%d",
               g_rejStopManipulation, g_rejLimitManipulation, g_rejStopLegitimate, g_rejLimitLegitimate), clrTomato);
      }

      // --- FILL REJECTIONS (broker cancelled pending orders) ---
      if(g_fillRejectionCount > 0)
      {
         color fillRejClr = (g_fillRejStopTriggered > 0) ? clrTomato : clrOrange;
         SetPanelLine(ln++, StringFormat("Fill Rejections: %d (stop:%d lim:%d)",
            g_fillRejectionCount, g_fillRejStopTotal, g_fillRejLimitTotal), fillRejClr);
         if(g_fillRejStopTriggered > 0 || g_fillRejLimitTriggered > 0)
            SetPanelLine(ln++, StringFormat("  Price-triggered: stop:%d lim:%d | Pre-emptive: stop:%d lim:%d",
               g_fillRejStopTriggered, g_fillRejLimitTriggered,
               g_fillRejStopPreemptive, g_fillRejLimitPreemptive), clrTomato);
         if(g_fillRejVerdict != "")
            SetPanelLine(ln++, StringFormat("  Verdict: %s", g_fillRejVerdict), fillRejClr);
      }

      // --- PHANTOM SPIKES ---
      if(g_phantomSpikeCount > 0)
      {
         int slSp3 = 0;
         for(int s = 0; s < g_phantomSpikeCount; s++)
            if(g_phantomSpikes[s].triggeredSL) slSp3++;
         color spikeClr = (slSp3 > 0) ? clrTomato : clrOrange;
         SetPanelLine(ln++, StringFormat("Phantom Spikes: %d detected (%d triggered SL)", g_phantomSpikeCount, slSp3), spikeClr);
      }

      SetPanelLine(ln++, " ", clrBlack);

      // --- FILE OUTPUT ---
      SetPanelLine(ln++, "─── Report Files ───", clrCyan);
      // Split path into multiple lines — 9pt Consolas ~62 chars in 620px with padding
      int maxChars = 58;
      string pathRemain = g_outputFolder;
      while(StringLen(pathRemain) > 0)
      {
         if(StringLen(pathRemain) <= maxChars)
         {
            SetPanelLine(ln++, pathRemain, clrSilver);
            break;
         }
         // Find last backslash before maxChars
         int splitAt = -1;
         for(int s = maxChars; s >= 10; s--)
         {
            if(StringGetCharacter(pathRemain, s) == '\\')
            { splitAt = s; break; }
         }
         if(splitAt <= 0) splitAt = maxChars; // no backslash found, hard break
         SetPanelLine(ln++, StringSubstr(pathRemain, 0, splitAt + 1), clrSilver);
         pathRemain = "  " + StringSubstr(pathRemain, splitAt + 1);
      }
      SetPanelLine(ln++, StringFormat("  %s", g_reportPdfName), clrWhite);
      if(InpWriteHTML)
         SetPanelLine(ln++, StringFormat("  %s", g_reportHtmName), clrWhite);
      SetPanelLine(ln++, StringFormat("  %s", g_evidenceCsvName), clrSilver);
      SetPanelLine(ln++, StringFormat("  %s", g_tickCsvName), clrSilver);
      SetPanelLine(ln++, StringFormat("  %s", g_brokerLogName), clrSilver);
      SetPanelLine(ln++, StringFormat("  %s", g_histCsvName), clrSilver);

      for(int i = ln; i < PANEL_LINES; i++) SetPanelLine(i, " ", clrBlack);
   }
   else
   {
      // During stress test states, line 1 is managed by the state machine — don't overwrite
      bool inStressState = (g_state >= STATE_STRESS_PLACE && g_state <= STATE_STRESS_FINAL_CLEANUP);
      if(!inStressState)
         SetPanelLine(1, StringFormat("Cycle %d/%d | CS Lag: %dms (one-way) | Lim:%d Pos/Pend/Tot:%d/%d/%d",
            g_cycleNum, g_effectiveCycles, (int)g_clientServerLagMs,
            (int)g_orderLimit, g_maxPositionsObserved, g_maxPendingObserved, g_maxTotalObserved), clrYellow);
      double panelBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double panelAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double panelSpread = panelAsk - panelBid;
      double panelSpreadPips = panelSpread / g_pipSize;
      double panelSpreadPts  = panelSpreadPips * 10.0;  // 1 pip = 10 points (universal)
      color  spreadClr = (panelSpreadPips > 5.0) ? clrTomato : (panelSpreadPips > 2.0) ? clrOrange : clrLime;
      SetPanelLine(2, StringFormat("Fills: %d | Closes: %d | TP: %d | SL: %d",
                        nFill, nClose, tpCount, slCount), clrWhite);

      // Account info line: leverage + account mode + netting warning
      string acctModeStr;
      color  acctModeClr;
      if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      {
         acctModeStr = "NETTING — NO HEDGING ALLOWED";
         acctModeClr = clrTomato;
      }
      else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_EXCHANGE)
      {
         acctModeStr = "Exchange";
         acctModeClr = clrYellow;
      }
      else
      {
         acctModeStr = "Hedging";
         acctModeClr = clrLime;
      }
      SetPanelLine(3, StringFormat("Leverage: 1:%d | %s", (int)g_accountLeverage, acctModeStr), acctModeClr);
      SetPanelRight(3, StringFormat("Spread: %.1f pips (%.0f pts)", panelSpreadPips, panelSpreadPts), spreadClr);

      int ln2 = 4;

      // Row: Sync Open / Sync Close (left | right)
      color sOClr = (medMarket > STD_MARKET_MANIP_MS) ? clrTomato : (medMarket > STD_MARKET_SLOW_MS) ? clrOrange : clrLime;
      color sCClr = (nSyncC > 0 && medSyncClose > STD_SYNC_CLOSE_MANIP_MS) ? clrTomato : (nSyncC > 0 && medSyncClose > STD_SYNC_CLOSE_SLOW_MS) ? clrOrange : clrLime;
      SetPanelLine(ln2, StringFormat("Sync Open: %s", FormatMs(medMarket)), sOClr);
      SetPanelRight(ln2, StringFormat("Sync Close: %s (%d)", FormatMs(medSyncClose), nSyncC), sCClr);
      ln2++;

      // Row: Async Open / Close (left | right)
      color aOClr = (asyncOpenMs > STD_FILL_MANIP_MS) ? clrTomato : (asyncOpenMs > STD_FILL_SLOW_MS) ? clrOrange : clrLime;
      string ordClStr = (g_orderDeleteCount > 0) ? FormatMs(asyncOrdCloseMs) : "N/A";
      SetPanelLine(ln2, StringFormat("Async Open: %s", FormatMs(asyncOpenMs)), aOClr);
      if(g_closeEaSendDurationMs > 0)
         SetPanelRight(ln2, StringFormat("Close: ord %s pos %s (EA %dms)",
            ordClStr, FormatMs(asyncPosCloseMs), (int)g_closeEaSendDurationMs), aOClr);
      else
         SetPanelRight(ln2, StringFormat("Close: ord %s pos %s",
            ordClStr, FormatMs(asyncPosCloseMs)), aOClr);
      ln2++;

      // Row: SL Place / TP Place (left | right)
      double ipSyncSL = CalcMedianFromArray(g_syncSLPlaceLags, g_syncSLPlaceCount);
      double ipSyncTP = CalcMedianFromArray(g_syncTPPlaceLags, g_syncTPPlaceCount);
      double ipAsyncSL = CalcMedianFromArray(g_asyncSLPlaceLags, g_asyncSLPlaceCount);
      double ipAsyncTP = CalcMedianFromArray(g_asyncTPPlaceLags, g_asyncTPPlaceCount);
      color slpClr = (ipSyncSL > STD_TPSL_MANIP_MS || ipAsyncSL > STD_TPSL_MANIP_MS) ? clrTomato :
         (ipSyncSL > STD_TPSL_SLOW_MS || ipAsyncSL > STD_TPSL_SLOW_MS) ? clrOrange : clrLime;
      color tppClr = (ipSyncTP > STD_TPSL_MANIP_MS || ipAsyncTP > STD_TPSL_MANIP_MS) ? clrTomato :
         (ipSyncTP > STD_TPSL_SLOW_MS || ipAsyncTP > STD_TPSL_SLOW_MS) ? clrOrange : clrLime;
      SetPanelLine(ln2, StringFormat("SL Place: s%s a%s",
         FormatMs(ipSyncSL, g_syncSLPlaceCount>0), FormatMs(ipAsyncSL, g_asyncSLPlaceCount>0)), slpClr);
      SetPanelRight(ln2, StringFormat("TP Place: s%s a%s",
         FormatMs(ipSyncTP, g_syncTPPlaceCount>0), FormatMs(ipAsyncTP, g_asyncTPPlaceCount>0)), tppClr);
      ln2++;

      // === Two-table asymmetry section ===
      // Headers: fill accuracy is primary, lag as context
      int boxHeaderLine = ln2;
      SetPanelLine(ln2, "  BROKER PROFITS", clrTomato);
      SetPanelRight(ln2, "  BROKER PAYS", clrLime);
      ln2++;

      // Row: Stop (lag-based) / Limit (trigger fill %) — same logic as final panel
      bool fillAsym = (nStop > 0 && nLimit > 0 && stopLimitRatio > 2.0);
      bool slTpAsym = (nSL > 0 && nTP > 0 && tpslExecRatio > 2.0);
      // Stops: color on LAG (market fill is normal)
      color stopClr = fillAsym ? clrOrange :
         (stopLag <= STD_FILL_GOOD_MS) ? clrLime : (stopLag <= STD_FILL_SLOW_MS) ? clrOrange : clrTomato;
      // Limits: color on TRIGGER FILL % (price guarantee)
      color limitClr = fillAsym ? clrLime :
         (limitTrigPct >= 90.0) ? clrLime : (limitTrigPct >= 70.0) ? clrOrange : (limitTrigPct >= 0) ? clrTomato : clrGray;
      if(stopTrigPct >= 0)
         SetPanelLine(ln2, StringFormat("  Stop: %.0f%% trig [%s] (%d)", stopTrigPct, FormatMs(stopLag), nStop), stopClr);
      else
         SetPanelLine(ln2, StringFormat("  Stop: %s (%d)", FormatMs(stopLag, nStop>0), nStop), fillAsym ? clrOrange : clrGray);
      if(limitTrigPct >= 0)
         SetPanelRight(ln2, StringFormat("  Limit: %.0f%% trig [%s] (%d)", limitTrigPct, FormatMs(limitLag), nLimit), limitClr);
      else
         SetPanelRight(ln2, StringFormat("  Limit: %s (%d)", FormatMs(limitLag, nLimit>0), nLimit), fillAsym ? clrLime : clrGray);
      ln2++;

      // Row: SL (lag-based) / TP (trigger fill %)
      // SL: color on LAG (fills at market by design)
      color slTrigClr = slTpAsym ? clrOrange :
         (medSL <= STD_TPSL_GOOD_MS) ? clrLime : (medSL <= STD_TPSL_SLOW_MS) ? clrOrange : clrTomato;
      // TP: color on TRIGGER FILL % (price guarantee)
      color tpTrigClr = slTpAsym ? clrLime :
         (tpTrigPct >= 90.0) ? clrLime : (tpTrigPct >= 70.0) ? clrOrange : (tpTrigPct >= 0) ? clrTomato : clrGray;
      if(slTrigPct >= 0)
         SetPanelLine(ln2, StringFormat("  SL: %.0f%% trig [%s] (%d)", slTrigPct, FormatMs(medSL), nSL), slTrigClr);
      else
         SetPanelLine(ln2, StringFormat("  SL: %s (%d)", FormatMs(medSL, nSL>0), nSL), slTpAsym ? clrOrange : clrGray);
      if(tpTrigPct >= 0)
         SetPanelRight(ln2, StringFormat("  TP: %.0f%% trig [%s] (%d)", tpTrigPct, FormatMs(medTP), nTP), tpTrigClr);
      else
         SetPanelRight(ln2, StringFormat("  TP: %s (%d)", FormatMs(medTP, nTP>0), nTP), slTpAsym ? clrLime : clrGray);
      ln2++;

      // Show the two coloured boxes around the asymmetry section
      ShowAsymmetryBoxes(boxHeaderLine, 2);

      // Row: Cost per lot (only if market fills detected)
      double stopCostPerLot = (g_totalLotsTraded > 0) ? g_stopAdverseSlipUSD / g_totalLotsTraded : 0;
      double avgStopPips = (g_stopAdverseFillCount > 0) ? g_stopAdverseSlipPips / g_stopAdverseFillCount : 0;
      if(stopTrigPct >= 0 && stopTrigPct < 100)
      {
         color costClr = (stopTrigPct < 70) ? clrTomato : (stopTrigPct < 90) ? clrOrange : clrYellow;
         SetPanelLine(ln2, StringFormat("Market fill cost: %s/lot (%.1f pips, %d fills)",
            FormatMoney(stopCostPerLot), avgStopPips, g_stopAdverseFillCount), costClr);
         SetPanelRight(ln2, StringFormat("Annual: %s/lot", FormatMoney(stopCostPerLot * 252)), costClr);
      }
      else
      {
         SetPanelLine(ln2, StringFormat("Cost: %s/lot  (%.1f pips avg)", FormatMoney(stopCostPerLot), avgStopPips), clrLime);
         SetPanelRight(ln2, " ", clrBlack);
      }
      ln2++;

      // Row: Stop/Limit LAG RATIO — the forensic signal (trigger fill % is structural)
      if(nStop > 0 && nLimit > 0)
      {
         color slrClr = fillAsym ? clrRed : (stopLimitRatio > 1.5) ? clrOrange : clrLime;
         string slrVerdict = fillAsym ? "ASYMMETRIC" : (stopLimitRatio > 1.5) ? "NOTABLE" : "FAIR";
         SetPanelLine(ln2++, StringFormat("Stop/Limit lag: %.1fx = %s", stopLimitRatio, slrVerdict), slrClr);
      }

      for(int i = ln2; i < PANEL_LINES; i++) SetPanelLine(i, " ", clrBlack);
   }
}


//+------------------------------------------------------------------+
//| PANEL: Set a single line on chart                                  |
//+------------------------------------------------------------------+
void SetPanelLine(int line, string text, color clr)
{
   if(line < 0 || line >= PANEL_LINES) return;

   string objName = g_panelLabels[line];

   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, PANEL_X + 8);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, PANEL_Y + 5 + line * PANEL_LINE_H);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
   }

   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| PANEL: Set right-column label for a dual-column line               |
//+------------------------------------------------------------------+
void SetPanelRight(int panelLine, string text, color clr)
{
   int idx = panelLine - PANEL_RCOL_START;
   if(idx < 0 || idx >= PANEL_RCOL_COUNT) return;
   string objName = g_panelRightLabels[idx];
   ObjectSetString(0, objName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| PANEL: Clear all right-column labels                               |
//+------------------------------------------------------------------+
void ClearPanelRight()
{
   for(int i = 0; i < PANEL_RCOL_COUNT; i++)
      ObjectSetString(0, g_panelRightLabels[i], OBJPROP_TEXT, " ");
   // Hide asymmetry boxes
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
}

//+------------------------------------------------------------------+
//| PANEL: Show the two asymmetry boxes at given panel line            |
//+------------------------------------------------------------------+
void ShowAsymmetryBoxes(int headerLine, int numDataLines)
{
   int boxY = PANEL_Y + 5 + headerLine * PANEL_LINE_H - 2;
   int boxH = (1 + numDataLines) * PANEL_LINE_H + 4;
   int halfW = PANEL_WIDTH / 2 - 6;

   // Left box (BROKER PROFITS — adverse)
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_XDISTANCE, PANEL_X + 2);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_YDISTANCE, boxY);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_XSIZE, halfW);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_YSIZE, boxH);
   ObjectSetInteger(0, g_panelLeftBoxName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

   // Right box (BROKER PAYS — favorable)
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_XDISTANCE, PANEL_X + PANEL_WIDTH / 2 + 4);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_YDISTANCE, boxY);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_XSIZE, halfW);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_YSIZE, boxH);
   ObjectSetInteger(0, g_panelRightBoxName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
}


//+------------------------------------------------------------------+
//| PANEL: Draw vertical bar chart at summary (3rd column)             |
//| Each bar = one order type, vertical: green/yellow/red segments     |
//+------------------------------------------------------------------+
void DrawSummaryBarChart()
{
   // Chart area position (right of existing 2-column panel)
   int chartX = PANEL_COL3_X;
   int chartY = PANEL_Y + 10;  // Top of chart area
   int baseY  = chartY + BAR_CHART_H;  // Bottom of bars (bars grow upward from here)

   // Background box for the chart area
   string bgName = "FA_BarBG";
   ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, chartX - 5);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, chartY - 5);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, BAR_CHART_W);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, BAR_CHART_H + 320); // Asymmetry bar + bars + x-labels + legend + trigger fill bar
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, clrWhite);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, C'60,60,60');

   // Title
   string titleName = "FA_BarTitle";
   ObjectCreate(0, titleName, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, titleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, titleName, OBJPROP_XDISTANCE, chartX + 20);
   ObjectSetInteger(0, titleName, OBJPROP_YDISTANCE, chartY);
   ObjectSetString(0, titleName, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, titleName, OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, titleName, OBJPROP_COLOR, clrBlack);
   ObjectSetString(0, titleName, OBJPROP_TEXT, "Execution vs Industry Standard");

   // --- Asymmetry bar (horizontal, full width, below title) ---
   {
      double sumA3 = 0; int nA3 = 0;
      double sumF3 = 0; int nF3 = 0;
      if(g_countByType[2] > 0) { sumA3 += MathMax(1, g_medianLag[2]); nA3++; }
      if(g_countByType[3] > 0) { sumA3 += MathMax(1, g_medianLag[3]); nA3++; }
      if(g_countByType[7] > 0) { sumA3 += MathMax(1, g_medianLag[7]); nA3++; }
      if(g_countByType[4] > 0) { sumF3 += MathMax(1, g_medianLag[4]); nF3++; }
      if(g_countByType[5] > 0) { sumF3 += MathMax(1, g_medianLag[5]); nF3++; }
      if(g_countByType[6] > 0) { sumF3 += MathMax(1, g_medianLag[6]); nF3++; }
      if(nA3 > 0 && nF3 > 0)
      {
         double avgA3 = sumA3 / nA3;
         double avgF3 = sumF3 / nF3;
         if(avgA3 < 1) avgA3 = 1;
         if(avgF3 < 1) avgF3 = 1;
         double ratio3 = avgA3 / avgF3;

         // Full bar width: scale both sides to fill entire chart width
         int barTotalW = BAR_CHART_W - 20;  // 10px margin each side
         int barLeft   = chartX + 10;       // Left edge of bar area
         // Use rounded display values so equal display = equal bar widths
         double dispA3 = MathRound(avgA3);
         double dispF3 = MathRound(avgF3);
         double totalLag = dispA3 + dispF3;
         if(totalLag < 1) totalLag = 1;
         int brkPx3, trdPx3;
         if(ratio3 <= 1.2 || dispA3 == dispF3)
         {
            // FAIR execution or equal display values — show equal bars
            brkPx3 = barTotalW / 2;
            trdPx3 = barTotalW - brkPx3;
         }
         else
         {
            brkPx3 = (int)MathMax(10, (dispA3 / totalLag) * barTotalW);
            trdPx3 = barTotalW - brkPx3;
            if(trdPx3 < 10) { trdPx3 = 10; brkPx3 = barTotalW - 10; }
         }

         // Row 1: Subheading centered
         int subY = chartY + 20;
         string subName = "FA_AsymSub";
         ObjectCreate(0, subName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, subName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, subName, OBJPROP_XDISTANCE, chartX + BAR_CHART_W / 2 - 65);
         ObjectSetInteger(0, subName, OBJPROP_YDISTANCE, subY);
         ObjectSetString(0, subName, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, subName, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, subName, OBJPROP_COLOR, C'80,80,80');
         ObjectSetString(0, subName, OBJPROP_TEXT, "Your Wait vs Broker's Wait");

         // === FAIR BAR: Honest broker (expected) — green 50/50 ===
         int fairLblY = subY + 18;
         string fairLbl = "FA_AsymFairLbl";
         ObjectCreate(0, fairLbl, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, fairLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, fairLbl, OBJPROP_XDISTANCE, barLeft);
         ObjectSetInteger(0, fairLbl, OBJPROP_YDISTANCE, fairLblY);
         ObjectSetString(0, fairLbl, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, fairLbl, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, fairLbl, OBJPROP_COLOR, C'100,100,100');
         ObjectSetString(0, fairLbl, OBJPROP_TEXT, "HONEST BROKER (expected):");

         int fairBarY = fairLblY + 14;
         int halfW3 = barTotalW / 2;
         // Left half (green)
         string fairL = "FA_AsymFairL";
         ObjectCreate(0, fairL, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, fairL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, fairL, OBJPROP_XDISTANCE, barLeft);
         ObjectSetInteger(0, fairL, OBJPROP_YDISTANCE, fairBarY);
         ObjectSetInteger(0, fairL, OBJPROP_XSIZE, halfW3 - 1);
         ObjectSetInteger(0, fairL, OBJPROP_YSIZE, 20);
         ObjectSetInteger(0, fairL, OBJPROP_BGCOLOR, C'40,100,40');
         ObjectSetInteger(0, fairL, OBJPROP_BORDER_COLOR, C'60,130,60');
         // Right half (green)
         string fairR = "FA_AsymFairR";
         ObjectCreate(0, fairR, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, fairR, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, fairR, OBJPROP_XDISTANCE, barLeft + halfW3 + 1);
         ObjectSetInteger(0, fairR, OBJPROP_YDISTANCE, fairBarY);
         ObjectSetInteger(0, fairR, OBJPROP_XSIZE, halfW3 - 1);
         ObjectSetInteger(0, fairR, OBJPROP_YSIZE, 20);
         ObjectSetInteger(0, fairR, OBJPROP_BGCOLOR, C'40,100,40');
         ObjectSetInteger(0, fairR, OBJPROP_BORDER_COLOR, C'60,130,60');
         // Labels centered in each half
         string fairTxtL = "FA_AsymFairTL";
         ObjectCreate(0, fairTxtL, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, fairTxtL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, fairTxtL, OBJPROP_XDISTANCE, barLeft + halfW3 / 2 - 25);
         ObjectSetInteger(0, fairTxtL, OBJPROP_YDISTANCE, fairBarY + 3);
         ObjectSetString(0, fairTxtL, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, fairTxtL, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, fairTxtL, OBJPROP_COLOR, C'140,210,140');
         ObjectSetString(0, fairTxtL, OBJPROP_TEXT, "Your orders");

         string fairTxtR = "FA_AsymFairTR";
         ObjectCreate(0, fairTxtR, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, fairTxtR, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, fairTxtR, OBJPROP_XDISTANCE, barLeft + halfW3 + halfW3 / 2 - 30);
         ObjectSetInteger(0, fairTxtR, OBJPROP_YDISTANCE, fairBarY + 3);
         ObjectSetString(0, fairTxtR, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, fairTxtR, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, fairTxtR, OBJPROP_COLOR, C'140,210,140');
         ObjectSetString(0, fairTxtR, OBJPROP_TEXT, "Broker orders");

         // === MEASURED BAR: Your broker (measured) — red/blue ===
         int hdrY = fairBarY + 28;
         string abrkHdr = "FA_AsymHdrB";
         ObjectCreate(0, abrkHdr, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, abrkHdr, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, abrkHdr, OBJPROP_XDISTANCE, barLeft);
         ObjectSetInteger(0, abrkHdr, OBJPROP_YDISTANCE, hdrY);
         ObjectSetString(0, abrkHdr, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, abrkHdr, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, abrkHdr, OBJPROP_COLOR, C'180,30,0');
         ObjectSetString(0, abrkHdr, OBJPROP_TEXT, "YOUR BROKER (measured):");

         int hdrY2 = hdrY + 14;
         string abrkHdr2 = "FA_AsymHdrB2";
         ObjectCreate(0, abrkHdr2, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, abrkHdr2, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, abrkHdr2, OBJPROP_XDISTANCE, barLeft);
         ObjectSetInteger(0, abrkHdr2, OBJPROP_YDISTANCE, hdrY2);
         ObjectSetString(0, abrkHdr2, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, abrkHdr2, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, abrkHdr2, OBJPROP_COLOR, C'180,30,0');
         ObjectSetString(0, abrkHdr2, OBJPROP_TEXT, "Your Orders (Stops/SL)");

         string atrdHdr = "FA_AsymHdrT";
         ObjectCreate(0, atrdHdr, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, atrdHdr, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, atrdHdr, OBJPROP_XDISTANCE, barLeft + barTotalW - 145);
         ObjectSetInteger(0, atrdHdr, OBJPROP_YDISTANCE, hdrY2);
         ObjectSetString(0, atrdHdr, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, atrdHdr, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, atrdHdr, OBJPROP_COLOR, C'30,90,220');
         ObjectSetString(0, atrdHdr, OBJPROP_TEXT, "Broker's Orders (Limits/TP)");

         // Row: The actual bar — full width, red left + blue right
         int asymY = hdrY2 + 14;
         string abrkName = "FA_AsymBrk";
         ObjectCreate(0, abrkName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, abrkName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, abrkName, OBJPROP_XDISTANCE, barLeft);
         ObjectSetInteger(0, abrkName, OBJPROP_YDISTANCE, asymY);
         ObjectSetInteger(0, abrkName, OBJPROP_XSIZE, brkPx3);
         ObjectSetInteger(0, abrkName, OBJPROP_YSIZE, 26);
         ObjectSetInteger(0, abrkName, OBJPROP_BGCOLOR, C'220,30,0');
         ObjectSetInteger(0, abrkName, OBJPROP_BORDER_COLOR, C'220,30,0');

         string atrdName = "FA_AsymTrd";
         ObjectCreate(0, atrdName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, atrdName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, atrdName, OBJPROP_XDISTANCE, barLeft + brkPx3);
         ObjectSetInteger(0, atrdName, OBJPROP_YDISTANCE, asymY);
         ObjectSetInteger(0, atrdName, OBJPROP_XSIZE, trdPx3);
         ObjectSetInteger(0, atrdName, OBJPROP_YSIZE, 26);
         ObjectSetInteger(0, atrdName, OBJPROP_BGCOLOR, C'30,90,220');
         ObjectSetInteger(0, atrdName, OBJPROP_BORDER_COLOR, C'30,90,220');

         // Value labels inside bars
         string abrkLbl = "FA_AsymBrkL";
         ObjectCreate(0, abrkLbl, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, abrkLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, abrkLbl, OBJPROP_XDISTANCE, barLeft + 4);
         ObjectSetInteger(0, abrkLbl, OBJPROP_YDISTANCE, asymY + 5);
         ObjectSetString(0, abrkLbl, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, abrkLbl, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, abrkLbl, OBJPROP_COLOR, clrWhite);
         ObjectSetString(0, abrkLbl, OBJPROP_TEXT, FormatMs(avgA3));

         string atrdLbl = "FA_AsymTrdL";
         ObjectCreate(0, atrdLbl, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, atrdLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         // Right-align inside the blue bar: anchor from right edge, 4px padding
         ObjectSetInteger(0, atrdLbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(0, atrdLbl, OBJPROP_XDISTANCE, barLeft + brkPx3 + trdPx3 - 4);
         ObjectSetInteger(0, atrdLbl, OBJPROP_YDISTANCE, asymY + 5);
         ObjectSetString(0, atrdLbl, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, atrdLbl, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, atrdLbl, OBJPROP_COLOR, clrWhite);
         ObjectSetString(0, atrdLbl, OBJPROP_TEXT, FormatMs(avgF3));

         // Row 4: Ratio verdict centered below bar
         string aVrdName = "FA_AsymVrd";
         ObjectCreate(0, aVrdName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, aVrdName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, aVrdName, OBJPROP_XDISTANCE, chartX + BAR_CHART_W / 2 - 60);
         ObjectSetInteger(0, aVrdName, OBJPROP_YDISTANCE, asymY + 30);
         ObjectSetString(0, aVrdName, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, aVrdName, OBJPROP_FONTSIZE, 9);
         color clrWarn = C'200,120,0';
         color clrOk   = C'0,140,0';
         color vrdClr3;
         if(ratio3 > 3.0)      vrdClr3 = clrRed;
         else if(ratio3 > 2.0) vrdClr3 = clrRed;
         else                   vrdClr3 = clrOk;
         string vrdTxt3 = (ratio3 > 3.0) ? "ASYMMETRIC" : (ratio3 > 2.0) ? "ASYMMETRIC" : "FAIR";
         ObjectSetInteger(0, aVrdName, OBJPROP_COLOR, vrdClr3);
         if(ratio3 <= 1.2)
            ObjectSetString(0, aVrdName, OBJPROP_TEXT, "Equal execution - FAIR");
         else if(ratio3 > 10)
            ObjectSetString(0, aVrdName, OBJPROP_TEXT, StringFormat("Stops %.0fx longer - %s", ratio3, vrdTxt3));
         else
            ObjectSetString(0, aVrdName, OBJPROP_TEXT, StringFormat("Stops %.1fx longer - %s", ratio3, vrdTxt3));

         // Shift vertical bars down to make room (fair bar + measured bar + verdict)
         baseY += 130;
      }
   }

   // Find max value for scaling
   double maxVal = 300;  // At least show up to 300ms (2026: top brokers 10-50ms)
   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] == 0) continue;
      if(g_medianLag[t] > maxVal) maxVal = g_medianLag[t];
   }
   maxVal *= 1.15;  // 15% headroom

   // Count active types for centering
   int activeTypes[];
   ArrayResize(activeTypes, 0);
   for(int t = 0; t < 10; t++)
      if(g_countByType[t] > 0)
      {
         int sz = ArraySize(activeTypes);
         ArrayResize(activeTypes, sz + 1);
         activeTypes[sz] = t;
      }
   int nBars = ArraySize(activeTypes);
   if(nBars == 0) return;

   // Center bars within chart width
   int totalBarsW = nBars * BAR_W + (nBars - 1) * BAR_GAP;
   int startX = chartX + (BAR_CHART_W - totalBarsW) / 2;
   int barAreaH = BAR_CHART_H - 25;  // Leave room for title at top

   // Y-axis scale lines (dotted reference at 100, 300, 500, 1000ms)
   int scaleVals[] = {50, 100, 200, 500};
   for(int s = 0; s < 4; s++)
   {
      if(scaleVals[s] > (int)maxVal) break;
      int scaleY = baseY - (int)((scaleVals[s] / maxVal) * barAreaH);
      string scaleName = StringFormat("FA_BarScale_%d", s);
      ObjectCreate(0, scaleName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, scaleName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, scaleName, OBJPROP_XDISTANCE, chartX - 2);
      ObjectSetInteger(0, scaleName, OBJPROP_YDISTANCE, scaleY - 6);
      ObjectSetString(0, scaleName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, scaleName, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, scaleName, OBJPROP_COLOR, C'130,130,130');
      ObjectSetString(0, scaleName, OBJPROP_TEXT, StringFormat("%d", scaleVals[s]));

      // Horizontal guide line
      string lineName = StringFormat("FA_BarLine_%d", s);
      ObjectCreate(0, lineName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, lineName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, lineName, OBJPROP_XDISTANCE, startX - 2);
      ObjectSetInteger(0, lineName, OBJPROP_YDISTANCE, scaleY);
      ObjectSetInteger(0, lineName, OBJPROP_XSIZE, totalBarsW + 4);
      ObjectSetInteger(0, lineName, OBJPROP_YSIZE, 1);
      ObjectSetInteger(0, lineName, OBJPROP_BGCOLOR, C'200,200,200');
      ObjectSetInteger(0, lineName, OBJPROP_BORDER_COLOR, C'200,200,200');
   }

   // Draw each bar
   for(int b = 0; b < nBars; b++)
   {
      int t = activeTypes[b];
      int barX = startX + b * (BAR_W + BAR_GAP);
      double measured = MathMax(1, g_medianLag[t]);  // Clamp 0ms → 1ms (<1ms display)

      // Determine industry standard for this type
      int stdGood;
      if(t <= 1) stdGood = STD_MARKET_GOOD_MS;
      else if(t <= 5) stdGood = STD_FILL_GOOD_MS;
      else if(t <= 7) stdGood = STD_TPSL_GOOD_MS;
      else if(t == 9) stdGood = STD_SYNC_CLOSE_GOOD_MS;
      else stdGood = STD_CLOSE_GOOD_MS;

      double stdMs = (double)stdGood;

      if(measured <= stdMs)
      {
         // Broker is FASTER: green bar (broker) + faded yellow (remaining standard headroom)
         int greenH = (int)MathMax(3, (measured / maxVal) * barAreaH);
         int yellowH = (int)MathMax(1, ((stdMs - measured) / maxVal) * barAreaH);

         // Yellow (standard headroom) — sits on top of green
         string yelName = StringFormat("FA_Bar_%d_Y", t);
         ObjectCreate(0, yelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, yelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, yelName, OBJPROP_XDISTANCE, barX);
         ObjectSetInteger(0, yelName, OBJPROP_YDISTANCE, baseY - greenH - yellowH);
         ObjectSetInteger(0, yelName, OBJPROP_XSIZE, BAR_W);
         ObjectSetInteger(0, yelName, OBJPROP_YSIZE, yellowH);
         ObjectSetInteger(0, yelName, OBJPROP_BGCOLOR, C'200,180,40');
         ObjectSetInteger(0, yelName, OBJPROP_BORDER_COLOR, C'200,180,40');

         // Green (broker measured) — bottom
         string grnName = StringFormat("FA_Bar_%d_G", t);
         ObjectCreate(0, grnName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, grnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, grnName, OBJPROP_XDISTANCE, barX);
         ObjectSetInteger(0, grnName, OBJPROP_YDISTANCE, baseY - greenH);
         ObjectSetInteger(0, grnName, OBJPROP_XSIZE, BAR_W);
         ObjectSetInteger(0, grnName, OBJPROP_YSIZE, greenH);
         ObjectSetInteger(0, grnName, OBJPROP_BGCOLOR, C'0,160,0');
         ObjectSetInteger(0, grnName, OBJPROP_BORDER_COLOR, C'0,160,0');

         // Value label above bar
         string valName = StringFormat("FA_BarVal_%d", t);
         ObjectCreate(0, valName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, valName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, valName, OBJPROP_XDISTANCE, barX);
         ObjectSetInteger(0, valName, OBJPROP_YDISTANCE, baseY - greenH - yellowH - 13);
         ObjectSetString(0, valName, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, valName, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, valName, OBJPROP_COLOR, C'0,120,0');
         ObjectSetString(0, valName, OBJPROP_TEXT, FormatMs(measured));
      }
      else
      {
         // Broker is SLOWER: yellow bar (standard) + red extension (excess)
         int yellowH = (int)MathMax(3, (stdMs / maxVal) * barAreaH);
         int redH = (int)MathMax(2, ((measured - stdMs) / maxVal) * barAreaH);
         int pctAbove = (stdGood > 0) ? (int)MathRound(((measured - stdMs) / stdMs) * 100) : 0;

         // Red (excess above standard) — on top
         string redName = StringFormat("FA_Bar_%d_R", t);
         ObjectCreate(0, redName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, redName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, redName, OBJPROP_XDISTANCE, barX);
         ObjectSetInteger(0, redName, OBJPROP_YDISTANCE, baseY - yellowH - redH);
         ObjectSetInteger(0, redName, OBJPROP_XSIZE, BAR_W);
         ObjectSetInteger(0, redName, OBJPROP_YSIZE, redH);
         ObjectSetInteger(0, redName, OBJPROP_BGCOLOR, C'220,20,0');
         ObjectSetInteger(0, redName, OBJPROP_BORDER_COLOR, C'220,20,0');

         // Yellow (standard) — bottom
         string yelName = StringFormat("FA_Bar_%d_Y", t);
         ObjectCreate(0, yelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
         ObjectSetInteger(0, yelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, yelName, OBJPROP_XDISTANCE, barX);
         ObjectSetInteger(0, yelName, OBJPROP_YDISTANCE, baseY - yellowH);
         ObjectSetInteger(0, yelName, OBJPROP_XSIZE, BAR_W);
         ObjectSetInteger(0, yelName, OBJPROP_YSIZE, yellowH);
         ObjectSetInteger(0, yelName, OBJPROP_BGCOLOR, C'200,180,40');
         ObjectSetInteger(0, yelName, OBJPROP_BORDER_COLOR, C'200,180,40');

         // Value label above bar (with % above)
         string valName = StringFormat("FA_BarVal_%d", t);
         ObjectCreate(0, valName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, valName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, valName, OBJPROP_XDISTANCE, barX - 2);
         ObjectSetInteger(0, valName, OBJPROP_YDISTANCE, baseY - yellowH - redH - 13);
         ObjectSetString(0, valName, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, valName, OBJPROP_FONTSIZE, 7);
         ObjectSetInteger(0, valName, OBJPROP_COLOR, C'200,0,0');
         ObjectSetString(0, valName, OBJPROP_TEXT, StringFormat("%s +%d%%", FormatMs(measured), pctAbove));
      }

      // X-axis label (short type name, below bar)
      string shortNames[] = {"MktB", "MktS", "BuyS", "SllS", "BuyL", "SllL", "TP", "SL", "AClz", "SClz"};
      string lblName = StringFormat("FA_BarLbl_%d", t);
      ObjectCreate(0, lblName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, lblName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, lblName, OBJPROP_XDISTANCE, barX - 1);
      ObjectSetInteger(0, lblName, OBJPROP_YDISTANCE, baseY + 3);
      ObjectSetString(0, lblName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, C'60,60,60');
      ObjectSetString(0, lblName, OBJPROP_TEXT, shortNames[t]);

      // Count label (below type name)
      string cntName = StringFormat("FA_BarCnt_%d", t);
      ObjectCreate(0, cntName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, cntName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, cntName, OBJPROP_XDISTANCE, barX);
      ObjectSetInteger(0, cntName, OBJPROP_YDISTANCE, baseY + 14);
      ObjectSetString(0, cntName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, cntName, OBJPROP_FONTSIZE, 6);
      ObjectSetInteger(0, cntName, OBJPROP_COLOR, C'120,120,120');
      ObjectSetString(0, cntName, OBJPROP_TEXT, StringFormat("(%d)", g_countByType[t]));

      // Standard ms label (below count)
      string stdName = StringFormat("FA_BarStd_%d", t);
      ObjectCreate(0, stdName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, stdName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, stdName, OBJPROP_XDISTANCE, barX - 2);
      ObjectSetInteger(0, stdName, OBJPROP_YDISTANCE, baseY + 24);
      ObjectSetString(0, stdName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, stdName, OBJPROP_FONTSIZE, 6);
      ObjectSetInteger(0, stdName, OBJPROP_COLOR, C'160,140,30');
      ObjectSetString(0, stdName, OBJPROP_TEXT, StringFormat("[%dms]", stdGood));
   }

   // Legend at bottom of chart
   int legY = baseY + 40;
   string legNames[] = {"FA_Leg_G", "FA_Leg_Y", "FA_Leg_R"};
   string legTexts[] = {"Broker (pass)", "Standard", "Excess (fail)"};
   color  legClrs[]  = {C'0,160,0', C'200,180,40', C'220,20,0'};
   for(int l = 0; l < 3; l++)
   {
      // Color swatch
      string swName = legNames[l] + "_sw";
      ObjectCreate(0, swName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, swName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, swName, OBJPROP_XDISTANCE, chartX + 10 + l * 140);
      ObjectSetInteger(0, swName, OBJPROP_YDISTANCE, legY);
      ObjectSetInteger(0, swName, OBJPROP_XSIZE, 10);
      ObjectSetInteger(0, swName, OBJPROP_YSIZE, 10);
      ObjectSetInteger(0, swName, OBJPROP_BGCOLOR, legClrs[l]);
      ObjectSetInteger(0, swName, OBJPROP_BORDER_COLOR, legClrs[l]);

      // Label
      string ltName = legNames[l] + "_tx";
      ObjectCreate(0, ltName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, ltName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, ltName, OBJPROP_XDISTANCE, chartX + 23 + l * 140);
      ObjectSetInteger(0, ltName, OBJPROP_YDISTANCE, legY - 1);
      ObjectSetString(0, ltName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, ltName, OBJPROP_FONTSIZE, 7);
      ObjectSetInteger(0, ltName, OBJPROP_COLOR, C'80,80,80');
      ObjectSetString(0, ltName, OBJPROP_TEXT, legTexts[l]);
   }

   // === TRIGGER FILL QUALITY INDICATOR ===
   // Shows market fill % for pending order types (stops + SL).
   // BUT: if asymmetric lag detected, fill price is IRRELEVANT — the timing itself is the violation.
   {
      // Detect asymmetric lag: recompute from globals (ratio3 was in inner scope)
      double tfSumAdv = 0; int tfNAdv = 0;
      double tfSumFav = 0; int tfNFav = 0;
      if(g_countByType[2] > 0) { tfSumAdv += MathMax(1, g_medianLag[2]); tfNAdv++; }
      if(g_countByType[3] > 0) { tfSumAdv += MathMax(1, g_medianLag[3]); tfNAdv++; }
      if(g_countByType[7] > 0) { tfSumAdv += MathMax(1, g_medianLag[7]); tfNAdv++; }
      if(g_countByType[4] > 0) { tfSumFav += MathMax(1, g_medianLag[4]); tfNFav++; }
      if(g_countByType[5] > 0) { tfSumFav += MathMax(1, g_medianLag[5]); tfNFav++; }
      if(g_countByType[6] > 0) { tfSumFav += MathMax(1, g_medianLag[6]); tfNFav++; }
      double tfAvgAdv = (tfNAdv > 0) ? tfSumAdv / tfNAdv : 0;
      double tfAvgFav = (tfNFav > 0) ? tfSumFav / tfNFav : 1;
      if(tfAvgFav < 1) tfAvgFav = 1;
      double tfLagRatio = (tfNAdv > 0 && tfNFav > 0) ? tfAvgAdv / tfAvgFav : 0;
      bool hasAsymLag = (tfLagRatio > 2.0);

      int stopTotal  = g_triggerFillCount[2] + g_marketFillCount[2]
                     + g_triggerFillCount[3] + g_marketFillCount[3];
      int stopMkt    = g_marketFillCount[2] + g_marketFillCount[3];
      int slTotal    = g_triggerFillCount[7] + g_marketFillCount[7];
      int slMkt      = g_marketFillCount[7];
      int allTotal   = stopTotal + slTotal;
      int allMkt     = stopMkt + slMkt;

      if(allTotal > 0)
      {
         double mktPct = (double)allMkt / allTotal * 100.0;
         int tfY = legY + 20;

         int tfBarW = BAR_CHART_W - 40;
         int tfBarX = chartX + 20;
         int tfBarH = 16;

         // Label above bar
         string tfHdr = "FA_TFHdr";
         ObjectCreate(0, tfHdr, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, tfHdr, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, tfHdr, OBJPROP_XDISTANCE, tfBarX);
         ObjectSetInteger(0, tfHdr, OBJPROP_YDISTANCE, tfY);
         ObjectSetString(0, tfHdr, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, tfHdr, OBJPROP_FONTSIZE, 7);

         int tfBarY = tfY + 14;

         if(hasAsymLag)
         {
            // ASYMMETRIC LAG: fill price is irrelevant — entire bar forced RED
            ObjectSetInteger(0, tfHdr, OBJPROP_COLOR, clrRed);
            ObjectSetString(0, tfHdr, OBJPROP_TEXT, "Fill Price IRRELEVANT — Asymmetric Lag Detected:");

            // Full-width red bar
            string tfRed = "FA_TFRed";
            ObjectCreate(0, tfRed, OBJ_RECTANGLE_LABEL, 0, 0, 0);
            ObjectSetInteger(0, tfRed, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, tfRed, OBJPROP_XDISTANCE, tfBarX);
            ObjectSetInteger(0, tfRed, OBJPROP_YDISTANCE, tfBarY);
            ObjectSetInteger(0, tfRed, OBJPROP_XSIZE, tfBarW);
            ObjectSetInteger(0, tfRed, OBJPROP_YSIZE, tfBarH);
            ObjectSetInteger(0, tfRed, OBJPROP_BGCOLOR, C'220,20,0');
            ObjectSetInteger(0, tfRed, OBJPROP_BORDER_COLOR, C'220,20,0');

            // Label inside bar
            string tfTrigLbl = "FA_TFTrigLbl";
            ObjectCreate(0, tfTrigLbl, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_XDISTANCE, tfBarX + 4);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_YDISTANCE, tfBarY + 1);
            ObjectSetString(0, tfTrigLbl, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_COLOR, clrWhite);
            ObjectSetString(0, tfTrigLbl, OBJPROP_TEXT, StringFormat("ASYMMETRIC LAG %.0fx — BROKER PASSES NOTHING", tfLagRatio));

            // Verdict below bar
            int vrdY = tfBarY + tfBarH + 3;
            string tfVrd = "FA_TFVrd";
            ObjectCreate(0, tfVrd, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, tfVrd, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, tfVrd, OBJPROP_XDISTANCE, chartX + 20);
            ObjectSetInteger(0, tfVrd, OBJPROP_YDISTANCE, vrdY);
            ObjectSetString(0, tfVrd, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, tfVrd, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, tfVrd, OBJPROP_COLOR, clrRed);
            ObjectSetString(0, tfVrd, OBJPROP_TEXT,
               "Counter fills arrive after EA close — price irrelevant");
         }
         else
         {
            // Normal mode: show trigger vs market fill bar
            // Stops/SL fill at MARKET by design (structural asymmetry in MT5 execution model).
            // Low trigger fill % on stops is expected physics, NOT broker manipulation.
            // Verdict depends on whether lag is fast+symmetric (FAIR) or slow/asymmetric (flag).
            ObjectSetInteger(0, tfHdr, OBJPROP_COLOR, C'60,60,60');
            ObjectSetString(0, tfHdr, OBJPROP_TEXT, "Stop/SL Fill Distribution (market fill = normal for stops):");

            int redW   = (int)MathMax(0, (mktPct / 100.0) * tfBarW);
            int greenW = tfBarW - redW;

            // Green bar (trigger fills) — left side
            if(greenW > 0)
            {
               string tfGrn = "FA_TFGrn";
               ObjectCreate(0, tfGrn, OBJ_RECTANGLE_LABEL, 0, 0, 0);
               ObjectSetInteger(0, tfGrn, OBJPROP_CORNER, CORNER_LEFT_UPPER);
               ObjectSetInteger(0, tfGrn, OBJPROP_XDISTANCE, tfBarX);
               ObjectSetInteger(0, tfGrn, OBJPROP_YDISTANCE, tfBarY);
               ObjectSetInteger(0, tfGrn, OBJPROP_XSIZE, greenW);
               ObjectSetInteger(0, tfGrn, OBJPROP_YSIZE, tfBarH);
               ObjectSetInteger(0, tfGrn, OBJPROP_BGCOLOR, C'0,160,0');
               ObjectSetInteger(0, tfGrn, OBJPROP_BORDER_COLOR, C'0,160,0');
            }

            // Red bar (market fills) — right side
            if(redW > 0)
            {
               string tfRed = "FA_TFRed";
               ObjectCreate(0, tfRed, OBJ_RECTANGLE_LABEL, 0, 0, 0);
               ObjectSetInteger(0, tfRed, OBJPROP_CORNER, CORNER_LEFT_UPPER);
               ObjectSetInteger(0, tfRed, OBJPROP_XDISTANCE, tfBarX + greenW);
               ObjectSetInteger(0, tfRed, OBJPROP_YDISTANCE, tfBarY);
               ObjectSetInteger(0, tfRed, OBJPROP_XSIZE, redW);
               ObjectSetInteger(0, tfRed, OBJPROP_YSIZE, tfBarH);
               ObjectSetInteger(0, tfRed, OBJPROP_BGCOLOR, C'180,80,0');
               ObjectSetInteger(0, tfRed, OBJPROP_BORDER_COLOR, C'180,80,0');
            }

            // Trigger fill % label (left-aligned inside green bar)
            double trigPct = 100.0 - mktPct;
            string tfTrigLbl = "FA_TFTrigLbl";
            ObjectCreate(0, tfTrigLbl, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_XDISTANCE, tfBarX + 4);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_YDISTANCE, tfBarY + 1);
            ObjectSetString(0, tfTrigLbl, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, tfTrigLbl, OBJPROP_COLOR, clrWhite);
            ObjectSetString(0, tfTrigLbl, OBJPROP_TEXT, StringFormat("Trigger: %.0f%%", trigPct));

            // Market fill % label (right-aligned inside red bar, if visible)
            if(redW > 40)
            {
               string tfMktLbl = "FA_TFMktLbl";
               ObjectCreate(0, tfMktLbl, OBJ_LABEL, 0, 0, 0);
               ObjectSetInteger(0, tfMktLbl, OBJPROP_CORNER, CORNER_LEFT_UPPER);
               ObjectSetInteger(0, tfMktLbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
               ObjectSetInteger(0, tfMktLbl, OBJPROP_XDISTANCE, tfBarX + tfBarW - 4);
               ObjectSetInteger(0, tfMktLbl, OBJPROP_YDISTANCE, tfBarY + 1);
               ObjectSetString(0, tfMktLbl, OBJPROP_FONT, "Consolas");
               ObjectSetInteger(0, tfMktLbl, OBJPROP_FONTSIZE, 8);
               ObjectSetInteger(0, tfMktLbl, OBJPROP_COLOR, clrWhite);
               ObjectSetString(0, tfMktLbl, OBJPROP_TEXT, StringFormat("Market: %.0f%%", mktPct));
            }

            // Verdict below bar — fast+symmetric lag = always FAIR for stops/SL
            int vrdY = tfBarY + tfBarH + 3;
            string tfVrd = "FA_TFVrd";
            ObjectCreate(0, tfVrd, OBJ_LABEL, 0, 0, 0);
            ObjectSetInteger(0, tfVrd, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            ObjectSetInteger(0, tfVrd, OBJPROP_XDISTANCE, chartX + 20);
            ObjectSetInteger(0, tfVrd, OBJPROP_YDISTANCE, vrdY);
            ObjectSetString(0, tfVrd, OBJPROP_FONT, "Consolas");
            ObjectSetInteger(0, tfVrd, OBJPROP_FONTSIZE, 8);

            // Stops/SL: verdict on LAG, not trigger fill % (market fill is normal)
            bool tfFastSym = (tfLagRatio <= 2.0) && (tfAvgAdv < STD_FILL_SLOW_MS);
            if(tfFastSym)
            {
               ObjectSetInteger(0, tfVrd, OBJPROP_COLOR, C'0,140,0');
               ObjectSetString(0, tfVrd, OBJPROP_TEXT,
                  StringFormat("FAIR — fast symmetric lag (%.0fms) — market fills expected for stops", tfAvgAdv));
            }
            else if(tfLagRatio > 2.0)
            {
               ObjectSetInteger(0, tfVrd, OBJPROP_COLOR, clrRed);
               ObjectSetString(0, tfVrd, OBJPROP_TEXT,
                  StringFormat("ASYMMETRIC LAG %.1fx — broker adds delay to worsen stop slippage", tfLagRatio));
            }
            else
            {
               ObjectSetInteger(0, tfVrd, OBJPROP_COLOR, C'200,120,0');
               ObjectSetString(0, tfVrd, OBJPROP_TEXT,
                  StringFormat("SLOW — %.0fms stop lag (%d/%d at trigger)", tfAvgAdv, allTotal - allMkt, allTotal));
            }
         }
      }
   }

   ChartRedraw(0);
}


//+------------------------------------------------------------------+
//| PANEL: Clean up bar chart objects                                   |
//+------------------------------------------------------------------+
void CleanupBarChart()
{
   ObjectDelete(0, "FA_BarBG");
   ObjectDelete(0, "FA_BarTitle");
   ObjectDelete(0, "FA_AsymSub");
   ObjectDelete(0, "FA_AsymFairLbl");
   ObjectDelete(0, "FA_AsymFairL");
   ObjectDelete(0, "FA_AsymFairR");
   ObjectDelete(0, "FA_AsymFairTL");
   ObjectDelete(0, "FA_AsymFairTR");
   ObjectDelete(0, "FA_AsymHdrB");
   ObjectDelete(0, "FA_AsymHdrB2");
   ObjectDelete(0, "FA_AsymHdrT");
   ObjectDelete(0, "FA_AsymBrk");
   ObjectDelete(0, "FA_AsymTrd");
   ObjectDelete(0, "FA_AsymBrkL");
   ObjectDelete(0, "FA_AsymTrdL");
   ObjectDelete(0, "FA_AsymVrd");
   for(int s = 0; s < 4; s++)
   {
      ObjectDelete(0, StringFormat("FA_BarScale_%d", s));
      ObjectDelete(0, StringFormat("FA_BarLine_%d", s));
   }
   for(int t = 0; t < 10; t++)
   {
      ObjectDelete(0, StringFormat("FA_Bar_%d_G", t));
      ObjectDelete(0, StringFormat("FA_Bar_%d_Y", t));
      ObjectDelete(0, StringFormat("FA_Bar_%d_R", t));
      ObjectDelete(0, StringFormat("FA_BarVal_%d", t));
      ObjectDelete(0, StringFormat("FA_BarLbl_%d", t));
      ObjectDelete(0, StringFormat("FA_BarCnt_%d", t));
      ObjectDelete(0, StringFormat("FA_BarStd_%d", t));
   }
   string legNames[] = {"FA_Leg_G", "FA_Leg_Y", "FA_Leg_R"};
   for(int l = 0; l < 3; l++)
   {
      ObjectDelete(0, legNames[l] + "_sw");
      ObjectDelete(0, legNames[l] + "_tx");
   }
   // Trigger fill quality bar
   ObjectDelete(0, "FA_TFHdr");
   ObjectDelete(0, "FA_TFGrn");
   ObjectDelete(0, "FA_TFRed");
   ObjectDelete(0, "FA_TFTrigLbl");
   ObjectDelete(0, "FA_TFMktLbl");
   ObjectDelete(0, "FA_TFVrd");
}


//+------------------------------------------------------------------+
//| CALCULATE ALL STATISTICS — called before report generation         |
//+------------------------------------------------------------------+
void CalcAllStatistics()
{
   PrintFormat("CalcAllStatistics: g_fillCount=%d (v1.18)", g_fillCount);
   // Reset aggregates
   for(int t = 0; t < 10; t++)
   {
      g_medianLag[t] = 0; g_meanLag[t] = 0; g_minLag[t] = 1e12; g_maxLag[t] = 0;
      g_countByType[t] = 0; g_lagValidCount[t] = 0;
      g_meanSlipSigned[t] = 0; g_meanSlipAbs[t] = 0; g_totalSlipUSD[t] = 0;
      g_driftLagSum[t] = 0; g_driftLagCount[t] = 0;
      g_triggerFillCount[t] = 0; g_marketFillCount[t] = 0;
   }

   // Collect lag arrays per type (separate arrays — MQL5 2D limitation)
   int lagCounts[10];
   for(int i2=0; i2<10; i2++) lagCounts[i2]=0;
   double lags0[], lags1[], lags2[], lags3[], lags4[], lags5[], lags6[], lags7[], lags8[], lags9[];
   ArrayResize(lags0, g_fillCount); ArrayResize(lags1, g_fillCount);
   ArrayResize(lags2, g_fillCount); ArrayResize(lags3, g_fillCount);
   ArrayResize(lags4, g_fillCount); ArrayResize(lags5, g_fillCount);
   ArrayResize(lags6, g_fillCount); ArrayResize(lags7, g_fillCount);
   ArrayResize(lags8, g_fillCount);
   ArrayResize(lags9, g_fillCount);

   // Separate async vs sync close lag arrays
   double asyncCloseLags[], syncCloseLags[];
   ArrayResize(asyncCloseLags, g_fillCount);
   ArrayResize(syncCloseLags, g_fillCount);
   g_asyncCloseCount = 0; g_asyncCloseMeanLag = 0; g_asyncCloseMedianLag = 0;
   g_syncCloseCount  = 0; g_syncCloseMeanLag  = 0; g_syncCloseMedianLag  = 0;

   for(int i = 0; i < g_fillCount; i++)
   {
      int t = (int)g_fills[i].fillType;
      if(t < 0 || t > 9) continue;

      g_countByType[t]++;
      g_meanSlipSigned[t] += g_fills[i].slippagePts;
      g_meanSlipAbs[t]    += MathAbs(g_fills[i].slippagePts);
      g_totalSlipUSD[t]   += g_fills[i].slippageUSD;

      // Accumulate drift lag (time-based, volatility-independent)
      if(g_fills[i].driftLagMs >= 0)
      {
         g_driftLagSum[t] += g_fills[i].driftLagMs;
         g_driftLagCount[t]++;
         ArrayResize(g_driftLagMedianArr, g_driftLagTotalCount + 1);
         g_driftLagMedianArr[g_driftLagTotalCount++] = g_fills[i].driftLagMs;
      }

      // Trigger/market classification for server-side triggers (types 2-7):
      // Primary test: does dealPrice match triggerPrice (requestedPrice)?
      //   YES → "trigger fill" (broker executed at the pending order level)
      //   NO  → "market fill" (broker executed at prevailing market price)
      // Secondary: when tickPriceAtDeal available, check piercing overshoot
      //   (the tick that crossed the trigger may have moved 1-2 pips past it)
      if(t >= 2 && t <= 7)
      {
         double dealP = g_fills[i].fillPrice;
         double trigP = g_fills[i].requestedPrice;
         double trigDelta = MathAbs(dealP - trigP);
         double threshold = 1.5 * g_point;  // 1.5 points tolerance

         if(trigDelta <= threshold)
            g_triggerFillCount[t]++;         // Filled at trigger price
         else
            g_marketFillCount[t]++;          // Filled away from trigger → market fill
      }

      // Only include fills with valid lag measurement in lag stats
      if(g_fills[i].lagValid)
      {
         g_meanLag[t] += g_fills[i].brokerExecMs;

         if(g_fills[i].brokerExecMs < g_minLag[t]) g_minLag[t] = g_fills[i].brokerExecMs;
         if(g_fills[i].brokerExecMs > g_maxLag[t]) g_maxLag[t] = g_fills[i].brokerExecMs;

         int idx = lagCounts[t];
         if(idx >= g_fillCount)
         {
            PrintFormat("BUG: lagCounts[%d]=%d >= g_fillCount=%d at fill %d, skipping", t, idx, g_fillCount, i);
            continue;
         }
         switch(t)
         {
            case 0: lags0[idx] = g_fills[i].brokerExecMs; break;
            case 1: lags1[idx] = g_fills[i].brokerExecMs; break;
            case 2: lags2[idx] = g_fills[i].brokerExecMs; break;
            case 3: lags3[idx] = g_fills[i].brokerExecMs; break;
            case 4: lags4[idx] = g_fills[i].brokerExecMs; break;
            case 5: lags5[idx] = g_fills[i].brokerExecMs; break;
            case 6: lags6[idx] = g_fills[i].brokerExecMs; break;
            case 7: lags7[idx] = g_fills[i].brokerExecMs; break;
            case 8: lags8[idx] = g_fills[i].brokerExecMs; break;
            case 9: lags9[idx] = g_fills[i].brokerExecMs; break;
         }
         lagCounts[t]++;
      }

      // Split close fills into async vs sync for aggregate stats
      // Both use brokerExecMs = DEAL_TIME_MSC - send_epoch - CS_lag (pure broker execution)
      if((t == 8 || t == 9) && g_fills[i].lagValid)
      {
         if(t == 9) // FILL_SYNC_CLOSE
         {
            syncCloseLags[g_syncCloseCount] = g_fills[i].brokerExecMs;
            g_syncCloseMeanLag += g_fills[i].brokerExecMs;
            g_syncCloseCount++;
         }
         else // FILL_ASYNC_CLOSE
         {
            asyncCloseLags[g_asyncCloseCount] = g_fills[i].brokerExecMs;
            g_asyncCloseMeanLag += g_fills[i].brokerExecMs;
            g_asyncCloseCount++;
         }
      }
   }

   // Compute means and medians
   for(int t = 0; t < 10; t++)
   {
      if(lagCounts[t] > 0)
         g_meanLag[t] /= lagCounts[t];
      if(g_countByType[t] > 0)
      {
         g_meanSlipSigned[t] /= g_countByType[t];
         g_meanSlipAbs[t]    /= g_countByType[t];
      }
      if(g_minLag[t] > 1e11) g_minLag[t] = 0;
   }

   // Medians per type
   g_medianLag[0] = CalcMedianFromArray(lags0, lagCounts[0]);
   g_medianLag[1] = CalcMedianFromArray(lags1, lagCounts[1]);
   g_medianLag[2] = CalcMedianFromArray(lags2, lagCounts[2]);
   g_medianLag[3] = CalcMedianFromArray(lags3, lagCounts[3]);
   g_medianLag[4] = CalcMedianFromArray(lags4, lagCounts[4]);
   g_medianLag[5] = CalcMedianFromArray(lags5, lagCounts[5]);
   g_medianLag[6] = CalcMedianFromArray(lags6, lagCounts[6]);
   g_medianLag[7] = CalcMedianFromArray(lags7, lagCounts[7]);
   g_medianLag[8] = CalcMedianFromArray(lags8, lagCounts[8]);
   g_medianLag[9] = CalcMedianFromArray(lags9, lagCounts[9]);

   // Store valid lag counts globally for report display
   for(int t2 = 0; t2 < 10; t2++) g_lagValidCount[t2] = lagCounts[t2];

   // Async vs Sync close medians and means
   if(g_asyncCloseCount > 0)
   {
      g_asyncCloseMeanLag /= g_asyncCloseCount;
      g_asyncCloseMedianLag = CalcMedianFromArray(asyncCloseLags, g_asyncCloseCount);
   }
   if(g_syncCloseCount > 0)
   {
      g_syncCloseMeanLag /= g_syncCloseCount;
      g_syncCloseMedianLag = CalcMedianFromArray(syncCloseLags, g_syncCloseCount);
   }

   //=== TP/SL MARKET TRIGGER DIRECTION ANALYSIS ===
   // TP triggers = favorable (hit target), SL triggers = adverse (hit stop)
   // Also check slippage direction on each trigger fill
   g_tpslTotalTriggers = 0; g_tpslFavorTriggers = 0; g_tpslAdverseTriggers = 0;
   g_tpslFavorSlip = 0; g_tpslAdverseSlip = 0; g_tpslNeutralSlip = 0;
   g_tpslFavorPct = 0; g_tpslAdversePct = 0; g_tpslSlipAsymRatio = 0;

   for(int i = 0; i < g_fillCount; i++)
   {
      int ft = (int)g_fills[i].fillType;
      if(ft == FILL_TP)
      {
         g_tpslTotalTriggers++;
         g_tpslFavorTriggers++;
         // Slippage on TP: positive = price improvement (better than target)
         double slip = g_fills[i].slippagePts;
         if(slip > g_point * 0.5)       g_tpslFavorSlip++;
         else if(slip < -g_point * 0.5) g_tpslAdverseSlip++;
         else                            g_tpslNeutralSlip++;
      }
      else if(ft == FILL_SL)
      {
         g_tpslTotalTriggers++;
         g_tpslAdverseTriggers++;
         // Slippage on SL: negative = worse fill (slipped past stop)
         double slip = g_fills[i].slippagePts;
         if(slip < -g_point * 0.5)      g_tpslAdverseSlip++;
         else if(slip > g_point * 0.5)  g_tpslFavorSlip++;
         else                            g_tpslNeutralSlip++;
      }
   }
   if(g_tpslTotalTriggers > 0)
   {
      g_tpslFavorPct  = 100.0 * g_tpslFavorTriggers  / g_tpslTotalTriggers;
      g_tpslAdversePct = 100.0 * g_tpslAdverseTriggers / g_tpslTotalTriggers;
   }
   // Slippage asymmetry: ratio of adverse-slipped fills to favorable-slipped fills
   if(g_tpslFavorSlip > 0)
      g_tpslSlipAsymRatio = (double)g_tpslAdverseSlip / (double)g_tpslFavorSlip;
   else if(g_tpslAdverseSlip > 0)
      g_tpslSlipAsymRatio = 99.0;  // All adverse, none favorable = extreme

   //=== PART 1: CLUSTER DETECTION (same price + same timestamp + same direction) ===
   // A cluster = 2+ fills sharing ALL of:
   //   (a) Same fill price (within 0.5 points tolerance)
   //   (b) Same broker timestamp (DEAL_TIME_MSC — exact match)
   //   (c) Same direction (all buys or all sells)
   //   (d) Same order category (stops grouped separately from limits)
   // This is the definitive sign of batch processing: the broker held multiple
   // orders from different trigger levels and filled them all at one price in one tick.
   // Stops and limits at the same price/time are separate clusters because
   // a stop at 1.2000 and a limit at 1.2000 have fundamentally different triggers.

   double ptTol = g_point * 0.5;
   for(int ct = 0; ct < 10; ct++) g_clusterByType[ct] = 0;
   g_clusterCount = 0;
   g_isolatedFills = 0;
   g_maxClusterSize = 0;
   int totalClusteredFills = 0;
   double clusterSizeSum = 0;
   // Reset per-cluster detail + fill model
   ArrayResize(g_clusterDetails, 0);
   g_clusterDetailCount = 0;
   g_fmLastTick = 0; g_fmTrigger = 0; g_fmLagInterp = 0; g_fmWorstPrice = 0;
   g_fmUnclassifiable = 0; g_fmTotal = 0;
   double interClusterGapSum = 0;
   int interClusterGapCount = 0;

   // Collect indices of all grid fills (stops + limits)
   int gridIdx[];
   int nGridFills = 0;
   ArrayResize(gridIdx, g_fillCount);
   for(int i = 0; i < g_fillCount; i++)
   {
      if(g_fills[i].fillType >= FILL_BUYSTOP && g_fills[i].fillType <= FILL_SELLLIMIT)
         gridIdx[nGridFills++] = i;
   }
   ArrayResize(gridIdx, nGridFills);

   // Mark which fills have been assigned to a cluster
   bool assigned[];
   ArrayResize(assigned, nGridFills);
   for(int i = 0; i < nGridFills; i++) assigned[i] = false;

   // Find clusters: for each unassigned fill, find all other fills matching
   // same fillPrice + same dealTimeMsc + same isBuy + same isLimit
   for(int i = 0; i < nGridFills; i++)
   {
      if(assigned[i]) continue;

      int fi = gridIdx[i];
      double fp = g_fills[fi].fillPrice;
      long   ft = g_fills[fi].dealTimeMsc;
      bool   fb = g_fills[fi].isBuy;
      bool   fl = (g_fills[fi].fillType == FILL_BUYLIMIT || g_fills[fi].fillType == FILL_SELLLIMIT);

      // Collect matching fills
      int members[];
      ArrayResize(members, nGridFills);
      int memberCount = 0;
      members[memberCount++] = i;

      for(int j = i + 1; j < nGridFills; j++)
      {
         if(assigned[j]) continue;
         int fj = gridIdx[j];

         // Must match: same price, same timestamp, same direction, same category
         bool samePrice = (MathAbs(g_fills[fj].fillPrice - fp) < ptTol);
         bool sameTime  = (g_fills[fj].dealTimeMsc == ft);
         bool sameDir   = (g_fills[fj].isBuy == fb);
         bool sameCat   = ((g_fills[fj].fillType == FILL_BUYLIMIT || g_fills[fj].fillType == FILL_SELLLIMIT) == fl);

         if(samePrice && sameTime && sameDir && sameCat)
            members[memberCount++] = j;
      }

      if(memberCount >= 2)
      {
         // This is a cluster
         g_clusterCount++;
         clusterSizeSum += memberCount;
         totalClusteredFills += memberCount;
         if(memberCount > (int)g_maxClusterSize)
            g_maxClusterSize = memberCount;

         for(int m = 0; m < memberCount; m++)
         {
            assigned[members[m]] = true;
            int fillIdx = gridIdx[members[m]];
            int cft = (int)g_fills[fillIdx].fillType;
            if(cft >= 0 && cft < 10) g_clusterByType[cft]++;
         }

         // ── Per-cluster detail capture for broker.rs fill model ──
         if(g_clusterDetailCount < MAX_CLUSTER_DETAILS)
         {
            int cd = g_clusterDetailCount;
            ArrayResize(g_clusterDetails, cd + 1);

            g_clusterDetails[cd].memberCount    = memberCount;
            g_clusterDetails[cd].fillPrice      = fp;
            g_clusterDetails[cd].dealTimeMsc    = ft;
            g_clusterDetails[cd].isBuy          = fb;
            g_clusterDetails[cd].isLimit        = fl;
            g_clusterDetails[cd].bestFitModel   = "";

            // Resize member arrays
            ArrayResize(g_clusterDetails[cd].memReqPrices,   memberCount);
            ArrayResize(g_clusterDetails[cd].memLagMs,       memberCount);
            ArrayResize(g_clusterDetails[cd].memSlipPts,     memberCount);
            ArrayResize(g_clusterDetails[cd].memTickAtDeal,  memberCount);
            ArrayResize(g_clusterDetails[cd].memVerifyDelta, memberCount);

            // Count distinct requested prices + gather member data
            double uniqueReq[];
            int    uniqueReqCount = 0;
            double sumLag = 0, sumSlip = 0, sumTickDelta = 0, sumDriftRate = 0;
            double sumResLastTick = 0, sumResTrigger = 0, sumResLagInterp = 0, sumResWorst = 0;
            int    validTickCount = 0;
            double maxLagInCluster = 0;

            // First pass: find max lag for interpolation denominator
            for(int m = 0; m < memberCount; m++)
            {
               int fIdx = gridIdx[members[m]];
               if(g_fills[fIdx].lagMs > maxLagInCluster)
                  maxLagInCluster = g_fills[fIdx].lagMs;
            }
            if(maxLagInCluster < 1.0) maxLagInCluster = 1.0;  // prevent div-by-zero

            // Second pass: compute all metrics
            for(int m = 0; m < memberCount; m++)
            {
               int fIdx = gridIdx[members[m]];
               double reqP  = g_fills[fIdx].requestedPrice;
               double tickP = g_fills[fIdx].tickPriceAtDeal;
               double lag   = g_fills[fIdx].lagMs;
               double slip  = g_fills[fIdx].slippagePts;
               double vdelta = g_fills[fIdx].priceVerifyDelta;

               // Store raw member data
               g_clusterDetails[cd].memReqPrices[m]   = reqP;
               g_clusterDetails[cd].memLagMs[m]       = lag;
               g_clusterDetails[cd].memSlipPts[m]     = slip;
               g_clusterDetails[cd].memTickAtDeal[m]   = tickP;
               g_clusterDetails[cd].memVerifyDelta[m]  = vdelta;

               sumLag  += lag;
               sumSlip += slip;

               // Track distinct requested prices
               bool found = false;
               for(int u = 0; u < uniqueReqCount; u++)
               {
                  if(MathAbs(uniqueReq[u] - reqP) < ptTol) { found = true; break; }
               }
               if(!found)
               {
                  ArrayResize(uniqueReq, uniqueReqCount + 1);
                  uniqueReq[uniqueReqCount++] = reqP;
               }

               // Model residuals (only if tickPriceAtDeal is valid)
               if(tickP > 0.0001)
               {
                  validTickCount++;
                  double absDeltaTick = MathAbs(fp - tickP) / g_point;
                  double absDeltaReq  = MathAbs(fp - reqP) / g_point;
                  sumTickDelta   += absDeltaTick;
                  sumResLastTick += absDeltaTick;
                  sumResTrigger  += absDeltaReq;

                  // Lag-interpolated: price between trigger and tick proportional to lag ratio
                  double interpPrice = reqP + (tickP - reqP) * (lag / maxLagInCluster);
                  sumResLagInterp += MathAbs(fp - interpPrice) / g_point;

                  // Worst price: most adverse for the trader
                  double worstP = fb ? MathMax(reqP, tickP) : MathMin(reqP, tickP);
                  sumResWorst += MathAbs(fp - worstP) / g_point;

                  // Tick drift rate (pts/ms)
                  if(lag > 0.5)
                     sumDriftRate += ((tickP - reqP) / g_point) / lag;
               }
            }

            g_clusterDetails[cd].distinctReqPrices  = uniqueReqCount;
            g_clusterDetails[cd].isSameLevelCluster = (uniqueReqCount <= 1);
            g_clusterDetails[cd].meanLagMs         = (memberCount > 0) ? sumLag / memberCount : 0;
            g_clusterDetails[cd].meanSlippagePts   = (memberCount > 0) ? sumSlip / memberCount : 0;

            if(validTickCount > 0)
            {
               g_clusterDetails[cd].meanTickDeltaPts   = sumTickDelta / validTickCount;
               g_clusterDetails[cd].residualLastTick    = sumResLastTick / validTickCount;
               g_clusterDetails[cd].residualTrigger     = sumResTrigger / validTickCount;
               g_clusterDetails[cd].residualLagInterp   = sumResLagInterp / validTickCount;
               g_clusterDetails[cd].residualWorstPrice  = sumResWorst / validTickCount;
               g_clusterDetails[cd].tickDriftRate       = sumDriftRate / validTickCount;

               // Classify best-fit model (smallest residual wins)
               double minRes = g_clusterDetails[cd].residualLastTick;
               string bestModel = "last_tick";
               if(g_clusterDetails[cd].residualTrigger < minRes)
               { minRes = g_clusterDetails[cd].residualTrigger; bestModel = "trigger_price"; }
               if(g_clusterDetails[cd].residualLagInterp < minRes)
               { minRes = g_clusterDetails[cd].residualLagInterp; bestModel = "lag_interpolated"; }
               if(g_clusterDetails[cd].residualWorstPrice < minRes)
               { minRes = g_clusterDetails[cd].residualWorstPrice; bestModel = "worst_price"; }

               g_clusterDetails[cd].bestFitModel = bestModel;

               // Aggregate fill model classification (weighted by member count)
               if(bestModel == "last_tick")          g_fmLastTick   += memberCount;
               else if(bestModel == "trigger_price") g_fmTrigger    += memberCount;
               else if(bestModel == "lag_interpolated") g_fmLagInterp += memberCount;
               else                                  g_fmWorstPrice += memberCount;
               g_fmTotal += memberCount;
            }
            else
            {
               // No valid tick data — unclassifiable
               g_clusterDetails[cd].meanTickDeltaPts  = 0;
               g_clusterDetails[cd].residualLastTick   = 0;
               g_clusterDetails[cd].residualTrigger    = 0;
               g_clusterDetails[cd].residualLagInterp  = 0;
               g_clusterDetails[cd].residualWorstPrice = 0;
               g_clusterDetails[cd].tickDriftRate      = 0;
               g_clusterDetails[cd].bestFitModel       = "unclassifiable";
               g_fmUnclassifiable += memberCount;
            }

            g_clusterDetailCount++;
         }
      }
      else
      {
         assigned[i] = true;
         g_isolatedFills++;
      }
   }

   g_avgClusterSize = (g_clusterCount > 0) ? clusterSizeSum / g_clusterCount : 0;
   g_avgInterClusterGap = 0;  // Not applicable for price-based clustering
   // Ratio = clustered fills / total grid fills (ALL grid fills, not just deviated)
   g_clusterRatio = (nGridFills > 0) ? (double)totalClusteredFills / (double)nGridFills : 0;

   // Per-type clustering percentages
   for(int ct2 = 2; ct2 <= 5; ct2++)
   {
      g_clusterByTypePct[ct2] = (g_countByType[ct2] > 0)
         ? 100.0 * g_clusterByType[ct2] / g_countByType[ct2] : 0;
   }
   // Max cluster as % of total grid fills
   g_maxClusterPct = (nGridFills > 0) ? 100.0 * g_maxClusterSize / nGridFills : 0;

   // Cluster verdict based on 2026 A-book benchmarks
   // Note: size-2 clusters are common coincidence on fast brokers (same-tick fills).
   // Only escalate to CAUTION/MANIPULATION when BOTH ratio is elevated AND cluster sizes
   // indicate genuine batch processing (size > 2 means 3+ orders grouped deliberately).
   {
      double clPct = g_clusterRatio * 100.0;
      bool largeClusters = ((int)g_maxClusterSize > 2);  // Size-2 = coincidence, size-3+ = batching

      if((clPct > STD_CLUSTER_CAUTION_PCT && largeClusters) || (int)g_maxClusterSize > STD_MAX_CLUSTER_MANIP)
         g_clusterVerdict = "MANIPULATION";
      else if((clPct > STD_CLUSTER_FAIR_PCT && largeClusters) || (int)g_maxClusterSize > STD_MAX_CLUSTER_FAIR)
         g_clusterVerdict = "CAUTION";
      else
         g_clusterVerdict = "FAIR";
   }

   // ── Fill model regression: fill_price ~ alpha * requested + beta * tick_at_deal ──
   // 2-variable OLS across all clustered fills with valid tick data.
   // broker.rs uses alpha/beta directly to emulate the broker's fill pricing.
   {
      double Srr = 0, Srt = 0, Stt = 0, Srf = 0, Stf = 0;
      int regN = 0;
      for(int cd2 = 0; cd2 < g_clusterDetailCount; cd2++)
      {
         for(int m2 = 0; m2 < g_clusterDetails[cd2].memberCount; m2++)
         {
            double tickP = g_clusterDetails[cd2].memTickAtDeal[m2];
            if(tickP < 0.0001) continue;  // skip fills without tick data
            double reqP  = g_clusterDetails[cd2].memReqPrices[m2];
            double fillP = g_clusterDetails[cd2].fillPrice;
            // Normalize to points from reqP to avoid numerical issues with large prices
            double r = (reqP - reqP);  // = 0 in normalized space; use raw prices instead
            // Actually use raw prices — the 2x2 system handles it fine for FX scales
            Srr += reqP * reqP;
            Srt += reqP * tickP;
            Stt += tickP * tickP;
            Srf += reqP * fillP;
            Stf += tickP * fillP;
            regN++;
         }
      }
      // Solve 2x2 normal equations: [Srr Srt; Srt Stt] * [a; b] = [Srf; Stf]
      double det = Srr * Stt - Srt * Srt;
      if(regN >= 4 && MathAbs(det) > 1e-20)
      {
         g_fmAlpha = (Srf * Stt - Stf * Srt) / det;
         g_fmBeta  = (Srr * Stf - Srt * Srf) / det;
      }
      else
      {
         // Insufficient data or singular — fall back to simple classification
         g_fmAlpha = 0;
         g_fmBeta  = 0;
      }

      // Determine dominant model
      int maxFm = g_fmLastTick;
      g_fmDominantModel = "last_tick";
      if(g_fmTrigger > maxFm)   { maxFm = g_fmTrigger;   g_fmDominantModel = "trigger_price"; }
      if(g_fmLagInterp > maxFm) { maxFm = g_fmLagInterp; g_fmDominantModel = "lag_interpolated"; }
      if(g_fmWorstPrice > maxFm){ maxFm = g_fmWorstPrice; g_fmDominantModel = "worst_price"; }
      if(g_fmTotal == 0) g_fmDominantModel = "insufficient_data";

      PrintFormat("FILL MODEL: %d classified (%d unclass) — last_tick:%d trigger:%d lag_interp:%d worst:%d — dominant=%s alpha=%.4f beta=%.4f",
         g_fmTotal, g_fmUnclassifiable, g_fmLastTick, g_fmTrigger, g_fmLagInterp, g_fmWorstPrice,
         g_fmDominantModel, g_fmAlpha, g_fmBeta);
   }

   // Gate: fill clustering is only forensically relevant when there is CLEAR
   // ASYMMETRY — stops filling off-trigger while limits fill on-trigger.
   // If stops and limits both fill at trigger price at similar rates, clustering
   // is normal market behavior. But if stops are pulled off-target while limits
   // fill perfectly, the off-trigger fills are evidence of manipulation.
   {
      double tcStopLag = 0, tcLimitLag = 0;
      int nStopTC = g_countByType[2] + g_countByType[3];
      int nLimitTC = g_countByType[4] + g_countByType[5];
      if(nStopTC > 0)
         tcStopLag = (g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) /
                     MathMax(1, nStopTC);
      if(nLimitTC > 0)
         tcLimitLag = (g_medianLag[4] * g_countByType[4] + g_medianLag[5] * g_countByType[5]) /
                      MathMax(1, nLimitTC);

      // Asymmetry detection — handle 0ms case properly:
      // If limits are ~0ms but stops are significant, that IS extreme asymmetry
      double tcSLR = 0;
      if(tcLimitLag > 10)
         tcSLR = tcStopLag / tcLimitLag;
      else if(nStopTC > 0 && nLimitTC > 0 && tcStopLag > 10)
         tcSLR = tcStopLag;  // Limits ~0ms, stops significant = extreme (use stop lag as ratio)

      double tcTPSLR = 0;
      if(g_medianLag[6] > 10 && g_medianLag[7] > 10)
         tcTPSLR = g_medianLag[7] / g_medianLag[6];
      else if(g_countByType[7] > 0 && g_countByType[6] > 0 && g_medianLag[7] > 10)
         tcTPSLR = g_medianLag[7];  // TP ~0ms, SL significant = extreme

      // Fill accuracy asymmetry: stops filling off-trigger while limits fill on-trigger
      double stopFairPct = (g_totalStopPriced > 0) ? (double)g_fairFillsStop / g_totalStopPriced * 100 : 100;
      double limitFairPct = (g_totalLimitPriced > 0) ? (double)g_fairFillsLimit / g_totalLimitPriced * 100 : 100;
      bool fillAccuracyAsymmetric = (g_totalStopPriced > 3 && g_totalLimitPriced > 3 &&
                                     limitFairPct > stopFairPct + 20);  // Limits 20%+ more accurate

      bool hasAsymmetry = (tcSLR > 2.0) || (tcTPSLR > 2.0) || fillAccuracyAsymmetric;

      if(!hasAsymmetry)
      {
         // No asymmetry detected — clustering is symmetric.
         // IMPORTANT: We no longer zero out clustering data because symmetric clustering
         // is STILL evidence of last-look / batch processing. The cluster verdict
         // was already computed on raw data. Keep it for the benchmark comparison.
         // The batchClassification (FAIR/CAUTION/MANIPULATION) remains separate from cluster verdict.
      }
   }


   //=== PART 2: PRICE-BASED BATCH DETECTION (actual fill damage assessment) ===
   // Includes grid fills (stops + limits) AND SL/TP fills — all have requestedPrice.
   // Groups by fillPrice: different requested levels filling at same price = batch.
   // Cross-referenced with fill clustering to classify broker behavior.

   // Collect all fills that have a trigger/requested price (grid + SL + TP)
   int pricedIdx[];
   int nPricedFills = 0;
   ArrayResize(pricedIdx, g_fillCount);
   for(int i = 0; i < g_fillCount; i++)
   {
      // Grid fills: stops and limits
      if(g_fills[i].fillType >= FILL_BUYSTOP && g_fills[i].fillType <= FILL_SELLLIMIT)
         pricedIdx[nPricedFills++] = i;
      // SL and TP fills
      else if(g_fills[i].fillType == FILL_TP || g_fills[i].fillType == FILL_SL)
         pricedIdx[nPricedFills++] = i;
   }
   ArrayResize(pricedIdx, nPricedFills);
   g_totalPricedFills = nPricedFills;

   g_batchCount = 0;
   g_individualFills = 0;
   g_maxBatchSize = 0;
   g_totalBatchedFills = 0;
   g_batchAdvantagePts = 0;
   g_fairFills = 0;
   g_fairFillsStop = 0;
   g_fairFillsLimit = 0;
   g_totalStopPriced = 0;
   g_totalLimitPriced = 0;
   g_batchTimeSpanMs = 0;
   g_maxBatchTimeSpanMs = 0;
   double batchSizeSum2 = 0;
   double batchTimeSpans[];
   ArrayResize(batchTimeSpans, nPricedFills);
   int batchTimeSpanCount = 0;

   double priceTolerance = g_point * 0.5;

   if(nPricedFills > 0)
   {
      // Sort by fillPrice for grouping (selection sort, typically < few hundred)
      int sorted[];
      ArrayResize(sorted, nPricedFills);
      for(int i = 0; i < nPricedFills; i++) sorted[i] = pricedIdx[i];

      for(int i = 0; i < nPricedFills - 1; i++)
      {
         int minIdx = i;
         for(int j = i + 1; j < nPricedFills; j++)
         {
            if(g_fills[sorted[j]].fillPrice < g_fills[sorted[minIdx]].fillPrice)
               minIdx = j;
         }
         if(minIdx != i)
         {
            int tmp = sorted[i];
            sorted[i] = sorted[minIdx];
            sorted[minIdx] = tmp;
         }
      }

      // Walk sorted fills, group consecutive with same fillPrice
      int groupStart = 0;
      while(groupStart < nPricedFills)
      {
         double groupPrice = g_fills[sorted[groupStart]].fillPrice;
         int groupEnd = groupStart + 1;
         while(groupEnd < nPricedFills &&
               MathAbs(g_fills[sorted[groupEnd]].fillPrice - groupPrice) < priceTolerance)
            groupEnd++;

         int groupSize = groupEnd - groupStart;

         // Count DIFFERENT requestedPrices in this group
         int uniqueRequested = 1;
         double reqPrices[];
         ArrayResize(reqPrices, groupSize);
         for(int g = 0; g < groupSize; g++)
            reqPrices[g] = g_fills[sorted[groupStart + g]].requestedPrice;
         for(int g = 1; g < groupSize; g++)
         {
            bool found = false;
            for(int k = 0; k < g; k++)
            {
               if(MathAbs(reqPrices[g] - reqPrices[k]) < priceTolerance)
               { found = true; break; }
            }
            if(!found) uniqueRequested++;
         }

         if(groupSize > 1 && uniqueRequested > 1)
         {
            // Batch: multiple different trigger levels filled at same price
            g_batchCount++;
            batchSizeSum2 += groupSize;
            g_totalBatchedFills += groupSize;
            if(groupSize > g_maxBatchSize)
               g_maxBatchSize = groupSize;

            // Broker advantage: sum |fillPrice - requestedPrice| per fill in points
            for(int g = 0; g < groupSize; g++)
            {
               int idx = sorted[groupStart + g];
               double drift = MathAbs(g_fills[idx].fillPrice - g_fills[idx].requestedPrice) / g_point;
               g_batchAdvantagePts += drift;
            }

            // Time span within batch (first→last fill = broker hold window)
            ulong minTime = ULONG_MAX, maxTime = 0;
            for(int g = 0; g < groupSize; g++)
            {
               int idx = sorted[groupStart + g];
               if(g_fills[idx].fillTimeMs < minTime) minTime = g_fills[idx].fillTimeMs;
               if(g_fills[idx].fillTimeMs > maxTime) maxTime = g_fills[idx].fillTimeMs;
            }
            double spanMs = (double)(maxTime - minTime);
            g_batchTimeSpanMs += spanMs;
            if(spanMs > g_maxBatchTimeSpanMs)
               g_maxBatchTimeSpanMs = spanMs;
            batchTimeSpans[batchTimeSpanCount++] = spanMs;
         }
         else
         {
            g_individualFills += groupSize;
         }

         // Count fair fills (fillPrice == requestedPrice) — total and per type
         for(int g = 0; g < groupSize; g++)
         {
            int idx = sorted[groupStart + g];
            bool isStopFill = (g_fills[idx].fillType == FILL_BUYSTOP || g_fills[idx].fillType == FILL_SELLSTOP);
            bool isLimitFill = (g_fills[idx].fillType == FILL_BUYLIMIT || g_fills[idx].fillType == FILL_SELLLIMIT);
            if(isStopFill)  g_totalStopPriced++;
            if(isLimitFill) g_totalLimitPriced++;
            if(MathAbs(g_fills[idx].fillPrice - g_fills[idx].requestedPrice) < priceTolerance)
            {
               g_fairFills++;
               if(isStopFill)  g_fairFillsStop++;
               if(isLimitFill) g_fairFillsLimit++;
            }
         }

         groupStart = groupEnd;
      }
   }

   g_avgBatchSize = (g_batchCount > 0) ? batchSizeSum2 / g_batchCount : 0;
   g_batchRatio = (nPricedFills > 0) ? (double)g_totalBatchedFills / (double)nPricedFills : 0;
   g_avgBatchAdvantagePts = (g_totalBatchedFills > 0) ? g_batchAdvantagePts / g_totalBatchedFills : 0;
   g_avgBatchTimeSpanMs = (g_batchCount > 0) ? g_batchTimeSpanMs / g_batchCount : 0;

   // Median batch time span
   g_medBatchTimeSpanMs = 0;
   if(batchTimeSpanCount > 0)
   {
      ArrayResize(batchTimeSpans, batchTimeSpanCount);
      ArraySort(batchTimeSpans);
      if(batchTimeSpanCount % 2 == 1)
         g_medBatchTimeSpanMs = batchTimeSpans[batchTimeSpanCount / 2];
      else
         g_medBatchTimeSpanMs = (batchTimeSpans[batchTimeSpanCount / 2 - 1] +
                                 batchTimeSpans[batchTimeSpanCount / 2]) / 2.0;
   }

   //=== PART 3: CLASSIFY BROKER BEHAVIOR ===
   // MANIPULATION = genuine red flags: adverse-only slippage, excessive lag with market fills,
   //                stop rejection after trigger
   // Stop/limit and SL/TP ratio asymmetry is ASYMMETRIC — broker-favorable delay applies to all operations
   // including EA-initiated close operations, causing losses on retracements
   //
   // We use the per-type median lags already computed in g_medianLag[]:
   //   [2]=buy_stop, [3]=sell_stop, [4]=buy_limit, [5]=sell_limit, [6]=TP, [7]=SL
   double medStopLagC = 0, medLimitLagC = 0;
   if(g_countByType[2] > 0 || g_countByType[3] > 0)
      medStopLagC = (g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) /
                    MathMax(1, g_countByType[2] + g_countByType[3]);
   if(g_countByType[4] > 0 || g_countByType[5] > 0)
      medLimitLagC = (g_medianLag[4] * g_countByType[4] + g_medianLag[5] * g_countByType[5]) /
                     MathMax(1, g_countByType[4] + g_countByType[5]);

   // Asymmetry ratio: tracked as evidence of discriminatory execution
   double stopLimitRatioC = 0;
   int nStopC = g_countByType[2] + g_countByType[3];
   int nLimitC = g_countByType[4] + g_countByType[5];
   if(medLimitLagC > 10)
      stopLimitRatioC = medStopLagC / medLimitLagC;
   else if(nStopC > 0 && nLimitC > 0 && medStopLagC > 10)
      stopLimitRatioC = medStopLagC;  // Limits ~0ms, stops significant = asymmetric delay

   double tpslRatioC = 0;
   if(g_medianLag[6] > 10 && g_medianLag[7] > 10)
      tpslRatioC = g_medianLag[7] / g_medianLag[6];
   else if(g_countByType[7] > 0 && g_countByType[6] > 0 && g_medianLag[7] > 10)
      tpslRatioC = g_medianLag[7];  // TP ~0ms, SL significant = asymmetric delay

   // MANIPULATION requires excessive lag AND poor trigger-fill rate (<90%).
   // Asymmetric lag is ALWAYS concerning: the same delay infrastructure affects EA-initiated closes.
   // Check each order type separately: stops, limits, SL.

   // Trigger fill rates per type group
   int nStopClassified = (g_triggerFillCount[2] + g_triggerFillCount[3] +
                          g_marketFillCount[2] + g_marketFillCount[3]);
   double stopTriggerPct = (nStopClassified > 0)
      ? (double)(g_triggerFillCount[2] + g_triggerFillCount[3]) / nStopClassified * 100.0
      : 100.0;

   int nLimitClassified = (g_triggerFillCount[4] + g_triggerFillCount[5] +
                           g_marketFillCount[4] + g_marketFillCount[5]);
   double limitTriggerPct = (nLimitClassified > 0)
      ? (double)(g_triggerFillCount[4] + g_triggerFillCount[5]) / nLimitClassified * 100.0
      : 100.0;

   int nSLClassified = g_triggerFillCount[7] + g_marketFillCount[7];
   double slTriggerPct = (nSLClassified > 0)
      ? (double)g_triggerFillCount[7] / nSLClassified * 100.0
      : 100.0;

   // Classification logic — respects structural asymmetry of order types:
   //   STOPS/SL: Fill at MARKET after trigger (structural — not broker's fault).
   //             Judge on LAG ONLY. Low trigger fill % is expected, not a red flag.
   //   LIMITS/TP: Price guarantee (trigger price or better).
   //             Judge on TRIGGER FILL %. Low trigger fill % IS the broker's fault.
   //   ASYMMETRY: Stop/limit or SL/TP lag ratio > 2x is always a red flag —
   //             broker adding delay on top of structural asymmetry to worsen slippage.
   //   FAST + SYMMETRIC: Always FAIR regardless of trigger fill %.

   // Stops/SL: lag-based only (trigger fill % is informational, not diagnostic)
   bool stopRedFlag  = (medStopLagC > STD_FILL_MANIP_MS);
   bool stopCaution  = (medStopLagC > STD_FILL_SLOW_MS) && !stopRedFlag;
   bool slRedFlag    = (g_medianLag[7] > STD_TPSL_MANIP_MS);
   bool slCaution    = (g_medianLag[7] > STD_TPSL_SLOW_MS) && !slRedFlag;

   // Limits/TP: trigger fill % is the metric (these have price guarantees)
   bool limitRedFlag = (medLimitLagC > STD_FILL_SLOW_MS)   && (limitTriggerPct < 70.0);
   bool limitCaution = (medLimitLagC > STD_FILL_SLOW_MS)   && (limitTriggerPct < 90.0) && !limitRedFlag;

   // TP: limit-like, should fill at trigger or better
   int nTPClassified = g_triggerFillCount[6] + g_marketFillCount[6];
   double tpTriggerPct = (nTPClassified > 0)
      ? (double)g_triggerFillCount[6] / nTPClassified * 100.0 : 100.0;
   bool tpRedFlag    = (g_medianLag[6] > STD_TPSL_SLOW_MS) && (tpTriggerPct < 70.0);
   bool tpCaution    = (g_medianLag[6] > STD_TPSL_SLOW_MS) && (tpTriggerPct < 90.0) && !tpRedFlag;

   // Asymmetric lag is always a red flag (broker adding delay to worsen structural slippage)
   bool asymRedFlag = (stopLimitRatioC > 2.0) || (tpslRatioC > 2.0);

   // Clustering as an escalation factor:
   // Symmetric slow lag + high clustering = last-look NOT excluded
   // High clustering alone is a huge warning sign (batch processing = internalization)
   bool clusterEscalation = (g_clusterVerdict == "MANIPULATION");
   bool clusterCaution = (g_clusterVerdict == "CAUTION");

   if(asymRedFlag || stopRedFlag || limitRedFlag || slRedFlag || tpRedFlag)
      g_batchClassification = "MANIPULATION";
   else if(stopCaution || limitCaution || slCaution || tpCaution)
   {
      // Symmetric slow + heavy clustering → escalate to MANIPULATION
      // (slow symmetric lag + batch fills = last-look cannot be excluded)
      if(clusterEscalation)
         g_batchClassification = "MANIPULATION";
      else
         g_batchClassification = "CAUTION";
   }
   else if(clusterEscalation)
   {
      // Even with fast execution, heavy clustering indicates B-book internalization
      g_batchClassification = "CAUTION";
   }
   else
      g_batchClassification = "FAIR";

   // Classify rejections using measured broker asymmetry
   ClassifyRejections(medStopLagC, medLimitLagC, stopLimitRatioC);
   ClassifyFillRejections(medStopLagC, medLimitLagC, stopLimitRatioC);

   PrintFormat("STATISTICS: %d total fills across %d cycles", g_fillCount, g_cycleNum);
   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] > 0)
         PrintFormat("  %s: n=%d medLag=%.0f meanLag=%.0f slip=%.2f%s",
                     GetFillTypeName((ENUM_FILL_TYPE)t), g_countByType[t],
                     g_medianLag[t], g_meanLag[t], g_meanSlipSigned[t], g_unitLabel);
   }
   PrintFormat("  Fill Clustering: %d clusters, %d isolated, avg_size=%.1f, max=%d, ratio=%.0f%% of %d grid fills",
               g_clusterCount, g_isolatedFills, g_avgClusterSize, (int)g_maxClusterSize,
               g_clusterRatio * 100, nGridFills);
   PrintFormat("  Price Accuracy: %d/%d fills at trigger price (%.0f%% fair)",
               g_fairFills, nPricedFills,
               (nPricedFills > 0) ? (double)g_fairFills / nPricedFills * 100 : 0);
   if(g_batchCount > 0)
      PrintFormat("  Price Batching: %d batches, %d fills, avg_size=%.1f, max=%d, advantage=%.1f pts/fill, hold=%.0f ms",
                  g_batchCount, g_totalBatchedFills, g_avgBatchSize,
                  g_maxBatchSize, g_avgBatchAdvantagePts, g_avgBatchTimeSpanMs);
   else
      PrintFormat("  Price Batching: NONE");
   PrintFormat("  Classification: %s", g_batchClassification);
   PrintFormat("  Cluster Verdict: %s (vs 2026 A-book: ≤%.0f%% fair, ≤%.0f%% caution)",
               g_clusterVerdict, STD_CLUSTER_FAIR_PCT, STD_CLUSTER_CAUTION_PCT);
   PrintFormat("  TP/SL Triggers: %d total (%.0f%% TP favorable, %.0f%% SL adverse), slip asym=%.1fx",
               g_tpslTotalTriggers, g_tpslFavorPct, g_tpslAdversePct, g_tpslSlipAsymRatio);
   PrintFormat("  Per-type clustering: BuyStop=%.0f%%, SellStop=%.0f%%, BuyLimit=%.0f%%, SellLimit=%.0f%%",
               g_clusterByTypePct[2], g_clusterByTypePct[3], g_clusterByTypePct[4], g_clusterByTypePct[5]);
}


//+------------------------------------------------------------------+
//| VIRTUAL DEALER PLUGIN (VDP) DETECTION                              |
//| Analyzes execution lag patterns for signatures of MetaTrader's     |
//| Virtual Dealer Plugin or similar dealer intervention tools.        |
//| VDP fingerprints: whole-second delays, flat distribution,          |
//| order-type discrimination, delay in 500ms-15s range.               |
//| Even WITHOUT VDP: any >2x asymmetry is flagged as a red flag.     |
//+------------------------------------------------------------------+
void DetectVirtualDealer()
{
   // Reset all VDP globals
   g_vdpScore = 0; g_vdpVerdict = "NOT DETECTED";
   g_vdpWholeSecCluster = false; g_vdpWholeSecPct = 0;
   g_vdpDelayRange = false;
   g_vdpAdverseMedian = 0; g_vdpFavorMedian = 0; g_vdpLagRatio = 0;
   g_vdpFlatDistribution = false; g_vdpIQRatio = 0;
   g_vdpOrderTypeDiscrim = false;
   g_vdpFlagsTriggered = 0;
   g_vdpAdverseCount = 0; g_vdpFavorCount = 0;

   // Collect raw lag values for adverse (stops=2,3, SL=7) and favorable (limits=4,5, TP=6) types
   double advLags[];  // Broker-profitable: stops + SL
   double favLags[];  // Broker-costly: limits + TP
   ArrayResize(advLags, g_fillCount);
   ArrayResize(favLags, g_fillCount);
   int nAdv = 0, nFav = 0;

   for(int i = 0; i < g_fillCount; i++)
   {
      if(!g_fills[i].lagValid) continue;
      int t = (int)g_fills[i].fillType;
      double lag = g_fills[i].brokerExecMs;

      if(t == 2 || t == 3 || t == 7) // BuyStop, SellStop, SL
         advLags[nAdv++] = lag;
      else if(t == 4 || t == 5 || t == 6) // BuyLimit, SellLimit, TP
         favLags[nFav++] = lag;
   }
   ArrayResize(advLags, nAdv);
   ArrayResize(favLags, nFav);
   g_vdpAdverseCount = nAdv;
   g_vdpFavorCount = nFav;

   if(nAdv < 3) return; // Not enough data for meaningful analysis

   // Sort for percentile calculations
   if(nAdv > 1) ArraySort(advLags);
   if(nFav > 1) ArraySort(favLags);

   // --- TEST 1: Adverse vs Favorable lag ratio (asymmetry) ---
   g_vdpAdverseMedian = CalcMedianFromArray(advLags, nAdv);
   g_vdpFavorMedian = (nFav > 0) ? CalcMedianFromArray(favLags, nFav) : 0;
   if(g_vdpFavorMedian < 1.0) g_vdpFavorMedian = 1.0;
   g_vdpLagRatio = g_vdpAdverseMedian / g_vdpFavorMedian;

   // Any asymmetry >2x is a red flag regardless of VDP
   if(g_vdpLagRatio > 2.0)
      g_vdpFlagsTriggered++;

   // --- TEST 2: Delay magnitude in VDP range ---
   // VDP typically configured 500ms-15000ms. Natural ECN: 20-200ms.
   if(g_vdpAdverseMedian > 500.0)
   {
      g_vdpDelayRange = true;
      g_vdpFlagsTriggered++;
   }

   // --- TEST 3: Whole-second clustering ---
   // VDP is configured in integer seconds. Check if fills cluster at 1000ms boundaries.
   int wholeSecCount = 0;
   for(int i = 0; i < nAdv; i++)
   {
      double ms = advLags[i];
      double nearestSec = MathRound(ms / 1000.0) * 1000.0;
      if(MathAbs(ms - nearestSec) <= 100.0 && nearestSec >= 500.0) // Within 100ms of a whole second
         wholeSecCount++;
   }
   g_vdpWholeSecPct = (nAdv > 0) ? (double)wholeSecCount / nAdv * 100.0 : 0;
   if(g_vdpWholeSecPct > 40.0 && nAdv >= 5) // >40% cluster at whole seconds
   {
      g_vdpWholeSecCluster = true;
      g_vdpFlagsTriggered++;
   }

   // --- TEST 4: Distribution shape (flat/uniform vs log-normal) ---
   // VDP: uniform distribution in [min_delay, max_delay] → low IQR/median ratio
   // Natural: log-normal → high IQR/median ratio (long tail)
   // Use interquartile range (IQR) relative to median
   if(nAdv >= 8)
   {
      double q1 = advLags[(int)(nAdv * 0.25)];
      double q3 = advLags[(int)(nAdv * 0.75)];
      double iqr = q3 - q1;
      g_vdpIQRatio = (g_vdpAdverseMedian > 1.0) ? iqr / g_vdpAdverseMedian : 0;

      // VDP: tight band → IQR/median < 0.5 AND delays >500ms
      // Natural: spread → IQR/median > 1.0 typically
      if(g_vdpIQRatio < 0.5 && g_vdpAdverseMedian > 500.0)
      {
         g_vdpFlatDistribution = true;
         g_vdpFlagsTriggered++;
      }
   }

   // --- TEST 5: Order-type discrimination ---
   // VDP has separate DelaySecs_Sl*, DelaySecs_Pending* settings.
   // If stops and SL have distinctly different median delays, it suggests per-type config.
   double medStop = 0, medSL = 0;
   int nStops = g_lagValidCount[2] + g_lagValidCount[3];
   int nSL = g_lagValidCount[7];
   if(nStops > 0 && nSL > 0)
   {
      medStop = (g_lagValidCount[2] > 0 && g_lagValidCount[3] > 0) ?
         (g_medianLag[2] * g_lagValidCount[2] + g_medianLag[3] * g_lagValidCount[3]) / nStops :
         (g_lagValidCount[2] > 0 ? g_medianLag[2] : g_medianLag[3]);
      medSL = g_medianLag[7];

      // If stop delay and SL delay differ by >50% AND both >500ms, suggests separate VDP config
      double typeRatio = (medSL > medStop) ? medSL / MathMax(1, medStop) : medStop / MathMax(1, medSL);
      if(typeRatio > 1.5 && medStop > 500.0 && medSL > 500.0)
      {
         g_vdpOrderTypeDiscrim = true;
         g_vdpFlagsTriggered++;
      }
   }

   // --- Compute VDP score and verdict ---
   // Each flag = 20 points. Plus bonus for extreme values.
   g_vdpScore = g_vdpFlagsTriggered * 20.0;

   // Bonus for extreme asymmetry
   if(g_vdpLagRatio > 10.0) g_vdpScore += 15;
   else if(g_vdpLagRatio > 5.0) g_vdpScore += 10;

   // Bonus for extreme delay
   if(g_vdpAdverseMedian > 3000.0) g_vdpScore += 10;
   else if(g_vdpAdverseMedian > 1000.0) g_vdpScore += 5;

   // Cap at 100
   if(g_vdpScore > 100) g_vdpScore = 100;

   // Verdict thresholds
   if(g_vdpScore >= 80)       g_vdpVerdict = "CONFIRMED";
   else if(g_vdpScore >= 50)  g_vdpVerdict = "PROBABLE";
   else if(g_vdpScore >= 25)  g_vdpVerdict = "POSSIBLE";
   else                        g_vdpVerdict = "NOT DETECTED";

   // IMPORTANT: Even if VDP is not detected, asymmetry alone is a violation
   // This is handled separately in the panel/PDF/HTML — any ratio >2x is RED

   PrintFormat("VDP Detection: score=%.0f verdict=%s flags=%d ratio=%.1fx adv_med=%.0fms fav_med=%.0fms",
      g_vdpScore, g_vdpVerdict, g_vdpFlagsTriggered, g_vdpLagRatio,
      g_vdpAdverseMedian, g_vdpFavorMedian);
   PrintFormat("  WholeSec: %.0f%% (%s)  DelayRange: %s  FlatDist: %s (IQR/med=%.2f)  TypeDiscrim: %s",
      g_vdpWholeSecPct, g_vdpWholeSecCluster ? "YES" : "no",
      g_vdpDelayRange ? "YES" : "no",
      g_vdpFlatDistribution ? "YES" : "no", g_vdpIQRatio,
      g_vdpOrderTypeDiscrim ? "YES" : "no");
}


//+------------------------------------------------------------------+
//| PREVIOUS DAY TICK-BASED DAMAGE PROJECTION (v1.17)                  |
//| Pulls the full previous trading day tick history, slides a window  |
//| equal to the measured median broker lag across all ticks, and      |
//| calculates the average OHLC range within that window. This gives  |
//| the real-world average slippage the broker's hold time causes,     |
//| accounting for both volatile and quiet market periods.             |
//+------------------------------------------------------------------+
void AnalyzePreviousDayDamage()
{
   // Step 1: Determine the dominant measured broker lag (weighted avg across fill types)
   double totalWeightedLag = 0;
   int    totalFills = 0;
   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] > 0 && g_medianLag[t] > 0)
      {
         totalWeightedLag += g_medianLag[t] * g_countByType[t];
         totalFills += g_countByType[t];
      }
   }
   if(totalFills == 0)
   {
      PrintFormat("PrevDay: No fills with measured lag — skipping damage projection");
      return;
   }
   double avgLagMs = totalWeightedLag / totalFills;
   g_prevDayLagUsedMs = avgLagMs;
   PrintFormat("PrevDay: Using weighted avg broker lag = %.0f ms (%d fills)", avgLagMs, totalFills);

   // Step 2: Find the previous trading day by scanning backwards for actual tick data.
   // This works for all markets: forex (skips weekends), crypto (24/7), and holidays.
   datetime now = TimeCurrent();
   datetime dayStart = 0;
   datetime dayEnd = 0;
   MqlTick ticks[];
   int tickCount = 0;

   for(int daysBack = 1; daysBack <= 7; daysBack++)
   {
      datetime candidate = now - daysBack * 86400;
      MqlDateTime cdt;
      TimeToStruct(candidate, cdt);

      cdt.hour = 0; cdt.min = 0; cdt.sec = 0;
      datetime ds = StructToTime(cdt);
      cdt.hour = 23; cdt.min = 59; cdt.sec = 59;
      datetime de = StructToTime(cdt);

      int tc = CopyTicksRange(Symbol(), ticks, COPY_TICKS_ALL,
                  (ulong)ds * 1000, (ulong)de * 1000);
      if(tc >= 100)
      {
         dayStart = ds;
         dayEnd = de;
         tickCount = tc;
         PrintFormat("PrevDay: Found %d ticks on %s (%d days back)",
            tc, TimeToString(ds, TIME_DATE), daysBack);
         break;
      }
   }
   if(tickCount < 100)
   {
      PrintFormat("PrevDay: No trading day with sufficient ticks in last 7 days");
      return;
   }
   g_prevDayStart = dayStart;
   g_prevDayEnd = dayEnd;
   g_prevDayTickCount = tickCount;
   PrintFormat("PrevDay: Using %s to %s (%d ticks)",
      TimeToString(dayStart, TIME_DATE|TIME_MINUTES),
      TimeToString(dayEnd, TIME_DATE|TIME_MINUTES), tickCount);

   // Step 4: Slide a window of avgLagMs across the tick data
   // For each starting tick, find the tick nearest to tick.time_msc + lagMs
   // and compute the high-low range within that span.
   // When lag < tick spacing, extend the window to the next available tick
   // and scale the result by sqrt(lag / actualSpan) to approximate the true lag damage.
   long lagWindowMs = (long)MathRound(avgLagMs);
   if(lagWindowMs < 1) lagWindowMs = 1;

   // Compute median tick spacing to detect sparse data
   long totalSpanMs = ticks[tickCount - 1].time_msc - ticks[0].time_msc;
   long avgSpacingMs = totalSpanMs / MathMax(1, tickCount - 1);
   bool sparseData = (lagWindowMs < avgSpacingMs * 2);
   if(sparseData)
      PrintFormat("PrevDay: Lag window (%lld ms) < tick spacing (~%lld ms), using adaptive windows",
         lagWindowMs, avgSpacingMs);

   double rangeSum = 0;
   int    windowCount = 0;
   int    endIdx = 0;

   // Sample every Nth tick to keep computation reasonable (target ~5000 windows)
   int step = MathMax(1, tickCount / 5000);

   for(int i = 0; i < tickCount - 1; i += step)
   {
      long windowStart = ticks[i].time_msc;
      long windowEnd   = windowStart + lagWindowMs;

      // Advance endIdx forward-only to find the last tick within the window
      if(endIdx <= i) endIdx = i + 1;
      while(endIdx < tickCount - 1 && ticks[endIdx].time_msc < windowEnd)
         endIdx++;

      // For sparse data: endIdx is now at or past windowEnd (or at i+1 if next tick > windowEnd)
      // Accept the window if endIdx > i and the span isn't absurdly large (< 10x lag)
      if(endIdx <= i) continue;
      long actualSpanMs = ticks[endIdx].time_msc - ticks[i].time_msc;
      if(actualSpanMs <= 0) continue;
      if(actualSpanMs > lagWindowMs * 10) continue;  // skip market gaps

      // Calculate high-low within window using mid price (bid+ask)/2
      double windowHigh = -1e18;
      double windowLow  = 1e18;
      for(int j = i; j <= endIdx; j++)
      {
         double mid = (ticks[j].bid + ticks[j].ask) / 2.0;
         if(mid > windowHigh) windowHigh = mid;
         if(mid < windowLow)  windowLow  = mid;
      }

      double range = windowHigh - windowLow;
      if(range >= 0)
      {
         // Scale by sqrt(lag/actualSpan) when window was extended beyond lag
         // Price range scales as sqrt(time) under diffusion assumption
         if(actualSpanMs > lagWindowMs)
            range *= MathSqrt((double)lagWindowMs / (double)actualSpanMs);
         rangeSum += range;
         windowCount++;
      }
   }

   if(windowCount == 0)
   {
      PrintFormat("PrevDay: No valid windows computed (lag=%lld ms, avgSpacing=%lld ms, ticks=%d)",
         lagWindowMs, avgSpacingMs, tickCount);
      return;
   }

   // Step 5: Calculate average range and project damage
   g_prevDayWindowCount = windowCount;
   g_prevDayAvgRangePrice = rangeSum / windowCount;
   g_prevDayAvgRangePoints = g_prevDayAvgRangePrice / g_point;
   g_prevDayAvgRangePips = g_prevDayAvgRangePrice / g_pipSize;

   // Slippage per lot = avg range in price units / tick_size * tick_value
   // This is the average $ damage per 1 lot per fill caused by the broker's lag
   g_prevDaySlippagePerLot = (g_prevDayAvgRangePrice / g_tickSize) * g_tickValue;

   // Annual projections: 252 trading days
   // A "trade" here = one fill event. Typical day-trader does multiple round-trips.
   // We project per-lot-per-day because the user's actual volume varies.
   g_prevDayAnnualDamage1  = g_prevDaySlippagePerLot * 252;   // 1 lot/day
   g_prevDayAnnualDamage10 = g_prevDaySlippagePerLot * 10 * 252; // 10 lots/day

   g_prevDayDataValid = true;

   PrintFormat("PrevDay: %d windows, avg range = %.2f pips (%.1f pts, %.5f price) over %.0fms lag",
      windowCount, g_prevDayAvgRangePips, g_prevDayAvgRangePoints, g_prevDayAvgRangePrice, avgLagMs);
   PrintFormat("PrevDay: Slippage per lot = %s, Annual @1lot = %s, @10lot = %s",
      FormatMoney(g_prevDaySlippagePerLot),
      FormatMoney(g_prevDayAnnualDamage1),
      FormatMoney(g_prevDayAnnualDamage10));
}

//+------------------------------------------------------------------+
//| GENERATE TEXT REPORT — Full forensic document                      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| PDF BUILDER HELPERS                                                |
//+------------------------------------------------------------------+
int PdfW(int fh, string s)
{
   uchar arr[];
   StringToCharArray(s, arr, 0, WHOLE_ARRAY, CP_ACP);
   int len = ArraySize(arr) - 1;
   if(len > 0) FileWriteArray(fh, arr, 0, len);
   return len;
}

void PdfInit()
{
   ArrayResize(g_pdfPages, 0);
   g_pdfPageCount = 0;
   g_pdfY = PDF_TOP;
   g_pdfCurStream = "";
}

void PdfFinishPage()
{
   if(StringLen(g_pdfCurStream) == 0) return;
   // Footer separator line
   g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f 60 m %.1f 60 l S\n",
      PDF_ML, PDF_ML + PDF_CW);
   g_pdfCurStream += StringFormat("BT /F1 8 Tf 0.5 0.5 0.5 rg %.1f 42 Td (Page %d) Tj ET\n",
      PDF_W/2 - 15, g_pdfPageCount);
   int idx = ArraySize(g_pdfPages);
   ArrayResize(g_pdfPages, idx + 1);
   g_pdfPages[idx] = g_pdfCurStream;
   g_pdfCurStream = "";
}

void PdfNewPage()
{
   PdfFinishPage();
   g_pdfPageCount++;
   g_pdfY = PDF_TOP;
   g_pdfCurStream = "";
   g_pdfCurStream += StringFormat("0.75 0.75 0.75 RG 0.4 w %.1f %.1f m %.1f %.1f l S\n",
      PDF_ML, PDF_TOP + 12, PDF_ML + PDF_CW, PDF_TOP + 12);
   g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (Broker Forensic Analysis Report) Tj ET\n",
      PDF_ML, PDF_TOP + 16);
}

void PdfCheckY(double needed)
{
   if(g_pdfY - needed < PDF_BOT)
      PdfNewPage();
}

string PdfEsc(string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "(", "\\(");
   StringReplace(r, ")", "\\)");
   return r;
}

void PdfCenterBold(string text, double sz, double r, double g2, double b)
{
   PdfCheckY(sz + 6);
   double tw = StringLen(text) * sz * 0.62;
   double x = PDF_ML + (PDF_CW - tw) / 2;
   if(x < PDF_ML) x = PDF_ML;
   g_pdfCurStream += StringFormat("BT /F2 %.0f Tf %.3f %.3f %.3f rg %.1f %.1f Td (%s) Tj ET\n",
      sz, r, g2, b, x, g_pdfY, PdfEsc(text));
   g_pdfY -= sz + 6;
}

void PdfCenter(string text, double sz)
{
   PdfCheckY(sz + 3);
   double tw = StringLen(text) * sz * 0.48;
   double x = PDF_ML + (PDF_CW - tw) / 2;
   if(x < PDF_ML) x = PDF_ML;
   g_pdfCurStream += StringFormat("BT /F1 %.0f Tf 0.35 0.35 0.35 rg %.1f %.1f Td (%s) Tj ET\n",
      sz, x, g_pdfY, PdfEsc(text));
   g_pdfY -= sz + 3;
}

void PdfSection(string text)
{
   PdfCheckY(28);
   g_pdfY -= 10;
   g_pdfCurStream += StringFormat("0.18 0.35 0.65 rg %.1f %.1f %.1f 20 re f\n",
      PDF_ML, g_pdfY - 5, PDF_CW);
   g_pdfCurStream += StringFormat("BT /F2 11 Tf 1 1 1 rg %.1f %.1f Td (%s) Tj ET\n",
      PDF_ML + 6, g_pdfY, PdfEsc(text));
   g_pdfY -= 26;
}

void PdfSubSec(string text)
{
   PdfCheckY(18);
   g_pdfY -= 4;
   g_pdfCurStream += StringFormat("BT /F2 10 Tf 0.18 0.40 0.70 rg %.1f %.1f Td (%s) Tj ET\n",
      PDF_ML, g_pdfY, PdfEsc(text));
   g_pdfY -= 16;
}

void PdfBody(string text)
{
   int maxCh = (int)(PDF_CW / (9.0 * 0.48));
   while(StringLen(text) > 0)
   {
      PdfCheckY(13);
      string line;
      if(StringLen(text) <= maxCh)
      { line = text; text = ""; }
      else
      {
         int bp = maxCh;
         for(int i = maxCh; i > maxCh/2; i--)
         { if(StringGetCharacter(text, i) == ' ') { bp = i; break; } }
         line = StringSubstr(text, 0, bp);
         text = StringSubstr(text, bp);
         StringTrimLeft(text);
      }
      g_pdfCurStream += StringFormat("BT /F1 9 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
         PDF_ML, g_pdfY, PdfEsc(line));
      g_pdfY -= 13;
   }
}

void PdfBodyBold(string text)
{
   int maxCh = (int)(PDF_CW / (9.0 * 0.52));
   while(StringLen(text) > 0)
   {
      PdfCheckY(13);
      string line;
      if(StringLen(text) <= maxCh)
      { line = text; text = ""; }
      else
      {
         int bp = maxCh;
         for(int i = maxCh; i > maxCh/2; i--)
         { if(StringGetCharacter(text, i) == ' ') { bp = i; break; } }
         line = StringSubstr(text, 0, bp);
         text = StringSubstr(text, bp);
         StringTrimLeft(text);
      }
      g_pdfCurStream += StringFormat("BT /F2 9 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
         PDF_ML, g_pdfY, PdfEsc(line));
      g_pdfY -= 13;
   }
}

void PdfBodyColor(string text, double r, double g2, double b)
{
   int maxCh = (int)(PDF_CW / (9.0 * 0.52));
   while(StringLen(text) > 0)
   {
      PdfCheckY(13);
      string line;
      if(StringLen(text) <= maxCh)
      { line = text; text = ""; }
      else
      {
         int bp = maxCh;
         for(int i = maxCh; i > maxCh/2; i--)
         { if(StringGetCharacter(text, i) == ' ') { bp = i; break; } }
         line = StringSubstr(text, 0, bp);
         text = StringSubstr(text, bp);
         StringTrimLeft(text);
      }
      g_pdfCurStream += StringFormat("BT /F2 9 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
         r, g2, b, PDF_ML, g_pdfY, PdfEsc(line));
      g_pdfY -= 13;
   }
}

void PdfHRule()
{
   PdfCheckY(14);
   g_pdfY -= 4;
   g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f m %.1f %.1f l S\n",
      PDF_ML, g_pdfY, PDF_ML + PDF_CW, g_pdfY);
   g_pdfY -= 10;
}

void PdfSpace(double pts)
{
   if(g_pdfY - pts < PDF_BOT && pts < 100)
      PdfNewPage();
   else
      g_pdfY -= pts;
}

void PdfKV(string key, string val)
{
   double valX = PDF_ML + 140;
   double valW = PDF_CW - 140;
   int maxCh = (int)(valW / (9.0 * 0.48));
   PdfCheckY(13);
   g_pdfCurStream += StringFormat("BT /F2 9 Tf 0.3 0.3 0.3 rg %.1f %.1f Td (%s) Tj ET\n",
      PDF_ML, g_pdfY, PdfEsc(key));
   // Wrap value text if too long
   bool firstLine = true;
   while(StringLen(val) > 0)
   {
      if(!firstLine) PdfCheckY(13);
      string line;
      if(StringLen(val) <= maxCh)
      { line = val; val = ""; }
      else
      {
         int bp = maxCh;
         for(int i = maxCh; i > maxCh/2; i--)
         { if(StringGetCharacter(val, i) == ' ') { bp = i; break; } }
         line = StringSubstr(val, 0, bp);
         val = StringSubstr(val, bp);
         StringTrimLeft(val);
      }
      g_pdfCurStream += StringFormat("BT /F1 9 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
         valX, g_pdfY, PdfEsc(line));
      g_pdfY -= 13;
      firstLine = false;
   }
}

// Draw a stat box: colored background rectangle with centered value and label below
void PdfStatBox(double x, double w, double h, string value, string label,
                double vr, double vg2, double vb)
{
   double boxY = g_pdfY - h;
   // Box background
   g_pdfCurStream += StringFormat("0.14 0.14 0.22 rg %.1f %.1f %.1f %.1f re f\n",
      x, boxY, w, h);
   // Border
   g_pdfCurStream += StringFormat("0.29 0.56 0.85 RG 0.5 w %.1f %.1f %.1f %.1f re S\n",
      x, boxY, w, h);
   // Value centered
   double valSz = 16;
   if(StringLen(value) > 8) valSz = 12;
   double tw = StringLen(value) * valSz * 0.5;
   double vx = x + (w - tw) / 2;
   if(vx < x + 4) vx = x + 4;
   g_pdfCurStream += StringFormat("BT /F2 %.0f Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
      valSz, vr, vg2, vb, vx, boxY + h/2 + 2, PdfEsc(value));
   // Label centered below value
   double lw = StringLen(label) * 7 * 0.45;
   double lx = x + (w - lw) / 2;
   if(lx < x + 4) lx = x + 4;
   g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (%s) Tj ET\n",
      lx, boxY + h/2 - 14, PdfEsc(label));
}

// Draw a table row with columns: text, value, standard, assessment (colored)
void PdfTableRow(string col1, string col2, string col3, string col4,
                 double cr, double cg, double cb)
{
   PdfCheckY(14);
   // Custom column positions: 22% / 40% / 18% / 20% of content width
   double x1 = PDF_ML;
   double x2 = PDF_ML + PDF_CW * 0.22;
   double x3 = PDF_ML + PDF_CW * 0.62;
   double x4 = PDF_ML + PDF_CW * 0.80;
   g_pdfCurStream += StringFormat("BT /F1 8 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
      x1 + 4, g_pdfY, PdfEsc(col1));
   g_pdfCurStream += StringFormat("BT /F2 8 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
      x2 + 4, g_pdfY, PdfEsc(col2));
   g_pdfCurStream += StringFormat("BT /F1 8 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n",
      x3 + 4, g_pdfY, PdfEsc(col3));
   g_pdfCurStream += StringFormat("BT /F2 8 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
      cr, cg, cb, x4 + 4, g_pdfY, PdfEsc(col4));
   // Row separator
   g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
      PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
   g_pdfY -= 14;
}

// Table header row
void PdfTableHeader(string col1, string col2, string col3, string col4)
{
   PdfCheckY(18);
   // Custom column positions: 22% / 40% / 18% / 20% of content width
   double x1 = PDF_ML;
   double x2 = PDF_ML + PDF_CW * 0.22;
   double x3 = PDF_ML + PDF_CW * 0.62;
   double x4 = PDF_ML + PDF_CW * 0.80;
   // Header background
   g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 14 re f\n",
      PDF_ML, g_pdfY - 4, PDF_CW);
   g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (%s) Tj ET\n",
      x1 + 4, g_pdfY, PdfEsc(col1));
   g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (%s) Tj ET\n",
      x2 + 4, g_pdfY, PdfEsc(col2));
   g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (%s) Tj ET\n",
      x3 + 4, g_pdfY, PdfEsc(col3));
   g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (%s) Tj ET\n",
      x4 + 4, g_pdfY, PdfEsc(col4));
   g_pdfY -= 18;
}

void PdfWriteFile(string filename)
{
   int fh = FileOpen(filename, FILE_WRITE | FILE_BIN | FILE_COMMON);
   if(fh == INVALID_HANDLE)
   {
      PrintFormat("ERROR: Cannot create PDF: %s", filename);
      return;
   }

   int nPages = ArraySize(g_pdfPages);
   if(nPages == 0) { FileClose(fh); return; }

   // Objects: 1=Catalog, 2=Pages, 3-5=Fonts, 6..5+N=PageObjs, 6+N..5+2N=Streams
   int totalObj = 5 + 2 * nPages;
   long offsets[];
   ArrayResize(offsets, totalObj + 1);
   long pos = 0;

   pos += PdfW(fh, "%PDF-1.4\n");

   offsets[1] = pos;
   pos += PdfW(fh, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

   offsets[2] = pos;
   string kids = "[";
   for(int p = 0; p < nPages; p++)
   {
      if(p > 0) kids += " ";
      kids += IntegerToString(6 + p) + " 0 R";
   }
   kids += "]";
   pos += PdfW(fh, StringFormat("2 0 obj\n<< /Type /Pages /Kids %s /Count %d >>\nendobj\n", kids, nPages));

   offsets[3] = pos;
   pos += PdfW(fh, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n");
   offsets[4] = pos;
   pos += PdfW(fh, "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>\nendobj\n");
   offsets[5] = pos;
   pos += PdfW(fh, "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>\nendobj\n");

   for(int p = 0; p < nPages; p++)
   {
      int pgId = 6 + p;
      int stId = 6 + nPages + p;
      offsets[pgId] = pos;
      pos += PdfW(fh, StringFormat("%d 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
         "/Contents %d 0 R /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> >>\nendobj\n",
         pgId, stId));
   }

   for(int p = 0; p < nPages; p++)
   {
      int stId = 6 + nPages + p;
      string content = g_pdfPages[p];
      uchar cArr[];
      StringToCharArray(content, cArr, 0, WHOLE_ARRAY, CP_ACP);
      int cLen = ArraySize(cArr) - 1;
      offsets[stId] = pos;
      pos += PdfW(fh, StringFormat("%d 0 obj\n<< /Length %d >>\nstream\n", stId, cLen));
      if(cLen > 0) FileWriteArray(fh, cArr, 0, cLen);
      pos += cLen;
      pos += PdfW(fh, "endstream\nendobj\n");
   }

   long xrefPos = pos;
   PdfW(fh, StringFormat("xref\n0 %d\n", totalObj + 1));
   PdfW(fh, "0000000000 65535 f \r\n");
   for(int i = 1; i <= totalObj; i++)
      PdfW(fh, StringFormat("%010d 00000 n \r\n", (int)offsets[i]));

   PdfW(fh, StringFormat("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n",
      totalObj + 1, (int)xrefPos));

   FileClose(fh);
   PrintFormat("PDF REPORT: %s", g_reportPdfName);
}


//+------------------------------------------------------------------+
//| GENERATE PDF REPORT — Letter size, professionally formatted        |
//+------------------------------------------------------------------+
void GeneratePDFReport()
{
   PdfInit();

   // --- Compute metrics ---
   double medStopLag = 0, medLimitLag = 0, medCloseLag = 0, medMarketLag = 0;
   if(g_countByType[2] > 0 || g_countByType[3] > 0)
      medStopLag = (g_medianLag[2]*g_countByType[2] + g_medianLag[3]*g_countByType[3]) / MathMax(1, g_countByType[2]+g_countByType[3]);
   if(g_countByType[4] > 0 || g_countByType[5] > 0)
      medLimitLag = (g_medianLag[4]*g_countByType[4] + g_medianLag[5]*g_countByType[5]) / MathMax(1, g_countByType[4]+g_countByType[5]);
   medCloseLag = g_medianLag[8];
   if(g_countByType[0] > 0 || g_countByType[1] > 0)
      medMarketLag = (g_medianLag[0]*g_countByType[0] + g_medianLag[1]*g_countByType[1]) / MathMax(1, g_countByType[0]+g_countByType[1]);
   double stopLimitRatio = (medLimitLag > 0.001) ? medStopLag / medLimitLag :
                           (medStopLag > 0.001 && (g_countByType[4] > 0 || g_countByType[5] > 0)) ? 999.0 : 0;
   // tpslRatio (slippage) removed — lag is the manipulation signal, not slippage
   double medTPLag = g_medianLag[6];   // TP broker exec from FindTriggerTick
   double medSLLag = g_medianLag[7];   // SL broker exec from FindTriggerTick
   double tpslExecRatio = 0;
   if(medTPLag > 10 && medSLLag > 10)
      tpslExecRatio = medSLLag / medTPLag;
   else if(medSLLag > 10 && medTPLag <= 10 && g_countByType[6] > 0)
      tpslExecRatio = medSLLag;  // TP ~0ms, SL large = extreme asymmetry (show SL as ratio)
   // Compute total damage consistently (same 5-component formula used in Section 5)
   double totalDamage = 0;
   double perLot = 0;
   if(g_batchClassification != "FAIR")
   {
      totalDamage = g_totalAdverseSlipUSD + MathAbs(g_totalFinancialDelta) + MathAbs(g_roundingErrorSum);
      if(g_countByType[2] > 0 && g_countByType[4] > 0)
      { double exL = medStopLag - medLimitLag; if(exL > 0) totalDamage += (exL / 1000.0) * 0.5 * g_totalLotsTraded * g_tickValue; }
      if(g_countByType[6] > 0 && g_countByType[7] > 0)
      { double exS = g_meanSlipAbs[7] - g_meanSlipAbs[6]; if(exS > 0) totalDamage += (exS / g_tickSize) * g_tickValue * g_lotSize * g_countByType[7]; }
      perLot = (g_totalLotsTraded > 0) ? totalDamage / g_totalLotsTraded : 0;
   }

   // Drift-harmless checks for verdict (PDF report)
   // Stops fill at market by design — judge on lag speed, not trigger fill %
   bool pdfStopDriftHarmless = (medStopLag <= STD_FILL_SLOW_MS);
   bool pdfCloseDriftHarmless = (g_driftLagCount[8] > 0) ? (g_driftLagSum[8] / g_driftLagCount[8] < 5.0) : false;
   bool pdfSyncCloseDriftHarmless = (g_driftLagCount[9] > 0) ? (g_driftLagSum[9] / g_driftLagCount[9] < 5.0) : false;

   int violations = 0;
   bool hasAsymmetry = false;  // True only when discriminatory execution detected
   if(!pdfStopDriftHarmless) { if(medStopLag > STD_FILL_MANIP_MS) violations += 2; else if(medStopLag > STD_FILL_SLOW_MS) violations++; }
   if(!pdfCloseDriftHarmless) { if(g_asyncCloseMedianLag > STD_CLOSE_MANIP_MS) violations += 2; else if(g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS) violations++; }
   if(g_syncCloseCount > 0 && !pdfSyncCloseDriftHarmless) { if(g_syncCloseMedianLag > STD_SYNC_CLOSE_MANIP_MS) violations += 2; else if(g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS) violations++; }
   // Stop/limit and SL/TP ratios indicate asymmetric execution — always broker-favorable
   bool hasStructuralAsymmetry = (stopLimitRatio > 2.0) || (tpslExecRatio > 2.0);
   if(hasStructuralAsymmetry) { violations++; hasAsymmetry = true; }  // Asymmetric lag is a violation
   // TP: limit-like (trigger fill % matters), SL: stop-like (lag only)
   {
      bool pdfTpH = false;
      int pdfTpC = g_triggerFillCount[6] + g_marketFillCount[6];
      if(pdfTpC > 0) pdfTpH = ((double)g_triggerFillCount[6] / pdfTpC * 100.0 >= 90.0);
      else if(g_driftLagCount[6] > 0) pdfTpH = (g_driftLagSum[6] / g_driftLagCount[6] < 5.0);
      // SL: stop-like, fills at market — judge on lag only
      bool pdfSlH = (medSLLag <= STD_TPSL_SLOW_MS);
      if(!(pdfTpH && pdfSlH)) { if(medTPLag > STD_TPSL_MANIP_MS || medSLLag > STD_TPSL_MANIP_MS) violations += 2;
      else if(medTPLag > STD_TPSL_SLOW_MS || medSLLag > STD_TPSL_SLOW_MS) violations++; }
   }
   if(g_batchClassification == "MANIPULATION" && g_roundingErrorSum < -0.01 && g_roundingErrorCount > 5) { violations++; hasAsymmetry = true; }
   // Batch/cluster ratio: only count violations when their own analysis flags a problem
   // A "FAIR" classification means the batch/cluster ratio is normal for this broker's execution speed
   if(g_batchClassification != "FAIR")
   { if(g_batchRatio > 0.60) { violations += 2; } else if(g_batchRatio > 0.30) { violations++; } }
   // Clustering: only count as independent violation when asymmetry exists
   // Symmetric slow execution naturally produces clusters — not independently suspicious
   if(g_clusterVerdict != "FAIR" && hasAsymmetry)
   { if(g_clusterRatio * 100.0 > STD_CLUSTER_CAUTION_PCT) { violations += 2; } else if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT) { violations++; } }

   string verdict;
   double vr = 0, vg2 = 0, vb = 0;
   if(hasAsymmetry)
   {
      // Asymmetric execution = discriminatory treatment = potential B-book
      if(violations >= 6)      { verdict = "MULTIPLE A-BOOK STANDARDS BREACHED — AVOID THIS BROKER"; vr = 0.85; }
      else if(violations >= 4) { verdict = "A-BOOK STANDARDS BREACHED — LIKELY B-BOOK EXECUTION"; vr = 0.85; vg2 = 0.20; }
      else if(violations >= 2) { verdict = "SUSPICIOUS — ASYMMETRIC EXECUTION DETECTED"; vr = 0.85; vg2 = 0.45; }
      else                     { verdict = "FAIR EXECUTION — WITHIN A-BOOK STANDARDS"; vg2 = 0.60; }
   }
   else
   {
      // No asymmetry — cannot conclude B-book, only slow infrastructure
      // Clusters in this context are a natural result of symmetric slow execution
      if(violations >= 4)      { verdict = "SLOW EXECUTION — SIGNIFICANTLY EXCEEDS A-BOOK STANDARDS"; vr = 0.85; vg2 = 0.55; }
      else if(violations >= 1) { verdict = "SLOW EXECUTION — EXCEEDS SOME A-BOOK STANDARDS"; vr = 0.85; vg2 = 0.55; }
      else                     { verdict = "FAIR EXECUTION — WITHIN A-BOOK STANDARDS"; vg2 = 0.60; }
   }

   // ==================== COVER PAGE (no header) ====================
   g_pdfPageCount++;
   g_pdfY = PDF_TOP;
   g_pdfCurStream = "";
   // Title block: two lines of 26pt bold, vertically centered between two HRs
   // 26pt Helvetica-Bold: cap height ~19pt above baseline, descender ~5pt below
   // Two lines with 8pt gap: visual height = 19 + 26 + 8 + 26 + 5 = ~58pt (baseline-to-baseline = 34pt)
   {
      PdfSpace(100);
      double titleFontSz = 26;
      double lineGap = 8;                           // gap between line 1 descender and line 2 cap
      double capH = titleFontSz * 0.72;             // cap height above baseline
      double desc = titleFontSz * 0.18;             // descender below baseline
      double bl1ToBl2 = titleFontSz + lineGap;      // baseline-to-baseline distance
      double visualH = capH + bl1ToBl2 + desc;      // total visual text height
      double padding = 24;                           // equal space above and below text
      double blockH = visualH + 2 * padding;         // total block between HR lines

      // Top HR
      double topHR = g_pdfY - 4;
      g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f m %.1f %.1f l S\n",
         PDF_ML, topHR, PDF_ML + PDF_CW, topHR);

      // Bottom HR
      double botHR = topHR - blockH;
      g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f m %.1f %.1f l S\n",
         PDF_ML, botHR, PDF_ML + PDF_CW, botHR);

      // Line 1 baseline: topHR - padding - capH
      double bl1 = topHR - padding - capH;
      // Line 2 baseline: bl1 - bl1ToBl2
      double bl2 = bl1 - bl1ToBl2;

      string t1 = "BROKER EXECUTION";
      string t2 = "FORENSIC ANALYSIS REPORT";
      double tw1 = StringLen(t1) * titleFontSz * 0.62;
      double tw2 = StringLen(t2) * titleFontSz * 0.62;
      double x1 = PDF_ML + (PDF_CW - tw1) / 2;
      double x2 = PDF_ML + (PDF_CW - tw2) / 2;

      g_pdfCurStream += StringFormat("BT /F2 %.0f Tf 0.120 0.250 0.500 rg %.1f %.1f Td (%s) Tj ET\n",
         titleFontSz, x1, bl1, PdfEsc(t1));
      g_pdfCurStream += StringFormat("BT /F2 %.0f Tf 0.120 0.250 0.500 rg %.1f %.1f Td (%s) Tj ET\n",
         titleFontSz, x2, bl2, PdfEsc(t2));

      g_pdfY = botHR - 4;  // continue below bottom HR
   }
   PdfSpace(40);
   PdfCenter(StringFormat("Report ID: FA-%d-%s", (int)g_accountNumber, TimeToString(TimeCurrent(), TIME_DATE)), 10);
   PdfCenter(StringFormat("Generated: %s", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)), 10);
   PdfSpace(10);
   PdfCenter(StringFormat("BrokerForensicAnalyzer v%s for MetaTrader 5 (Build %d)", FA_VERSION, g_mt5Build), 9);
   PdfSpace(60);
   PdfCenter(StringFormat("%s  |  %s  |  Account %d  |  %s",
      g_brokerName, g_serverName, (int)g_accountNumber, Symbol()), 9);

   // ==================== PAGE 2: EXECUTIVE SUMMARY DASHBOARD ====================
   PdfNewPage();
   PdfSection("EXECUTIVE SUMMARY");
   PdfSpace(6);

   // --- Verdict banner ---
   {
      double bannerH = 30;
      double bannerY = g_pdfY - bannerH;
      // Banner background
      g_pdfCurStream += StringFormat("%.2f %.2f %.2f rg %.1f %.1f %.1f %.1f re f\n",
         vr * 0.15, vg2 * 0.15, vb * 0.15, PDF_ML, bannerY, PDF_CW, bannerH);
      g_pdfCurStream += StringFormat("%.2f %.2f %.2f RG 1.5 w %.1f %.1f %.1f %.1f re S\n",
         vr, vg2, vb, PDF_ML, bannerY, PDF_CW, bannerH);
      // Verdict text centered — scale font to fit within banner width
      // Use 0.62 width factor for bold uppercase (Helvetica-Bold caps are wide)
      double vsz = 16;
      double vCharW = 0.62;
      double vtw = StringLen(verdict) * vsz * vCharW;
      while(vtw > PDF_CW - 20 && vsz > 8)
      {
         vsz -= 1;
         vtw = StringLen(verdict) * vsz * vCharW;
      }
      double vx = PDF_ML + (PDF_CW - vtw) / 2;
      if(vx < PDF_ML + 4) vx = PDF_ML + 4;
      g_pdfCurStream += StringFormat("BT /F2 %.0f Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
         vsz, vr, vg2, vb, vx, bannerY + (bannerH - vsz) / 2, PdfEsc(verdict));
      g_pdfY -= bannerH + 8;
   }

   // --- Key stat boxes row ---
   PdfSpace(4);
   {
      double bw = (PDF_CW - 24) / 4;  // 4 boxes, 8pt gap between
      double bh = 44;
      PdfStatBox(PDF_ML,            bw, bh, IntegerToString(g_fillCount), "Total Fills",    0.29, 0.56, 0.85);
      PdfStatBox(PDF_ML + bw + 8,   bw, bh, IntegerToString(g_cycleNum), "Cycles",          0.29, 0.56, 0.85);
      PdfStatBox(PDF_ML + (bw+8)*2, bw, bh, FormatMoney(totalDamage),    "Total Damage",
         (totalDamage > 1.0) ? 0.85 : 0.0, (totalDamage > 1.0) ? 0.17 : 0.60, 0.0);
      PdfStatBox(PDF_ML + (bw+8)*3, bw, bh, FormatMoney(perLot),         "Cost per Lot",
         (perLot > 1.0) ? 0.85 : 0.0, (perLot > 1.0) ? 0.27 : 0.60, 0.0);
      g_pdfY -= bh + 4;
   }

   // --- Case identification (compact) ---
   PdfSpace(4);
   PdfSubSec("Case Identification");
   PdfKV("Broker:", StringFormat("%s (%s)", g_brokerName, g_serverName));
   PdfKV("Account:", StringFormat("%d (%s, Leverage 1:%d)", (int)g_accountNumber, g_accountCurrency, (int)g_accountLeverage));
   PdfKV("Symbol:", StringFormat("%s (%d digits, tick value %.4f)", Symbol(), g_digits, g_tickValue));
   PdfKV("Lot Size:", StringFormat("%.4f (minimum)", g_lotSize));

   // Measurement standard note — smaller font, boxed, centered in content area
   {
      PdfSpace(4);
      double curAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      string stdQuote = DoubleToString(curAsk, g_stdDigits);           // e.g. "3021.45" (2-digit)
      string extQuote = DoubleToString(curAsk, g_stdDigits + 1);      // e.g. "3021.453" (3-digit)

      string msText = "Measurement Standard: All distance measurements in this report (lag, slippage, spread, stops level, "
         "rejection distance) are expressed in standardized pips — not broker-specific points. "
         "For example, XAUUSD standard pricing uses 2 decimals (e.g. 3021.45), where 1 pip = $0.01 = 1 point. "
         "Some brokers add an extra digit for precision (e.g. 3021.453), where 1 pip still equals $0.01 but now "
         "equals 10 of that broker's \"points.\" Without this normalization, a \"50 point slippage\" on a 3-digit "
         "broker would appear 10x worse than \"5 point slippage\" on a 2-digit broker — yet both represent the "
         "same $0.05 price movement. " +
         StringFormat("This broker quotes %s at %d digits (%s). 1 pip = %s = %d broker point%s. "
         "Raw broker points shown in parentheses where relevant.",
         g_baseSymbol, g_digits, DoubleToString(curAsk, g_digits),
         DoubleToString(g_pipSize, g_stdDigits),
         g_pipMult, (g_pipMult == 1) ? "" : "s");

      // Render at 7pt in a light-bordered box, 6pt padding inside
      double msFont = 7;
      double msCharW = msFont * 0.48;
      double msLineH = 10;
      double boxPad = 6;
      double boxInnerW = PDF_CW - 2 * boxPad;
      int msMaxCh = (int)(boxInnerW / msCharW);
      // Count lines
      int msLines = 0;
      string msTmp = msText;
      while(StringLen(msTmp) > 0)
      {
         msLines++;
         if(StringLen(msTmp) <= msMaxCh) break;
         int bp = msMaxCh;
         for(int i = msMaxCh; i > msMaxCh/2; i--)
         { if(StringGetCharacter(msTmp, i) == ' ') { bp = i; break; } }
         msTmp = StringSubstr(msTmp, bp);
         StringTrimLeft(msTmp);
      }
      double boxH = msLines * msLineH + 2 * boxPad;
      PdfCheckY(boxH + 8);

      // Light gray border box
      g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f %.1f %.1f re S\n",
         PDF_ML, g_pdfY - boxH, PDF_CW, boxH);

      // Render text inside box at 7pt, dark gray
      double txX = PDF_ML + boxPad;
      double txY = g_pdfY - boxPad - msFont;
      string msRem = msText;
      bool msFirst = true;
      while(StringLen(msRem) > 0)
      {
         string msLine;
         if(StringLen(msRem) <= msMaxCh)
         { msLine = msRem; msRem = ""; }
         else
         {
            int bp = msMaxCh;
            for(int i = msMaxCh; i > msMaxCh/2; i--)
            { if(StringGetCharacter(msRem, i) == ' ') { bp = i; break; } }
            msLine = StringSubstr(msRem, 0, bp);
            msRem = StringSubstr(msRem, bp);
            StringTrimLeft(msRem);
         }
         // Bold "Measurement Standard:" on first line
         if(msFirst)
         {
            g_pdfCurStream += StringFormat("BT /F2 %.0f Tf 0.2 0.2 0.2 rg %.1f %.1f Td (Measurement Standard: ) Tj ET\n",
               msFont, txX, txY);
            double prefW = 23 * msCharW; // "Measurement Standard: " = 23 chars
            string msRest = StringSubstr(msLine, 23);
            g_pdfCurStream += StringFormat("BT /F1 %.0f Tf 0.3 0.3 0.3 rg %.1f %.1f Td (%s) Tj ET\n",
               msFont, txX + prefW, txY, PdfEsc(msRest));
            msFirst = false;
         }
         else
         {
            g_pdfCurStream += StringFormat("BT /F1 %.0f Tf 0.3 0.3 0.3 rg %.1f %.1f Td (%s) Tj ET\n",
               msFont, txX, txY, PdfEsc(msLine));
         }
         txY -= msLineH;
      }
      g_pdfY -= boxH + 4;
      PdfSpace(2);
      // Account denomination note
      if(g_accountCurrency != "USD")
      {
         PdfBody(StringFormat("Account Denomination: This account uses %s. All monetary values in this report are shown "
            "as reported by the trading platform in %s and labeled as USD for standardized presentation. "
            "If your account uses a sub-denomination (e.g. USC = US cents, GBX = pence), you should apply "
            "the appropriate conversion factor to the dollar amounts shown (e.g. divide by 100 for cent accounts).",
            g_accountCurrency, g_accountCurrency));
         PdfSpace(2);
      }
   }

   // Stops Level with A-book benchmark assessment
   // Normalized to PIPS so 2-digit and 3-digit brokers are evaluated equally
   // Tiers: 0-5 pips = ideal A-book ECN; 5-20 pips = still A-book but caution with tight SL;
   //        >20 pips = unusually restrictive, not typical of A-book
   {
      double stopsInPips = g_stopsLevel * g_point / g_pipSize;
      string stopsAssess;
      if(stopsInPips < 0.01)  // effectively 0
         stopsAssess = "IDEAL — no minimum distance restriction (consistent with true ECN/A-book)";
      else if(stopsInPips <= 5.0)
         stopsAssess = StringFormat("IDEAL — %.1f pips (%d broker points). Within the 0-5 pip range standard for A-book ECN brokers. "
            "No practical limitation for most trading strategies", stopsInPips, g_stopsLevel);
      else if(stopsInPips <= 20.0)
         stopsAssess = StringFormat("A-BOOK COMPATIBLE — %.1f pips (%d broker points). Still within A-broker range, but traders using "
            "stop-losses or take-profits closer than %.1f pips to the entry price should be aware that this broker "
            "will not accept those orders. Scalping strategies and tight stop-loss EAs may need adjustment",
            stopsInPips, g_stopsLevel, stopsInPips);
      else
         stopsAssess = StringFormat("UNUSUALLY RESTRICTIVE — %.1f pips (%d broker points). This exceeds the typical A-book range of "
            "0-20 pips. Traders should exercise caution — this level of restriction prevents most tight stop-loss "
            "strategies and is not typical of transparent ECN/A-book execution", stopsInPips, g_stopsLevel);
      PdfKV("Stops Level:", StringFormat("%.1f pips (%d broker points) — %s", stopsInPips, g_stopsLevel, stopsAssess));
      if(g_freezeLevel > 0)
      {
         double freezeInPips = g_freezeLevel * g_point / g_pipSize;
         PdfKV("Freeze Level:", StringFormat("%.1f pips (%d broker points) — orders cannot be modified/cancelled when price is within this distance. "
            "A-book benchmark: 0", freezeInPips, g_freezeLevel));
      }
   }
   PdfKV("CS Latency:", StringFormat("%d ms round-trip, %d ms one-way", (int)g_clientServerRoundTripMs, (int)g_clientServerLagMs));
   {
      int gmtOff = (int)((TimeCurrent() - TimeGMT()) / 3600);
      string tzStr = (gmtOff >= 0) ? StringFormat("UTC+%d", gmtOff) : StringFormat("UTC%d", gmtOff);
      PdfKV("Test Period:", StringFormat("%s to %s (%s)",
         TimeToString(g_collectionStartTime, TIME_DATE|TIME_SECONDS),
         TimeToString(g_collectionEndTime, TIME_DATE|TIME_SECONDS), tzStr));
      long totalSecs = (long)(g_collectionEndTime - g_collectionStartTime);
      int hrs = (int)(totalSecs / 3600);
      int mins = (int)((totalSecs % 3600) / 60);
      int secs = (int)(totalSecs % 60);
      string durStr;
      if(hrs > 0) durStr = StringFormat("%dh %dm %ds", hrs, mins, secs);
      else if(mins > 0) durStr = StringFormat("%dm %ds", mins, secs);
      else durStr = StringFormat("%ds", secs);
      PdfKV("Total Duration:", durStr);
   }
   PdfKV("Sample Size:", StringFormat("%d fills, %d cycles, %.2f lots traded", g_fillCount, g_cycleNum, g_totalLotsTraded));
   {
      // Statistical representativeness: CLT requires 30+ per group → 60 fills minimum
      int cltMin = 60;
      string statNote;
      if(g_fillCount >= cltMin)
         statNote = StringFormat("%d deals evaluated (minimum %d required). Sample exceeds Central Limit Theorem "
            "threshold for two-sample comparison (30 per group) — results are statistically representative.", g_fillCount, cltMin);
      else
         statNote = StringFormat("%d deals evaluated (minimum %d required). Sample is below Central Limit Theorem "
            "threshold — results should be interpreted with caution.", g_fillCount, cltMin);
      PdfKV("Statistical Validity:", statNote);
   }
   PdfKV("Order Limit:", StringFormat("%d (max observed: %d pos, %d pending, %d total)", (int)g_orderLimit, g_maxPositionsObserved, g_maxPendingObserved, g_maxTotalObserved));

   // --- ASYMMETRY BAR (PDF) ---
   {
      double sumAdv2 = 0; int nAdv2 = 0;
      double sumFav2 = 0; int nFav2 = 0;
      if(g_countByType[2] > 0) { sumAdv2 += g_medianLag[2]; nAdv2++; }
      if(g_countByType[3] > 0) { sumAdv2 += g_medianLag[3]; nAdv2++; }
      if(g_countByType[7] > 0) { sumAdv2 += g_medianLag[7]; nAdv2++; }
      if(g_countByType[4] > 0) { sumFav2 += g_medianLag[4]; nFav2++; }
      if(g_countByType[5] > 0) { sumFav2 += g_medianLag[5]; nFav2++; }
      if(g_countByType[6] > 0) { sumFav2 += g_medianLag[6]; nFav2++; }
      if(nAdv2 > 0 && nFav2 > 0)
      {
         double avgA2 = sumAdv2 / nAdv2;
         double avgF2 = sumFav2 / nFav2;
         // Use rounded display values so equal display = equal bar widths
         double dispA2 = MathRound(avgA2);
         double dispF2 = MathRound(avgF2);
         double totalLag2 = dispA2 + dispF2;
         if(totalLag2 < 1) totalLag2 = 1;
         double barTotalW = PDF_CW * 0.85;
         double brkW2 = MathMax(15, (dispA2 / totalLag2) * barTotalW);
         double trdW2 = MathMax(15, barTotalW - brkW2);
         // Clamp so both fit
         if(brkW2 + trdW2 > barTotalW) { double sc = barTotalW / (brkW2 + trdW2); brkW2 *= sc; trdW2 *= sc; }
         double ratio2 = (avgF2 > 0.001) ? avgA2 / avgF2 : (avgA2 > 0.001 ? 999.0 : 1.0);
         string vrd2 = (ratio2 > 3.0) ? "ASYMMETRIC" : (ratio2 > 2.0) ? "ASYMMETRIC" : "FAIR";

         PdfSpace(4);
         PdfCheckY(160);

         // --- Centered heading ---
         {
            string qHdr = "Execution Time by Order Type";
            double qHdrW = StringLen(qHdr) * 9 * 0.48;
            double qHdrX = PDF_ML + (PDF_CW - qHdrW) / 2;
            if(qHdrX < PDF_ML) qHdrX = PDF_ML;
            g_pdfCurStream += StringFormat("BT /F2 9 Tf 1.0 0.53 0.0 rg %.1f %.1f Td (%s) Tj ET\n",
               qHdrX, g_pdfY, PdfEsc(qHdr));
            g_pdfY -= 16;
         }

         double barStartX = PDF_ML + (PDF_CW - barTotalW) / 2;

         // --- FAIR bar (green, equal halves with visible center divider) ---
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (FAIR EXECUTION \\(equal processing time\\):) Tj ET\n",
            PDF_ML, g_pdfY);
         g_pdfY -= 12;
         double halfW = barTotalW / 2;
         // Left half
         g_pdfCurStream += StringFormat("0.17 0.35 0.17 rg %.1f %.1f %.1f 18 re f\n",
            barStartX, g_pdfY - 18, halfW - 0.5);
         // Right half (0.5pt gap = center divider)
         g_pdfCurStream += StringFormat("0.17 0.35 0.17 rg %.1f %.1f %.1f 18 re f\n",
            barStartX + halfW + 0.5, g_pdfY - 18, halfW - 0.5);
         // Centered labels inside each half
         {
            string lbl1 = "Your orders";
            string lbl2 = "Broker orders";
            double lbl1W = StringLen(lbl1) * 7 * 0.48;
            double lbl2W = StringLen(lbl2) * 7 * 0.48;
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.8 0.5 rg %.1f %.1f Td (%s) Tj ET\n",
               barStartX + (halfW - lbl1W) / 2, g_pdfY - 12, PdfEsc(lbl1));
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.8 0.5 rg %.1f %.1f Td (%s) Tj ET\n",
               barStartX + halfW + (halfW - lbl2W) / 2, g_pdfY - 12, PdfEsc(lbl2));
         }
         g_pdfY -= 24;
         PdfSpace(16);

         // --- YOUR BROKER (measured) label ---
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (YOUR BROKER \\(measured\\):) Tj ET\n",
            PDF_ML, g_pdfY);
         g_pdfY -= 12;

         // --- Left/right labels aligned to bar edges ---
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.25 0.25 rg %.1f %.1f Td (Your Execution Time \\(Stops/SL\\)) Tj ET\n",
            barStartX, g_pdfY);
         {
            string rtLbl = "Broker's Execution Time (Limits/TP)";
            double rtLblW = StringLen(rtLbl) * 7 * 0.48;
            g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.25 0.35 0.85 rg %.1f %.1f Td (%s) Tj ET\n",
               barStartX + barTotalW - rtLblW, g_pdfY, PdfEsc(rtLbl));
         }
         g_pdfY -= 12;

         // --- Proportional red/blue bar ---
         double barH = 22;
         // Red bar (your wait = slow stops/SL)
         g_pdfCurStream += StringFormat("0.87 0.13 0.00 rg %.1f %.1f %.1f %.1f re f\n",
            barStartX, g_pdfY - barH, brkW2, barH);
         // Blue bar (broker's speed = fast limits/TP)
         g_pdfCurStream += StringFormat("0.13 0.40 0.87 rg %.1f %.1f %.1f %.1f re f\n",
            barStartX + brkW2, g_pdfY - barH, trdW2, barH);
         // Value labels centered inside each bar segment
         {
            string redTxt = FormatMs(avgA2);
            string bluTxt = FormatMs(avgF2);
            double redTxtW = StringLen(redTxt) * 8 * 0.48;
            double bluTxtW = StringLen(bluTxt) * 8 * 0.48;
            double redTxtX = barStartX + (brkW2 - redTxtW) / 2;
            double bluTxtX = barStartX + brkW2 + (trdW2 - bluTxtW) / 2;
            g_pdfCurStream += StringFormat("BT /F2 8 Tf 1 1 1 rg %.1f %.1f Td (%s) Tj ET\n",
               redTxtX, g_pdfY - barH + 7, PdfEsc(redTxt));
            g_pdfCurStream += StringFormat("BT /F2 8 Tf 1 1 1 rg %.1f %.1f Td (%s) Tj ET\n",
               bluTxtX, g_pdfY - barH + 7, PdfEsc(bluTxt));
         }
         g_pdfY -= barH + 6;

         // --- Centered verdict ---
         {
            string verdictStr;
            double vr = 0, vg2 = 0, vb = 0;
            if(ratio2 > 2.0)
            {
               verdictStr = StringFormat("Stops took %.0fx longer than limits - %s", ratio2, vrd2);
               vr = 0.85; vg2 = 0.65; vb = 0;
            }
            else if(ratio2 > 1.5)
            {
               verdictStr = StringFormat("Stops took %.1fx longer than limits - %s", ratio2, vrd2);
               vr = 0.85; vg2 = 0.65; vb = 0;
            }
            else if(ratio2 <= 1.2)
            {
               verdictStr = "Equal execution - FAIR";
               vr = 0; vg2 = 0.7; vb = 0;
            }
            else
            {
               verdictStr = StringFormat("Ratio: %.1fx - %s", ratio2, vrd2);
               vr = 0; vg2 = 0.7; vb = 0;
            }
            double verdW = StringLen(verdictStr) * 9 * 0.48;
            double verdX = PDF_ML + (PDF_CW - verdW) / 2;
            if(verdX < PDF_ML) verdX = PDF_ML;
            g_pdfCurStream += StringFormat("BT /F2 9 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
               vr, vg2, vb, verdX, g_pdfY, PdfEsc(verdictStr));
            g_pdfY -= 14;
         }

         // --- Explanation box (matching HTML left-border style) ---
         if(ratio2 > 1.5)
         {
            PdfSpace(6);
            // Draw a dark background box with red left border
            double boxW = PDF_CW;
            string explTxt = StringFormat("What this means: The side with the fastest execution reaps all the benefits. "
               "Fair execution allocates the same processing time to both sides - when one side consistently "
               "receives faster execution, that side profits at the other's expense. "
               "Here, the broker's orders (limits/TP) execute in %.0fms, while your orders (stops/SL) are held "
               "for %.0fms - a %.0fx difference. During the %.0fms delay on your stops/SL, the market moves "
               "against you, manufacturing adverse slippage. The %.0fms execution on broker orders suppresses "
               "your favorable slippage - the price has no time to improve in your favour. "
               "This is not a timing anomaly - it is the mechanism by which the broker extracts value from every trade.",
               avgF2, avgA2, ratio2, avgA2, avgF2);
            // Estimate box height (wrap at ~95 chars per line)
            int explLines = (int)MathCeil((double)StringLen(explTxt) / 95.0);
            double boxH = explLines * 10 + 12;
            PdfCheckY(boxH + 4);
            // Background
            g_pdfCurStream += StringFormat("0.10 0.06 0.12 rg %.1f %.1f %.1f %.1f re f\n",
               PDF_ML, g_pdfY - boxH, boxW, boxH);
            // Red left border (3pt wide)
            g_pdfCurStream += StringFormat("0.85 0.13 0.13 rg %.1f %.1f 3 %.1f re f\n",
               PDF_ML, g_pdfY - boxH, boxH);
            // Text inside box
            double txX = PDF_ML + 8;
            double txY = g_pdfY - 10;
            double txMaxW = boxW - 16;
            int charsPerLine = (int)(txMaxW / (7 * 0.48));
            int pos = 0;
            int txtLen = StringLen(explTxt);
            while(pos < txtLen)
            {
               int lineEnd = pos + charsPerLine;
               if(lineEnd >= txtLen) lineEnd = txtLen;
               else
               {
                  // Find last space before lineEnd for word wrap
                  int lastSpace = lineEnd;
                  while(lastSpace > pos && StringGetCharacter(explTxt, lastSpace) != ' ')
                     lastSpace--;
                  if(lastSpace > pos) lineEnd = lastSpace + 1;
               }
               string line = StringSubstr(explTxt, pos, lineEnd - pos);
               // Bold "What this means:" prefix on first line
               if(pos == 0)
               {
                  g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.9 0.9 0.9 rg %.1f %.1f Td (What this means: ) Tj ET\n",
                     txX, txY);
                  line = StringSubstr(line, 17); // Remove "What this means: " from regular text
                  double prefixW = 17 * 7 * 0.48;
                  g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.8 0.8 0.8 rg %.1f %.1f Td (%s) Tj ET\n",
                     txX + prefixW, txY, PdfEsc(line));
               }
               else
                  g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.8 0.8 0.8 rg %.1f %.1f Td (%s) Tj ET\n",
                     txX, txY, PdfEsc(line));
               txY -= 10;
               pos = lineEnd;
            }
            g_pdfY -= boxH + 4;
         }
      }
   }

   // --- Visual Bar Chart: Execution Lag vs Industry Standard ---
   PdfSpace(6);
   PdfCheckY(250);  // Need ~250pt for the bar chart — auto page-break if needed
   PdfSubSec("Your Broker's Execution Time vs Industry Standard");
   PdfSpace(2);

   {
      // Each bar scales relative to its OWN standard — full bar width = standard threshold.
      // Broker value shown as green fill within the standard outline.
      // If broker exceeds standard, red segment extends beyond the outline.
      double barH  = 14;     // bar height
      double barGap = 4;     // gap between bars
      double labelW = 100;   // label column width
      double stdBarW = PDF_CW - labelW - 110; // standard threshold = this width (room for red + text)
      double barX = PDF_ML + labelW;  // bar start X

      for(int t = 0; t < 10; t++)
      {
         if(g_countByType[t] == 0) continue;

         int stdGood2;
         if(t <= 1) stdGood2 = STD_MARKET_GOOD_MS;
         else if(t <= 5) stdGood2 = STD_FILL_GOOD_MS;
         else if(t <= 7) stdGood2 = STD_TPSL_GOOD_MS;
         else if(t == 9) stdGood2 = STD_SYNC_CLOSE_GOOD_MS;
         else stdGood2 = STD_CLOSE_GOOD_MS;

         double measured = g_medianLag[t];
         PdfCheckY(barH + barGap + 2);

         // Label: "Order Type (count)"
         string barLabel = StringFormat("%s (%d)", GetFillTypeName((ENUM_FILL_TYPE)t), g_countByType[t]);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.6 0.6 0.6 rg %.1f %.1f Td (%s) Tj ET\n",
            PDF_ML, g_pdfY - barH + 4, PdfEsc(barLabel));

         string valText = FormatMs(measured, true);

         // Draw standard outline (full width = standard threshold)
         // Light gray outline box representing the industry standard
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.5 w %.1f %.1f %.1f %.1f re S\n",
            barX, g_pdfY - barH, stdBarW, barH);

         // Standard label at end of outline
         g_pdfCurStream += StringFormat("BT /F1 6 Tf 0.65 0.65 0.65 rg %.1f %.1f Td (%dms) Tj ET\n",
            barX + stdBarW + 3, g_pdfY - barH + 4, stdGood2);

         if(measured <= (double)stdGood2)
         {
            // Within standard — green bar proportional to standard
            double greenW = (measured / (double)stdGood2) * stdBarW;
            if(greenW < 6) greenW = 6;
            // Green bar
            g_pdfCurStream += StringFormat("0.00 0.80 0.00 rg %.1f %.1f %.1f %.1f re f\n",
               barX, g_pdfY - barH, greenW, barH);
            // Value text to the right of green bar
            g_pdfCurStream += StringFormat("BT /F2 7 Tf 0 0.55 0 rg %.1f %.1f Td (%s) Tj ET\n",
               barX + greenW + 4, g_pdfY - barH + 4, PdfEsc(valText));
         }
         else
         {
            // Exceeds standard — green fills entire standard, red extends beyond
            double redW = ((measured - (double)stdGood2) / (double)stdGood2) * stdBarW;
            if(redW < 4) redW = 4;
            if(redW > stdBarW * 0.35) redW = stdBarW * 0.35; // cap red at 35% of standard width
            // Green segment (fills entire standard width)
            g_pdfCurStream += StringFormat("0.00 0.80 0.00 rg %.1f %.1f %.1f %.1f re f\n",
               barX, g_pdfY - barH, stdBarW, barH);
            // Red segment (extends beyond standard outline)
            g_pdfCurStream += StringFormat("1.00 0.13 0.00 rg %.1f %.1f %.1f %.1f re f\n",
               barX + stdBarW, g_pdfY - barH, redW, barH);
            // Value text with % above standard
            int pdfPctAbove = (stdGood2 > 0) ? (int)MathRound(((measured - (double)stdGood2) / (double)stdGood2) * 100) : 0;
            string excText = StringFormat("%s (+%d%%)", valText, pdfPctAbove);
            g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.1 0 rg %.1f %.1f Td (%s) Tj ET\n",
               barX + stdBarW + redW + 4, g_pdfY - barH + 4, PdfEsc(excText));
         }

         g_pdfY -= (barH + barGap);
      }

      // Legend
      PdfCheckY(24);
      PdfSpace(4);
      double legY = g_pdfY;
      // Green square
      g_pdfCurStream += StringFormat("0.00 0.80 0.00 rg %.1f %.1f 8 8 re f\n", PDF_ML, legY - 8);
      g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (Broker execution time) Tj ET\n",
         PDF_ML + 12, legY - 7);
      // Gray outline square
      g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.5 w %.1f %.1f 8 8 re S\n", PDF_ML + 130, legY - 8);
      g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (Industry standard) Tj ET\n",
         PDF_ML + 142, legY - 7);
      // Red square
      g_pdfCurStream += StringFormat("1.00 0.13 0.00 rg %.1f %.1f 8 8 re f\n", PDF_ML + 270, legY - 8);
      g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (Excess beyond standard) Tj ET\n",
         PDF_ML + 282, legY - 7);
      g_pdfY -= 12;
   }

   // --- Asymmetric Analysis Summary + Financial Impact ---
   PdfNewPage();
   PdfSubSec("Key Asymmetry Indicators");
   PdfTableHeader("Indicator", "Value", "Fair Range", "Assessment");

   {
      // Stop vs Limit — LAG RATIO is the forensic signal (not trigger fill %).
      // Stops fill at market by design. The question: does broker add extra delay?
      string slA = (stopLimitRatio > 2.0) ? "ASYMMETRIC" :
                   (stopLimitRatio > 1.5) ? "NOTABLE" : "FAIR";
      double sr=0,sg=0,sb=0;
      if(stopLimitRatio > 2.0) { sr=0.85; sg=0.10; }
      else if(stopLimitRatio > 1.5) { sr=0.85; sg=0.55; }
      else sg = 0.60;
      PdfTableRow("Stop vs Limit Lag", StringFormat("%.1fx", stopLimitRatio), "< 1.5x", slA, sr, sg, sb);

      // Fill Accuracy + Classification
      double fairPctSc = (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0;
      sr=0; sg=0;
      if(g_batchClassification == "MANIPULATION") sr = 0.85;
      else if(g_batchClassification == "CAUTION") { sr = 0.85; sg = 0.55; }
      else sg = 0.60;
      PdfTableRow("Fill Accuracy", StringFormat("%.0f%% at trigger [%s]", fairPctSc, g_batchClassification), "100%", g_batchClassification, sr, sg, sb);

      // Order Rejection Symmetry
      int pdfStopRej = 0, pdfLimitRej = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         if(StringFind(g_rejections[r].orderType, "Stop") >= 0)  pdfStopRej++;
         if(StringFind(g_rejections[r].orderType, "Limit") >= 0) pdfLimitRej++;
      }
      string rejVal, rejAssess;
      sr=0; sg=0;
      if(pdfStopRej == 0 && pdfLimitRej == 0)
      {
         rejVal = "Yours: 0, Broker: 0";
         rejAssess = "FAIR";
         sg = 0.60;
      }
      else if(pdfStopRej > 0 && pdfLimitRej == 0)
      {
         rejVal = StringFormat("Yours: %d, Broker: 0 (%d:0)", pdfStopRej, pdfStopRej);
         rejAssess = (pdfStopRej >= 3) ? "FAIL" : "SUSPICIOUS";
         sr = 0.85;
      }
      else
      {
         double pdfRejRatio = (double)pdfStopRej / MathMax(1, pdfLimitRej);
         rejVal = StringFormat("Yours: %d, Broker: %d (%.1fx)", pdfStopRej, pdfLimitRej, pdfRejRatio);
         if(pdfRejRatio > 3.0)      { rejAssess = "FAIL"; sr = 0.85; }
         else if(pdfRejRatio > 2.0) { rejAssess = "SUSPICIOUS"; sr = 0.85; sg = 0.45; }
         else                       { rejAssess = "FAIR"; sg = 0.60; }
      }
      PdfTableRow("Order Rejections", rejVal, "< 1.5x", rejAssess, sr, sg, sb);
   }

   // --- Financial Impact Summary ---
   PdfSpace(4);
   PdfSubSec("Financial Impact");
   if(g_batchClassification == "FAIR")
   {
      PdfBody("No broker-induced damage detected. All execution within 2026 industry standards.");
      PdfBody("Execution drift from broker receipt price is zero or negligible — lag has no financial impact.");
   }
   else
   {
      PdfKV("Lag-Induced Cost:", StringFormat("%s %s (price moved against you during broker hold)", FormatMoney(g_totalAdverseSlipUSD), g_displayCurrency));
      PdfKV("Close Lag Impact:", StringFormat("%s %s", FormatMoney(MathAbs(g_totalFinancialDelta)), g_displayCurrency));
      PdfKV("Rounding Skew:", StringFormat("%s %s", FormatMoney(MathAbs(g_roundingErrorSum)), g_displayCurrency));
      PdfHRule();
      PdfSpace(6);
      PdfBodyBold(StringFormat("TOTAL MEASURED DAMAGE: %s %s", FormatMoney(totalDamage), g_displayCurrency));
      PdfSpace(4);
      PdfKV("Cost per Lot:", StringFormat("%s %s", FormatMoney(perLot), g_displayCurrency));
      if(perLot > 0)
      {
         PdfKV("Annual @ 1 lot/day:", StringFormat("%s %s", FormatMoney(perLot * 252), g_displayCurrency));
         PdfKV("Annual @ 10 lots/day:", StringFormat("%s %s", FormatMoney(perLot * 10 * 252), g_displayCurrency));
      }
   }

   // ==================== SECTION 2: METHODOLOGY ====================
   PdfNewPage();
   PdfSection("SECTION 2: METHODOLOGY");
   PdfBody("This Expert Advisor (EA) places controlled test trades at minimum lot "
      "size to measure execution quality across all retail order types:");
   PdfSpace(2);
   PdfBody("1. MARKET ORDERS: Synchronous buy and sell with round-trip timing");
   PdfBody("2. PENDING STOP ORDERS (BuyStop/SellStop): Grid-based placement");
   PdfBody("3. PENDING LIMIT ORDERS (BuyLimit/SellLimit): Same grid, different type");
   PdfBody("4. TAKE-PROFIT TRIGGERS: Broker-side execution of TP levels");
   PdfBody("5. STOP-LOSS TRIGGERS: Broker-side execution of SL levels");
   PdfBody("6. BATCH CLOSE: Async close of all positions simultaneously");

   PdfSpace(4);
   PdfSubSec("Grid Configuration");
   PdfKV("Start distance:", StringFormat("%.1f x spread", InpGridStartMult));
   PdfKV("Spacing:", StringFormat("%.1f%% of spread", InpGridSpacingPct));
   PdfKV("Levels per side:", StringFormat("%d (auto-derived max distance)", GRID_LEVELS_PER_SIDE));
   if(g_cycleNum > 0)
   {
      PdfKV("Levels per side:", IntegerToString(g_cycles[0].levelsPerSide));
      PdfKV("Spread at test:", StringFormat("%.1f %s", g_cycles[0].spreadAtPlace, g_unitLabel));
   }
   PdfKV("Dwell time:", StringFormat("%d seconds", InpDwellSeconds));

   PdfSpace(4);
   PdfSubSec("Order Type Distribution (per side)");
   PdfBody("40%  Stop orders - clean (baseline, no TP/SL)");
   PdfBody("15%  Stop orders - with Take Profit attached");
   PdfBody("15%  Stop orders - with Stop Loss attached");
   PdfBody("15%  Limit orders - clean (for stop vs limit comparison)");
   PdfBody("15%  Limit orders - with both TP and SL (broker-side trigger test)");

   PdfSpace(4);
   PdfSubSec("Timing");
   PdfBody("All timestamps use GetTickCount64() - the OS monotonic clock with "
      "millisecond precision. This cannot be spoofed or manipulated by the broker "
      "or terminal. The full calibration sequence (pending order place/delete, "
      "sync market buy/sell, SL/TP placements, sync close buy/sell) runs TWICE "
      "before grid cycles begin. All measurements are averaged across both passes "
      "to reduce network jitter noise. The CS round-trip is deducted from all "
      "subsequent measurements to isolate the broker's actual processing time.");

   PdfSpace(4);
   PdfSubSec("How This Report Measures Execution Quality");
   PdfBody("Execution quality is determined by two independent measurements for every fill:");
   PdfBody("1. Broker execution time — how long the broker held the instruction before executing.");
   PdfBody("2. Execution drift — the difference between the market price at broker receipt and the actual fill price.");
   PdfSpace(2);
   PdfBody("Both lag asymmetry and drift are independent red flags:");
   PdfSpace(2);
   PdfBody("ASYMMETRIC LAG: When stop-like orders (stops, SL) are consistently delayed longer than "
      "limit-like orders (limits, TP), this asymmetry always benefits the broker — regardless of "
      "whether the delayed fills arrive at the trigger price.");
   PdfSpace(2);
   PdfBody("HOW LAGGED FILL CONFIRMATIONS TURN PROFITS INTO LOSSES:");
   PdfSpace(2);
   PdfBody("Your EA sees the market price in real time. But when it sends orders, the broker "
      "delays sending back fill confirmations. Without confirmations, your EA does not know "
      "those positions exist — so it calculates profit, trailing stops, and close decisions on "
      "incomplete data. The EA's math is perfect — but it is solving the wrong equation.");
   PdfSpace(2);
   PdfBody("Step-by-step example:");
   PdfBody("1. Price climbing. EA sends 5 buy orders. Broker confirms 3 fills. EA calculates "
      "P&L on 3 positions. But the account actually has 5 positions — 2 confirmations are delayed.");
   PdfBody("2. EA sees price retracing. Trailing stop calculation based on 3 confirmed positions "
      "shows +$5 profit. Trail triggers — EA closes. But the 2 unseen positions are losing money.");
   PdfBody("3. EA closes 3 confirmed positions at profit. Logs: '+$5 profit, good trade.' "
      "But 2 unconfirmed losing positions are still open. Net P&L is already negative.");
   PdfBody("4. Delayed confirmations finally arrive. Those 2 positions were filled at bad prices "
      "and are deep in the red. They wipe out the +$5 profit AND eat $4 of capital.");
   PdfBody("5. RESULT: EA calculated +$5 profit. Account shows -$4 LOSS. The EA's logic was "
      "perfect. Its trailing stop worked correctly. But it was making decisions based on "
      "3 confirmed fills instead of 5 actual fills.");
   PdfSpace(2);
   PdfBody("Think of it like this: You order 5 items from a supplier to resell at a markup. "
      "Cash on delivery. 3 arrive on time — you pay, mark up, sell at profit. But you ordered 5. "
      "By the time the last 2 arrive, the market price has dropped. You must pay the original price "
      "but can only sell at a loss. Those 2 late deliveries wipe out all the profit from the first 3.");
   PdfSpace(2);
   PdfBody("THE DOUBLE WHAMMY — Two problems compound each other:");
   PdfBody("1. FILL CLUSTERING: Because the broker holds orders, multiple fills arrive at the same "
      "time at the same price. This is the visible evidence — fills batched together instead of "
      "spread across different prices.");
   PdfBody("2. BLIND EA DECISIONS: This is the real damage. Delayed confirmations mean the EA "
      "does not know its true position size. It calculates trailing stops, profit targets, and "
      "close decisions on incomplete data. Every decision after a missing confirmation is wrong.");
   PdfBody("Clustering is the symptom. Blind decisions are the damage. Both are caused by the "
      "same root: the broker holding your orders.");
   PdfSpace(2);
   PdfBody("A fair broker confirms fills immediately. Without instant confirmations, the EA cannot "
      "calculate its true position size, true profit, or true risk. Every trailing stop, every "
      "breakeven move, every close decision is made on incomplete information.");
   PdfSpace(2);
   PdfBody("Therefore, 'zero drift' on server-side triggers does NOT exonerate asymmetric lag. "
      "It does not matter if the fill price matches the trigger price — what matters is WHEN that "
      "fill confirmation arrives. The asymmetric delay itself is the mechanism of harm.");
   PdfSpace(2);
   PdfBody("EXECUTION DRIFT: Non-zero drift proves the broker held an order and the fill price "
      "deviated from the receipt price. This is a separate, additional red flag on top of lag asymmetry.");
   PdfSpace(2);
   PdfBody("Client-server network lag (the time for instructions to travel from EA to broker) is "
      "excluded from all measurements. Network latency is infrastructure, not broker behavior. "
      "All price references use the market price at the moment the broker received the instruction, "
      "not the price when the client sent it.");
   PdfSpace(2);
   PdfBody("For pending orders (stops, limits, TP, SL), the receipt price is the trigger price — "
      "the price that obligated the broker to execute. For market and close orders, the receipt "
      "price is the bid/ask at the broker's server when the instruction arrived (send time + "
      "one-way client-server lag).");
   PdfSpace(2);
   PdfBody("Example: A sell stop triggers at $2,650.00 on XAUUSD (1 lot). A fair "
      "broker fills at $2,650.00 in 5ms — zero drift, zero cost. "
      "A manipulating broker holds for 1,500ms and fills at $2,648.50 — $1.50 drift "
      "during the hold, costing $150.00. But even if the stop fills at trigger price, "
      "the 1,500ms delay infrastructure also applies when the EA sends a close instruction "
      "during a retracement — and THAT close will suffer the full adverse price movement.");
   PdfSpace(2);
   PdfBody("When lag is asymmetric — high for broker-profitable orders, low for "
      "broker-costly orders — it proves discriminatory treatment regardless of drift. "
      "If drift is ALSO non-zero, that compounds the evidence. "
      "Both are independently damning; together they are conclusive.");
   PdfSpace(2);
   PdfBody("All raw data is provided in the accompanying evidence files for "
      "independent verification by any qualified forensic auditor.");

   // ==================== SECTION 3: CLIENT-SERVER ENVIRONMENT ====================
   PdfNewPage();
   PdfSection("SECTION 3: CLIENT-SERVER ENVIRONMENT");
   PdfKV("Round-trip:", StringFormat("%d ms (averaged from 2 calibration passes)", (int)g_clientServerRoundTripMs));
   PdfKV("One-way latency:", StringFormat("%d ms (round-trip / 2)", (int)g_clientServerLagMs));
   PdfKV("  Pass 1:", StringFormat("%d ms one-way, %d ms RT", (int)g_csPass1LagMs, (int)g_csPass1RoundTripMs));
   PdfKV("  Pass 2:", StringFormat("%d ms one-way, %d ms RT", (int)g_csPass2LagMs, (int)g_csPass2RoundTripMs));
   if(g_csCalibPlaceRtMs > 0 || g_csCalibDeleteRtMs > 0)
   {
      PdfKV("  Avg Place RT:", StringFormat("%d ms", (int)g_csCalibPlaceRtMs));
      PdfKV("  Avg Delete RT:", StringFormat("%d ms", (int)g_csCalibDeleteRtMs));
   }
   PdfSpace(4);
   PdfBody("All broker execution time measurements use DEAL_TIME_MSC (the broker's "
      "authoritative server-side timestamp) and deduct client-server latency: "
      "broker_exec = DEAL_TIME_MSC - send_epoch - CS_lag. This isolates the "
      "broker's actual processing time from network transit.");

   // --- Account Settings ---
   PdfSpace(6);
   PdfSubSec("Account Settings (Measured)");
   PdfKV("Reported Leverage:", StringFormat("1:%d", (int)g_accountLeverage));
   string marginModeStr = "Unknown";
   if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) marginModeStr = "Retail Netting";
   else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) marginModeStr = "Exchange";
   else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) marginModeStr = "Retail Hedging";
   PdfKV("Margin Mode:", marginModeStr);
   if(g_measuredMarginBuy > 0)
   {
      PdfKV("Margin (Buy only):", StringFormat("%.2f %s", g_measuredMarginBuy, g_displayCurrency));
      PdfKV("Verified Leverage (Buy):", StringFormat("1:%.0f", g_verifiedLeverage));
   }
   if(g_measuredMarginBoth > 0)
   {
      PdfKV("Margin (Both open):", StringFormat("%.2f %s", g_measuredMarginBoth, g_displayCurrency));
      PdfKV("Equity (Both open):", StringFormat("%.2f %s", g_measuredEquityBoth, g_displayCurrency));
      PdfKV("Verified Leverage (Both):", StringFormat("1:%.0f", g_verifiedLeverageBoth));
      if(g_verifiedLeverage > 0)
      {
         double marginRatio = g_measuredMarginBoth / g_measuredMarginBuy;
         PdfKV("Margin Ratio (Both/Buy):", StringFormat("%.2fx (%s)",
            marginRatio, (marginRatio < 1.5) ? "hedged/netted" : "additive"));
      }
   }
   if(g_calculatedHedgingRatio >= 0)
   {
      string hrDesc = "unknown";
      if(g_calculatedHedgingRatio < 0.01) hrDesc = "NET (hedged = zero margin)";
      else if(g_calculatedHedgingRatio < 0.55) hrDesc = "larger-leg only";
      else if(g_calculatedHedgingRatio < 0.85) hrDesc = "partial additive";
      else hrDesc = "GROSS (both legs)";
      PdfKV("Hedging Ratio:", StringFormat("%.4f — %s", g_calculatedHedgingRatio, hrDesc));
   }

   // --- 8 Sync Measurements ---
   PdfSpace(6);
   PdfSubSec("Sync Execution Baseline (8 Measurements, 2-pass averaged)");
   PdfBody("Each measurement is a single sync (blocking) operation, run twice and averaged. "
      "Broker exec = round_trip - CS_round_trip. All figures are net broker processing "
      "time with client-server network latency removed.");
   PdfSpace(2);
   PdfKV("1. Open Buy:", FormatMs(g_mktSyncOpenBuyMs, true));
   PdfKV("2. Open Sell:", FormatMs(g_mktSyncOpenSellMs, true));
   PdfKV("3. Place SL (Buy):", FormatMs(g_mktSyncSLBuyMs, g_mktSyncSLBuyMs > 0));
   PdfKV("4. Place SL (Sell):", FormatMs(g_mktSyncSLSellMs, g_mktSyncSLSellMs > 0));
   PdfKV("5. Place TP (Buy):", FormatMs(g_mktSyncTPBuyMs, g_mktSyncTPBuyMs > 0));
   PdfKV("6. Place TP (Sell):", FormatMs(g_mktSyncTPSellMs, g_mktSyncTPSellMs > 0));
   PdfKV("7. Close Buy:", StringFormat("%s (%s, PnL: %.2f %s)",
      FormatMs(g_mktSyncCloseBuyMs, g_mktSyncCloseBuyMs > 0),
      g_mktCloseBuyInProfit ? "PROFIT" : "LOSS", g_mktCloseBuyPnL, g_displayCurrency));
   PdfKV("8. Close Sell:", StringFormat("%s (%s, PnL: %.2f %s)",
      FormatMs(g_mktSyncCloseSellMs, g_mktSyncCloseSellMs > 0),
      g_mktCloseSellInProfit ? "PROFIT" : "LOSS", g_mktCloseSellPnL, g_displayCurrency));

   // ==================== SECTION 4: FINDINGS ====================
   PdfNewPage();
   PdfSection("SECTION 4: DETAILED FINDINGS");

   // --- Execution Audit Table — Fill Accuracy primary, lag as context ---
   PdfSubSec("Broker Execution Audit");
   PdfBody(StringFormat("Fill accuracy is the primary metric per MiFID II best execution. "
      "Lag (%dms CS latency removed) shown as context. "
      "Long lag + clustering can devastate grid strategies.", (int)g_clientServerRoundTripMs));
   PdfSpace(4);

   // 5-column table: Operation | Count | Fill Accuracy | Lag | Verdict
   {
      double c1 = PDF_ML;          // Operation
      double c2 = PDF_ML + 110;    // Count
      double c3 = PDF_ML + 155;    // Fill Accuracy
      double c4 = PDF_ML + 330;    // Lag
      double c5 = PDF_ML + 410;    // Verdict

      // Header row background
      PdfCheckY(18);
      g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 14 re f\n",
         PDF_ML, g_pdfY - 4, PDF_CW);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Operation) Tj ET\n", c1 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Count) Tj ET\n", c2 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Fill Accuracy) Tj ET\n", c3 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Median Lag) Tj ET\n", c4 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Verdict) Tj ET\n", c5 + 4, g_pdfY);
      g_pdfY -= 18;

      // Data rows — per order type
      for(int t = 0; t < 10; t++)
      {
         if(g_countByType[t] == 0) continue;

         int stdGood3;
         if(t <= 1) stdGood3 = STD_MARKET_GOOD_MS;
         else if(t <= 5) stdGood3 = STD_FILL_GOOD_MS;
         else if(t <= 7) stdGood3 = STD_TPSL_GOOD_MS;
         else if(t == 9) stdGood3 = STD_SYNC_CLOSE_GOOD_MS;
         else stdGood3 = STD_CLOSE_GOOD_MS;

         double meas = g_medianLag[t];
         string countStr2;
         if(g_lagValidCount[t] < g_countByType[t])
            countStr2 = StringFormat("%d (%d)", g_countByType[t], g_lagValidCount[t]);
         else
            countStr2 = IntegerToString(g_countByType[t]);
         string medStr2 = (g_lagValidCount[t] > 0) ? FormatMs(meas, true) : "N/A";

         // Fill accuracy and verdict
         string fillAccPdf = "";
         string verdictPdf = "";
         double vr2 = 0, vg2 = 0.6, vb2 = 0;  // verdict color (default green)
         double fr2 = 0, fg2 = 0.6, fb2 = 0;  // fill acc color (default green)

         // Structural asymmetry: stops/SL fill at market (lag-based verdict),
         // limits/TP have price guarantee (trigger fill %-based verdict).
         int pdfTotalClassified = g_triggerFillCount[t] + g_marketFillCount[t];
         bool pdfIsStopLike = (t == 2 || t == 3 || t == 7);
         bool pdfLagExceeded = (meas > stdGood3);
         bool pdfAsymOverride = (hasStructuralAsymmetry || g_vdpLagRatio > 2.0) && pdfIsStopLike;

         if(t >= 2 && t <= 7 && pdfTotalClassified > 0)
         {
            double pdfTrigPct = (double)g_triggerFillCount[t] / pdfTotalClassified * 100.0;
            fillAccPdf = StringFormat("%.0f%% trigger, %.0f%% market", pdfTrigPct, 100.0 - pdfTrigPct);

            if(pdfAsymOverride)
            {
               // Asymmetric lag on broker-profitable type
               fr2 = 0.85; fg2 = 0.1; fb2 = 0; verdictPdf = "FAIL (asymmetric lag)"; vr2 = 0.85; vg2 = 0.1;
            }
            else if(pdfIsStopLike)
            {
               // Stops/SL: market fill is normal. Verdict on lag only.
               if(!pdfLagExceeded)
               {
                  fg2 = 0.6; verdictPdf = "PASS (fast lag)"; vg2 = 0.6;
               }
               else
               {
                  fr2 = 0.85; fg2 = 0.3; fb2 = 0; verdictPdf = "SLOW (adds slippage)"; vr2 = 0.85; vg2 = 0.3;
               }
            }
            else if(meas < 10.0)
            {
               // Limits/TP with <10ms: instant execution, can't manipulate
               fg2 = 0.6; verdictPdf = "PASS (instant)"; vg2 = 0.6;
            }
            else if(pdfTrigPct >= 90.0)
            {
               // Limits/TP: price guarantee honoured
               fg2 = 0.6; verdictPdf = "PASS"; vg2 = 0.6;
            }
            else if(pdfTrigPct >= 70.0)
            {
               // Limits/TP: price guarantee partially violated
               fr2 = 0.85; fg2 = 0.55; fb2 = 0; verdictPdf = "CAUTION"; vr2 = 0.85; vg2 = 0.55;
            }
            else
            {
               // Limits/TP: price guarantee violated (with slow lag)
               fr2 = 0.85; fg2 = 0.1; fb2 = 0; verdictPdf = "FAIL"; vr2 = 0.85; vg2 = 0.1;
            }
         }
         else if(t >= 2 && t <= 7)
         {
            fillAccPdf = "N/A";
            verdictPdf = (meas <= stdGood3) ? "PASS" : "SLOW";
            if(meas > stdGood3) { vr2 = 0.6; vg2 = 0.6; }
         }
         else
         {
            // Market orders and closes — drift-based
            double pdfMeanDrift = (g_driftLagCount[t] > 0) ? g_driftLagSum[t] / g_driftLagCount[t] : 0;
            if(g_driftLagCount[t] > 0)
            {
               if(pdfMeanDrift < 5.0) fillAccPdf = "No drift";
               else fillAccPdf = StringFormat("%.1fms drift", pdfMeanDrift);
            }
            else
               fillAccPdf = "EA-initiated";
            bool pdfDriftHarmless = (pdfMeanDrift < 5.0);
            if(meas <= stdGood3) { verdictPdf = "PASS"; }
            else if(pdfDriftHarmless) { verdictPdf = "SLOW"; vr2 = 0.6; vg2 = 0.6; }
            else { verdictPdf = "FAIL"; vr2 = 0.85; vg2 = 0.1; }
         }

         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
            c1 + 4, g_pdfY, PdfEsc(GetFillTypeName((ENUM_FILL_TYPE)t)));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n",
            c2 + 4, g_pdfY, PdfEsc(countStr2));
         g_pdfCurStream += StringFormat("BT /F2 7.5 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
            fr2, fg2, fb2, c3 + 4, g_pdfY, PdfEsc(fillAccPdf));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n",
            c4 + 4, g_pdfY, PdfEsc(medStr2));
         g_pdfCurStream += StringFormat("BT /F2 7.5 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
            vr2, vg2, vb2, c5 + 4, g_pdfY, PdfEsc(verdictPdf));
         // Row separator
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // Close Buy row — 5-column layout
      if(g_mktCloseBuySendMs > 0)
      {
         bool cbFail = (g_mktSyncCloseBuyMs > STD_SYNC_CLOSE_GOOD_MS);
         string cbLabel = StringFormat("Close Buy (%s)", g_mktCloseBuyInProfit ? "PROFIT" : "LOSS");
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", c1 + 4, g_pdfY, PdfEsc(cbLabel));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (1) Tj ET\n", c2 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (EA-initiated) Tj ET\n", c3 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n", c4 + 4, g_pdfY, PdfEsc(FormatMs(g_mktSyncCloseBuyMs)));
         if(cbFail)
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (FAIL) Tj ET\n", c5 + 4, g_pdfY);
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (PASS) Tj ET\n", c5 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // Close Sell row — 5-column layout
      if(g_mktCloseSellSendMs > 0)
      {
         bool csFail = (g_mktSyncCloseSellMs > STD_SYNC_CLOSE_GOOD_MS);
         string csLabel = StringFormat("Close Sell (%s)", g_mktCloseSellInProfit ? "PROFIT" : "LOSS");
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", c1 + 4, g_pdfY, PdfEsc(csLabel));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (1) Tj ET\n", c2 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (EA-initiated) Tj ET\n", c3 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n", c4 + 4, g_pdfY, PdfEsc(FormatMs(g_mktSyncCloseSellMs)));
         if(csFail)
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (FAIL) Tj ET\n", c5 + 4, g_pdfY);
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (PASS) Tj ET\n", c5 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // Async Open row — 5-column with fill accuracy
      {
         double tblAsyncOpenMs = 0;
         if(g_gridEarliestSetupMsc > 0 && g_gridPlacedMs > 0)
         {
            long aoSendEp = (long)(g_epochMsOffset + g_gridPlacedMs);
            tblAsyncOpenMs = (double)(g_gridEarliestSetupMsc - aoSendEp - (long)g_clientServerLagMs);
            if(tblAsyncOpenMs < 0) tblAsyncOpenMs = 0;
         }
         if(g_gridOrdersConfirmed > 0)
         {
            // Use stop trigger fill % for grid open since those are the pending orders
            int aoStopClass = g_triggerFillCount[2] + g_marketFillCount[2] + g_triggerFillCount[3] + g_marketFillCount[3];
            int aoStopTrig = g_triggerFillCount[2] + g_triggerFillCount[3];
            double aoTrigPct = (aoStopClass > 0) ? (double)aoStopTrig / aoStopClass * 100.0 : -1;
            string aoAccStr = (aoTrigPct >= 0) ? StringFormat("%.0f%% trigger (grid)", aoTrigPct) : "Async batch";
            double aoAr = 0, aoAg = 0.6, aoAb = 0;
            if(aoTrigPct >= 0 && aoTrigPct < 70) { aoAr = 0.85; aoAg = 0.1; }
            else if(aoTrigPct >= 0 && aoTrigPct < 90) { aoAr = 0.85; aoAg = 0.55; }

            bool aoFail = (tblAsyncOpenMs > STD_FILL_GOOD_MS) && (aoTrigPct < 90.0 || aoTrigPct < 0);
            PdfCheckY(14);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Async Open \\(grid\\)) Tj ET\n", c1 + 4, g_pdfY);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%d) Tj ET\n", c2 + 4, g_pdfY, g_gridOrdersConfirmed);
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf %.2f %.2f %.2f rg %.1f %.1f Td (%s) Tj ET\n",
               aoAr, aoAg, aoAb, c3 + 4, g_pdfY, PdfEsc(aoAccStr));
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n", c4 + 4, g_pdfY, PdfEsc(FormatMs(tblAsyncOpenMs)));
            if(aoFail)
               g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (FAIL) Tj ET\n", c5 + 4, g_pdfY);
            else
               g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (PASS) Tj ET\n", c5 + 4, g_pdfY);
            g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
               PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
            g_pdfY -= 14;
         }
      }

      // Async Close row — 5-column with fill accuracy
      {
         double tblAsyncCloseMs = 0;
         if(g_posCloseEarliestMsc > 0 && g_posCloseSendMs > 0)
         {
            long acSendEp = (long)(g_epochMsOffset + g_posCloseSendMs);
            tblAsyncCloseMs = (double)(g_posCloseEarliestMsc - acSendEp - (long)g_clientServerLagMs);
            if(tblAsyncCloseMs < 0) tblAsyncCloseMs = 0;
         }
         if(g_asyncCloseCount > 0 || g_posCloseFirstFillBootMs > 0)
         {
            int totalCl = g_asyncCloseCount + g_syncCloseCount;
            bool acFail = (tblAsyncCloseMs > STD_CLOSE_GOOD_MS);
            bool acDriftH = (g_driftLagCount[8] > 0) ? (g_driftLagSum[8] / g_driftLagCount[8] < 5.0) : false;
            PdfCheckY(14);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Async Close \\(batch\\)) Tj ET\n", c1 + 4, g_pdfY);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%d) Tj ET\n", c2 + 4, g_pdfY, totalCl);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (EA-initiated) Tj ET\n", c3 + 4, g_pdfY);
            g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n", c4 + 4, g_pdfY, PdfEsc(FormatMs(tblAsyncCloseMs)));
            if(acFail && !acDriftH)
               g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (FAIL) Tj ET\n", c5 + 4, g_pdfY);
            else
               g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (PASS) Tj ET\n", c5 + 4, g_pdfY);
            g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
               PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
            g_pdfY -= 14;
         }
      }
   }

   // --- Asymmetry Detection Table (matches HTML) ---
   PdfSpace(8);
   PdfSubSec("Asymmetry Detection");
   PdfBody("Comparing your execution time vs the broker's execution time. Fair execution allocates the same processing time to both sides — the side with faster execution reaps all the benefits.");
   PdfSpace(4);

   // 4-column asymmetry table
   {
      double a1 = PDF_ML;          // Comparison
      double a2 = PDF_ML + 130;    // Trader Benefit
      double a3 = PDF_ML + 240;    // Broker Benefit
      double a4 = PDF_ML + 340;    // Ratio
      double a5 = PDF_ML + 400;    // Result

      PdfCheckY(18);
      g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 14 re f\n", PDF_ML, g_pdfY - 4, PDF_CW);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Comparison) Tj ET\n", a1 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Your Execution) Tj ET\n", a2 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Broker Execution) Tj ET\n", a3 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Ratio) Tj ET\n", a4 + 4, g_pdfY);
      g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Result) Tj ET\n", a5 + 4, g_pdfY);
      g_pdfY -= 18;

      // Stop vs Limit — asymmetric delay
      {
         string slR = (stopLimitRatio > 2.0) ? "ASYMMETRIC" : "FAIR";
         bool slFail = (stopLimitRatio > 2.0);  // Asymmetric delay is a failure
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Stop vs Limit) Tj ET\n", a1 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Stop: %s) Tj ET\n", a2 + 4, g_pdfY, PdfEsc(FormatMs(medStopLag)));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Limit: %s) Tj ET\n", a3 + 4, g_pdfY, PdfEsc(FormatMs(medLimitLag)));
         g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0 0 rg %.1f %.1f Td (%.1fx) Tj ET\n", a4 + 4, g_pdfY, stopLimitRatio);
         if(slFail)
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(slR));
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(slR));
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // SL vs TP
      if(g_countByType[6] > 0 && g_countByType[7] > 0)
      {
         string tsR = (tpslExecRatio > 2.0) ? "ASYMMETRIC" : "FAIR";
         bool tsFail = (tpslExecRatio > 2.0);  // Asymmetric SL/TP delay benefits broker
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (SL vs TP) Tj ET\n", a1 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (SL: %s \\(n=%d\\)) Tj ET\n", a2 + 4, g_pdfY, PdfEsc(FormatMs(medSLLag)), g_countByType[7]);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (TP: %s \\(n=%d\\)) Tj ET\n", a3 + 4, g_pdfY, PdfEsc(FormatMs(medTPLag)), g_countByType[6]);
         g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0 0 rg %.1f %.1f Td (%.1fx) Tj ET\n", a4 + 4, g_pdfY, tpslExecRatio);
         if(tsFail)
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(tsR));
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(tsR));
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // Fill Accuracy — overall and per-type
      {
         double fairPctPdf = (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0;
         double sFairPctPdf = (g_totalStopPriced > 0) ? (double)g_fairFillsStop / g_totalStopPriced * 100 : 0;
         double lFairPctPdf = (g_totalLimitPriced > 0) ? (double)g_fairFillsLimit / g_totalLimitPriced * 100 : 0;
         string bMeas = StringFormat("%d/%d (%.0f%%)", g_fairFills, g_totalPricedFills, fairPctPdf);
         string bStop = StringFormat("Stop: %d/%d (%.0f%%)", g_fairFillsStop, g_totalStopPriced, sFairPctPdf);
         string bLimit = StringFormat("Limit: %d/%d (%.0f%%)", g_fairFillsLimit, g_totalLimitPriced, lFairPctPdf);
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Fill Accuracy) Tj ET\n", a1 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", a2 + 4, g_pdfY, PdfEsc(bStop));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", a3 + 4, g_pdfY, PdfEsc(bLimit));
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (100%%) Tj ET\n", a4 + 4, g_pdfY);
         if(g_batchClassification == "MANIPULATION")
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(g_batchClassification));
         else if(g_batchClassification == "CAUTION")
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.55 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(g_batchClassification));
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(g_batchClassification));
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }

      // Order Rejections row
      {
         int pdf2StopRej = 0, pdf2LimitRej = 0;
         for(int r = 0; r < g_rejectionCount; r++)
         {
            if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
            if(StringFind(g_rejections[r].orderType, "Stop") >= 0)  pdf2StopRej++;
            if(StringFind(g_rejections[r].orderType, "Limit") >= 0) pdf2LimitRej++;
         }

         string rjResult;
         bool rjFail = false;
         string rjRatioStr;
         if(pdf2StopRej == 0 && pdf2LimitRej == 0)
         {
            rjResult = "FAIR";
            rjRatioStr = "-";
         }
         else if(pdf2LimitRej > 0)
         {
            double rjR = (double)pdf2StopRej / pdf2LimitRej;
            rjRatioStr = StringFormat("%.1fx", rjR);
            rjResult = (rjR > 3.0) ? "FAIL" : (rjR > 2.0) ? "SUSPICIOUS" : "FAIR";
            rjFail = (rjR > 2.0);
         }
         else
         {
            rjRatioStr = StringFormat("%d:0", pdf2StopRej);
            rjResult = (pdf2StopRej >= 3) ? "FAIL" : "SUSPICIOUS";
            rjFail = true;
         }

         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Order Rejections) Tj ET\n", a1 + 4, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Your stops: %d rej) Tj ET\n", a2 + 4, g_pdfY, pdf2StopRej);
         g_pdfCurStream += StringFormat("BT /F1 7.5 Tf 0 0 0 rg %.1f %.1f Td (Broker lim: %d rej) Tj ET\n", a3 + 4, g_pdfY, pdf2LimitRej);
         g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", a4 + 4, g_pdfY, PdfEsc(rjRatioStr));
         if(rjFail)
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0.85 0.1 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(rjResult));
         else
            g_pdfCurStream += StringFormat("BT /F2 7.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s) Tj ET\n", a5 + 4, g_pdfY, PdfEsc(rjResult));
         g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n",
            PDF_ML, g_pdfY - 4, PDF_ML + PDF_CW, g_pdfY - 4);
         g_pdfY -= 14;
      }
   }

   // --- Asymmetric Execution Note ---
   if(g_countByType[6] > 0 && g_countByType[7] > 0 && (tpslExecRatio > 2.0 || stopLimitRatio > 2.0))
   {
      PdfSpace(8);
      PdfSubSec("Asymmetric Execution Warning");
      PdfBody("The stop/limit and SL/TP timing asymmetry measured above is discriminatory and "
         "always benefits the broker:");
      PdfBody("- Stop orders and SL are delayed significantly longer than limit orders and TP.");
      PdfBody("- This asymmetric delay applies to ALL broker operations, not just server-side triggers.");
      PdfBody("- When an EA monitors profit and closes positions during a retracement, counter orders "
         "triggered BEFORE the close may still be held by the broker with asymmetric lag.");
      PdfBody("- These lagged counter fills arrive AFTER the EA has already closed — creating new "
         "unwanted positions against the trader. The losses can be enormous.");
      PdfSpace(2);
      PdfBody("Even if server-side triggers fill at the trigger price, this does NOT exonerate the "
         "asymmetric delay. It does not matter what price the fill arrives at — what matters is "
         "WHEN it arrives. A fill that arrives after the EA has closed creates unwanted exposure "
         "regardless of its price accuracy.");
   }

   // --- Close Price Cross-Validation ---
   PdfSpace(8);
   PdfSubSec("Close Price Cross-Validation");
   PdfBody("Each close fill's deal price is cross-validated against the EA's tick buffer "
      "at the broker's recorded execution time (DEAL_TIME_MSC).");
   PdfSpace(2);
   if(g_closePriceVerifyCount > 0)
   {
      PdfKV("Verified Fills:", IntegerToString(g_closePriceVerifyCount));
      PdfKV("Mismatches (>0.5 pts):", IntegerToString(g_closePriceMismatchCount));
      PdfKV("Mean |Delta|:", StringFormat("%.2f %s", g_closePriceVerifyAbsSum / g_closePriceVerifyCount, g_unitLabel));
      PdfKV("Max |Delta|:", StringFormat("%.2f %s", g_closePriceVerifyMaxAbs, g_unitLabel));
      bool fastCloseExec = (g_asyncCloseMedianLag <= 20 && (g_syncCloseCount == 0 || g_syncCloseMedianLag <= 20));
      string verifyAssess;
      if(g_closePriceMismatchCount == 0)
         verifyAssess = "PASS - Deal prices match tick data exactly";
      else if(g_closePriceMismatchCount <= 2)
         verifyAssess = "ACCEPTABLE - Minor discrepancies within tick resolution";
      else if(fastCloseExec)
         verifyAssess = "NOTE - Price deltas reflect tick buffer resolution at fast execution speeds (<10ms lag)";
      else
         verifyAssess = "FAIL - Multiple price mismatches detected";
      PdfBodyBold(StringFormat("Assessment: %s", verifyAssess));
   }
   else
      PdfBody("No close fills available for cross-validation.");

   // --- Direction Bias ---
   PdfSpace(4);
   // Buy vs Sell direction bias
   double buyLag = 0, sellLag = 0;
   int nBuy = 0, nSell = 0;
   for(int i = 0; i < g_fillCount; i++)
   {
      if(g_fills[i].fillType >= FILL_BUYSTOP && g_fills[i].fillType <= FILL_SELLLIMIT)
      {
         if(g_fills[i].isBuy) { buyLag += g_fills[i].brokerExecMs; nBuy++; }
         else                 { sellLag += g_fills[i].brokerExecMs; nSell++; }
      }
   }
   if(nBuy > 0) buyLag /= nBuy;
   if(nSell > 0) sellLag /= nSell;
   double dirRatio = (MathMin(buyLag, sellLag) > 0.001) ? MathMax(buyLag, sellLag) / MathMin(buyLag, sellLag) : (MathMax(buyLag, sellLag) > 0.001 ? 999.0 : 0);
   if(dirRatio > 2.0) hasAsymmetry = true;

   PdfBodyBold("Buy vs Sell direction bias:");
   PdfBody(StringFormat("Buy avg lag: %s (n=%d) | Sell avg lag: %s (n=%d) | Ratio: %.1fx",
      FormatMs(buyLag), nBuy, FormatMs(sellLag), nSell, dirRatio));
   PdfBody(StringFormat("%s",
      (dirRatio > 2.0) ? "DIRECTIONAL BIAS DETECTED" :
      (dirRatio > 1.5) ? "Slight directional bias" : "No significant bias"));

   // 5.8 Price Rounding
   PdfSpace(6);
   PdfSubSec("4.10 Price Rounding Analysis");
   if(g_roundingErrorCount > 0)
   {
      double roundingBias = g_roundingErrorSum / g_roundingErrorCount;
      PdfKV("Total rounding errors:", IntegerToString((int)g_roundingErrorCount));
      PdfKV("Cumulative rounding:", StringFormat("%+.6f %s", g_roundingErrorSum, g_displayCurrency));
      PdfKV("Mean rounding/fill:", StringFormat("%+.6f %s", roundingBias, g_displayCurrency));
      PdfKV("Max absolute:", StringFormat("%.6f %s", g_roundingErrorMax, g_displayCurrency));
      string roundDir;
      if(g_roundingErrorSum < -0.001)
      {
         double meanRound = MathAbs(g_roundingErrorSum / g_roundingErrorCount);
         if(meanRound < 0.05)
            roundDir = "Slight broker-favorable bias (negligible per fill)";
         else
            roundDir = "FAVORS BROKER (client loses)";
      }
      else if(g_roundingErrorSum > 0.001)
         roundDir = "Favors client";
      else
         roundDir = "Approximately neutral";
      PdfKV("Direction:", roundDir);
      if(g_totalLotsTraded > 0)
         PdfKV("Projected annual (1 lot/day):", FormatMoney(MathAbs(roundingBias) * (1.0 / g_lotSize) * 252.0));
   }

   // 5.9 Fill Clustering & Batching Analysis
   PdfSpace(6);
   PdfSubSec("4.11 Fill Clustering & Batching Analysis");

   // Part A: Fill clustering (exact-match detection)
   PdfBodyBold("A. Fill Clustering (exact-match detection)");
   PdfBody("Detects fills sharing the exact same price, broker timestamp (DEAL_TIME_MSC), "
      "direction, and order category. Clusters indicate batch processing where the broker "
      "groups pending orders instead of filling them individually — a hallmark of B-book internalization.");
   PdfSpace(2);
   PdfKV("Cluster method:", "Exact match (same price + timestamp + direction + order category)");
   PdfKV("Total grid fills:", IntegerToString(
      g_countByType[2] + g_countByType[3] + g_countByType[4] + g_countByType[5]));
   PdfKV("Fill clusters detected:", IntegerToString(g_clusterCount));
   PdfKV("Isolated fills:", IntegerToString(g_isolatedFills));
   PdfKV("Avg cluster size:", StringFormat("%.1f fills", g_avgClusterSize));
   PdfKV("Largest cluster:", IntegerToString((int)g_maxClusterSize));
   PdfKV("Avg inter-cluster gap:", FormatMs(g_avgInterClusterGap));
   PdfKV("Fill clustering ratio:", StringFormat("%.0f%%", g_clusterRatio * 100));

   // Part B: Price-based batching
   PdfSpace(4);
   PdfBodyBold("B. Price-Based Batching (actual fill damage)");
   PdfBody("Measures whether different grid levels filled at the same price — "
      "the direct evidence of the broker holding orders and filling them in a batch. "
      "Includes grid entries, SL, and TP fills.");
   PdfSpace(2);
   PdfKV("Total priced fills:", IntegerToString(g_totalPricedFills));
   PdfKV("Fills at trigger price:", StringFormat("%d (%.0f%%)", g_fairFills,
      (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0));
   PdfKV("Price batches detected:", IntegerToString(g_batchCount));
   if(g_batchCount > 0)
   {
      PdfKV("Batched fills:", IntegerToString(g_totalBatchedFills));
      PdfKV("Avg batch size:", StringFormat("%.1f fills", g_avgBatchSize));
      PdfKV("Largest batch:", IntegerToString(g_maxBatchSize));
      PdfKV("Batch ratio:", StringFormat("%.0f%%", g_batchRatio * 100));
      PdfKV("Avg broker advantage:", StringFormat("%.1f points/fill", g_avgBatchAdvantagePts));
      PdfKV("Total broker advantage:", StringFormat("%.1f points", g_batchAdvantagePts));
      PdfKV("Avg batch hold time:", FormatMs(g_avgBatchTimeSpanMs));
      PdfKV("Max batch hold time:", FormatMs(g_maxBatchTimeSpanMs));
      PdfKV("Median batch hold time:", FormatMs(g_medBatchTimeSpanMs));
   }

   // Part C: Classification
   PdfSpace(4);
   PdfBodyBold("C. Classification");
   PdfBody("Stops/SL fill at market by design (structural asymmetry in MT5 execution model). "
      "Low trigger fill % on stops is expected, not a red flag. "
      "Limits/TP have price guarantees — low trigger fill % on these IS the broker's fault. "
      "The forensic signal is LAG RATIO: does the broker add extra delay on broker-profitable orders?");
   PdfSpace(2);
   if(hasStructuralAsymmetry || g_vdpLagRatio > 2.0)
   {
      // Asymmetric lag: broker adding delay on top of structural asymmetry
      PdfBodyColor(StringFormat("FAIL — Asymmetric execution detected (%.0fx). "
         "Broker adds extra delay on broker-profitable orders (stops/SL) beyond the structural asymmetry. "
         "This is broker manipulation, not market conditions.",
         stopLimitRatio > tpslExecRatio ? stopLimitRatio : tpslExecRatio), 0.95, 0, 0);
   }
   else if(g_batchClassification == "MANIPULATION")
      PdfBodyColor(StringFormat("MANIPULATION — %sExcessive lag detected. Broker delays worsen structural slippage on stops/SL.",
         (g_batchCount > 0) ? StringFormat("Price batching detected (%d batches, %.1f pts advantage). ", g_batchCount, g_batchAdvantagePts) : ""), 0.85, 0, 0);
   else if(g_batchClassification == "CAUTION")
      PdfBodyColor(StringFormat("CAUTION — Limit/TP trigger fill rate 70-90%% on some order types. "
         "Stops/SL: lag-based (fast = FAIR). Limits/TP: %d/%d at trigger (%.0f%%).",
         g_fairFills, g_totalPricedFills,
         (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0), 0.85, 0.55, 0);
   else
      PdfBodyColor(StringFormat("FAIR — Fast symmetric lag, no asymmetry. Limits/TP: %d/%d at trigger (%.0f%%). "
         "Stops/SL: market fills are normal (structural).",
         g_fairFills, g_totalPricedFills,
         (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0), 0, 0.60, 0);

   // ==================== PATTERN 1: SYMMETRIC LAST-LOOK (PDF) ====================
   {
      PdfNewPage();
      PdfSection("PATTERN 1: How Symmetric Lag Enables Last-Look");

      // Calculate max lag for example
      double p1Lag = 0;
      for(int t = 0; t < 10; t++)
         if(g_lagValidCount[t] > 0 && g_medianLag[t] > p1Lag) p1Lag = g_medianLag[t];
      bool p1Hypo = (p1Lag < 100);
      double p1Show = p1Hypo ? 250.0 : p1Lag;
      string p1Str = FormatMs(p1Show);

      PdfBody("A broker that delays ALL orders equally looks fair - there is no discrimination. "
         "But if that equal delay is slow, the broker has a window to inspect every order before confirming it. "
         "The market moves during the delay. The broker sees which direction. Then it decides what price to give you.");
      PdfSpace(4);

      PdfSubSec(StringFormat("What Happens Inside the %s Window", p1Str));
      PdfBody("SCENARIO A: Price rises (against your buy) - Broker fills at HIGHER price. You pay more. "
         "Broker or LP keeps the difference.");
      PdfBody("SCENARIO B: Price drops (in your favor) - Broker fills at ORIGINAL price. "
         "No improvement given. Or the order is requoted entirely.");
      PdfSpace(2);
      PdfBodyColor("Result: You absorb all adverse moves. You receive none of the favorable ones. This is last-look.", 0.85, 0.4, 0);
      PdfSpace(6);

      // 10-trade comparison table
      PdfSubSec("10 Gold Trades: Fast Broker vs Slow Symmetric Broker");
      if(p1Hypo)
         PdfBody(StringFormat("(Illustrative at 250ms - this broker's actual max lag was %s)", FormatMs(p1Lag)));
      else
         PdfBody(StringFormat("(Using this broker's measured maximum lag of %s)", p1Str));
      PdfSpace(4);

      // Custom 5-column table
      {
         double c1 = PDF_ML;
         double c2 = PDF_ML + 28;
         double c3 = PDF_ML + 115;
         double c4 = PDF_ML + 225;
         double c5 = PDF_ML + 335;
         double rw = PDF_CW;

         // FAIR BROKER HEADER
         PdfCheckY(16);
         g_pdfCurStream += StringFormat("0 0.40 0 rg %.1f %.1f %.1f 14 re f\n", PDF_ML, g_pdfY - 4, rw);
         g_pdfCurStream += StringFormat("BT /F2 8 Tf 1 1 1 rg %.1f %.1f Td (FAIR BROKER \\(30ms\\) - No time for price to move) Tj ET\n",
            PDF_ML + 4, g_pdfY);
         g_pdfY -= 18;

         // Header row
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 12 re f\n", PDF_ML, g_pdfY - 3, rw);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (#) Tj ET\n", c1+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Request Price) Tj ET\n", c2+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (30ms Later) Tj ET\n", c3+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Filled At) Tj ET\n", c4+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Hidden Cost) Tj ET\n", c5+2, g_pdfY);
         g_pdfY -= 14;

         string fairP[] = {"$2,000.00","$2,001.20","$1,999.50","$2,002.00","$1,998.80",
                           "$2,003.10","$2,000.90","$2,004.00","$1,997.60","$2,001.50"};
         for(int i = 0; i < 10; i++)
         {
            PdfCheckY(12);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%d) Tj ET\n", c1+2, g_pdfY, i+1);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", c2+2, g_pdfY, fairP[i]);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td (~same) Tj ET\n", c3+2, g_pdfY);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", c4+2, g_pdfY, fairP[i]);
            g_pdfCurStream += StringFormat("BT /F2 7 Tf 0 0.5 0 rg %.1f %.1f Td ($0) Tj ET\n", c5+2, g_pdfY);
            g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n", PDF_ML, g_pdfY-3, PDF_ML+rw, g_pdfY-3);
            g_pdfY -= 12;
         }
         // Total
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F2 8 Tf 0 0.5 0 rg %.1f %.1f Td (Hidden cost: $0.00) Tj ET\n", c5-40, g_pdfY);
         g_pdfY -= 16;

         PdfSpace(6);

         // SLOW BROKER HEADER
         PdfCheckY(16);
         g_pdfCurStream += StringFormat("0.60 0.35 0 rg %.1f %.1f %.1f 14 re f\n", PDF_ML, g_pdfY - 4, rw);
         g_pdfCurStream += StringFormat("BT /F2 8 Tf 1 1 1 rg %.1f %.1f Td (%s) Tj ET\n",
            PDF_ML + 4, g_pdfY, PdfEsc(StringFormat("SLOW SYMMETRIC BROKER (%s) - Price moves in window, broker fills accordingly", p1Str)));
         g_pdfY -= 18;

         // Header row
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 12 re f\n", PDF_ML, g_pdfY - 3, rw);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (#) Tj ET\n", c1+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Request Price) Tj ET\n", c2+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (%s) Tj ET\n", c3+2, g_pdfY, PdfEsc(p1Str + " Later"));
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Filled At) Tj ET\n", c4+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Hidden Cost) Tj ET\n", c5+2, g_pdfY);
         g_pdfY -= 14;

         string slowF[] = {"$2,000.40","$2,001.20","$1,999.80","$2,002.00","$1,999.30",
                           "$2,003.50","$2,000.90","$2,004.60","$1,997.60","$2,001.90"};
         string slowW[] = {"$2,000.40 UP","$2,000.90 DN","$1,999.80 UP","$2,001.50 DN","$1,999.30 UP",
                           "$2,003.50 UP","$2,000.60 DN","$2,004.60 UP","$1,997.20 DN","$2,001.90 UP"};
         string slowC[] = {"-$40","$0","-$30","$0","-$50","-$40","$0","-$60","$0","-$40"};
         bool slowAdv[] = {true,false,true,false,true,true,false,true,false,true};

         for(int i = 0; i < 10; i++)
         {
            PdfCheckY(12);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%d) Tj ET\n", c1+2, g_pdfY, i+1);
            g_pdfCurStream += StringFormat("BT /F1 7 Tf 0 0 0 rg %.1f %.1f Td (%s) Tj ET\n", c2+2, g_pdfY, fairP[i]);
            if(slowAdv[i])
               g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.85 0.3 0.3 rg %.1f %.1f Td (%s) Tj ET\n", c3+2, g_pdfY, PdfEsc(slowW[i]));
            else
               g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.3 0.7 0.3 rg %.1f %.1f Td (%s) Tj ET\n", c3+2, g_pdfY, PdfEsc(slowW[i]));
            if(slowAdv[i])
            {
               g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (%s) Tj ET\n", c4+2, g_pdfY, PdfEsc(slowF[i]));
               g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (%s) Tj ET\n", c5+2, g_pdfY, PdfEsc(slowC[i]));
            }
            else
            {
               g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.6 0.4 0 rg %.1f %.1f Td (%s) Tj ET\n", c4+2, g_pdfY, PdfEsc(slowF[i]));
               g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.5 0.5 0.5 rg %.1f %.1f Td ($0) Tj ET\n", c5+2, g_pdfY);
            }
            g_pdfCurStream += StringFormat("0.85 0.85 0.85 RG 0.3 w %.1f %.1f m %.1f %.1f l S\n", PDF_ML, g_pdfY-3, PDF_ML+rw, g_pdfY-3);
            g_pdfY -= 12;
         }
         // Total
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("BT /F2 9 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (Hidden cost \\(1 lot = 100oz\\): -$260) Tj ET\n", c4-30, g_pdfY);
         g_pdfY -= 16;
      }

      PdfSpace(6);
      PdfBodyBold(StringFormat("Same 10 trades. Same market. Same symmetric %s delay.", p1Str));
      PdfBody("Fast broker: $0. Slow broker: -$260. Over 250 trading days: -$6,500/year in hidden losses.");
      PdfSpace(6);

      // Analogy
      PdfSubSec("Analogy: The Delayed Cash Register");
      PdfBody("Imagine a shop where the cash register takes 5 minutes to process every transaction. "
         "Seems fair - everyone waits equally. But during those 5 minutes, the shopkeeper watches the ticker. "
         "If the item's price went up, the shopkeeper charges the new higher price. "
         "If the price went down, the shopkeeper charges the original price anyway. "
         "The fairness is in the wait time. The unfairness is in the price you pay.");
      PdfSpace(6);

      // Key insight
      PdfCheckY(50);
      g_pdfCurStream += StringFormat("0.85 0.4 0 RG 1.5 w %.1f %.1f %.1f 44 re S\n",
         PDF_ML, g_pdfY - 40, PDF_CW);
      g_pdfCurStream += StringFormat("0.16 0.10 0.10 rg %.1f %.1f %.1f 44 re f\n",
         PDF_ML + 1, g_pdfY - 39, PDF_CW - 2);
      g_pdfY -= 8;
      PdfCenterBold("Symmetric lag = equal waiting time. NOT equal outcome.", 9, 0.85, 0.4, 0);
      PdfCenterBold("The lag is the weapon. It creates the window.", 9, 0.85, 0.4, 0);
      g_pdfY -= 10;
   }

   // ==================== PATTERN 2: ASYMMETRIC SPEED DISCRIMINATION (PDF) ====================
   if(hasStructuralAsymmetry || g_vdpLagRatio > 2.0)
   {
      PdfNewPage();
      PdfSection("PATTERN 2: Asymmetric Lag - The Broker's Profit Machine");

      double p2Fast = g_vdpFavorMedian;
      double p2Slow = g_vdpAdverseMedian;
      if(p2Fast < 1.0) p2Fast = medLimitLag;
      if(p2Slow < 1.0) p2Slow = medStopLag;
      string p2FStr = FormatMs(p2Fast);
      string p2SStr = FormatMs(p2Slow);

      PdfBody("With asymmetric lag, the broker uses different speeds for different outcomes. "
         "Losing trades are filled instantly - locked in before you can react. "
         "Winning trades are delayed - the price retraces, your profit is shaved.");
      PdfSpace(4);

      // Two Speeds box
      PdfSubSec("Two Speeds, One Broker");
      PdfCheckY(40);
      // Fast lane box (green)
      double boxW = (PDF_CW - 20) / 2;
      double boxH = 36;
      double bx1 = PDF_ML;
      double bx2 = PDF_ML + boxW + 20;
      g_pdfCurStream += StringFormat("0 0.5 0 RG 1 w %.1f %.1f %.1f %.1f re S\n", bx1, g_pdfY - boxH, boxW, boxH);
      g_pdfCurStream += StringFormat("BT /F2 8 Tf 0 0.65 0 rg %.1f %.1f Td (Losing Trades: %s) Tj ET\n",
         bx1 + 8, g_pdfY - 12, PdfEsc(p2FStr));
      g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (Filled instantly. Loss locked in.) Tj ET\n",
         bx1 + 8, g_pdfY - 26);
      // Slow lane box (red)
      g_pdfCurStream += StringFormat("0.85 0.2 0.2 RG 1 w %.1f %.1f %.1f %.1f re S\n", bx2, g_pdfY - boxH, boxW, boxH);
      g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (Winning Trades: %s) Tj ET\n",
         bx2 + 8, g_pdfY - 12, PdfEsc(p2SStr));
      g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (Held and delayed. Profit shaved.) Tj ET\n",
         bx2 + 8, g_pdfY - 26);
      g_pdfY -= boxH + 30;

      PdfBodyColor(StringFormat("%s on losing trades proves the infrastructure can do %s. "
         "%s on winning trades is a business decision, not a limitation.",
         p2FStr, p2FStr, p2SStr), 0.85, 0.4, 0);
      PdfSpace(10);

      // 10-trade asymmetric table
      PdfSubSec("10 Gold Trades: What Asymmetric Lag Costs You");
      PdfBody(StringFormat("Broker fills losses fast (%s) and delays wins (%s).", p2FStr, p2SStr));
      PdfSpace(4);

      {
         double c1 = PDF_ML;          // #
         double c2 = PDF_ML + 18;     // Dir
         double c3 = PDF_ML + 48;     // Requested
         double c4 = PDF_ML + 130;    // Outcome
         double c5 = PDF_ML + 210;    // Speed
         double c6 = PDF_ML + 280;    // Filled At
         double c7 = PDF_ML + 350;    // Your P&L
         double c8 = PDF_ML + 400;    // Broker Gets
         double rw = PDF_CW;

         // Header
         PdfCheckY(14);
         g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 12 re f\n", PDF_ML, g_pdfY - 3, rw);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (#) Tj ET\n", c1+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Dir) Tj ET\n", c2+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Requested) Tj ET\n", c3+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Outcome) Tj ET\n", c4+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Speed) Tj ET\n", c5+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Filled At) Tj ET\n", c6+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Your P&L) Tj ET\n", c7+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Broker) Tj ET\n", c8+2, g_pdfY);
         g_pdfY -= 14;

         // Data: 10 trades alternating loss (fast) and win (slow)
         string aDir[]   = {"Buy","Buy","Sell","Buy","Sell","Buy","Buy","Sell","Sell","Buy"};
         string aReq[]   = {"$2,000.00","$2,001.20","$1,999.50","$2,002.00","$1,998.80",
                             "$2,003.10","$2,000.90","$2,004.00","$1,997.60","$2,001.50"};
         string aOut[]   = {"Price drops","Price rises","Price rises","Price rises","Price rises",
                             "Price rises","Price drops","Price drops","Price rises","Price rises"};
         string aFill[]  = {"$2,000.00","$2,001.50","$1,999.50","$2,002.40","$1,998.80",
                             "$2,003.60","$2,000.90","$2,003.50","$1,997.60","$2,001.90"};
         string aPnl[]   = {"-$350","+$90","-$280","+$160","-$420","+$250","-$310","+$350","-$380","+$210"};
         string aBrk[]   = {"+$350","+$30","+$280","+$40","+$420","+$50","+$310","+$50","+$380","+$40"};
         bool   aLoss[]  = {true,false,true,false,true,false,true,false,true,false};

         for(int i = 0; i < 10; i++)
         {
            PdfCheckY(11);
            // Alternating background
            if(aLoss[i])
               g_pdfCurStream += StringFormat("0.15 0.08 0.08 rg %.1f %.1f %.1f 10 re f\n", PDF_ML, g_pdfY-3, rw);
            else
               g_pdfCurStream += StringFormat("0.08 0.12 0.08 rg %.1f %.1f %.1f 10 re f\n", PDF_ML, g_pdfY-3, rw);

            g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%d) Tj ET\n", c1+2, g_pdfY, i+1);
            g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.8 0.8 0.8 rg %.1f %.1f Td (%s) Tj ET\n", c2+2, g_pdfY, aDir[i]);
            g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.8 0.8 0.8 rg %.1f %.1f Td (%s) Tj ET\n", c3+2, g_pdfY, aReq[i]);
            if(aLoss[i])
               g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.85 0.3 0.3 rg %.1f %.1f Td (%s) Tj ET\n", c4+2, g_pdfY, PdfEsc(aOut[i]));
            else
               g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.3 0.7 0.3 rg %.1f %.1f Td (%s) Tj ET\n", c4+2, g_pdfY, PdfEsc(aOut[i]));
            // Speed
            if(aLoss[i])
               g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s FAST) Tj ET\n", c5+2, g_pdfY, PdfEsc(p2FStr));
            else
               g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (%s SLOW) Tj ET\n", c5+2, g_pdfY, PdfEsc(p2SStr));
            // Fill
            if(!aLoss[i])
               g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.6 0.4 0 rg %.1f %.1f Td (%s) Tj ET\n", c6+2, g_pdfY, PdfEsc(aFill[i]));
            else
               g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.8 0.8 0.8 rg %.1f %.1f Td (%s) Tj ET\n", c6+2, g_pdfY, PdfEsc(aFill[i]));
            // P&L
            if(aLoss[i])
               g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (%s) Tj ET\n", c7+2, g_pdfY, PdfEsc(aPnl[i]));
            else
               g_pdfCurStream += StringFormat("BT /F1 6.5 Tf 0.6 0.6 0.6 rg %.1f %.1f Td (%s) Tj ET\n", c7+2, g_pdfY, PdfEsc(aPnl[i]));
            // Broker
            g_pdfCurStream += StringFormat("BT /F2 6.5 Tf 0 0.6 0 rg %.1f %.1f Td (%s) Tj ET\n", c8+2, g_pdfY, PdfEsc(aBrk[i]));

            g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.2 w %.1f %.1f m %.1f %.1f l S\n", PDF_ML, g_pdfY-3, PDF_ML+rw, g_pdfY-3);
            g_pdfY -= 11;
         }

         // P&L summary boxes
         PdfSpace(6);
         PdfCheckY(32);
         double sumW = (PDF_CW - 30) / 2;
         // YOUR loss box
         g_pdfCurStream += StringFormat("0.85 0.2 0.2 RG 1.5 w %.1f %.1f %.1f 28 re S\n", PDF_ML, g_pdfY - 28, sumW);
         g_pdfCurStream += StringFormat("0.15 0.08 0.08 rg %.1f %.1f %.1f 28 re f\n", PDF_ML+1, g_pdfY-27, sumW-2);
         g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.85 0.4 0.4 rg %.1f %.1f Td (YOUR Net P&L) Tj ET\n", PDF_ML+8, g_pdfY-10);
         g_pdfCurStream += StringFormat("BT /F2 14 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (-$680) Tj ET\n", PDF_ML+8, g_pdfY-24);
         // BROKER profit box
         double bx = PDF_ML + sumW + 30;
         g_pdfCurStream += StringFormat("0 0.6 0 RG 1.5 w %.1f %.1f %.1f 28 re S\n", bx, g_pdfY - 28, sumW);
         g_pdfCurStream += StringFormat("0.08 0.15 0.08 rg %.1f %.1f %.1f 28 re f\n", bx+1, g_pdfY-27, sumW-2);
         g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.4 0.75 0.4 rg %.1f %.1f Td (BROKER Profit) Tj ET\n", bx+8, g_pdfY-10);
         g_pdfCurStream += StringFormat("BT /F2 14 Tf 0 0.6 0 rg %.1f %.1f Td (+$1,950) Tj ET\n", bx+8, g_pdfY-24);
         g_pdfY -= 34;
      }
      PdfSpace(6);

      // Analogy
      PdfSubSec("Analogy: The Rigged Roulette Table");
      PdfBody("The ball settles in 2 seconds when you bet on a losing number - locked in, no take-backs. "
         "But when you bet on a winning number, the wheel 'malfunctions' for 30 seconds. "
         "During those 30 seconds, the croupier subtly nudges the ball. You still win sometimes, "
         "but your payout is always smaller than it should be. "
         "The rigging is not in what you can bet on. It is in how fast the ball settles.");
      PdfSpace(6);

      // Self-benchmark
      PdfCheckY(50);
      g_pdfCurStream += StringFormat("0.85 0.4 0 RG 1.5 w %.1f %.1f %.1f 44 re S\n",
         PDF_ML, g_pdfY - 40, PDF_CW);
      g_pdfCurStream += StringFormat("0.16 0.10 0.10 rg %.1f %.1f %.1f 44 re f\n",
         PDF_ML + 1, g_pdfY - 39, PDF_CW - 2);
      g_pdfY -= 8;
      PdfCenterBold("The Self-Benchmark Principle", 9, 0.85, 0.4, 0);
      PdfCenterBold(StringFormat("Fastest: %s (proves capability). Slowest: %s (proves intent).", p2FStr, p2SStr), 8, 0.85, 0.2, 0.2);
      g_pdfY -= 10;
   }

   // ==================== PATTERN 3: EA BLINDNESS — UNIVERSAL (PDF) ====================
   {
      PdfNewPage();
      PdfSection("PATTERN 3: Lagged Fill Confirmations - EA Blindness (Universal)");

      PdfBody("This pattern applies to ALL lag - symmetric or asymmetric. Patterns 1 and 2 are about price "
         "manipulation. This pattern is about information manipulation - the broker uses delay to make your EA "
         "blind to its true position.");
      PdfSpace(4);

      PdfBody("Your EA sees the market price in real time. But when it sends orders, the broker delays sending "
         "back fill confirmations. Without confirmations, your EA does not know those positions exist - so it "
         "calculates profit, trailing stops, and close decisions on incomplete data. "
         "The EA's math is perfect - but it is solving the wrong equation.");
      PdfSpace(6);

      // Step-by-step table
      PdfSubSec("Step by Step - What Goes Wrong");
      PdfSpace(4);

      {
         double cStep   = PDF_ML;
         double cEA     = PDF_ML + 28;
         double cActual = PDF_ML + 230;
         double rw = PDF_CW;

         // Header
         PdfCheckY(16);
         g_pdfCurStream += StringFormat("0.16 0.16 0.28 rg %.1f %.1f %.1f 14 re f\n", PDF_ML, g_pdfY - 4, rw);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.29 0.56 0.85 rg %.1f %.1f Td (Step) Tj ET\n", cStep+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.2 0.85 0.2 rg %.1f %.1f Td (What Your EA Knows) Tj ET\n", cEA+2, g_pdfY);
         g_pdfCurStream += StringFormat("BT /F2 7 Tf 0.85 0.2 0.2 rg %.1f %.1f Td (What Your Account Has) Tj ET\n", cActual+2, g_pdfY);
         g_pdfY -= 16;

         // Step data
         string sNum[]  = {"1","2","3","4","5"};
         string sEA[]   = {"EA sends 5 buys. Broker confirms 3. EA calculates on 3.",
                           "Price retraces. Trail triggers on 3 fills: +$5. EA closes.",
                           "EA closes 3 positions at profit. Logs: +$5 profit.",
                           "Confirmations arrive: 2 extra positions?!",
                           "EA: +$5 profit  |  Account: -$4 LOSS"};
         string sAcct[] = {"Account has 5 positions. 2 confirmations not arrived.",
                           "2 unseen positions are losing money. True P&L negative.",
                           "3 closes + 2 unseen losers still open. Net negative.",
                           "Filled at bad prices, deep red. Wipe out profit + capital.",
                           "EA logic was perfect. 3 confirmed != 5 actual fills."};
         double sClr[]  = {0.2, 0.6, 0.6, 0.85, 0.85};  // red intensity

         int eaMaxCh  = 30;   // wrap limit for EA column  (202pt wide)
         int accMaxCh = 32;   // wrap limit for Account column (221pt wide)

         for(int i = 0; i < 5; i++)
         {
            PdfCheckY(40);
            // Step number
            g_pdfCurStream += StringFormat("BT /F2 8 Tf 0.2 0.85 0.2 rg %.1f %.1f Td (%s) Tj ET\n", cStep+2, g_pdfY, sNum[i]);
            // EA column (wrap) — dark text for readability
            string eaTxt = sEA[i];
            double eaY = g_pdfY;
            while(StringLen(eaTxt) > 0)
            {
               string eLine;
               if(StringLen(eaTxt) <= eaMaxCh)
               { eLine = eaTxt; eaTxt = ""; }
               else
               {
                  int bp2 = eaMaxCh;
                  for(int j = eaMaxCh; j > eaMaxCh/2; j--)
                  { if(StringGetCharacter(eaTxt, j) == ' ') { bp2 = j; break; } }
                  eLine = StringSubstr(eaTxt, 0, bp2);
                  eaTxt = StringSubstr(eaTxt, bp2);
                  StringTrimLeft(eaTxt);
               }
               g_pdfCurStream += StringFormat("BT /F1 7 Tf 0.20 0.20 0.30 rg %.1f %.1f Td (%s) Tj ET\n", cEA+2, eaY, PdfEsc(eLine));
               eaY -= 11;
            }
            // Account column (wrap)
            string accTxt = sAcct[i];
            double accY = g_pdfY;
            while(StringLen(accTxt) > 0)
            {
               string aLine;
               if(StringLen(accTxt) <= accMaxCh)
               { aLine = accTxt; accTxt = ""; }
               else
               {
                  int bp3 = accMaxCh;
                  for(int j = accMaxCh; j > accMaxCh/2; j--)
                  { if(StringGetCharacter(accTxt, j) == ' ') { bp3 = j; break; } }
                  aLine = StringSubstr(accTxt, 0, bp3);
                  accTxt = StringSubstr(accTxt, bp3);
                  StringTrimLeft(accTxt);
               }
               g_pdfCurStream += StringFormat("BT /F1 7 Tf %.2f 0.2 0.2 rg %.1f %.1f Td (%s) Tj ET\n", sClr[i], cActual+2, accY, PdfEsc(aLine));
               accY -= 11;
            }
            double lowestY = MathMin(eaY, accY);
            g_pdfY = lowestY - 6;
            g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.2 w %.1f %.1f m %.1f %.1f l S\n", PDF_ML, g_pdfY, PDF_ML+rw, g_pdfY);
            g_pdfY -= 14;
         }
      }

      PdfSpace(6);

      // Double Whammy
      PdfSubSec("The Double Whammy: Clustering + Blind Decisions");
      PdfBody("1. FILL CLUSTERING: Held orders arrive in batches at the same price. This is the visible symptom.");
      PdfBody("2. BLIND EA DECISIONS: The real damage. Missing confirmations mean the EA does not know its true "
         "position size. Every trailing stop, close, and P&L calculation is wrong.");
      PdfBodyColor("Clustering is the symptom. Blind decisions are the damage. Both caused by the broker holding orders.", 0.85, 0.2, 0.2);
      PdfSpace(6);

      // Analogy
      PdfSubSec("Analogy: The Late Supplier");
      PdfBody("You order 5 items from a supplier to resell at a markup. Cash on delivery. "
         "The first 3 arrive on time - you sell them at profit. "
         "But the last 2 arrive late, after the market price has dropped. "
         "You are obligated to pay the original price, but can only sell at a loss. "
         "Those 2 late deliveries wipe out all your profit and then some. "
         "The broker is that supplier.");
      PdfSpace(6);

      // Key insight box
      PdfCheckY(56);
      g_pdfCurStream += StringFormat("0.85 0.2 0.2 RG 1.5 w %.1f %.1f %.1f 50 re S\n",
         PDF_ML, g_pdfY - 46, PDF_CW);
      g_pdfCurStream += StringFormat("0.16 0.10 0.10 rg %.1f %.1f %.1f 50 re f\n",
         PDF_ML + 1, g_pdfY - 45, PDF_CW - 2);
      g_pdfY -= 8;
      PdfCenterBold("Patterns 1 & 2 steal your money through PRICE.", 8, 0.85, 0.4, 0);
      PdfCenterBold("Pattern 3 steals your money through INFORMATION.", 8, 0.85, 0.4, 0);
      PdfCenterBold("A fair broker confirms fills immediately.", 8, 0, 0.6, 0);
      g_pdfY -= 8;
   }

   // ==================== PER-ORDER-TYPE LAG + CLUSTERING vs 2026 BENCHMARKS ====================
   PdfNewPage();
   PdfSection("EXECUTION LAG BY ORDER TYPE");
   PdfBody("Each pending order type measured separately. Buy/Sell stops and Buy/Sell limits");
   PdfBody("should execute at similar speeds if the broker is fair.");
   PdfSpace(4);

   // Per-type lag table
   PdfTableHeader("Order Type", "Count", "Median Lag", "Standard");
   {
      int pdfTypeOrder[] = {2, 3, 4, 5, 6, 7};
      for(int pti = 0; pti < 6; pti++)
      {
         int pt = pdfTypeOrder[pti];
         if(g_countByType[pt] == 0) continue;
         int pstd;
         if(pt <= 5) pstd = STD_FILL_GOOD_MS;
         else pstd = STD_TPSL_GOOD_MS;
         string pStatus;
         double pr=0,pg2=0,pb=0;
         if(g_medianLag[pt] <= (double)pstd) { pStatus = "PASS"; pr=0; pg2=0.6; pb=0; }
         else if(g_medianLag[pt] <= (double)pstd * 2.0) { pStatus = "SLOW"; pr=0.9; pg2=0.5; pb=0; }
         else { pStatus = "FAIL"; pr=1; pg2=0; pb=0; }
         PdfTableRow(GetFillTypeName((ENUM_FILL_TYPE)pt),
                     StringFormat("%d", g_countByType[pt]),
                     StringFormat("%s (%s)", FormatMs(g_medianLag[pt]), pStatus),
                     StringFormat("%dms", pstd), pr, pg2, pb);
      }
   }
   PdfSpace(8);

   // TP/SL trigger analysis
   if(g_tpslTotalTriggers > 0)
   {
      PdfSubSec("TP/SL Market Trigger Analysis");
      PdfKV("Total TP/SL Triggers:", StringFormat("%d", g_tpslTotalTriggers));
      PdfKV("Favorable (TP hit):", StringFormat("%d (%.0f%%)", g_tpslFavorTriggers, g_tpslFavorPct));
      PdfKV("Adverse (SL hit):", StringFormat("%d (%.0f%%)", g_tpslAdverseTriggers, g_tpslAdversePct));
      PdfKV("Favorable Slippage:", StringFormat("%d fills (price improvement)", g_tpslFavorSlip));
      PdfKV("Adverse Slippage:", StringFormat("%d fills (worse than trigger)", g_tpslAdverseSlip));
      PdfKV("At Trigger Price:", StringFormat("%d fills (no slippage)", g_tpslNeutralSlip));
      if(g_tpslSlipAsymRatio > STD_SLIPPAGE_ASYM_MAX)
         PdfBodyColor(StringFormat("WARNING: Slippage asymmetry %.1fx exceeds 2026 standard of %.1fx",
                      g_tpslSlipAsymRatio, STD_SLIPPAGE_ASYM_MAX), 1, 0, 0);
      else
         PdfBodyColor(StringFormat("Slippage symmetry %.1fx within 2026 standard (<=%.1fx)",
                      g_tpslSlipAsymRatio, STD_SLIPPAGE_ASYM_MAX), 0, 0.6, 0);
      PdfSpace(8);
   }

   // Clustering vs 2026 A-book benchmarks
   PdfCheckY(200);
   PdfSubSec("Fill Clustering vs 2026 A-Book Standards");
   PdfBody("Source: FX Global Code Principle 17, MiFID II RTS 27/28, ESMA Feb 2026.");
   PdfSpace(4);

   {
      double clPctP = g_clusterRatio * 100.0;
      double baPctP = g_batchRatio * 100.0;

      PdfTableHeader("Metric", "Measured", "A-Book Std", "Status");

      // Fill cluster ratio
      {
         string ps; double cr2=0,cg2=0,cb2=0;
         if(clPctP <= STD_CLUSTER_FAIR_PCT) { ps="PASS"; cg2=0.6; }
         else if(clPctP <= STD_CLUSTER_CAUTION_PCT) { ps="CAUTION"; cr2=0.9; cg2=0.5; }
         else { ps="FAIL"; cr2=1; }
         PdfTableRow("Fill Cluster Ratio", StringFormat("%.0f%%", clPctP),
                     StringFormat("<=%.0f%%", STD_CLUSTER_FAIR_PCT), ps, cr2, cg2, cb2);
      }
      // Max cluster size
      {
         string ps; double cr2=0,cg2=0,cb2=0;
         if((int)g_maxClusterSize <= STD_MAX_CLUSTER_FAIR) { ps="PASS"; cg2=0.6; }
         else if((int)g_maxClusterSize <= STD_MAX_CLUSTER_MANIP) { ps="CAUTION"; cr2=0.9; cg2=0.5; }
         else { ps="FAIL"; cr2=1; }
         PdfTableRow("Max Cluster Size", StringFormat("%d fills", (int)g_maxClusterSize),
                     StringFormat("<=%d", STD_MAX_CLUSTER_FAIR), ps, cr2, cg2, cb2);
      }
      // Largest cluster as % of all fills
      {
         string ps; double cr2=0,cg2=0,cb2=0;
         if(g_maxClusterPct <= 3.0) { ps="PASS"; cg2=0.6; }
         else if(g_maxClusterPct <= 5.0) { ps="CAUTION"; cr2=0.9; cg2=0.5; }
         else { ps="FAIL"; cr2=1; }
         PdfTableRow("Largest Cluster %", StringFormat("%.1f%%", g_maxClusterPct), "<=3%", ps, cr2, cg2, cb2);
      }
      // Price batch ratio — gated by batch classification
      {
         string ps; double cr2=0,cg2=0,cb2=0;
         if(g_batchClassification == "FAIR")
         {
            // Fast broker with symmetric execution — price drift is normal
            ps = "PASS"; cg2 = 0.6;
         }
         else if(baPctP <= STD_BATCH_FAIR_PCT) { ps="PASS"; cg2=0.6; }
         else if(baPctP <= STD_BATCH_CAUTION_PCT) { ps="CAUTION"; cr2=0.9; cg2=0.5; }
         else { ps="FAIL"; cr2=1; }
         PdfTableRow("Price Batch Ratio", StringFormat("%.0f%%", baPctP),
                     StringFormat("<=%.0f%%", STD_BATCH_FAIR_PCT), ps, cr2, cg2, cb2);
      }
      // Slippage symmetry
      {
         string ps; double cr2=0,cg2=0,cb2=0;
         if(g_tpslSlipAsymRatio <= STD_SLIPPAGE_ASYM_MAX) { ps="PASS"; cg2=0.6; }
         else if(g_tpslSlipAsymRatio <= 2.0) { ps="CAUTION"; cr2=0.9; cg2=0.5; }
         else { ps="FAIL"; cr2=1; }
         PdfTableRow("Slippage Symmetry", StringFormat("%.1fx", g_tpslSlipAsymRatio),
                     StringFormat("<=%.1fx", STD_SLIPPAGE_ASYM_MAX), ps, cr2, cg2, cb2);
      }

      PdfSpace(6);

      // Per-type clustering breakdown
      if(g_clusterCount > 0)
      {
         PdfCheckY(100);
         PdfBodyBold("Clustering by Order Type:");
         PdfTableHeader("Order Type", "Total", "In Clusters", "Cluster %");
         int cTypesP[] = {2, 3, 4, 5};
         for(int ci2 = 0; ci2 < 4; ci2++)
         {
            int ct3 = cTypesP[ci2];
            if(g_countByType[ct3] == 0) continue;
            double ctr=0,ctg=0,ctb=0;
            if(g_clusterByTypePct[ct3] <= STD_CLUSTER_FAIR_PCT) ctg=0.6;
            else if(g_clusterByTypePct[ct3] <= STD_CLUSTER_CAUTION_PCT) { ctr=0.9; ctg=0.5; }
            else ctr=1;
            PdfTableRow(GetFillTypeName((ENUM_FILL_TYPE)ct3),
                        StringFormat("%d", g_countByType[ct3]),
                        StringFormat("%d", g_clusterByType[ct3]),
                        StringFormat("%.0f%%", g_clusterByTypePct[ct3]), ctr, ctg, ctb);
         }
         PdfSpace(4);
      }

      // Cluster verdict
      PdfCheckY(50);
      if(g_clusterVerdict == "MANIPULATION")
      {
         PdfBodyColor(StringFormat("CLUSTERING VERDICT: %s", g_clusterVerdict), 1, 0, 0);
         PdfBody("Fill clustering exceeds 2026 A-book benchmarks. This broker is holding");
         PdfBody("and batching orders internally. Clustered fills are devastating for EAs.");
      }
      else if(g_clusterVerdict == "CAUTION")
      {
         PdfBodyColor(StringFormat("CLUSTERING VERDICT: %s", g_clusterVerdict), 0.9, 0.5, 0);
         PdfBody("Fill clustering above normal A-book levels. Monitor closely.");
      }
      else
      {
         PdfBodyColor(StringFormat("CLUSTERING VERDICT: %s", g_clusterVerdict), 0, 0.6, 0);
         PdfBody("Fill clustering within 2026 A-book standards.");
      }
   }

   // ==================== SECTION 5: FINANCIAL DAMAGE ====================
   PdfNewPage();
   PdfSection("SECTION 5: FINANCIAL DAMAGE ASSESSMENT");
   PdfSubSec("5.1 Measured Damage (This Test Session)");

   if(violations < 2)
   {
      // FAIR verdict — no meaningful damage to report
      PdfBody("No broker-induced damage detected. All execution within 2026 industry standards.");
      PdfBody("Execution drift from broker receipt price is zero or negligible — lag has no financial impact.");
   }
   else
   {
      double slipBiasCost = g_totalAdverseSlipUSD;
      double closeLagCost = MathAbs(g_totalFinancialDelta);
      double roundingCost = MathAbs(g_roundingErrorSum);
      double stopLimitCost = 0, tpslCost = 0;
      if(g_countByType[2] > 0 && g_countByType[4] > 0)
      {
         double excessLag = medStopLag - medLimitLag;
         if(excessLag > 0) stopLimitCost = (excessLag / 1000.0) * 0.5 * g_totalLotsTraded * g_tickValue;
      }
      if(g_countByType[6] > 0 && g_countByType[7] > 0)
      {
         double excessSlip = g_meanSlipAbs[7] - g_meanSlipAbs[6];
         if(excessSlip > 0) tpslCost = (excessSlip / g_tickSize) * g_tickValue * g_lotSize * g_countByType[7];
      }
      totalDamage = slipBiasCost + closeLagCost + roundingCost + stopLimitCost + tpslCost;

      PdfKV("Adverse execution drift:", FormatMoney(slipBiasCost));
      PdfKV("Stop vs Limit asymmetry:", FormatMoney(stopLimitCost));
      PdfKV("SL vs TP asymmetry:", FormatMoney(tpslCost));
      PdfKV("Close lag impact:", FormatMoney(closeLagCost));
      PdfKV("Price rounding skew:", FormatMoney(roundingCost));
      PdfHRule();
      PdfSpace(6);
      PdfBodyBold(StringFormat("TOTAL MEASURED DAMAGE: %s %s", FormatMoney(totalDamage), g_displayCurrency));

      PdfSpace(6);
      PdfSubSec("5.2 Per-Lot Damage Rate");
      perLot = (g_totalLotsTraded > 0) ? totalDamage / g_totalLotsTraded : 0;
      PdfKV("Total lots traded:", StringFormat("%.2f", g_totalLotsTraded));
      PdfKV("Damage per lot:", FormatMoney(perLot));
      PdfBody("This is the hidden tax on every trade.");
   }

   // --- 5.3-5.5 Annual Damage Projections ---
   // Only show when manipulation detected. Lag without drift = trigger fill (but asymmetric lag still harms).
   if(g_batchClassification == "MANIPULATION")
   {
      PdfSpace(6);
      PdfSubSec("5.3 Projected Annual Damage (Previous Day Tick Data)");
      if(g_prevDayDataValid)
      {
         PdfBody(StringFormat("The previous trading day's full tick history (%s, %s) was analyzed "
            "to determine the real-world price impact of the measured broker drift.",
            TimeToString(g_prevDayStart, TIME_DATE), Symbol()));
         PdfSpace(2);
         PdfKV("Tick data analyzed:", StringFormat("%d ticks, %d sliding windows",
            g_prevDayTickCount, g_prevDayWindowCount));
         PdfKV("Lag window used:", StringFormat("%.0f ms (weighted avg across all fill types)", g_prevDayLagUsedMs));
         PdfKV("Avg price range during lag:", StringFormat("%.2f pips (%.1f pts, %.5f price units)",
            g_prevDayAvgRangePips, g_prevDayAvgRangePoints, g_prevDayAvgRangePrice));
         PdfKV("Avg slippage per lot:", StringFormat("%s %s",
            FormatMoney(g_prevDaySlippagePerLot), g_displayCurrency));
         PdfSpace(4);
         double slipPerLot = g_prevDaySlippagePerLot;
         PdfKV("1 lot/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
            FormatMoney(slipPerLot), FormatMoney(slipPerLot * 21), FormatMoney(slipPerLot * 252)));
         PdfKV("5 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
            FormatMoney(slipPerLot * 5), FormatMoney(slipPerLot * 5 * 21), FormatMoney(slipPerLot * 5 * 252)));
         PdfKV("10 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
            FormatMoney(slipPerLot * 10), FormatMoney(slipPerLot * 10 * 21), FormatMoney(slipPerLot * 10 * 252)));
         PdfKV("50 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
            FormatMoney(slipPerLot * 50), FormatMoney(slipPerLot * 50 * 21), FormatMoney(slipPerLot * 50 * 252)));
      }
      else
         PdfBody("Previous trading day tick data was not available or insufficient for analysis.");

      PdfSpace(6);
      PdfSubSec("5.4 Projected Annual Damage (Test Session Per-Lot Rate)");
      PdfKV("1 lot/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
         FormatMoney(perLot), FormatMoney(perLot * 21), FormatMoney(perLot * 252)));
      PdfKV("5 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
         FormatMoney(perLot * 5), FormatMoney(perLot * 5 * 21), FormatMoney(perLot * 5 * 252)));
      PdfKV("10 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
         FormatMoney(perLot * 10), FormatMoney(perLot * 10 * 21), FormatMoney(perLot * 10 * 252)));
      PdfKV("50 lots/day:", StringFormat("Daily %s  Monthly %s  Annual %s",
         FormatMoney(perLot * 50), FormatMoney(perLot * 50 * 21), FormatMoney(perLot * 50 * 252)));

      PdfSpace(6);
      PdfSubSec("5.5 Systemic Impact Statement");
      if(g_prevDayDataValid)
         PdfBody(StringFormat("Based on the previous day's tick data for %s, "
            "any client trading 1 lot/day with %s would lose approximately %s per year "
            "to execution drift alone — independent of market outcomes or trading strategy.",
            Symbol(), g_brokerName, FormatMoney(g_prevDayAnnualDamage1)));
      else
         PdfBody(StringFormat("Based on the measured execution deficiencies, any client "
            "trading %s with %s at 1 lot/day would lose approximately %s per year to "
            "execution drift alone, independent of market outcomes.",
            Symbol(), g_brokerName, FormatMoney(perLot * 252)));
   }
   else
   {
      PdfSpace(6);
      PdfSubSec("5.3 Annual Damage Assessment");
      PdfBodyColor("No execution drift detected — all fills at correct prices. "
         "However, if lag is asymmetric between order types, the broker still benefits from "
         "delayed counter fills arriving after EA close operations. "
         "Projected drift damage: $0.00. Check lag asymmetry separately.", 0, 0.60, 0);
   }

   // ==================== SECTION 6: INDUSTRY STANDARDS ====================
   PdfNewPage();
   PdfSection("SECTION 6: INDUSTRY STANDARDS REFERENCE");
   PdfKV("Market order (sync place):", StringFormat("<%d ms good, >%d ms manipulation", STD_MARKET_GOOD_MS, STD_MARKET_MANIP_MS));
   PdfKV("Pending order (stop/limit):", StringFormat("<%d ms good, >%d ms manipulation", STD_FILL_GOOD_MS, STD_FILL_MANIP_MS));
   PdfKV("Async batch close:", StringFormat("<%d ms good, >%d ms manipulation", STD_CLOSE_GOOD_MS, STD_CLOSE_MANIP_MS));
   PdfKV("Sync individual close:", StringFormat("<%d ms good, >%d ms manipulation", STD_SYNC_CLOSE_GOOD_MS, STD_SYNC_CLOSE_MANIP_MS));
   PdfKV("TP/SL execution:", StringFormat("<%d ms good, >%d ms manipulation", STD_TPSL_GOOD_MS, STD_TPSL_MANIP_MS));
   PdfKV("Stop/Limit ratio:", "fair <1.5x, asymmetric >2x (broker-favorable delay on all operations)");
   PdfKV("SL/TP exec lag ratio:", "fair <2x, asymmetric >2x (broker-favorable delay on all operations)");
   PdfKV("Fill clustering:", "A-book <10%, caution 10-25%, manipulation >25%");
   PdfKV("Price batching:", "FAIR = all at trigger price, MANIPULATION = excessive lag or asymmetry");
   PdfKV("Lag symmetry:", "all order types filled at equal speed (best execution)");
   PdfKV("TP/SL quality:", "equal treatment (fair treatment principle)");
   PdfKV("Price rounding:", "unbiased");
   PdfSpace(4);
   PdfBody("All thresholds represent broker-side processing time only (network transit deducted).");
   PdfBody("Measurements use DEAL_TIME_MSC (broker's authoritative server timestamp) for accuracy.");
   PdfSpace(6);
   PdfBodyBold("Why these thresholds (2026 industry reality):");
   PdfBody("These thresholds reflect 2026 A-book industry performance. Top brokers — IC Markets, "
      "Pepperstone, Global Prime — routinely execute market orders in 10-50ms. True STP/A-book "
      "processing should complete under 100ms for all order types. Any broker processing time above "
      "100ms warrants scrutiny; above 200ms indicates a possible hold or last-look window.");
   PdfSpace(4);
   PdfBodyBold("Symmetric high lag is also a risk:");
   PdfBody("Symmetric execution speed (equal lag on all order types) does NOT prove fair execution "
      "if the baseline is high. A broker executing all orders at 250ms provides a 50-200ms last-look "
      "window on every trade — enough time to check whether the fill benefits or costs the broker "
      "before confirming. The FX Global Code of Conduct Principle 17 explicitly prohibits additional "
      "hold time beyond what is needed for price and validity checks. Industry leaders demonstrate "
      "this is achievable: Northern Trust completes checks within 3ms, XTX Markets operates at 0ms "
      "hold time. Hold times in the hundreds of milliseconds are indefensible.");
   PdfSpace(4);
   PdfBodyBold("Self-benchmarking principle:");
   PdfBody("When a broker shows different speeds for different order types, its fastest execution "
      "proves what its infrastructure can achieve. If limit orders fill in 30ms but stop orders take "
      "250ms, the 30ms proves the broker can process orders in 30ms. The 250ms on stops is therefore "
      "a choice, not a limitation. The broker's own best performance becomes the evidence against it.");
   PdfSpace(4);
   PdfBodyBold("Sources:");
   PdfBody("- MiFID II RTS 27/28: Execution quality reporting requirements");
   PdfBody("- FCA COBS 11.2: Best execution obligations");
   PdfBody("- ESMA Q&A on MiFID II investor protection: Best execution");
   PdfBody("- FAIS Act (South Africa): General fairness in financial services");
   PdfBody("- ASIC RG 227: Best execution guidance");
   PdfSpace(2);
   PdfBodyBold("Enforcement case documents (direct links):");
   PdfBody("- CFTC v FXCM (2011): https://www.cftc.gov/PressRoom/PressReleases/6119-11");
   PdfBody("- FCA v FXCM UK (2014): https://www.fca.org.uk/publication/final-notices/forex-capital-markets-limited.pdf");
   PdfBody("- CFTC v FXCM (2017): https://www.cftc.gov/PressRoom/PressReleases/7528-17");
   PdfBody("- CFTC v FXDD (2013): https://www.cftc.gov/PressRoom/PressReleases/6697-13");
   PdfBody("- NFA v GAIN Capital (2010): https://www.nfa.futures.org/BasicNet/CaseDocument.aspx?seqnum=2622");
   PdfBody("- NFA Rule 9064: https://www.nfa.futures.org/rulebooksql/rules.aspx?Section=9&RuleID=9064");
   PdfBody("- NYDFS v Barclays (2015): https://www.dfs.ny.gov/system/files/documents/2020/04/ea151118.pdf");
   PdfBody("- ASIC v AGM Markets (2020): https://asic.gov.au/about-asic/news-centre/find-a-media-release/2020-releases/20-246mr/");
   PdfBody("- ASIC v EuropeFX/USG (2024): https://asic.gov.au/about-asic/news-centre/find-a-media-release/2024-releases/24-287mr/");

   // ==================== SECTION 7: VERDICT ====================
   PdfNewPage();
   PdfSection("SECTION 7: VERDICT AND RECOMMENDATIONS");
   PdfBodyColor("FINAL VERDICT: " + verdict, vr, vg2, vb);
   PdfSpace(4);
   if(violations >= 2)
   {
      PdfBodyBold("Violations identified:");
      int vn = 1;
      if(medStopLag > STD_FILL_SLOW_MS)
         PdfBody(StringFormat("%d. Pending stop execution delay: %s (standard: <%d ms)",
            vn++, FormatMs(medStopLag), STD_FILL_GOOD_MS));
      if(g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS)
         PdfBody(StringFormat("%d. Async batch close delay: %s (standard: <%d ms)",
            vn++, FormatMs(g_asyncCloseMedianLag), STD_CLOSE_GOOD_MS));
      if(g_syncCloseCount > 0 && g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS)
         PdfBody(StringFormat("%d. Sync individual close delay: %s (standard: <%d ms)",
            vn++, FormatMs(g_syncCloseMedianLag), STD_SYNC_CLOSE_GOOD_MS));
      if(stopLimitRatio > 2.0)
         PdfBody(StringFormat("%d. Stop/Limit timing difference: %.1fx — ASYMMETRIC (broker-favorable delay affects all operations including EA closes)", vn++, stopLimitRatio));
      if(tpslExecRatio > 2.0)
         PdfBody(StringFormat("%d. SL/TP timing difference: %.1fx — ASYMMETRIC (broker-favorable delay affects all operations including EA closes)", vn++, tpslExecRatio));
      if(medSLLag > STD_TPSL_SLOW_MS)
         PdfBody(StringFormat("%d. Stop-loss execution delay: %s (standard: <%d ms)",
            vn++, FormatMs(medSLLag), STD_TPSL_GOOD_MS));
      if(medTPLag > STD_TPSL_SLOW_MS)
         PdfBody(StringFormat("%d. Take-profit execution delay: %s (standard: <%d ms)",
            vn++, FormatMs(medTPLag), STD_TPSL_GOOD_MS));
      if(medMarketLag > STD_MARKET_SLOW_MS)
         PdfBody(StringFormat("%d. Sync placement (market order) delay: %s (standard: <%d ms)",
            vn++, FormatMs(medMarketLag), STD_MARKET_GOOD_MS));
      if(g_roundingErrorSum < -0.01)
         PdfBody(StringFormat("%d. Systematic rounding error favoring broker: %s",
            vn++, FormatMoney(MathAbs(g_roundingErrorSum))));
      if(dirRatio > 2.0)
         PdfBody(StringFormat("%d. Directional execution bias: %.1fx", vn++, dirRatio));
      if(g_batchCount > 0 && g_batchClassification != "FAIR")
         PdfBody(StringFormat("%d. Price batching: %d batches detected, %.1f pts avg broker advantage",
            vn++, g_batchCount, g_avgBatchAdvantagePts));
      if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT)
         PdfBody(StringFormat("%d. Fill clustering: %.0f%% of fills share same price/timestamp/direction",
            vn++, g_clusterRatio * 100));

      PdfSpace(4);
      PdfBodyBold("What this means:");
      if(hasAsymmetry)
      {
         PdfBody("The above violations include execution red flags. A genuine A-book/STP broker "
            "routes all orders to external liquidity providers and has no control over execution lag. "
            "Adverse-only slippage, excessive rejection, asymmetric delay between order types, "
            "or fills consistently at market price rather than trigger price indicate the broker likely "
            "operates a B-book model with direct control over order processing.");
      }
      else if(hasStructuralAsymmetry)
      {
         PdfBody("The timing differences above show asymmetric execution that benefits the broker. "
            "Counter orders (stops, SL) that are triggered and held with asymmetric lag can fill "
            "AFTER an EA has already closed positions on a retracement — creating new unwanted "
            "exposure against the trader. The fill price is irrelevant; what matters is that the "
            "delayed fill arrives after the EA has exited, opening positions the trader never intended. "
            "This asymmetry is broker-favorable regardless of trigger-fill rates.");
      }
      else
      {
         PdfBody("The above execution lag values exceed standard benchmarks. This may indicate slow "
            "infrastructure or network conditions. Re-test during different market conditions to confirm.");
      }
      PdfSpace(2);
      if((hasAsymmetry || hasStructuralAsymmetry || g_vdpLagRatio > 2.0) && g_vdpScore >= 50)
      {
         PdfBodyColor(StringFormat("VIRTUAL DEALER PLUGIN DETECTED: %.0f%% probability — %s",
            g_vdpScore, g_vdpVerdict), 0.95, 0.0, 0.0);
         PdfBody(StringFormat("Broker-profitable orders delayed %.0fx longer than broker-costly orders. "
            "Execution pattern matches MetaTrader Virtual Dealer Plugin signatures. "
            "Asymmetric delay is never caused by market conditions — it is broker manipulation.",
            g_vdpLagRatio));
      }
      else if(hasAsymmetry || hasStructuralAsymmetry || g_vdpLagRatio > 2.0)
      {
         PdfBodyColor(StringFormat("ASYMMETRIC EXECUTION DETECTED (%.0fx)", g_vdpLagRatio), 0.95, 0.15, 0.0);
         PdfBody("Broker-profitable orders (stops, SL) are consistently delayed longer than "
            "broker-costly orders (limits, TP). Asymmetric delay between order types is never "
            "caused by market conditions or infrastructure — it requires deliberate per-order-type "
            "configuration. This is broker manipulation.");
         PdfSpace(4);
         PdfBodyBold("SELF-BENCHMARKING:");
         PdfBody(StringFormat("This broker's fastest execution (%.0fms on limit/TP orders) proves its "
            "infrastructure can process orders at that speed. The slower execution on stop/SL orders "
            "(%.0fms) is therefore a choice, not a technical limitation. The broker's own best "
            "performance becomes the evidence against it.", medLimitLag, medStopLag));
         if(g_vdpScore >= 25)
            PdfBody(StringFormat("Virtual Dealer Plugin probability: %.0f%% — %s",
               g_vdpScore, g_vdpVerdict));
      }
      else if(violations >= 4 && !hasAsymmetry)
      {
         PdfBodyBold("SLOW EXECUTION:");
         PdfBody("Execution times significantly exceed A-book standards, but no asymmetric treatment was "
            "detected between order types. Stops, limits, TP, and SL are all processed at similar speeds. "
            "This indicates slow broker infrastructure rather than discriminatory B-book execution.");
         PdfSpace(4);
         PdfBody("Top A-book brokers execute in 10-50ms in 2026. Slow symmetric execution still affects "
            "fill quality because market prices move during the delay. However, without asymmetry, "
            "this does not indicate selective manipulation or B-book internalization.");
         if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT)
         {
            PdfSpace(4);
            PdfBody(StringFormat("NOTE: %.0f%% of fills are clustered — a natural consequence of the slow "
               "symmetric execution. Orders batch together due to infrastructure latency, not selective broker behavior.",
               g_clusterRatio * 100));
         }
      }
      else if(violations >= 1 && !hasAsymmetry)
      {
         PdfBodyBold("SLOW EXECUTION:");
         PdfBody("Some execution times exceed A-book standards. However, no asymmetric treatment was "
            "detected between order types — stops, limits, TP, and SL are all processed at similar speeds. "
            "This indicates slow broker infrastructure rather than discriminatory execution.");
         PdfSpace(4);
         PdfBody("Slow symmetric execution still affects fill quality because market prices move during the delay, "
            "but it does not indicate B-book or selective manipulation.");
         if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT)
         {
            PdfSpace(4);
            PdfBody(StringFormat("NOTE: %.0f%% of fills are clustered — a natural result of the slow symmetric execution. "
               "Orders batch together due to infrastructure latency, not selective broker behavior.",
               g_clusterRatio * 100));
         }
      }

      // --- Fiduciary Duty Breach Statement (bold red) ---
      // Show statutory breach for genuine red flags including asymmetric execution
      if(hasAsymmetry && violations >= 4)
      {
         PdfSpace(6);
         PdfBodyColor("STATUTORY DUTY OF EXECUTION BREACHED", 0.90, 0.05, 0.0);
         PdfSpace(2);
         PdfBodyColor(StringFormat("The execution data measured on broker \"%s\" (server: %s, account: %d) "
            "shows discriminatory execution including asymmetric delay between order types.",
            g_brokerName, g_serverName, (int)g_accountNumber), 0.90, 0.05, 0.0);
         PdfSpace(2);
         if(medStopLag > STD_FILL_SLOW_MS || medSLLag > STD_TPSL_SLOW_MS)
         {
            PdfBodyColor("- Excessive execution lag on stop-like orders with adverse price impact.", 0.90, 0.05, 0.0);
         }
         if(g_batchCount > 0 && g_batchClassification != "FAIR")
         {
            PdfBodyColor(StringFormat("- Price batching detected (%d batches, %.1f pts avg advantage).",
               g_batchCount, g_avgBatchAdvantagePts), 0.90, 0.05, 0.0);
         }
         if(g_roundingErrorSum < -0.01 && g_roundingErrorCount > 5)
         {
            PdfBodyColor(StringFormat("- Systematic rounding error favoring broker: %s.",
               FormatMoney(MathAbs(g_roundingErrorSum))), 0.90, 0.05, 0.0);
         }
      }
   }
   else
   {
      // FAIR verdict — no violations to list
      PdfBody("No significant violations detected. All execution metrics are within 2026 A-book industry standards.");
      PdfBody("Lag is fast and symmetric across all order types. No asymmetric delay, no discriminatory treatment.");
   }
   PdfSpace(4);
   PdfBody("This report and accompanying evidence files constitute a complete "
      "evidentiary package for regulatory complaint or legal proceedings.");

   // ==================== SECTION 8: HOW TO FILE COMPLAINT ====================
   PdfNewPage();
   PdfSection("SECTION 8: HOW TO FILE A COMPLAINT");
   PdfBody("1. Contact your broker's compliance department first. Reference "
      "the specific findings in this report and request an explanation of "
      "their execution practices.");
   PdfSpace(2);
   PdfBody("2. If unresolved, file with your jurisdiction's financial regulator:");
   PdfBody("   - FSCA (South Africa): www.fsca.co.za");
   PdfBody("   - FCA (United Kingdom): www.fca.org.uk");
   PdfBody("   - CySEC (Cyprus/EU): www.cysec.gov.cy");
   PdfBody("   - ASIC (Australia): www.asic.gov.au");
   PdfBody("   - CFTC/NFA (United States): www.cftc.gov / www.nfa.futures.org");
   PdfBody("   - BaFin (Germany): www.bafin.de");
   PdfBody("   - AMF (France): www.amf-france.org");
   PdfSpace(2);
   PdfBody("3. Include with your complaint: This report (PDF or HTML version), "
      "the evidence CSV file, the tick CSV file, and your account statement "
      "for the test period.");
   PdfSpace(2);
   PdfBody("4. Request from your broker: Explanation of execution practices for "
      "each order type, compensation for measured damages, proof of A-book "
      "routing (LP fill confirmations).");

   // ==================== SECTION 9: ENFORCEMENT PRECEDENTS ====================
   PdfNewPage();
   PdfSection("SECTION 9: ENFORCEMENT PRECEDENTS & CASE LAW");
   PdfSpace(4);
   PdfBody("The execution behaviors measured in this report have been prosecuted by financial "
      "regulators worldwide. The following enforcement actions establish legal precedent that "
      "asymmetric execution constitutes market manipulation, regardless of whether the broker "
      "attributes it to liquidity providers or technical infrastructure.");
   PdfSpace(6);

   // --- FXCM ---
   PdfSubSec("FXCM Inc. (2011-2017) — $16M+ fines, permanent CFTC ban");
   PdfSpace(2);
   PdfBodyBold("Violation: Asymmetric slippage retention");
   PdfBody("FXCM retained 100% of positive price slippage (when prices moved in the client's favor "
      "between order submission and execution) while passing 100% of negative slippage to clients. "
      "Total retained: $9,828,677. Average per-trade retention: $3.70.");
   PdfSpace(2);
   PdfBodyBold("Enforcement actions:");
   PdfBody("- NFA (2011): $2M fine + $8.3M client restitution for asymmetric slippage.");
   PdfBody("- FCA (2014): GBP 4M fine. FXCM UK retained approx. GBP 6M in favorable price movements.");
   PdfBody("- CFTC (2017): $7M fine + permanent US ban. FXCM held an undisclosed interest in "
      "Effex Capital, its principal market maker, receiving ~70% of Effex's trading profits — "
      "profits generated by trading against FXCM's own customers as counterparty.");
   PdfSpace(2);
   PdfBodyBold("Relevance to this report:");
   PdfBody("If the stop/limit execution ratio in Section 3 exceeds 1.5x, the same asymmetric "
      "pattern that led to FXCM's prosecution is present in your broker's execution.");
   PdfSpace(2);
   PdfBody("References: NFA Case No. 11-BCC-023; FCA Final Notice, 24 Feb 2014; "
      "CFTC Docket No. 17-04.");
   PdfBody("Download: https://www.cftc.gov/PressRoom/PressReleases/6119-11");
   PdfBody("Download: https://www.fca.org.uk/publication/final-notices/forex-capital-markets-limited.pdf");
   PdfBody("Download: https://www.cftc.gov/PressRoom/PressReleases/7528-17");
   PdfSpace(6);

   // --- FXDD ---
   PdfSubSec("FXDD (2009-2013) — $3.5M+ fines");
   PdfSpace(2);
   PdfBodyBold("Violation: Asymmetric requoting threshold");
   PdfBody("FXDD rejected all client orders where price moved more than 2 pips in the client's "
      "favor (requoting at a worse price), but filled orders at the original price with unlimited "
      "pip movement in FXDD's favor. Period: December 2009 to June 2011.");
   PdfSpace(2);
   PdfBodyBold("Enforcement actions:");
   PdfBody("- NFA: $1.1M fine + $1.8M client restitution for asymmetric slippage.");
   PdfBody("- CFTC: Additional $2.74M fine for supervision failures.");
   PdfBody("- Senior employees including CCO deliberately misled NFA during investigation.");
   PdfSpace(2);
   PdfBody("Reference: NFA Case No. 13-BCC-014; CFTC Order, 12 Sept 2013.");
   PdfBody("Download: https://www.cftc.gov/PressRoom/PressReleases/6697-13");
   PdfSpace(6);

   // --- Barclays ---
   PdfSubSec("Barclays Bank (2009-2014) — $150M fine");
   PdfSpace(2);
   PdfBodyBold("Violation: Last-look abuse with asymmetric hold times");
   PdfBody("Barclays applied hold times in the 'tens and hundreds of milliseconds' on all FIX/API "
      "trades. If price moved against Barclays beyond a threshold during the hold period, the trade "
      "was rejected. If price moved in Barclays' favor, the trade was accepted. Barclays did not "
      "distinguish toxic flow from normal favorable price movements — Last Look was used as a "
      "'general filter to reject unprofitable trades.' When clients questioned rejections, Barclays "
      "cited 'technical issues.'");
   PdfSpace(2);
   PdfBodyBold("Enforcement action:");
   PdfBody("- NYDFS (2015): $150M fine. Barclays' Last Look system was found to be a mechanism "
      "for systematically disadvantaging clients.");
   PdfSpace(2);
   PdfBodyBold("Relevance to this report:");
   PdfBody("The execution lag measured in this report (broker processing time after deducting "
      "network latency) is functionally identical to a hold time. If stop orders are consistently "
      "held longer than limit orders, the broker is applying the same asymmetric hold pattern "
      "that cost Barclays $150M.");
   PdfSpace(2);
   PdfBody("Reference: NYDFS Consent Order, 18 Nov 2015.");
   PdfBody("Download: https://www.dfs.ny.gov/system/files/documents/2020/04/ea151118.pdf");
   PdfSpace(6);

   // --- GAIN Capital ---
   PdfSubSec("GAIN Capital (2010) — $459K fine");
   PdfSpace(2);
   PdfBody("NFA found asymmetric slippage on GAIN's MetaTrader platform. Orders exceeding 5 "
      "contracts were disproportionately slipped against clients.");
   PdfSpace(2);
   PdfBody("Reference: NFA Case No. 10-BCC-009.");
   PdfBody("Download: https://www.nfa.futures.org/BasicNet/CaseDocument.aspx?seqnum=2622");
   PdfSpace(6);

   // --- IKON ---
   PdfSubSec("IKON Global Markets (2007-2010) — NFA action");
   PdfSpace(2);
   PdfBody("IKON used the MetaTrader Virtual Dealer Plugin from December 2007 to April 2010 "
      "with asymmetric slippage settings. Stopped when NFA raised concerns.");
   PdfSpace(2);
   PdfBody("Reference: NFA regulatory action, 2010.");
   PdfSpace(6);

   // --- AGM Markets (Australia) ---
   PdfSubSec("AGM Markets / OT Markets / Ozifin (2020) — A$75M penalty (Australia)");
   PdfSpace(2);
   PdfBodyBold("Violation: Unconscionable conduct in OTC derivatives");
   PdfBody("AGM Markets and its authorised representatives OT Markets and Ozifin engaged in "
      "systemic unconscionable conduct while providing OTC derivative products (CFDs). "
      "Approximately 10,000 clients lost a combined A$32 million. The Federal Court imposed "
      "A$75 million in penalties — A$35M for AGM, A$20M each for OT Markets and Ozifin.");
   PdfSpace(2);
   PdfBodyBold("Relevance to this report:");
   PdfBody("This was the largest single enforcement penalty in ASIC history at the time. "
      "The Corporations Act s912A requires all AFSL holders to provide financial services "
      "'efficiently, honestly and fairly' — the same standard that execution asymmetry violates.");
   PdfSpace(2);
   PdfBody("Reference: ASIC Media Release 20-246MR, 16 Oct 2020; Federal Court of Australia.");
   PdfBody("Download: https://asic.gov.au/about-asic/news-centre/find-a-media-release/2020-releases/20-246mr/");
   PdfSpace(6);

   // --- EuropeFX / TradeFred / USG (Australia) ---
   PdfSubSec("EuropeFX / TradeFred / USG (2024) — A$83M+ client losses (Australia)");
   PdfSpace(2);
   PdfBodyBold("Violation: Systemic unconscionable conduct, unlicensed advice");
   PdfBody("Union Standard International Group (USG), BrightAU Capital (TradeFred), and "
      "Maxi EFX Global AU (EuropeFX) engaged in systemic unconscionable conduct. Companies "
      "directly profited from client losses, 95-99% of customers lost money. Account managers "
      "were incentivised to pressure investors into depositing more funds.");
   PdfSpace(2);
   PdfBody("Reference: ASIC Media Release 24-287MR; Federal Court of Australia.");
   PdfBody("Download: https://asic.gov.au/about-asic/news-centre/find-a-media-release/2024-releases/24-287mr/");
   PdfSpace(6);

   // --- Big Four Banks FX (Australia) ---
   PdfSubSec("Australian Big Four Banks (2016-2017) — Spot FX enforceable undertakings");
   PdfSpace(2);
   PdfBodyBold("Violation: Confidential order leaking and inadequate FX controls");
   PdfBody("NAB, CBA (2016), Westpac, ANZ (2017), and Macquarie Bank entered enforceable "
      "undertakings with ASIC after investigations found inadequate systems and controls in "
      "their wholesale spot FX businesses (2008-2013). Specific findings included sharing "
      "confidential client order information with external market participants and entering "
      "offers into trading platforms without legitimate commercial reason. A$13 million in "
      "voluntary contributions to financial literacy projects.");
   PdfSpace(2);
   PdfBodyBold("Relevance to this report:");
   PdfBody("Front-running and confidential order leaking are the wholesale equivalent of "
      "the retail execution manipulation this EA detects. When a broker sees your pending "
      "stop order and adjusts execution accordingly, it is functionally identical to the "
      "conduct that prompted ASIC action against Australia's largest banks.");
   PdfSpace(2);
   PdfBody("References: ASIC Media Releases 16-455MR, 17-065MR.");
   PdfBody("Download: https://asic.gov.au/about-asic/news-centre/find-a-media-release/2016-releases/16-455mr/");
   PdfBody("Download: https://asic.gov.au/about-asic/news-centre/find-a-media-release/2017-releases/17-065mr/");
   PdfSpace(6);

   // --- Legal principles ---
   PdfSubSec("Established Legal Principles");
   PdfSpace(2);
   PdfBodyBold("1. Asymmetry is the defining test");
   PdfBody("Every major enforcement action centered on the same pattern: accepting trades when "
      "price moved in the broker's favor while rejecting, requoting, or delaying when price moved "
      "in the client's favor. This is the single most reliably prosecuted behavior across all "
      "jurisdictions.");
   PdfSpace(2);
   PdfBodyBold("2. The broker's duty of execution is non-delegable");
   PdfBody("A broker's obligation to execute client orders fairly is a statutory duty that cannot "
      "be transferred to a liquidity provider. The legal maxim 'delegatus non potest delegare' "
      "(a delegate cannot further delegate) applies directly: the broker accepted the client's "
      "trust and regulatory mandate, and cannot pass that obligation downstream.");
   PdfSpace(2);
   PdfBody("This principle is codified across every major jurisdiction:");
   PdfBody("- MiFID II Art. 27: The investment firm must take 'all sufficient steps' to obtain "
      "best execution and must demonstrate compliance to clients and regulators. This demonstration "
      "burden is non-delegable.");
   PdfBody("- FCA SYSC 8.1 (UK): When a firm outsources operational functions, it 'remains fully "
      "responsible for discharging all of its obligations.' Outsourcing does not alter obligations "
      "toward clients.");
   PdfBody("- FINRA Rule 5310 (US): 'No member can transfer to another person its obligation to "
      "provide best execution to its customers' orders.'");
   PdfBody("- Corporations Act s912A (Australia): AFSL holders must provide services 'efficiently, "
      "honestly and fairly' — a statutory obligation that applies regardless of execution model.");
   PdfBody("- FAIS Act General Code s.2 (South Africa): The provider must render services 'with "
      "due skill, care and diligence, and in the interests of clients.' Blaming an LP for poor "
      "execution is a failure of due skill and diligence in LP selection and monitoring.");
   PdfSpace(2);
   PdfBody("When a broker operates a B-book (acts as principal/market maker), the position is even "
      "more adverse: the broker IS the counterparty. There is no LP to blame. The broker profits "
      "directly when the client loses, creating an inherent conflict of interest that MiFID II "
      "Art. 23, FCA COBS 10A, and FAIS Act s.3A all require to be managed — not exploited.");
   PdfSpace(2);
   PdfBodyBold("Precedent: CFTC v. FXCM (2017) — Hidden counterparty fraud");
   PdfBody("FXCM claimed its 'No Dealing Desk' platform had no conflicts because risk was borne "
      "by independent market makers. In reality, FXCM held an undisclosed interest in its principal "
      "market maker (Effex Capital), receiving ~70% of Effex's trading profits — profits generated "
      "by trading against FXCM's customers as counterparty. The CFTC imposed a $7M fine and "
      "permanent US ban. The 7th Circuit upheld NFA's findings in Effex Capital v. NFA (2019). "
      "A broker cannot hide behind its LP arrangement.");
   PdfBody("Download: https://www.cftc.gov/PressRoom/PressReleases/7528-17");
   PdfSpace(2);
   PdfBodyBold("3. NFA Rule 9064: The symmetric execution standard");
   PdfBody("NFA Interpretive Notice 9064 (effective 26 March 2012) is the most specific execution "
      "rule in any jurisdiction. It explicitly requires: slippage settings applied uniformly "
      "regardless of market direction; if an FDM requotes when market moves against it, it must "
      "also requote when market moves in its favor; demo account parameters must match live "
      "account parameters.");
   PdfBody("Download: https://www.nfa.futures.org/rulebooksql/rules.aspx?Section=9&RuleID=9064");
   PdfSpace(2);
   PdfBodyBold("4. FX Global Code of Conduct (2021): Last look boundaries");
   PdfBody("Principle 17 explicitly prohibits 'additional hold time' beyond what is needed for "
      "price and validity checks. Industry leaders demonstrate this is achievable: Northern Trust "
      "completes checks within 3ms, XTX Markets operates at 0ms hold time. Hold times in the "
      "'tens and hundreds of milliseconds' (per Barclays) are indefensible.");
   PdfSpace(2);
   PdfBodyBold("5. Execution lag IS a hold time");
   PdfBody("The broker processing time measured in this report (DEAL_TIME_MSC minus send time "
      "minus network latency) is functionally identical to a last-look hold time. When this "
      "processing time correlates with order type profitability — high for broker-profitable orders, "
      "low for broker-costly orders — the broker is operating an undisclosed last-look mechanism "
      "against retail clients who have no ability to detect or refuse it.");
   PdfSpace(6);

   // --- Benchmark table ---
   PdfSubSec("Regulatory Benchmark Summary");
   PdfSpace(2);
   PdfBody("Based on enforcement precedents and regulatory frameworks:");
   PdfSpace(2);
   PdfBody("Execution latency:    <100ms = Fair    |  100-200ms = Suspicious  |  >200ms = Manipulative");
   PdfBody("  (ECN brokers achieve 30-40ms; Barclays fined for 'tens to hundreds of ms')");
   PdfSpace(2);
   PdfBody("Stop/Limit ratio:     <1.2x = Fair     |  1.2-1.5x = Suspicious  |  >1.5x = Manipulative");
   PdfBody("  (NFA Rule 9064 requires symmetric execution across order types)");
   PdfSpace(2);
   PdfBody("Slippage symmetry:    0.8-1.2 = Fair   |  0.6-0.8 = Suspicious   |  <0.5 = Manipulative");
   PdfBody("  (FXCM fined for retaining 100% of favorable slippage)");
   PdfSpace(2);
   PdfBody("Last look / hold:     <5ms = Legitimate |  5-50ms = Questionable  |  >50ms = Illegitimate");
   PdfBody("  (FX Global Code 2021: no additional hold time; XTX operates at 0ms)");
   PdfSpace(2);
   PdfBody("Rejection asymmetry:  Symmetric = Fair  |  Directional >10% = Suspicious  |  Systematic = Manipulative");
   PdfBody("  (FXDD rejected all >2 pip favorable client moves)");
   PdfSpace(6);

   PdfBody("All references are publicly available enforcement records from the respective "
      "regulatory agencies (NFA, CFTC, FCA, NYDFS, ASIC). Direct download links are provided "
      "above and in the Sources section. All links verified as of March 2026.");

   // ==================== SECTION 10: VDP / ASYMMETRY ANALYSIS ====================
   PdfNewPage();
   PdfSection("SECTION 10: VIRTUAL DEALER PLUGIN & ASYMMETRY ANALYSIS");
   PdfSpace(4);

   PdfBodyBold("What is the Virtual Dealer Plugin (VDP)?");
   PdfBody("The MetaTrader Virtual Dealer Plugin is a server-side tool available to all MT4/MT5 "
      "brokers. It intercepts client orders and applies configurable execution delays, asymmetric "
      "slippage thresholds, and price rechecks — all invisible to the trader. Third-party clones "
      "(TradeToolsFX, FXLab DealerLogic, AzyPrime, Viktex) offer identical functionality.");
   PdfSpace(2);

   PdfBodyBold("VDP Configuration Parameters (broker admin interface):");
   PdfBody("- DelaySecs: base execution delay (integer seconds, 0-15) — separate settings for "
      "market orders, pending orders, stop-loss, and take-profit");
   PdfBody("- MaxProfitSlippagePips: if price moves in client's favor during delay, broker keeps "
      "improvement up to this threshold; beyond it, order is requoted/rejected");
   PdfBody("- MaxLosingSlippagePips: if price moves against client, order fills at worse price "
      "up to this limit (often unlimited)");
   PdfBody("- MaxProfitSlippageVolume: large orders that benefit client are automatically rejected");
   PdfBody("- Per-account and per-symbol overrides allow targeted manipulation of specific traders");
   PdfSpace(4);

   PdfBodyBold("How this report detects VDP use:");
   PdfBody("This EA analyzes the raw execution lag distribution for five forensic fingerprints "
      "that distinguish VDP-manipulated execution from natural ECN/STP latency:");
   PdfSpace(2);
   PdfBody("1. WHOLE-SECOND CLUSTERING: VDP delays are configured in integer seconds. If fills "
      "cluster at 1000ms, 2000ms, 3000ms boundaries rather than showing continuous distribution, "
      "it indicates configured delays rather than network variation.");
   PdfBody("2. DELAY MAGNITUDE: Natural ECN/STP execution is 20-200ms. VDP delays are typically "
      "500-15000ms. Median adverse delay above 500ms is a VDP indicator.");
   PdfBody("3. FLAT DISTRIBUTION: Natural lag follows a log-normal curve (right-skewed, long tail). "
      "VDP produces a flat/uniform distribution within the configured min-max delay range.");
   PdfBody("4. ORDER-TYPE DISCRIMINATION: VDP has separate delay parameters for stops, SL, TP, "
      "and limits. If each adverse type has a distinctly different delay, it suggests per-type "
      "configuration.");
   PdfBody("5. ASYMMETRIC LAG RATIO: Broker-profitable orders (stops, SL) delayed longer than "
      "broker-costly orders (limits, TP) by >2x.");
   PdfSpace(4);

   // VDP Detection Results
   PdfSubSec("Detection Results for This Account");
   PdfSpace(2);

   if(g_vdpAdverseCount < 3)
   {
      PdfBody("Insufficient data for VDP analysis (fewer than 3 adverse fills measured).");
   }
   else
   {
      // Main verdict
      double vr2 = 0, vg3 = 0, vb2 = 0;
      if(g_vdpScore >= 50)       { vr2 = 0.95; vg3 = 0.0;  vb2 = 0.0; }
      else if(g_vdpLagRatio > 2) { vr2 = 0.95; vg3 = 0.2;  vb2 = 0.0; }
      else                        { vr2 = 0.0;  vg3 = 0.55; vb2 = 0.0; }

      PdfBodyColor(StringFormat("VDP Score: %.0f/100 — %s", g_vdpScore, g_vdpVerdict), vr2, vg3, vb2);
      PdfSpace(2);

      PdfKV("Adverse fills (stops + SL):", StringFormat("%d fills, median %s",
         g_vdpAdverseCount, FormatMs(g_vdpAdverseMedian)));
      PdfKV("Favorable fills (limits + TP):", StringFormat("%d fills, median %s",
         g_vdpFavorCount, FormatMs(g_vdpFavorMedian)));
      PdfKV("Lag asymmetry ratio:", StringFormat("%.1fx %s",
         g_vdpLagRatio, g_vdpLagRatio > 2.0 ? "— ASYMMETRIC (broker-favorable)" : "— within tolerance"));
      PdfSpace(2);

      PdfBodyBold("Individual test results:");
      PdfBody(StringFormat("  Whole-second clustering: %.0f%% of adverse fills — %s",
         g_vdpWholeSecPct, g_vdpWholeSecCluster ? "DETECTED (>40%%)" : "not detected"));
      PdfBody(StringFormat("  Delay magnitude: median %s — %s",
         FormatMs(g_vdpAdverseMedian), g_vdpDelayRange ? "IN VDP RANGE (>500ms)" : "within natural range"));
      PdfBody(StringFormat("  Distribution shape: IQR/median = %.2f — %s",
         g_vdpIQRatio, g_vdpFlatDistribution ? "FLAT (configured delay band)" : "normal spread"));
      PdfBody(StringFormat("  Order-type discrimination: %s",
         g_vdpOrderTypeDiscrim ? "DETECTED (stops vs SL have different delays)" : "not detected"));
      PdfBody(StringFormat("  Lag asymmetry (>2x): %s",
         g_vdpLagRatio > 2.0 ? "YES — broker-profitable orders delayed longer" : "no"));
      PdfSpace(4);

      if(g_vdpScore >= 50)
      {
         PdfBodyColor("CONCLUSION: The execution pattern on this account is consistent with "
            "Virtual Dealer Plugin intervention. The broker appears to be applying configured "
            "execution delays that discriminate between order types, systematically disadvantaging "
            "the trader on broker-profitable fills.", 0.90, 0.05, 0.0);
      }
      else if(g_vdpLagRatio > 2.0)
      {
         PdfBodyColor(StringFormat("CONCLUSION: Although VDP-specific signatures were not conclusively "
            "detected, this account shows %.0fx asymmetric execution — broker-profitable orders "
            "(stops, SL) are delayed %.0fx longer than broker-costly orders (limits, TP). "
            "This asymmetry is a regulatory violation regardless of the mechanism used. "
            "The fill price is irrelevant; the timing difference itself causes harm when an EA "
            "closes positions on a retracement and delayed counter fills arrive afterward, "
            "creating unwanted exposure.", g_vdpLagRatio, g_vdpLagRatio), 0.90, 0.20, 0.0);
      }
      else
      {
         if(violations >= 1)
            PdfBody("CONCLUSION: No significant asymmetry or VDP signatures detected. "
               "Execution is slow but consistent across all order types — this indicates "
               "slow broker infrastructure, not discriminatory B-book behavior.");
         else
            PdfBody("CONCLUSION: No significant asymmetry or VDP signatures detected. "
               "Execution appears consistent with legitimate ECN/STP processing.");
      }
   }
   PdfSpace(4);

   PdfBodyBold("Natural ECN/STP vs VDP-Manipulated Execution:");
   PdfSpace(2);
   PdfBody("Metric                  Natural ECN/STP          VDP-Manipulated");
   PdfBody("Delay distribution      Log-normal, continuous   Discrete spikes at whole seconds");
   PdfBody("Delay magnitude         20-200ms typical         500-15000ms typical");
   PdfBody("Slippage symmetry       ~50/50 pos/neg           80%+ negative");
   PdfBody("Delay vs volatility     Increases with vol       Constant (configured)");
   PdfBody("Per-type differences    None systematic          Separate delays per type");
   PdfBody("Distribution shape      Right-skewed tail        Flat/uniform band");
   PdfSpace(4);

   PdfBody("References: CashbackForex VDP analysis; TradeToolsFX VDP product documentation; "
      "Forex Factory thread 70582 (VDP configuration parameters); "
      "NFA Interpretive Notice 9064 (symmetric execution requirement).");

   // ==================== APPENDIX A ====================
   PdfNewPage();
   PdfSection("APPENDIX A: EVIDENCE FILE MANIFEST");
   PdfKV("Evidence CSV:", g_evidenceCsvName);
   PdfKV("Tick CSV:", g_tickCsvName);
   PdfKV("Broker Log:", g_brokerLogName);
   PdfKV("Trade History:", g_histCsvName);
   PdfKV("PDF Report:", g_reportPdfName);
   if(InpWriteHTML)
      PdfKV("HTML Report:", g_reportHtmName);
   PdfKV("TOML Data:", g_tomlName);
   PdfSpace(2);
   PdfBody(StringFormat("All files located in: %s",
      TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files"));
   PdfSpace(4);
   PdfSubSec("File Descriptions");
   PdfBody("Evidence CSV: Every fill/close event with ms timestamps, prices, lag, and cost");
   PdfBody("Tick CSV: Every market tick during the entire test (bid, ask, spread, ms timestamps)");
   PdfBody("Broker Log: Raw broker transaction stream - ALL OnTradeTransaction events logged");
   PdfBody("Trade History: MT5 deal and order history export with broker timestamps (DEAL_TIME_MSC)");

   // ==================== APPENDIX B ====================
   PdfNewPage();
   PdfSection("APPENDIX B: RAW TRADE DATA SUMMARY");
   PdfBodyBold("First 10 fills:");
   int showN = (int)MathMin(g_fillCount, 10);
   for(int i = 0; i < showN; i++)
   {
      PdfBody(StringFormat("Cycle %d | %s | Req %.5f | Fill %.5f | Drift %+.1f | Lag %s",
         g_fills[i].cycleNum, GetFillTypeName(g_fills[i].fillType),
         g_fills[i].requestedPrice, g_fills[i].fillPrice,
         g_fills[i].slippagePts, FormatMs(g_fills[i].brokerExecMs)));
   }
   if(g_fillCount > 20)
   {
      PdfBody("...");
      PdfBodyBold("Last 10 fills:");
      for(int i = g_fillCount - 10; i < g_fillCount; i++)
      {
         PdfBody(StringFormat("Cycle %d | %s | Req %.5f | Fill %.5f | Slip %+.1f | Lag %s",
            g_fills[i].cycleNum, GetFillTypeName(g_fills[i].fillType),
            g_fills[i].requestedPrice, g_fills[i].fillPrice,
            g_fills[i].slippagePts, FormatMs(g_fills[i].brokerExecMs)));
      }
   }
   PdfSpace(2);
   PdfBody(StringFormat("Full dataset: %d fills - see %s", g_fillCount, g_evidenceCsvName));

   // ==================== APPENDIX C ====================
   PdfNewPage();
   PdfSection("APPENDIX C: GRID CONFIGURATION PER CYCLE");
   for(int c = 0; c < g_cycleNum; c++)
   {
      PdfBody(StringFormat("Cycle %d: Spread=%.1f  Space=%.1f  Levels=%d  "
         "Placed=%d  Filled=%d  TP=%d  SL=%d  Closes=%d",
         g_cycles[c].cycleNum, g_cycles[c].spreadAtPlace, g_cycles[c].spacingPts,
         g_cycles[c].levelsPerSide, g_cycles[c].totalPlaced, g_cycles[c].totalFilled,
         g_cycles[c].tpTriggers, g_cycles[c].slTriggers, g_cycles[c].closeFills));
   }

   // ==================== APPENDIX D ====================
   PdfNewPage();
   PdfSection("APPENDIX D: GLOSSARY");
   PdfKV("Fill Lag:", "Time from order trigger to fill confirmation (ms)");
   PdfKV("Lag Cost:", "Financial damage caused by price movement during broker hold period");
   PdfKV("B-Book:", "Broker takes opposite side of client trades (conflict of interest)");
   PdfKV("A-Book:", "Broker routes orders to external liquidity (STP/ECN)");
   PdfKV("STP:", "Straight-Through Processing - orders routed directly to LP");
   PdfKV("ECN:", "Electronic Communication Network - anonymous matching");
   PdfKV("Last-Look:", "Broker holds order to check if price moved favorably");
   PdfKV("Take Profit:", "Automatic close when price reaches profit target");
   PdfKV("Stop Loss:", "Automatic close when price reaches loss limit");
   PdfKV("Pending Order:", "Order placed in advance to trigger at specified price");
   PdfKV("Buy Stop:", "Pending buy above current price (breakout entry)");
   PdfKV("Sell Stop:", "Pending sell below current price (breakout entry)");
   PdfKV("Buy Limit:", "Pending buy below current price (pullback entry)");
   PdfKV("Sell Limit:", "Pending sell above current price (pullback entry)");
   PdfKV("Rounding:", "Difference between broker's P&L and exact P&L calculation");

   // ===== ORDER REJECTION ANALYSIS =====
   if(g_rejectionCount > 0 || g_fillRejectionCount > 0)
   {
      PdfCheckY(180);
      // Question header for rejections (combined placement + fill rejections)
      {
         int pRejStop = 0, pRejLimit = 0;
         for(int pr = 0; pr < g_rejectionCount; pr++)
         {
            if(StringFind(g_rejections[pr].orderType, "STRESS") >= 0) continue;
            if(StringFind(g_rejections[pr].orderType, "Stop") >= 0) pRejStop++;
            if(StringFind(g_rejections[pr].orderType, "Limit") >= 0) pRejLimit++;
         }
         // Include fill rejections in totals
         pRejStop += g_fillRejStopTotal;
         pRejLimit += g_fillRejLimitTotal;
         if(pRejStop > 0 || pRejLimit > 0)
         {
            PdfSubSec("Whose orders get rejected - yours, or the broker's?");
            PdfSpace(2);
            if(pRejStop > 0 && pRejLimit == 0)
               PdfBodyColor(StringFormat("Only your orders were rejected: %d stop rejections, 0 limit rejections. "
                  "The broker's orders were never refused.", pRejStop), 0.85, 0.1, 0);
            else if(pRejLimit > 0 && pRejStop > pRejLimit)
               PdfBodyColor(StringFormat("Your orders were rejected %.1fx more often: %d stop vs %d limit rejections.",
                  (double)pRejStop / pRejLimit, pRejStop, pRejLimit), 0.85, 0.1, 0);
            else
               PdfBody(StringFormat("Rejections: %d stop, %d limit — distributed symmetrically.", pRejStop, pRejLimit));
            if(g_fillRejectionCount > 0)
               PdfBodyColor(StringFormat("NOTE: %d orders were accepted then cancelled by the broker "
                  "instead of filling (fill rejections — see separate section below).",
                  g_fillRejectionCount), 0.85, 0.1, 0);
            PdfSpace(4);
         }
      }
      if(g_rejectionCount > 0)
      {
      PdfSubSec("Order Placement Rejection Analysis");
      PdfKV("Total Placement Rejections:", IntegerToString(g_rejectionCount));
      PdfKV("Your Stop Rejections:", StringFormat("%d (manipulation: %d, legitimate: %d)",
         g_rejStopTotal, g_rejStopManipulation, g_rejStopLegitimate));
      PdfKV("Broker Limit Rejections:", StringFormat("%d (manipulation: %d, legitimate: %d)",
         g_rejLimitTotal, g_rejLimitManipulation, g_rejLimitLegitimate));
      PdfKV("Market Rejections:", IntegerToString(g_rejMarketTotal));
      if(g_rejTransientCount > 0)
         PdfKV("Transient (retry verified):", StringFormat("%d — excluded from manipulation count", g_rejTransientCount));
      if(g_rejPersistentCount > 0)
         PdfKV("Persistent (retry failed):", StringFormat("%d — classified normally", g_rejPersistentCount));

      // Calculate median/max distance for manipulative rejections
      double manipDistArr[];
      int manipCount = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(g_rejections[r].classification >= REJ_CLASS_SUSPICIOUS &&
            g_rejections[r].classification <= REJ_CLASS_ASYMMETRIC_REQUOTE &&
            StringFind(g_rejections[r].orderType, "STRESS") < 0)
         {
            ArrayResize(manipDistArr, manipCount + 1);
            manipDistArr[manipCount++] = g_rejections[r].distSpreads;
         }
      }
      if(manipCount > 0)
      {
         ArraySort(manipDistArr);
         double medDist = manipDistArr[manipCount / 2];
         double maxDist2 = manipDistArr[manipCount - 1];
         PdfKV("Manipulative — median distance:", StringFormat("%.1f spreads from price", medDist));
         PdfKV("Manipulative — max distance:", StringFormat("%.1f spreads from price", maxDist2));
      }

      // Count by classification type for detail
      int cntSusp = 0, cntAsymDelay = 0, cntAsymRequote = 0, cntLegit = 0, cntSymReq = 0, cntTransient = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         switch(g_rejections[r].classification)
         {
            case REJ_CLASS_SUSPICIOUS:        cntSusp++; break;
            case REJ_CLASS_ASYMMETRIC_DELAY:  cntAsymDelay++; break;
            case REJ_CLASS_ASYMMETRIC_REQUOTE:cntAsymRequote++; break;
            case REJ_CLASS_LEGITIMATE:        cntLegit++; break;
            case REJ_CLASS_SYMMETRIC_REQUOTE: cntSymReq++; break;
            case REJ_CLASS_TRANSIENT:         cntTransient++; break;
         }
      }

      PdfSpace(2);
      PdfBody("Classification breakdown:");
      if(cntSusp > 0)
         PdfBodyColor(StringFormat("  Price away from level: %d — Order rejected while price was well away from the order level. "
            "No market reason exists for this rejection.", cntSusp), 0.85, 0.1, 0);
      if(cntAsymDelay > 0)
         PdfBodyColor(StringFormat("  Asymmetric delay: %d — Price passed the order level, but the broker has measured "
            "asymmetric processing delay (stops processed slower than limits). The price movement that \"caused\" the rejection "
            "was manufactured by the broker's own artificial delay.", cntAsymDelay), 0.85, 0.1, 0);
      if(cntAsymRequote > 0)
         PdfBodyColor(StringFormat("  Asymmetric requote: %d — Broker cited \"liquidity\" (requote), but requotes were "
            "applied selectively to stop orders while limit orders were not requoted. This is not a genuine liquidity event — "
            "genuine liquidity affects both order types equally.", cntAsymRequote), 0.85, 0.1, 0);
      if(cntLegit > 0)
         PdfBody(StringFormat("  Legitimate: %d — Price genuinely moved past order level during symmetric broker processing.", cntLegit));
      if(cntSymReq > 0)
         PdfBody(StringFormat("  Symmetric requote: %d — Both order types requoted at similar rates (genuine liquidity).", cntSymReq));
      if(cntTransient > 0)
         PdfBody(StringFormat("  Transient (retry verified): %d — Server rejected initially but accepted identical order on retry %dms later. "
            "Momentary server issue, not manipulation. Excluded from manipulation count.", cntTransient, InpRejRetryDelayMs));

      // Per-rejection detail: Broker Reason vs Measured Reason (non-stress, non-legitimate)
      {
         int rejDetailCount = 0;
         for(int r = 0; r < g_rejectionCount; r++)
         {
            if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
            rejDetailCount++;
         }
         if(rejDetailCount > 0 && rejDetailCount <= 30)
         {
            PdfSpace(4);
            PdfBody("Rejection Detail — Broker Reason vs Measured Reason:");
            PdfSpace(2);
            for(int r = 0; r < g_rejectionCount; r++)
            {
               if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
               PdfCheckY(50);
               bool isManipRej = (g_rejections[r].classification >= REJ_CLASS_SUSPICIOUS &&
                                  g_rejections[r].classification <= REJ_CLASS_ASYMMETRIC_REQUOTE);
               string classTag2 = "";
               switch(g_rejections[r].classification)
               {
                  case REJ_CLASS_SUSPICIOUS:        classTag2 = "PRICE AWAY"; break;
                  case REJ_CLASS_ASYMMETRIC_DELAY:  classTag2 = "ASYM DELAY"; break;
                  case REJ_CLASS_ASYMMETRIC_REQUOTE:classTag2 = "ASYM REQUOTE"; break;
                  case REJ_CLASS_LEGITIMATE:        classTag2 = "LEGITIMATE"; break;
                  case REJ_CLASS_SYMMETRIC_REQUOTE: classTag2 = "SYM REQUOTE"; break;
                  case REJ_CLASS_TRANSIENT:         classTag2 = "TRANSIENT"; break;
                  default:                          classTag2 = "UNCLASSIFIED"; break;
               }
               if(isManipRej)
               {
                  PdfBodyColor(StringFormat("%s — dist: %.1f pts (%.1f spreads) — %s",
                     g_rejections[r].orderType, g_rejections[r].distPoints,
                     g_rejections[r].distSpreads, classTag2), 0.85, 0.1, 0);
                  PdfBody(StringFormat("  Broker says: %s", g_rejections[r].brokerReason));
                  PdfBodyColor(StringFormat("  Measured: %s", g_rejections[r].measuredReason), 0.85, 0.3, 0);
               }
               else
               {
                  PdfBody(StringFormat("%s — dist: %.1f pts (%.1f spreads) — %s",
                     g_rejections[r].orderType, g_rejections[r].distPoints,
                     g_rejections[r].distSpreads, classTag2));
                  PdfBody(StringFormat("  Broker says: %s", g_rejections[r].brokerReason));
                  PdfBody(StringFormat("  Measured: %s", g_rejections[r].measuredReason));
               }
               PdfSpace(2);
            }
         }
      }

      PdfSpace(2);
      if(g_rejectionVerdict != "NONE" && StringFind(g_rejectionVerdict, "NONE") < 0)
         PdfBodyColor(StringFormat("VERDICT: %s", g_rejectionVerdict), 0.85, 0.1, 0);
      else if(g_rejectionCount > 0)
         PdfBody("VERDICT: No manipulative rejection patterns detected.");
      PdfSpace(4);
      } // end if(g_rejectionCount > 0)
   }

   // ===== FILL REJECTIONS — BROKER CANCELLED PENDING ORDERS =====
   if(g_fillRejectionCount > 0)
   {
      PdfCheckY(80);
      PdfSubSec("Did the broker accept your orders then refuse to fill them?");
      PdfSpace(2);
      PdfBodyColor(StringFormat("The broker accepted %d pending orders onto the server, "
         "then cancelled them instead of filling when price reached the trigger level.",
         g_fillRejectionCount), 0.85, 0.1, 0);
      PdfSpace(2);
      PdfKV("Total Fill Rejections:", IntegerToString(g_fillRejectionCount));
      PdfKV("Your Stop Orders Cancelled:", StringFormat("%d (price triggered: %d, pre-emptive: %d)",
         g_fillRejStopTotal, g_fillRejStopTriggered, g_fillRejStopPreemptive));
      PdfKV("Broker Limit Orders Cancelled:", StringFormat("%d (price triggered: %d, pre-emptive: %d)",
         g_fillRejLimitTotal, g_fillRejLimitTriggered, g_fillRejLimitPreemptive));
      PdfSpace(2);

      if(g_fillRejStopTriggered > 0 && g_fillRejLimitTriggered == 0)
      {
         PdfBodyColor("SELECTIVE FILL SUPPRESSION: Only YOUR stop orders were cancelled after "
            "price triggered them. The broker's limit orders were always honored. "
            "The broker accepted the order, watched price reach it, then refused to fill it — "
            "the order disappeared as if it was never placed.", 0.85, 0.1, 0);
      }
      else if(g_fillRejStopTriggered > 0)
      {
         PdfBodyColor(StringFormat("ASYMMETRIC FILL SUPPRESSION: %d stop orders vs %d limit orders "
            "cancelled after price trigger. Your orders are disproportionately targeted.",
            g_fillRejStopTriggered, g_fillRejLimitTriggered), 0.85, 0.1, 0);
      }

      // Per-rejection detail
      if(g_fillRejectionCount <= 30)
      {
         PdfSpace(4);
         PdfBody("Fill Rejection Detail — Broker Reason vs Measured Reason:");
         PdfSpace(2);
         for(int r = 0; r < g_fillRejectionCount; r++)
         {
            PdfCheckY(50);
            bool isTriggered = (g_fillRejections[r].classification == FILLREJ_CLASS_PRICE_TRIGGERED);
            if(isTriggered)
            {
               PdfBodyColor(StringFormat("%s — price TRIGGERED — dist: %.1f pts — cycle %d",
                  g_fillRejections[r].orderType, g_fillRejections[r].distPoints,
                  g_fillRejections[r].cycleNum), 0.85, 0.1, 0);
               PdfBody(StringFormat("  Broker says: %s", g_fillRejections[r].brokerReason));
               PdfBodyColor(StringFormat("  Measured: %s", g_fillRejections[r].measuredReason), 0.85, 0.3, 0);
            }
            else
            {
               PdfBody(StringFormat("%s — pre-emptive — dist: %.1f pts — cycle %d",
                  g_fillRejections[r].orderType, g_fillRejections[r].distPoints,
                  g_fillRejections[r].cycleNum));
               PdfBody(StringFormat("  Broker says: %s", g_fillRejections[r].brokerReason));
               PdfBody(StringFormat("  Measured: %s", g_fillRejections[r].measuredReason));
            }
            PdfSpace(2);
         }
      }

      PdfSpace(2);
      PdfBodyColor(StringFormat("VERDICT: %s", g_fillRejVerdict), 0.85, 0.1, 0);
      PdfSpace(4);
   }

   // ===== PHANTOM SPIKE DETECTION =====
   if(g_phantomSpikeCount > 0)
   {
      int slSp = 0;
      for(int s = 0; s < g_phantomSpikeCount; s++)
         if(g_phantomSpikes[s].triggeredSL) slSp++;

      PdfCheckY(50);
      PdfSubSec("Phantom Spike Detection");
      PdfKV("Anomalous Spikes:", IntegerToString(g_phantomSpikeCount));
      PdfKV("Median Spread:", StringFormat("%.1f pts", g_medianSpread / g_tickSize));
      if(slSp > 0)
         PdfBodyColor(StringFormat("WARNING: %d spike(s) coincided with SL triggers within 2 seconds", slSp), 0.85, 0.1, 0);
      else
         PdfBody("No spikes coincided with SL triggers.");
      PdfSpace(4);
   }

   // ===== MARGIN VERIFICATION =====
   if(g_theoreticalMarginBuy > 0)
   {
      PdfCheckY(50);
      PdfSubSec("Margin Verification");
      PdfKV("Theoretical (Buy):", StringFormat("%.2f %s", g_theoreticalMarginBuy, g_displayCurrency));
      PdfKV("Actual (Buy):", StringFormat("%.2f %s", g_measuredMarginBuy, g_displayCurrency));
      PdfKV("Discrepancy:", StringFormat("%.2f (%.1f%%)", g_marginDiscrepancyBuy, g_marginMarkupPctBuy));
      if(MathAbs(g_marginMarkupPctBuy) > 10.0)
         PdfBodyColor("Margin charged deviates >10% from theoretical calculation", 0.85, 0.45, 0);
      PdfSpace(4);
   }

   // ===== ORDER CAPACITY STRESS TEST =====
   {
      PdfCheckY(80);
      PdfSubSec("Order Capacity Stress Test");
      PdfKV("Batch Size:", StringFormat("%d orders/cycle (measured order limit)", (int)g_orderLimit));

      // Limit results with rejection rate
      double limRejPctPdf = (g_stressLimitTotalAttempts > 0) ?
         (100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts) : 0;
      string limRes = g_stressLimitBlocked ?
         StringFormat("BLOCKED at cycle %d", g_stressLimitBlockedAt) :
         StringFormat("%d cycles | Max verified: %d", g_stressCycleLimit, g_stressMaxVerifiedLimit);
      if(limRejPctPdf > 10.0)
         limRes += StringFormat(" | %.0f%% REJECTED (%d/%d)", limRejPctPdf,
            g_stressLimitTotalRejects, g_stressLimitTotalAttempts);
      PdfKV("Limit Orders (baseline):", limRes);

      // Stop results with rejection rate
      double stpRejPctPdf = (g_stressStopTotalAttempts > 0) ?
         (100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts) : 0;
      string stpRes = g_stressStopBlocked ?
         StringFormat("BLOCKED at cycle %d", g_stressStopBlockedAt) :
         StringFormat("%d cycles | Max verified: %d", g_stressCycleStop, g_stressMaxVerifiedStop);
      if(stpRejPctPdf > 10.0)
         stpRes += StringFormat(" | %.0f%% REJECTED (%d/%d)", stpRejPctPdf,
            g_stressStopTotalRejects, g_stressStopTotalAttempts);
      PdfKV("Stop Orders:", stpRes);

      if(g_stressStopBlocked && !g_stressLimitBlocked)
      {
         PdfBodyColor("SELECTIVE ORDER BLOCKING: Broker allows unlimited limit-order cycling but blocks "
            "stop-order cycling. This prevents traders from maintaining hedging/risk-management via stop orders.", 0.85, 0.1, 0);
      }
      else if(!g_stressStopBlocked && !g_stressLimitBlocked)
      {
         bool asymRejPdf = (stpRejPctPdf > limRejPctPdf * 1.5 && stpRejPctPdf > 10.0) ||
                            (limRejPctPdf > stpRejPctPdf * 1.5 && limRejPctPdf > 10.0);
         if(asymRejPdf)
            PdfBodyColor("Both order types completed all cycles, but with asymmetric rejection rates (see below).", 0.85, 0.5, 0);
         else if(limRejPctPdf > 10.0 || stpRejPctPdf > 10.0)
            PdfBody("Both order types completed all cycles. Rejection rates are symmetric (legitimate rate limiting).");
         else
            PdfBody("No selective blocking detected. Both order types completed all cycles.");
      }

      // Rejection analysis — distinguish rate limiting (legitimate) from asymmetry (manipulation)
      if(limRejPctPdf > 10.0 || stpRejPctPdf > 10.0)
      {
         PdfSpace(2);
         bool asymThrottlePdf = (stpRejPctPdf > limRejPctPdf * 1.5 && stpRejPctPdf > 10.0) ||
                                (limRejPctPdf > stpRejPctPdf * 1.5 && limRejPctPdf > 10.0);
         if(asymThrottlePdf)
         {
            PdfBodyColor(StringFormat("ASYMMETRIC ORDER REJECTION: Stops %.0f%% rejected vs limits %.0f%%. "
               "Both order types were placed under identical conditions (same burst rate, same account). "
               "Asymmetric rejection rates indicate the broker's rate limiter treats order types differently, "
               "which cannot be attributed to server load.", stpRejPctPdf, limRejPctPdf), 0.85, 0.1, 0);
         }
         else
         {
            double totalRejPctPdf = 100.0 * (g_stressStopTotalRejects + g_stressLimitTotalRejects) /
               MathMax(1, g_stressStopTotalAttempts + g_stressLimitTotalAttempts);
            PdfBody(StringFormat("Rate limiting: %.0f%% of rapid-fire burst placements were rejected. "
               "Rejection rates are symmetric between order types (stops %.0f%% vs limits %.0f%%), "
               "consistent with legitimate server-side rate limiting rather than selective manipulation.",
               totalRejPctPdf, stpRejPctPdf, limRejPctPdf));
         }
      }

      // Throttle lockout
      if(g_throttleRecoveryCount > 0)
      {
         PdfSpace(2);
         PdfKV("Post-Activity Throttle Lockout:", IntegerToString(g_throttleRecoveryCount) + " events detected");
         if(g_throttleLimitMeasurements > 0)
            PdfKV("  Limit Orders:", StringFormat("avg %.0fms | worst %.0fms",
               g_throttleLimitTotalMs / g_throttleLimitMeasurements, g_throttleLimitMaxMs));
         if(g_throttleStopMeasurements > 0)
            PdfKV("  Stop Orders:", StringFormat("avg %.0fms | worst %.0fms",
               g_throttleStopTotalMs / g_throttleStopMeasurements, g_throttleStopMaxMs));
         double worstOverall = MathMax(g_throttleLimitMaxMs, g_throttleStopMaxMs);
         if(worstOverall > 500)
            PdfBodyColor(StringFormat("SCALPING EA IMPACT: Broker imposes a %.0fms (%.1fs) lockout after "
               "order activity. During fast market moves, this delay causes missed entries or adverse slippage.",
               worstOverall, worstOverall / 1000.0), 0.85, 0.1, 0);
      }

      // EA Tuning Recommendations (optional — controlled by InpShowEATuning)
      if(InpShowEATuning)
      {
         PdfSpace(2);
         PdfSubSec("EA Tuning Recommendations");
         PdfBody("The following values are measured from your broker's actual behavior and can be used to "
            "configure trading EAs to avoid rate-limiting rejections during live trading:");
         PdfSpace(2);
         if(g_stressMaxVerifiedStop > 0)
            PdfKV("Max Async Burst (Stops):", StringFormat("%d orders accepted in a single burst", g_stressMaxVerifiedStop));
         if(g_stressMaxVerifiedLimit > 0)
            PdfKV("Max Async Burst (Limits):", StringFormat("%d orders accepted in a single burst", g_stressMaxVerifiedLimit));
         if(g_safeAsyncBatchStop > 0)
            PdfKV("Safe Async Batch (Stops):", StringFormat("%d orders (90%% of measured max)", g_safeAsyncBatchStop));
         if(g_safeAsyncBatchLimit > 0)
            PdfKV("Safe Async Batch (Limits):", StringFormat("%d orders (90%% of measured max)", g_safeAsyncBatchLimit));
         if(g_bufferFlushCount > 0)
         {
            PdfKV("Buffer Flush Cost:", StringFormat("avg %.0fms | max %.0fms (sync place+delete round-trip)",
               g_bufferFlushAvgMs, g_bufferFlushMaxMs));
            PdfSpace(2);
            PdfBody(StringFormat("Recommended pattern for trading EAs: Place up to %d async orders per burst, "
               "then execute a sync place+delete of a throwaway order (~$1000 from price) to flush the broker's "
               "async processing pipeline (cost: ~%.0fms). This ensures the next async batch is not rate-limited.",
               MathMin(g_safeAsyncBatchStop, g_safeAsyncBatchLimit), g_bufferFlushAvgMs));
         }
      }
      PdfSpace(4);
   }

   // ===== DATA PROVENANCE & VERIFICATION PROTOCOL =====
   PdfCheckY(200);
   PdfSection("Data Provenance & Verification Protocol");
   PdfSpace(4);

   PdfSubSec("Data Source Attestation");
   PdfBody("All timestamps: DEAL_TIME_MSC - server-side millisecond timestamp generated by the broker's trade server.");
   PdfBody("All fill prices: DEAL_PRICE - actual execution price recorded by the broker's server.");
   PdfBody("Live prices: SymbolInfoTick() - broker's live bid/ask feed, read-only.");
   PdfBody("CS calibration: round-trip latency via pending order place+delete, averaged across 2 passes.");
   PdfBody("The EA has NO mechanism to alter, intercept, or fabricate any of these values.");
   PdfSpace(4);

   PdfSubSec("Why This Data Cannot Be Fabricated");
   PdfBody("1. DEAL_TIME_MSC is generated server-side by the broker, not the client terminal.");
   PdfBody("   The EA reads these values after the fact via read-only API calls.");
   PdfBody("2. MT5 deal history is immutable. No EA, script, or indicator can modify recorded deals.");
   PdfBody("3. Every measurement can be cross-validated against MT5's built-in deal history export");
   PdfBody("   (History tab > right-click > Export) by comparing DEAL_TIME_MSC timestamps.");
   PdfBody("4. The EA source code (.mq5) is open source and available for full inspection.");
   PdfBody("5. Multiple independent users running this EA on the same broker produce");
   PdfBody("   statistically consistent results - the profile is the broker's, not the tool's.");
   PdfSpace(4);

   PdfSubSec("Independent Verification Steps");
   PdfBody("1. Download the EA source from any of these repositories:");
   PdfBody("   - GitHub:      https://github.com/TraderJoe2026/ExecutionEdge");
   PdfBody("   - SourceForge: https://sourceforge.net/projects/executionedge/");
   PdfBody("2. Inspect the source code - verify it only uses standard MT5 API calls");
   PdfBody("3. Compile with MetaEditor (compiled .ex5 hash should match published hash)");
   PdfBody("4. Open a demo AND live account with the same broker");
   PdfBody("5. Run the EA on both accounts - compare the execution profiles");
   PdfBody("6. Run on a known A-book broker as a CONTROL GROUP - expect FAIR verdict");
   PdfBody("7. Cross-check the evidence CSV against MT5's built-in deal history export");
   PdfBody("8. Verify file integrity: SHA-256 hashes are recorded in the TOML data file");
   PdfSpace(4);

   PdfSubSec("File Integrity");
   PdfBody("SHA-256 hashes of all output files are recorded in the TOML data file ([integrity] section).");
   PdfBody("To verify no file has been tampered with, recompute the SHA-256 hash of each file");
   PdfBody("and compare against the recorded values.");
   PdfKV("TOML file:", g_tomlName);
   PdfSpace(4);

   PdfSubSec("Regulatory Standards Referenced");
   PdfBody("MiFID II RTS 27/28 (EU/ESMA) - Best execution reporting requirements");
   PdfBody("COBS 11.2 (FCA, UK) - Best execution obligations");
   PdfBody("COBS 4.2 (FCA, UK) - Fair, clear, not misleading communications");
   PdfBody("FAIS Act (FSCA, South Africa) - Fair treatment of clients");
   PdfBody("Corporations Act s912A (ASIC, Australia) - Efficient, honest, fair financial services");
   PdfBody("ASIC Product Intervention Order 2020/986 - CFD leverage limits, margin close-out, NBP");
   PdfBody("Article 24, MiFID II - Honest, fair, professional conduct");
   PdfSpace(8);

   // END OF REPORT: single line of 10pt bold, vertically centered between two HRs
   {
      PdfSpace(16);
      double eSz = 10;
      double eCapH = eSz * 0.72;
      double eDesc = eSz * 0.18;
      double eVisH = eCapH + eDesc;
      double ePad = 10;
      double eBlockH = eVisH + 2 * ePad;

      double eTopHR = g_pdfY - 4;
      g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f m %.1f %.1f l S\n",
         PDF_ML, eTopHR, PDF_ML + PDF_CW, eTopHR);

      double eBotHR = eTopHR - eBlockH;
      g_pdfCurStream += StringFormat("0.7 0.7 0.7 RG 0.5 w %.1f %.1f m %.1f %.1f l S\n",
         PDF_ML, eBotHR, PDF_ML + PDF_CW, eBotHR);

      double eBl = eTopHR - ePad - eCapH;
      string eText = "END OF REPORT";
      double eTw = StringLen(eText) * eSz * 0.52;
      double eX = PDF_ML + (PDF_CW - eTw) / 2;

      g_pdfCurStream += StringFormat("BT /F2 %.0f Tf 0.4 0.4 0.4 rg %.1f %.1f Td (%s) Tj ET\n",
         eSz, eX, eBl, PdfEsc(eText));

      g_pdfY = eBotHR - 4;
   }

   PdfFinishPage();
   PdfWriteFile(g_reportPdfName);
}


//+------------------------------------------------------------------+
//| GENERATE HTML REPORT                                               |
//+------------------------------------------------------------------+
void GenerateHTMLReport()
{
   int h = FileOpen(g_reportHtmName, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("ERROR: Cannot create HTML report: %s", g_reportHtmName);
      return;
   }

   // Recompute metrics (same as text report)
   double medStopLag  = 0, medLimitLag = 0, medCloseLag = 0, medMarketLag = 0;
   if(g_countByType[2] > 0 || g_countByType[3] > 0)
      medStopLag = (g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) /
                   MathMax(1, g_countByType[2] + g_countByType[3]);
   if(g_countByType[4] > 0 || g_countByType[5] > 0)
      medLimitLag = (g_medianLag[4] * g_countByType[4] + g_medianLag[5] * g_countByType[5]) /
                    MathMax(1, g_countByType[4] + g_countByType[5]);
   medCloseLag = g_medianLag[8];
   if(g_countByType[0] > 0 || g_countByType[1] > 0)
      medMarketLag = (g_medianLag[0] * g_countByType[0] + g_medianLag[1] * g_countByType[1]) /
                     MathMax(1, g_countByType[0] + g_countByType[1]);
   double stopLimitRatio = (medLimitLag > 0.001) ? medStopLag / medLimitLag :
                           (medStopLag > 0.001 && (g_countByType[4] > 0 || g_countByType[5] > 0)) ? 999.0 : 0;
   // tpslRatio (slippage) removed — lag is the manipulation signal, not slippage
   double medTPLag = g_medianLag[6];
   double medSLLag = g_medianLag[7];
   double tpslExecRatio = 0;
   if(medTPLag > 10 && medSLLag > 10)
      tpslExecRatio = medSLLag / medTPLag;
   else if(medSLLag > 10 && medTPLag <= 10 && g_countByType[6] > 0)
      tpslExecRatio = medSLLag;  // TP ~0ms, SL large = extreme asymmetry (show SL as ratio)

   // Trigger fill accuracy per category (for HTML report tables)
   int stopTrigTotal  = g_triggerFillCount[2] + g_triggerFillCount[3];
   int limitTrigTotal = g_triggerFillCount[4] + g_triggerFillCount[5];
   int stopClassified  = stopTrigTotal + g_marketFillCount[2] + g_marketFillCount[3];
   int limitClassified = limitTrigTotal + g_marketFillCount[4] + g_marketFillCount[5];
   int tpClassifiedH = g_triggerFillCount[6] + g_marketFillCount[6];
   int slClassifiedH = g_triggerFillCount[7] + g_marketFillCount[7];
   double stopTrigPct  = (stopClassified > 0)  ? (double)stopTrigTotal / stopClassified * 100.0 : -1;
   double limitTrigPct = (limitClassified > 0) ? (double)limitTrigTotal / limitClassified * 100.0 : -1;

   // Compute total damage consistently (same 5-component formula as PDF Section 5)
   double totalDamage = 0;
   double perLot = 0;
   if(g_batchClassification != "FAIR")
   {
      totalDamage = g_totalAdverseSlipUSD + MathAbs(g_totalFinancialDelta) + MathAbs(g_roundingErrorSum);
      if(g_countByType[2] > 0 && g_countByType[4] > 0)
      { double exL = medStopLag - medLimitLag; if(exL > 0) totalDamage += (exL / 1000.0) * 0.5 * g_totalLotsTraded * g_tickValue; }
      if(g_countByType[6] > 0 && g_countByType[7] > 0)
      { double exS = g_meanSlipAbs[7] - g_meanSlipAbs[6]; if(exS > 0) totalDamage += (exS / g_tickSize) * g_tickValue * g_lotSize * g_countByType[7]; }
      perLot = (g_totalLotsTraded > 0) ? totalDamage / g_totalLotsTraded : 0;
   }

   // Verdict
   // Drift-harmless checks: Stops fill at market by design — judge on lag, not trigger fill %.
   // For stops: harmless = lag is fast (below slow threshold). Trigger fill % is irrelevant.
   bool stopDriftHarmless = (medStopLag <= STD_FILL_SLOW_MS);
   bool closeDriftHarmless = false;
   if(g_driftLagCount[8] > 0)
      closeDriftHarmless = (g_driftLagSum[8] / g_driftLagCount[8] < 5.0);
   bool syncCloseDriftHarmless = false;
   if(g_driftLagCount[9] > 0)
      syncCloseDriftHarmless = (g_driftLagSum[9] / g_driftLagCount[9] < 5.0);

   int violations = 0;
   bool hasAsymmetry = false;  // True only when discriminatory execution detected
   // Only count lag as violation if drift shows adverse price impact
   if(!stopDriftHarmless) { if(medStopLag > STD_FILL_MANIP_MS) violations += 2; else if(medStopLag > STD_FILL_SLOW_MS) violations++; }
   if(!closeDriftHarmless) { if(g_asyncCloseMedianLag > STD_CLOSE_MANIP_MS) violations += 2; else if(g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS) violations++; }
   if(g_syncCloseCount > 0 && !syncCloseDriftHarmless) { if(g_syncCloseMedianLag > STD_SYNC_CLOSE_MANIP_MS) violations += 2; else if(g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS) violations++; }
   // Stop/limit and SL/TP ratios — asymmetric lag always benefits broker
   bool hasStructuralAsymmetry = (stopLimitRatio > 2.0) || (tpslExecRatio > 2.0);
   if(hasStructuralAsymmetry) violations++;  // Asymmetric lag is itself a violation
   // TP/SL: TP = limit-like (trigger fill % matters), SL = stop-like (lag only)
   {
      // TP: price guarantee — use trigger fill % as harmless check
      bool tpHarmless = false;
      int tpClassified = g_triggerFillCount[6] + g_marketFillCount[6];
      if(tpClassified > 0) tpHarmless = ((double)g_triggerFillCount[6] / tpClassified * 100.0 >= 90.0);
      else if(g_driftLagCount[6] > 0) tpHarmless = (g_driftLagSum[6] / g_driftLagCount[6] < 5.0);
      // SL: stop-like, fills at market — judge on lag only
      bool slHarmless = (medSLLag <= STD_TPSL_SLOW_MS);
      if(!(tpHarmless && slHarmless)) { if(medTPLag > STD_TPSL_MANIP_MS || medSLLag > STD_TPSL_MANIP_MS) violations += 2;
      else if(medTPLag > STD_TPSL_SLOW_MS || medSLLag > STD_TPSL_SLOW_MS) violations++; }
   }
   if(g_batchClassification == "MANIPULATION" && g_roundingErrorSum < -0.01 && g_roundingErrorCount > 5) { violations++; hasAsymmetry = true; }
   // Batch/cluster ratio: only count violations when their own analysis flags a problem
   // A "FAIR" classification means the batch/cluster ratio is normal for this broker's execution speed
   if(g_batchClassification != "FAIR")
   { if(g_batchRatio > 0.60) { violations += 2; } else if(g_batchRatio > 0.30) { violations++; } }
   // Clustering: only count as independent violation when asymmetry exists
   // Symmetric slow execution naturally produces clusters — not independently suspicious
   if(g_clusterVerdict != "FAIR" && hasAsymmetry)
   { if(g_clusterRatio * 100.0 > STD_CLUSTER_CAUTION_PCT) { violations += 2; } else if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT) { violations++; } }

   string verdict;
   string verdictColor;
   if(hasAsymmetry)
   {
      // Asymmetric execution = discriminatory treatment = potential B-book
      if(violations >= 6)      { verdict = "MULTIPLE A-BOOK STANDARDS BREACHED — AVOID THIS BROKER"; verdictColor = "#ff0000"; }
      else if(violations >= 4) { verdict = "A-BOOK STANDARDS BREACHED — LIKELY B-BOOK EXECUTION"; verdictColor = "#ff4400"; }
      else if(violations >= 2) { verdict = "SUSPICIOUS — ASYMMETRIC EXECUTION DETECTED"; verdictColor = "#ff8800"; }
      else                     { verdict = "FAIR EXECUTION — WITHIN A-BOOK STANDARDS";            verdictColor = "#00cc00"; }
   }
   else
   {
      // No asymmetry — cannot conclude B-book, only slow infrastructure
      // Clusters in this context are a natural result of symmetric slow execution
      if(violations >= 4)      { verdict = "SLOW EXECUTION — SIGNIFICANTLY EXCEEDS A-BOOK STANDARDS"; verdictColor = "#ff8800"; }
      else if(violations >= 1) { verdict = "SLOW EXECUTION — EXCEEDS SOME A-BOOK STANDARDS";          verdictColor = "#ccaa00"; }
      else                     { verdict = "FAIR EXECUTION — WITHIN A-BOOK STANDARDS";                 verdictColor = "#00cc00"; }
   }

   // HTML header
   FileWriteString(h, "<!DOCTYPE html><html><head><meta charset='utf-8'>\r\n");
   FileWriteString(h, "<title>Broker Forensic Analysis Report</title>\r\n");
   FileWriteString(h, "<style>\r\n");
   FileWriteString(h, "body{font-family:'Segoe UI',Arial,sans-serif;background:#1a1a2e;color:#e0e0e0;max-width:1000px;margin:0 auto;padding:20px;}\r\n");
   FileWriteString(h, "h1{color:#fff;text-align:center;border-bottom:3px solid #4a90d9;padding-bottom:15px;}\r\n");
   FileWriteString(h, "h2{color:#4a90d9;border-bottom:1px solid #333;padding-bottom:8px;margin-top:30px;}\r\n");
   FileWriteString(h, "h3{color:#7ab8f5;margin-top:20px;}\r\n");
   FileWriteString(h, "table{width:100%;border-collapse:collapse;margin:10px 0;}\r\n");
   FileWriteString(h, "th{background:#2a2a4a;color:#4a90d9;padding:8px;text-align:left;border:1px solid #333;}\r\n");
   FileWriteString(h, "td{padding:8px;border:1px solid #333;}\r\n");
   FileWriteString(h, "tr:nth-child(even){background:#1e1e3a;}\r\n");
   FileWriteString(h, ".pass{color:#00cc00;font-weight:bold;}\r\n");
   FileWriteString(h, ".warn{color:#ff8800;font-weight:bold;}\r\n");
   FileWriteString(h, ".fail{color:#ff0000;font-weight:bold;}\r\n");
   FileWriteString(h, ".verdict{font-size:24px;text-align:center;padding:20px;margin:20px 0;border:3px solid;border-radius:10px;}\r\n");
   FileWriteString(h, ".stat-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin:15px 0;}\r\n");
   FileWriteString(h, ".stat-box{background:#2a2a4a;padding:15px;border-radius:8px;text-align:center;}\r\n");
   FileWriteString(h, ".stat-box .value{font-size:28px;font-weight:bold;}\r\n");
   FileWriteString(h, ".stat-box .label{font-size:12px;color:#888;}\r\n");
   FileWriteString(h, ".section{background:#16213e;padding:15px;border-radius:8px;margin:10px 0;}\r\n");
   FileWriteString(h, "</style></head><body>\r\n");

   // Title
   FileWriteString(h, "<h1>BROKER EXECUTION FORENSIC ANALYSIS REPORT</h1>\r\n");
   FileWriteString(h, StringFormat("<p style='text-align:center;color:#888'>Generated: %s | Tool: BrokerForensicAnalyzer v%s | MT5 Build: %d</p>\r\n",
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), FA_VERSION, g_mt5Build));

   // Broker/Account info header
   FileWriteString(h, "<div class='stat-grid' style='grid-template-columns:1fr 1fr 1fr 1fr;gap:8px;margin:15px 0'>\r\n");
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Broker</div><div style='font-size:16px;font-weight:bold;color:#fff'>%s</div></div>\r\n", g_brokerName));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Server</div><div style='font-size:14px;color:#ccc'>%s</div></div>\r\n", g_serverName));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Account</div><div style='font-size:16px;color:#fff'>%d (%s)</div></div>\r\n", (int)g_accountNumber, g_accountCurrency));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Symbol</div><div style='font-size:16px;font-weight:bold;color:#4a90d9'>%s</div></div>\r\n", Symbol()));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Leverage</div><div style='font-size:14px;color:#ccc'>1:%d</div></div>\r\n", (int)g_accountLeverage));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Lot Size</div><div style='font-size:14px;color:#ccc'>%.2f</div></div>\r\n", g_lotSize));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>CS Latency</div><div style='font-size:14px;color:#ccc'>%d ms</div></div>\r\n", (int)g_clientServerLagMs));
   {
      int gmtOffH = (int)((TimeCurrent() - TimeGMT()) / 3600);
      string tzStrH = (gmtOffH >= 0) ? StringFormat("UTC+%d", gmtOffH) : StringFormat("UTC%d", gmtOffH);
      long totSecsH = (long)(g_collectionEndTime - g_collectionStartTime);
      int hrsH = (int)(totSecsH / 3600); int minsH = (int)((totSecsH % 3600) / 60); int secsH = (int)(totSecsH % 60);
      string durStrH;
      if(hrsH > 0) durStrH = StringFormat("%dh %dm %ds", hrsH, minsH, secsH);
      else if(minsH > 0) durStrH = StringFormat("%dm %ds", minsH, secsH);
      else durStrH = StringFormat("%ds", secsH);
      FileWriteString(h, StringFormat("<div class='stat-box'><div class='label'>Test Period (%s)</div><div style='font-size:12px;color:#ccc'>%s<br>to %s<br>Duration: %s</div></div>\r\n",
         tzStrH,
         TimeToString(g_collectionStartTime, TIME_DATE|TIME_SECONDS),
         TimeToString(g_collectionEndTime, TIME_DATE|TIME_SECONDS), durStrH));
   }
   FileWriteString(h, "</div>\r\n");

   // Verdict banner
   FileWriteString(h, StringFormat("<div class='verdict' style='color:%s;border-color:%s'>%s</div>\r\n",
      verdictColor, verdictColor, verdict));

   // Recommendation / VDP detection banner
   bool bannerAsym = (hasAsymmetry || hasStructuralAsymmetry || g_vdpLagRatio > 2.0);
   if(bannerAsym && g_vdpScore >= 50)
   {
      // Asymmetry + VDP detected: show VDP probability
      FileWriteString(h, "<div style='background:#2a0000;border:3px solid #ff0000;border-radius:8px;padding:15px;margin:10px 0;text-align:center'>\r\n");
      FileWriteString(h, StringFormat("<p style='color:#ff0000;font-size:16px;margin:0'>"
         "<b>VIRTUAL DEALER PLUGIN DETECTED: %.0f%% probability &mdash; %s</b></p>\r\n",
         g_vdpScore, g_vdpVerdict));
      FileWriteString(h, StringFormat("<p style='color:#ff4444;font-size:13px;margin:8px 0 0 0'>"
         "Broker-profitable orders delayed <b>%.0fx longer</b> than broker-costly orders. "
         "Execution pattern matches MetaTrader Virtual Dealer Plugin signatures. "
         "Asymmetric delay is never caused by market conditions &mdash; it is broker manipulation.</p>\r\n",
         g_vdpLagRatio));
      FileWriteString(h, "</div>\r\n");
   }
   else if(bannerAsym)
   {
      // Asymmetry without VDP: still broker manipulation, not market conditions
      FileWriteString(h, "<div style='background:#2a1a00;border:3px solid #ff4400;border-radius:8px;padding:15px;margin:10px 0;text-align:center'>\r\n");
      FileWriteString(h, StringFormat("<p style='color:#ff4400;font-size:16px;margin:0'>"
         "<b>ASYMMETRIC EXECUTION DETECTED (%.0fx)</b></p>\r\n", g_vdpLagRatio));
      FileWriteString(h, "<p style='color:#ff8800;font-size:13px;margin:8px 0 0 0'>"
         "Broker-profitable orders (stops, SL) are consistently delayed longer than broker-costly orders (limits, TP). "
         "Asymmetric delay between order types is never caused by market conditions or infrastructure &mdash; "
         "it requires deliberate per-order-type configuration. This is broker manipulation.</p>\r\n");
      if(g_vdpScore >= 25)
         FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:12px;margin:4px 0 0 0'>"
            "Virtual Dealer Plugin probability: %.0f%% &mdash; %s</p>\r\n", g_vdpScore, g_vdpVerdict));
      FileWriteString(h, "</div>\r\n");
   }
   else if(violations >= 4)
   {
      // High lag but symmetric: could be slow infrastructure
      FileWriteString(h, "<div style='background:#2a2a1a;border:2px solid #ccaa00;border-radius:8px;padding:15px;margin:10px 0;text-align:center'>\r\n");
      FileWriteString(h, "<p style='color:#ccaa00;font-size:14px;margin:0'><b>NOTE:</b> Some execution times exceed A-book standards, "
         "but no asymmetric treatment was detected between order types. "
         "This may indicate slow infrastructure. Re-test during peak hours for confirmation.</p>\r\n");
      FileWriteString(h, "<p style='color:#ccaa00;font-size:12px;margin:10px 0 0 0'><b>LAST-LOOK WARNING:</b> "
         "Symmetric high lag is itself a concern &mdash; even if all order types are delayed equally. "
         "A uniform 200ms+ processing time provides the broker (or its liquidity provider) a last-look window on every trade. "
         "In 2026, top A-book brokers execute in 10-50ms. If this broker consistently exceeds 100ms on all order types, "
         "the infrastructure itself enables undisclosed last-look regardless of symmetry. "
         "The absence of asymmetry does not prove the absence of manipulation &mdash; "
         "it may simply mean the broker applies last-look uniformly. <b>Last-look cannot be excluded.</b></p>\r\n");
      if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT)
         FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:13px;font-weight:bold;margin:10px 0 0 0'>"
            "&#9888; NOTE: %.0f%% of fills share the same price, timestamp, and direction (fill clusters). "
            "This clustering is a natural consequence of the slow symmetric execution &mdash; "
            "the broker&rsquo;s infrastructure processes orders in batches due to latency. "
            "No discriminatory treatment was detected between order types, so this does not indicate "
            "selective B-book internalization. However, the slow execution itself may affect fill quality.</p>\r\n",
            g_clusterRatio * 100));
      FileWriteString(h, "</div>\r\n");
   }
   else if(violations >= 1 && !hasAsymmetry)
   {
      FileWriteString(h, "<div style='background:#2a2a1a;border:2px solid #ccaa00;border-radius:8px;padding:15px;margin:10px 0;text-align:center'>\r\n");
      FileWriteString(h, "<p style='color:#ccaa00;font-size:14px;margin:0'><b>SLOW EXECUTION:</b> Some execution times exceed A-book standards. "
         "However, no asymmetric treatment was detected between order types &mdash; "
         "stops, limits, TP, and SL are all processed at similar speeds. "
         "This indicates slow broker infrastructure rather than discriminatory execution.</p>\r\n");
      FileWriteString(h, "<p style='color:#ccaa00;font-size:12px;margin:10px 0 0 0'>"
         "Top A-book brokers execute in 10-50ms in 2026. Slow symmetric execution still affects fill quality "
         "because market prices move during the delay, but it does not indicate B-book or selective manipulation.</p>\r\n");
      if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT)
         FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:13px;margin:10px 0 0 0'>"
            "&#9888; NOTE: %.0f%% of fills are clustered &mdash; a natural result of the slow symmetric execution. "
            "Orders batch together due to infrastructure latency, not selective broker behavior.</p>\r\n",
            g_clusterRatio * 100));
      FileWriteString(h, "</div>\r\n");
   }

   // --- Fiduciary Duty Breach Statement ---
   // Show for genuine red flags including asymmetric delay
   if(violations >= 4 && (hasAsymmetry || hasStructuralAsymmetry))
   {
      FileWriteString(h, "<div style='background:#2a0a0a;border:3px solid #ff0000;border-radius:8px;padding:20px;margin:15px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff0000;font-size:18px;font-weight:bold;margin:0 0 12px 0;text-align:center'>"
         "STATUTORY DUTY OF EXECUTION BREACHED</p>\r\n");
      FileWriteString(h, StringFormat("<p style='color:#ff4444;font-weight:bold;font-size:13px'>The execution data measured on broker "
         "<span style='color:#ffffff'>\"%s\"</span> (server: %s, account: %d) shows discriminatory execution "
         "including asymmetric delay between order types that benefits the broker.</p>\r\n",
         g_brokerName, g_serverName, (int)g_accountNumber));

      FileWriteString(h, "<ul style='color:#ff4444;font-weight:bold;font-size:12px;margin:4px 0 12px 0'>\r\n");
      if(medStopLag > STD_FILL_SLOW_MS || medSLLag > STD_TPSL_SLOW_MS)
      {
         FileWriteString(h, "<li>Excessive execution lag on stop-like orders with adverse price impact.</li>\r\n");
      }
      if(g_batchCount > 0 && g_batchClassification != "FAIR")
      {
         FileWriteString(h, StringFormat("<li>Price batching detected (%d batches, %.1f pts avg advantage).</li>\r\n",
            g_batchCount, g_avgBatchAdvantagePts));
      }
      if(g_roundingErrorSum < -0.01 && g_roundingErrorCount > 5)
      {
         FileWriteString(h, StringFormat("<li>Systematic rounding error favoring broker: %s.</li>\r\n",
            FormatMoney(MathAbs(g_roundingErrorSum))));
      }
      FileWriteString(h, "</ul>\r\n");
      FileWriteString(h, "</div>\r\n");
   }
   else if(hasStructuralAsymmetry)
   {
      FileWriteString(h, "<div style='background:#2a1a1a;border:2px solid #ff4400;border-radius:8px;padding:15px;margin:10px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;font-size:14px;margin:0'><b>ASYMMETRIC EXECUTION DETECTED:</b> "
         "Broker-profitable orders (stops, SL) are delayed significantly longer than broker-costly orders (limits, TP). "
         "This asymmetry benefits the broker regardless of fill price &mdash; delayed counter fills arriving after EA close operations "
         "create unwanted exposure against the trader.</p>\r\n");
      FileWriteString(h, "</div>\r\n");
   }

   // Summary stat boxes
   FileWriteString(h, "<div class='stat-grid'>\r\n");
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='value'>%d</div><div class='label'>Total Fills</div></div>\r\n", g_fillCount));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='value'>%d</div><div class='label'>Cycles</div></div>\r\n", g_cycleNum));
   FileWriteString(h, StringFormat("<div class='stat-box'><div class='value' style='color:%s'>%s</div><div class='label'>Total Damage</div></div>\r\n",
      (totalDamage > 1.0) ? "#ff4400" : "#00cc00", FormatMoney(totalDamage)));
   FileWriteString(h, "</div>\r\n");

   // Case Identification
   FileWriteString(h, "<h2>1. Case Identification</h2><div class='section'>\r\n");
   FileWriteString(h, StringFormat("<table><tr><td>Broker</td><td><b>%s</b></td><td>Server</td><td>%s</td></tr>\r\n", g_brokerName, g_serverName));
   FileWriteString(h, StringFormat("<tr><td>Account</td><td>%d</td><td>Currency</td><td>%s</td></tr>\r\n", (int)g_accountNumber, g_accountCurrency));
   FileWriteString(h, StringFormat("<tr><td>Symbol</td><td><b>%s</b></td><td>Lot Size</td><td>%.2f</td></tr>\r\n", Symbol(), g_lotSize));
   FileWriteString(h, StringFormat("<tr><td>Leverage</td><td>1:%d</td><td>Tick Value</td><td>%.4f</td></tr>\r\n", (int)g_accountLeverage, g_tickValue));

   // Measurement standard note — pip normalization explanation
   {
      double curAskH = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      FileWriteString(h, "<tr><td style='vertical-align:top'>Units</td><td colspan='3' style='font-size:12px'>"
         "<b>Note on Units:</b> This report uses <b>pips</b> (not points) for all distance measurements, ensuring "
         "equal comparison across brokers regardless of their decimal precision. "
         "For XAUUSD: 1 pip = $0.01. A 3-digit broker quotes an extra decimal place for precision, but 1 pip still "
         "equals $0.01 (= 10 of that broker's &ldquo;points&rdquo;). A 2-digit broker's points and pips are identical. "
         "All benchmarks and thresholds in this report are pip-based, so a broker quoting 2 decimals and one quoting "
         "3 decimals are held to the same real-world standard."
         "<table style='margin:8px 0; font-size:12px; border-collapse:collapse'>"
         "<tr style='border-bottom:1px solid #444'><td></td>"
         "<td style='padding:4px 12px'><b>2-digit broker</b></td>"
         "<td style='padding:4px 12px'><b>3-digit broker</b></td></tr>"
         "<tr><td style='padding:4px 12px; color:#aaa'>Quote example</td>"
         "<td style='padding:4px 12px'>3021.45</td>"
         "<td style='padding:4px 12px'>3021.453</td></tr>"
         "<tr><td style='padding:4px 12px; color:#aaa'>1 pip</td>"
         "<td style='padding:4px 12px'>$0.01 = 1 point</td>"
         "<td style='padding:4px 12px'>$0.01 = 10 points</td></tr>"
         "<tr><td style='padding:4px 12px; color:#aaa'>&ldquo;5 pip slippage&rdquo;</td>"
         "<td style='padding:4px 12px'>5 points</td>"
         "<td style='padding:4px 12px'>50 points</td></tr>"
         "</table>");
      FileWriteString(h, StringFormat("This broker: <b>%s at %d digits</b> (%s) &mdash; 1 pip = %s = %d broker point%s. "
         "Raw broker points shown in parentheses for reference.</td></tr>\r\n",
         g_baseSymbol, g_digits, DoubleToString(curAskH, g_digits),
         DoubleToString(g_pipSize, g_stdDigits),
         g_pipMult, (g_pipMult == 1) ? "" : "s"));
      // Account denomination note
      if(g_accountCurrency != "USD")
      {
         FileWriteString(h, StringFormat("<tr><td style='vertical-align:top'>Currency</td><td colspan='3' style='font-size:12px; color:#ffaa00'>"
            "<b>Account Denomination Note:</b> This account uses <b>%s</b>. All monetary values in this report are shown "
            "as reported by the trading platform and labeled as USD for standardized presentation. "
            "If your account uses a sub-denomination (e.g. USC = US cents, GBX = pence), apply "
            "the appropriate conversion factor to the dollar amounts shown (e.g. &divide; 100 for cent accounts)."
            "</td></tr>\r\n", g_accountCurrency));
      }
   }

   // Stops Level + Freeze Level with A-book benchmark
   // Tiers: 0-5 pips = ideal; 5-20 pips = A-book but caution; >20 pips = unusually restrictive
   {
      double stopsInPipsH = g_stopsLevel * g_point / g_pipSize;
      string stopsClrH, stopsNoteH;
      if(stopsInPipsH < 0.01)  // effectively 0
      { stopsClrH = "#00cc00"; stopsNoteH = "Ideal — no restriction (true ECN/A-book)"; }
      else if(stopsInPipsH <= 5.0)
      { stopsClrH = "#00cc00"; stopsNoteH = StringFormat("%.1f pips — ideal A-book ECN range (0-5 pips)", stopsInPipsH); }
      else if(stopsInPipsH <= 20.0)
      { stopsClrH = "#ffcc00"; stopsNoteH = StringFormat("%.1f pips — A-book compatible. Caution: SL/TP closer than %.1f pips to entry will be rejected", stopsInPipsH, stopsInPipsH); }
      else
      { stopsClrH = "#ff4444"; stopsNoteH = StringFormat("%.1f pips — unusually restrictive, exceeds typical A-book range (0-20 pips)", stopsInPipsH); }

      string freezeStr = "";
      if(g_freezeLevel > 0)
      {
         double freezePipsH = g_freezeLevel * g_point / g_pipSize;
         freezeStr = StringFormat(" | Freeze: <b>%.1f pips</b> (%d pts)", freezePipsH, g_freezeLevel);
      }
      FileWriteString(h, StringFormat("<tr><td>Stops Level</td><td><b style='color:%s'>%.1f pips</b> (%d pts)%s</td>"
         "<td colspan='2' style='font-size:12px;color:%s'>%s</td></tr>\r\n",
         stopsClrH, stopsInPipsH, g_stopsLevel, freezeStr, stopsClrH, stopsNoteH));
   }
   {
      int gmtOffHtm = (int)((TimeCurrent() - TimeGMT()) / 3600);
      string tzHtm = (gmtOffHtm >= 0) ? StringFormat("UTC+%d", gmtOffHtm) : StringFormat("UTC%d", gmtOffHtm);
      long totSecsHtm = (long)(g_collectionEndTime - g_collectionStartTime);
      int hH = (int)(totSecsHtm / 3600); int mH = (int)((totSecsHtm % 3600) / 60); int sH = (int)(totSecsHtm % 60);
      string durHtm;
      if(hH > 0) durHtm = StringFormat("%dh %dm %ds", hH, mH, sH);
      else if(mH > 0) durHtm = StringFormat("%dm %ds", mH, sH);
      else durHtm = StringFormat("%ds", sH);
      FileWriteString(h, StringFormat("<tr><td>Test Period</td><td colspan='3'>%s to %s (%s)</td></tr>\r\n",
         TimeToString(g_collectionStartTime, TIME_DATE | TIME_SECONDS),
         TimeToString(g_collectionEndTime, TIME_DATE | TIME_SECONDS), tzHtm));
      FileWriteString(h, StringFormat("<tr><td>Total Duration</td><td colspan='3'>%s</td></tr>\r\n", durHtm));
      int cltMinH = 60;
      string statH = (g_fillCount >= cltMinH)
         ? StringFormat("<span style='color:#00cc00'>SUFFICIENT</span> &mdash; %d deals evaluated (minimum %d required for CLT two-sample comparison)", g_fillCount, cltMinH)
         : StringFormat("<span style='color:#ff4400'>LIMITED</span> &mdash; %d deals evaluated (minimum %d required)", g_fillCount, cltMinH);
      FileWriteString(h, StringFormat("<tr><td>Statistical Validity</td><td colspan='3'>%s</td></tr>\r\n", statH));
   }
   FileWriteString(h, StringFormat("<tr><td>CS Latency</td><td>%d ms</td><td>Lots Traded</td><td>%.2f</td></tr>\r\n",
      (int)g_clientServerLagMs, g_totalLotsTraded));
   FileWriteString(h, StringFormat("<tr><td>Order Limit</td><td>%d</td><td>Max Observed</td><td>Pos:%d Pend:%d Tot:%d</td></tr>\r\n",
      (int)g_orderLimit, g_maxPositionsObserved, g_maxPendingObserved, g_maxTotalObserved));
   {
      string htmMarginMode = "Unknown";
      if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) htmMarginMode = "Retail Netting";
      else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) htmMarginMode = "Exchange";
      else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) htmMarginMode = "Retail Hedging";
      FileWriteString(h, StringFormat("<tr><td>Margin Mode</td><td>%s</td><td>Reported Leverage</td><td>1:%d</td></tr>\r\n",
         htmMarginMode, (int)g_accountLeverage));
      if(g_measuredMarginBuy > 0)
         FileWriteString(h, StringFormat("<tr><td>Margin (Buy only)</td><td>%.2f %s</td><td>Verified Lev (Buy)</td><td>1:%.0f</td></tr>\r\n",
            g_measuredMarginBuy, g_displayCurrency, g_verifiedLeverage));
      if(g_measuredMarginBoth > 0)
      {
         FileWriteString(h, StringFormat("<tr><td>Margin (Both open)</td><td>%.2f %s</td><td>Verified Lev (Both)</td><td>1:%.0f</td></tr>\r\n",
            g_measuredMarginBoth, g_displayCurrency, g_verifiedLeverageBoth));
         FileWriteString(h, StringFormat("<tr><td>Equity (Both open)</td><td>%.2f %s</td><td>Margin Ratio</td><td>%.2fx (%s)</td></tr>\r\n",
            g_measuredEquityBoth, g_displayCurrency,
            (g_measuredMarginBuy > 0) ? g_measuredMarginBoth / g_measuredMarginBuy : 0.0,
            (g_measuredMarginBuy > 0 && g_measuredMarginBoth / g_measuredMarginBuy < 1.5) ? "hedged/netted" : "additive"));
      }
      if(g_calculatedHedgingRatio >= 0)
      {
         string hrDesc = "unknown";
         if(g_calculatedHedgingRatio < 0.01) hrDesc = "NET";
         else if(g_calculatedHedgingRatio < 0.55) hrDesc = "larger-leg";
         else if(g_calculatedHedgingRatio < 0.85) hrDesc = "partial";
         else hrDesc = "GROSS";
         FileWriteString(h, StringFormat("<tr><td>Hedging Ratio</td><td>%.4f (%s)</td><td colspan='2'>Solver input: margin = gross &times; ratio</td></tr>\r\n",
            g_calculatedHedgingRatio, hrDesc));
      }
   }
   FileWriteString(h, "</table></div>\r\n");

   // Unified Execution Quality Table — all measurements in one place
   FileWriteString(h, "<h2>Broker Execution Audit</h2><div class='section'>\r\n");
   FileWriteString(h, StringFormat("<p style='color:#888;font-size:12px'>All times are net broker processing (client-server latency of %dms round-trip removed, "
      "calibrated via 2-pass sequence: pending order, market buy/sell, SL/TP placements, close buy/sell — all averaged across both passes). "
      "Measured via DEAL_TIME_MSC server timestamps.</p>\r\n", (int)g_clientServerRoundTripMs));
   FileWriteString(h, "<table><tr><th>Operation</th><th>Count</th><th>Fill Accuracy</th><th>Median Lag</th><th>Standard</th><th>Verdict</th></tr>\r\n");

   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] == 0) continue;

      int stdGood;
      if(t <= 1) stdGood = STD_MARKET_GOOD_MS;
      else if(t <= 5) stdGood = STD_FILL_GOOD_MS;
      else if(t <= 7) stdGood = STD_TPSL_GOOD_MS;
      else if(t == 9) stdGood = STD_SYNC_CLOSE_GOOD_MS;
      else stdGood = STD_CLOSE_GOOD_MS;

      double measured = g_medianLag[t];
      bool lagExceeded = (measured > stdGood);

      string countStr;
      if(g_lagValidCount[t] < g_countByType[t])
         countStr = StringFormat("%d (%d)", g_countByType[t], g_lagValidCount[t]);
      else
         countStr = StringFormat("%d", g_countByType[t]);

      string medStr = (g_lagValidCount[t] > 0) ? FormatMs(measured, true) : "N/A";

      // Fill accuracy and verdict per type
      string fillAccStr = "";
      string fillAccCss = "pass";
      string verdictStr = "";
      string verdictCss = "pass";

      // Server-side triggers (types 2-7) — respects structural asymmetry:
      //   STOPS (2,3) / SL (7): Fill at MARKET by design. Verdict on LAG, not trigger fill %.
      //   LIMITS (4,5) / TP (6): Price guarantee. Verdict on TRIGGER FILL %.
      //   Asymmetric lag: ALL broker-profitable types = FAIL regardless.
      int totalClassified = g_triggerFillCount[t] + g_marketFillCount[t];
      bool isBrokerProfitType = (t == 2 || t == 3 || t == 7); // BuyStop, SellStop, SL
      bool isStopLike = (t == 2 || t == 3 || t == 7); // Stops + SL fill at market by design
      bool asymOverride = (hasStructuralAsymmetry || g_vdpLagRatio > 2.0) && isBrokerProfitType;

      if(t >= 2 && t <= 7 && totalClassified > 0)
      {
         double triggerPct = (double)g_triggerFillCount[t] / totalClassified * 100.0;
         double marketPct = 100.0 - triggerPct;
         fillAccStr = StringFormat("%.0f%% trigger, %.0f%% market", triggerPct, marketPct);

         if(asymOverride)
         {
            // Asymmetric lag: fill accuracy is irrelevant for broker-profitable orders
            fillAccCss = "fail";
            verdictCss = "fail";
            verdictStr = StringFormat("FAIL &mdash; asymmetric lag %s [fill price irrelevant]", medStr);
         }
         else if(isStopLike)
         {
            // Stops/SL: market fills are EXPECTED (structural). Judge on lag only.
            // Show trigger/market ratio for information, but verdict is lag-based.
            if(!lagExceeded)
            {
               fillAccCss = "pass"; verdictCss = "pass";
               verdictStr = StringFormat("PASS &mdash; fast lag %s [market fill normal for %s]", medStr,
                  (t == 7) ? "SL" : "stops");
            }
            else
            {
               fillAccCss = "warn"; verdictCss = "fail";
               verdictStr = StringFormat("SLOW &mdash; %s lag [broker adds delay to worsen slippage]", medStr);
            }
         }
         else if(measured < 10.0)
         {
            // Limits/TP with <10ms lag: broker executes instantly.
            // Any "market fills" at this speed are price improvement or
            // micro-movement during the execution window — not manipulation.
            // You cannot manipulate a price in <10ms.
            fillAccCss = "pass";
            verdictCss = "pass";
            verdictStr = StringFormat("PASS &mdash; instant execution %s [%.0f%% trigger, %.0f%% price improved]",
               medStr, triggerPct, marketPct);
         }
         else if(triggerPct >= 90.0)
         {
            // Limits/TP: high trigger fill % = good (price guarantee honoured)
            fillAccCss = "pass";
            verdictCss = "pass";
            verdictStr = lagExceeded ? StringFormat("PASS &mdash; %.0f%% at trigger [lag %s]", triggerPct, medStr) :
                                       StringFormat("PASS &mdash; %.0f%% at trigger", triggerPct);
         }
         else if(triggerPct >= 70.0)
         {
            // Limits/TP: moderate trigger fill — only flag when lag is slow enough to matter
            fillAccCss = "warn";
            verdictCss = "warn";
            verdictStr = StringFormat("CAUTION &mdash; %.0f%% trigger [%s lag, price guarantee weak]", triggerPct, medStr);
         }
         else
         {
            // Limits/TP: low trigger fill with slow lag — price guarantee violated
            fillAccCss = "fail";
            verdictCss = "fail";
            verdictStr = StringFormat("FAIL &mdash; only %.0f%% trigger [%s lag, %s should fill at trigger or better]",
               triggerPct, medStr, (t == 6) ? "TP" : "limits");
         }
      }
      else if(t >= 2 && t <= 7)
      {
         // Server-side trigger but no classification data yet
         fillAccStr = "N/A";
         if(!lagExceeded) { verdictCss = "pass"; verdictStr = "PASS"; }
         else { verdictCss = "fail"; verdictStr = StringFormat("SLOW &mdash; %s (no fill data)", medStr); }
      }
      else
      {
         // Market orders (types 0-1) and close fills: drift-based quality
         double meanDriftLag = (g_driftLagCount[t] > 0) ? g_driftLagSum[t] / g_driftLagCount[t] : 0;
         if(g_driftLagCount[t] > 0)
         {
            if(meanDriftLag < 0.5)       { fillAccStr = "PERFECT (zero drift)";    fillAccCss = "pass"; }
            else if(meanDriftLag < 5.0)   { fillAccStr = StringFormat("GOOD (%.1fms drift)", meanDriftLag);  fillAccCss = "pass"; }
            else if(meanDriftLag < 50.0)  { fillAccStr = StringFormat("ACCEPTABLE (%.1fms drift)", meanDriftLag); fillAccCss = "pass"; }
            else                          { fillAccStr = StringFormat("POOR (%.1fms drift)", meanDriftLag);   fillAccCss = "fail"; }
         }
         else
            fillAccStr = "N/A";

         if(!lagExceeded)                              { verdictCss = "pass"; verdictStr = "PASS"; }
         else if(meanDriftLag < 5.0)                   { verdictCss = "pass"; verdictStr = StringFormat("SLOW &mdash; no adverse effect [%.1fms drift]", meanDriftLag); }
         else                                          { verdictCss = "fail"; verdictStr = StringFormat("FAIL &mdash; %s lag, %.1fms drift", medStr, meanDriftLag); }
      }

      FileWriteString(h, StringFormat("<tr><td>%s</td><td>%s</td><td class='%s'>%s</td><td>%s</td><td>&lt;%d ms</td><td class='%s'>%s</td></tr>\r\n",
         GetFillTypeName((ENUM_FILL_TYPE)t), countStr, fillAccCss, fillAccStr, medStr, stdGood, verdictCss, verdictStr));
   }

   // Sync baseline: market test close buy/sell (individual measurements, not aggregated)
   if(g_mktCloseBuySendMs > 0)
   {
      bool cbSlow = (g_mktSyncCloseBuyMs > STD_SYNC_CLOSE_GOOD_MS);
      string cbCss = (cbSlow && !syncCloseDriftHarmless) ? "fail" : "pass";
      string cbResult = !cbSlow ? "PASS" : (syncCloseDriftHarmless ? "SLOW &mdash; no adverse effect" : "FAIL");
      string cbAcc = syncCloseDriftHarmless ? "EA-initiated (no drift)" : "EA-initiated";
      FileWriteString(h, StringFormat("<tr><td>Close Buy <span style='color:%s'>(%s, PnL: %.2f)</span></td><td>1</td><td class='pass'>%s</td><td>%s</td><td>&lt;%d ms</td><td class='%s'>%s</td></tr>\r\n",
         g_mktCloseBuyInProfit ? "#ff4444" : "#44ff44", g_mktCloseBuyInProfit ? "PROFIT" : "LOSS",
         g_mktCloseBuyPnL, cbAcc, FormatMs(g_mktSyncCloseBuyMs), STD_SYNC_CLOSE_GOOD_MS, cbCss, cbResult));
   }
   if(g_mktCloseSellSendMs > 0)
   {
      bool csSlow = (g_mktSyncCloseSellMs > STD_SYNC_CLOSE_GOOD_MS);
      string csCss = (csSlow && !syncCloseDriftHarmless) ? "fail" : "pass";
      string csResult = !csSlow ? "PASS" : (syncCloseDriftHarmless ? "SLOW &mdash; no adverse effect" : "FAIL");
      string csAcc = syncCloseDriftHarmless ? "EA-initiated (no drift)" : "EA-initiated";
      FileWriteString(h, StringFormat("<tr><td>Close Sell <span style='color:%s'>(%s, PnL: %.2f)</span></td><td>1</td><td class='pass'>%s</td><td>%s</td><td>&lt;%d ms</td><td class='%s'>%s</td></tr>\r\n",
         g_mktCloseSellInProfit ? "#ff4444" : "#44ff44", g_mktCloseSellInProfit ? "PROFIT" : "LOSS",
         g_mktCloseSellPnL, csAcc, FormatMs(g_mktSyncCloseSellMs), STD_SYNC_CLOSE_GOOD_MS, csCss, csResult));
   }

   // Async open: EARLIEST_SETUP_MSC - send_epoch - CS_one_way = broker processing time
   {
      double htmlAsyncOpenMs = 0;
      if(g_gridEarliestSetupMsc > 0 && g_gridPlacedMs > 0)
      {
         long aoSendEpoch = (long)(g_epochMsOffset + g_gridPlacedMs);
         htmlAsyncOpenMs = (double)(g_gridEarliestSetupMsc - aoSendEpoch - (long)g_clientServerLagMs);
         if(htmlAsyncOpenMs < 0) htmlAsyncOpenMs = 0;
      }
      if(g_gridOrdersConfirmed > 0)
      {
         bool aoSlow = (htmlAsyncOpenMs > STD_FILL_GOOD_MS);
         // Grid open — stops fill at market by design; show trigger % as info, not diagnostic
         string aoAcc = (stopTrigPct >= 0) ? StringFormat("%.0f%% trigger (stops fill at market)", stopTrigPct) : "Async batch";
         string aoAccCss = "pass";  // Stop trigger fill % is not a quality indicator
         string aoResult = !aoSlow ? "PASS" : (stopDriftHarmless ? "SLOW &mdash; no adverse effect" : "FAIL");
         string aoResCss = (aoSlow && !stopDriftHarmless) ? "fail" : "pass";
         FileWriteString(h, StringFormat("<tr><td>Async Open (grid)</td><td>%d</td><td class='%s'>%s</td><td>%s</td><td>&lt;%d ms</td><td class='%s'>%s</td></tr>\r\n",
            g_gridOrdersConfirmed, aoAccCss, aoAcc, FormatMs(htmlAsyncOpenMs), STD_FILL_GOOD_MS, aoResCss, aoResult));
      }
   }

   // Async close: EARLIEST_CLOSE_MSC - send_epoch - CS_one_way = broker processing time
   {
      double htmlAsyncPosCloseMs = 0;
      if(g_posCloseEarliestMsc > 0 && g_posCloseSendMs > 0)
      {
         long acSendEpoch = (long)(g_epochMsOffset + g_posCloseSendMs);
         htmlAsyncPosCloseMs = (double)(g_posCloseEarliestMsc - acSendEpoch - (long)g_clientServerLagMs);
         if(htmlAsyncPosCloseMs < 0) htmlAsyncPosCloseMs = 0;
      }
      if(g_asyncCloseCount > 0 || g_posCloseFirstFillBootMs > 0)
      {
         int totalCloses = g_asyncCloseCount + g_syncCloseCount;
         bool acSlow = (htmlAsyncPosCloseMs > STD_CLOSE_GOOD_MS);
         string acCss = (acSlow && !closeDriftHarmless) ? "fail" : "pass";
         string acResult = !acSlow ? "PASS" : (closeDriftHarmless ? "SLOW &mdash; no adverse effect" : "FAIL");
         string acAcc = closeDriftHarmless ? "EA-initiated (no drift)" : "EA-initiated";
         FileWriteString(h, StringFormat("<tr><td>Async Close (batch)</td><td>%d</td><td class='pass'>%s</td><td>%s</td><td>&lt;%d ms</td><td class='%s'>%s</td></tr>\r\n",
            totalCloses, acAcc, FormatMs(htmlAsyncPosCloseMs), STD_CLOSE_GOOD_MS, acCss, acResult));
      }
   }

   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #333;border-radius:6px;padding:10px;margin:10px 0;font-size:12px'>\r\n");
   FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 5px 0'><b>How to read this table</b></p>\r\n");
   FileWriteString(h, "<p style='color:#aaa;margin:0'>"
      "<b>Structural asymmetry:</b> MT5 execution treats order types differently. "
      "<b>Stops/SL</b> trigger a market order &mdash; they fill at whatever price exists after the trigger. "
      "Low trigger fill % on stops is <u>expected physics</u>, not broker manipulation. "
      "<b>Limits/TP</b> have a price guarantee &mdash; they should fill at the trigger price or better. "
      "Low trigger fill % on limits/TP IS the broker's fault. "
      "<b>Verdicts reflect this:</b> Stops/SL are judged on <b>lag speed</b> (is the broker adding delay to worsen natural slippage?). "
      "Limits/TP are judged on <b>trigger fill %</b> (is the price guarantee being honoured?). "
      "<b>Trigger fill</b> = filled at trigger price. <b>Market fill</b> = filled at prevailing market. "
      "<b>Thresholds for limits/TP</b>: &gt;90% trigger = PASS, 70-90% = CAUTION, &lt;70% = FAIL. "
      "<b>When asymmetric lag is detected</b> (&gt;2x ratio): ALL broker-profitable order types are FAIL &mdash; "
      "the broker is adding delay on top of the structural asymmetry to extract extra slippage.</p>\r\n");
   FileWriteString(h, "</div>\r\n");
   FileWriteString(h, "</div>\r\n");

   // Asymmetry Detection — B-book signals
   FileWriteString(h, "<h2>Asymmetry Detection</h2><div class='section'>\r\n");
   FileWriteString(h, "<p style='color:#888;font-size:12px'>Comparing execution time (lag) by order type. "
      "<b>Note:</b> Stops and SL structurally fill at market (not trigger price) &mdash; this is how MT5 works, not broker manipulation. "
      "The forensic question is whether the broker adds <b>extra delay</b> on broker-profitable orders (stops, SL) vs broker-costly orders (limits, TP). "
      "A lag ratio &gt;2x means the broker is exploiting the structural asymmetry by adding delay to worsen stop/SL slippage. "
      "Trigger fill % is shown for context but is only diagnostic for limits/TP (which have price guarantees).</p>\r\n");
   FileWriteString(h, "<table><tr><th>Comparison</th><th>Trader Side</th><th>Broker Side</th><th>Fill Accuracy</th><th>Lag Ratio</th><th>Result</th></tr>\r\n");

   // Stop vs Limit — LAG RATIO is the diagnostic (not trigger fill %).
   // Stops fill at market by design (structural asymmetry in MT5 execution model).
   // Comparing trigger fill % between stops and limits is comparing apples to oranges.
   // The forensic question: does the broker add EXTRA delay on stops to worsen the structural slippage?
   string slFillClass = "pass";
   string slFillResult = "FAIR";
   double stopAccH = (stopClassified > 0) ? (double)stopTrigTotal / stopClassified * 100.0 : -1;
   double limAccH = (limitClassified > 0) ? (double)limitTrigTotal / limitClassified * 100.0 : -1;
   if(stopLimitRatio > 2.0)
   {
      slFillClass = "fail";
      slFillResult = StringFormat("ASYMMETRIC &mdash; stops delayed %.1f&times; longer", stopLimitRatio);
   }
   else if(stopLimitRatio > 1.5)
   {
      slFillClass = "warn";
      slFillResult = StringFormat("NOTABLE &mdash; stops %.1f&times; slower", stopLimitRatio);
   }
   else
   {
      slFillClass = "pass";
      slFillResult = "FAIR &mdash; symmetric lag";
   }
   // Show trigger fill % as informational context (not diagnostic for stops)
   string stopAccStr = (stopAccH >= 0) ? StringFormat("%.0f%% trigger [%s]", stopAccH, FormatMs(medStopLag)) : FormatMs(medStopLag);
   string limAccStr = (limAccH >= 0) ? StringFormat("%.0f%% trigger [%s]", limAccH, FormatMs(medLimitLag)) : FormatMs(medLimitLag);
   string slFillStr = (stopAccH >= 0 && limAccH >= 0)
      ? StringFormat("%.0f%% vs %.0f%% (structural)", stopAccH, limAccH) : "&mdash;";
   FileWriteString(h, StringFormat("<tr><td>Stop vs Limit</td><td>Stop: %s</td><td>Limit: %s</td><td>%s</td><td>%.1f&times;</td><td class='%s'>%s</td></tr>\r\n",
      stopAccStr, limAccStr, slFillStr, stopLimitRatio, slFillClass, slFillResult));

   // SL vs TP — LAG RATIO is the diagnostic (same structural asymmetry as stops).
   // SL = stop-like (fills at market), TP = limit-like (price guarantee).
   // The forensic question: does the broker add extra delay on SL to worsen slippage?
   if(g_countByType[6] > 0 && g_countByType[7] > 0)
   {
      double slAccH = (slClassifiedH > 0) ? (double)g_triggerFillCount[7] / slClassifiedH * 100.0 : -1;
      double tpAccH = (tpClassifiedH > 0) ? (double)g_triggerFillCount[6] / tpClassifiedH * 100.0 : -1;
      string tpslFillClass = "pass";
      string tpslFillResult = "FAIR";
      if(tpslExecRatio > 2.0)
      {
         tpslFillClass = "fail";
         tpslFillResult = StringFormat("ASYMMETRIC &mdash; SL delayed %.1f&times; longer", tpslExecRatio);
      }
      else if(tpslExecRatio > 1.5)
      {
         tpslFillClass = "warn";
         tpslFillResult = StringFormat("NOTABLE &mdash; SL %.1f&times; slower", tpslExecRatio);
      }
      else
      {
         tpslFillClass = "pass";
         tpslFillResult = "FAIR &mdash; symmetric lag";
      }
      // Show trigger fill % as informational context (not diagnostic for SL)
      string slAccStr = (slAccH >= 0) ? StringFormat("%.0f%% trigger [%s] (n=%d)", slAccH, FormatMs(medSLLag), g_countByType[7]) :
                                         StringFormat("%s (n=%d)", FormatMs(medSLLag), g_countByType[7]);
      string tpAccStr = (tpAccH >= 0) ? StringFormat("%.0f%% trigger [%s] (n=%d)", tpAccH, FormatMs(medTPLag), g_countByType[6]) :
                                         StringFormat("%s (n=%d)", FormatMs(medTPLag), g_countByType[6]);
      string tpslFillStr = (slAccH >= 0 && tpAccH >= 0) ? StringFormat("%.0f%% vs %.0f%% (structural)", slAccH, tpAccH) : "&mdash;";
      FileWriteString(h, StringFormat("<tr><td>SL vs TP</td><td>SL: %s</td><td>TP: %s</td><td>%s</td><td>%.1f&times;</td><td class='%s'>%s</td></tr>\r\n",
         slAccStr, tpAccStr, tpslFillStr, tpslExecRatio, tpslFillClass, tpslFillResult));
   }

   // Fill clustering — same price + timestamp + direction = broker internalization
   string tcClass = (g_clusterRatio * 100 > STD_CLUSTER_CAUTION_PCT) ? "fail" : (g_clusterRatio * 100 > STD_CLUSTER_FAIR_PCT) ? "warn" : "pass";
   FileWriteString(h, StringFormat("<tr><td>Fill Clustering</td><td colspan='2'>%.0f%% clustered (%d clusters, avg %.1f fills) &mdash; "
      "same price/timestamp/direction fills indicate batch processing</td><td>&mdash;</td><td>&mdash;</td><td class='%s'>%s</td></tr>\r\n",
      g_clusterRatio * 100, g_clusterCount, g_avgClusterSize, tcClass,
      (g_clusterRatio * 100 > STD_CLUSTER_CAUTION_PCT) ? "FAIL" : (g_clusterRatio * 100 > STD_CLUSTER_FAIR_PCT) ? "CAUTION" : "FAIR"));

   // Overall classification
   string bClass = (g_batchClassification == "MANIPULATION") ? "fail" :
                   (g_batchClassification == "CAUTION") ? "warn" : "pass";
   double fairPctHtml = (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0;
   double sFairPctH = (g_totalStopPriced > 0) ? (double)g_fairFillsStop / g_totalStopPriced * 100 : 0;
   double lFairPctH = (g_totalLimitPriced > 0) ? (double)g_fairFillsLimit / g_totalLimitPriced * 100 : 0;
   FileWriteString(h, StringFormat("<tr><td>Overall Fill Accuracy</td>"
      "<td>Stop: %d/%d (%.0f%%)</td><td>Limit: %d/%d (%.0f%%)</td>"
      "<td>%.0f%% overall</td><td>&mdash;</td><td class='%s'>%s</td></tr>\r\n",
      g_fairFillsStop, g_totalStopPriced, sFairPctH,
      g_fairFillsLimit, g_totalLimitPriced, lFairPctH,
      fairPctHtml, bClass, g_batchClassification));

   // Order Rejection Symmetry — always present in comparison table
   {
      // Exclude stress test rejections
      int gridStopRej = 0, gridLimitRej = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         if(StringFind(g_rejections[r].orderType, "Stop") >= 0)  gridStopRej++;
         if(StringFind(g_rejections[r].orderType, "Limit") >= 0) gridLimitRej++;
      }

      double rejRatio = 0;
      string rejResult, rejClass;
      if(gridStopRej == 0 && gridLimitRej == 0)
      {
         rejResult = "FAIR";
         rejClass = "pass";
      }
      else if(gridLimitRej > 0 && gridStopRej > 0)
      {
         rejRatio = (double)gridStopRej / gridLimitRej;
         if(rejRatio > 3.0)       { rejResult = "FAIL"; rejClass = "fail"; }
         else if(rejRatio > 2.0)  { rejResult = "SUSPICIOUS"; rejClass = "warn"; }
         else                     { rejResult = "FAIR"; rejClass = "pass"; }
      }
      else if(gridStopRej > 0 && gridLimitRej == 0)
      {
         rejRatio = (double)gridStopRej;  // Only stops rejected
         rejResult = (gridStopRej >= 3) ? "FAIL" : "SUSPICIOUS";
         rejClass = (gridStopRej >= 3) ? "fail" : "warn";
      }
      else
      {
         // Only limits rejected — unusual but not broker-adverse manipulation
         rejRatio = 0;
         rejResult = "FAIR";
         rejClass = "pass";
      }

      string stopRejStr = (gridStopRej > 0) ? StringFormat("Your stops: %d rejected", gridStopRej) : "Your stops: 0 rejected";
      string limRejStr = (gridLimitRej > 0) ? StringFormat("Broker limits: %d rejected", gridLimitRej) : "Broker limits: 0 rejected";
      string ratioStr = (gridStopRej == 0 && gridLimitRej == 0) ? "—"
                       : (gridLimitRej > 0) ? StringFormat("%.1f&times;", rejRatio)
                       : StringFormat("%d:0", gridStopRej);

      FileWriteString(h, StringFormat("<tr><td>Order Rejections</td>"
         "<td>%s</td><td>%s</td><td>%s</td><td>&lt;1.5&times;</td>"
         "<td class='%s'>%s</td></tr>\r\n",
         stopRejStr, limRejStr, ratioStr, rejClass, rejResult));

      if(g_rejStopManipulation > 0)
         FileWriteString(h, StringFormat("<tr><td></td><td colspan='4' style='color:#ff8800;font-size:12px'>"
            "Of %d stop rejections, %d classified as manipulation (price well away / asymmetric delay / asymmetric requote)</td>"
            "<td></td></tr>\r\n", gridStopRej, g_rejStopManipulation));
   }

   FileWriteString(h, "</table></div>\r\n");

   // --- ASYMMETRY BAR: Trader Benefit vs Broker Benefit Execution Time ---
   // (Placed before financial damage so the observer sees manipulation evidence first)
   {
      // Average lags: adverse (stops+SL) vs favorable (limits+TP)
      double sumAdverse = 0; int nAdverse = 0;
      double sumFavor = 0;   int nFavor = 0;
      // Stops: types 2,3  SL: type 7
      if(g_countByType[2] > 0) { sumAdverse += g_medianLag[2]; nAdverse++; }
      if(g_countByType[3] > 0) { sumAdverse += g_medianLag[3]; nAdverse++; }
      if(g_countByType[7] > 0) { sumAdverse += g_medianLag[7]; nAdverse++; }
      // Limits: types 4,5  TP: type 6
      if(g_countByType[4] > 0) { sumFavor += g_medianLag[4]; nFavor++; }
      if(g_countByType[5] > 0) { sumFavor += g_medianLag[5]; nFavor++; }
      if(g_countByType[6] > 0) { sumFavor += g_medianLag[6]; nFavor++; }

      if(nAdverse > 0 && nFavor > 0)
      {
         double avgAdverse = sumAdverse / nAdverse;
         double avgFavor   = sumFavor / nFavor;
         double totalLag   = avgAdverse + avgFavor;
         if(totalLag < 1) totalLag = 1;
         double ratio = (avgFavor > 0.5) ? avgAdverse / avgFavor : avgAdverse;
         string verdictTxt = (ratio > 3.0) ? "ASYMMETRIC" : (ratio > 2.0) ? "ASYMMETRIC" : "FAIR";
         string verdictClr = (ratio > 3.0) ? "#ff4444" : (ratio > 2.0) ? "#ff4444" : "#00cc00";

         // --- HEADER ---
         FileWriteString(h, "<h3 style='color:#ff8800;text-align:center;font-size:18px;margin:20px 0 5px 0'>"
            "Execution Time by Order Type</h3>\r\n");
         FileWriteString(h, "<div style='margin:15px 0;padding:16px;background:#1a1a2a;border-radius:8px'>\r\n");

         // --- FAIR vs ACTUAL comparison ---
         FileWriteString(h, "<div style='margin-bottom:16px'>\r\n");
         // FAIR bar
         FileWriteString(h, "<div style='margin-bottom:4px;font-size:11px;color:#888;font-weight:bold'>FAIR EXECUTION (equal processing time):</div>\r\n");
         FileWriteString(h, "<div style='display:flex;align-items:center;width:100%;margin-bottom:12px'>"
            "<div style='background:#2a5a2a;height:24px;flex:0.5;border-radius:4px 0 0 4px;display:flex;align-items:center;justify-content:center;font-size:11px;color:#88cc88;border:1px solid #338833'>Your orders</div>"
            "<div style='background:#2a5a2a;height:24px;flex:0.5;border-radius:0 4px 4px 0;display:flex;align-items:center;justify-content:center;font-size:11px;color:#88cc88;border:1px solid #338833;border-left:none'>Broker orders</div>"
            "</div>\r\n");
         // ACTUAL bar
         FileWriteString(h, "<div style='margin-bottom:4px;font-size:11px;color:#ff4444;font-weight:bold'>YOUR BROKER (measured):</div>\r\n");
         FileWriteString(h, "<div style='display:flex;justify-content:space-between;margin-bottom:4px;font-size:11px'>"
            "<span style='color:#ff4444;font-weight:bold'>Your Execution Time (Stops/SL)</span>"
            "<span style='color:#4488ff;font-weight:bold;text-align:right'>Broker's Execution Time (Limits/TP)</span></div>\r\n");
         // Use rounded display values for flex so equal display = equal bar widths
         double dispAdverse = MathRound(avgAdverse);
         double dispFavor   = MathRound(avgFavor);
         double dispTotal   = dispAdverse + dispFavor;
         if(dispTotal < 1) dispTotal = 1;
         double flexAdverse = dispAdverse / dispTotal;
         double flexFavor   = dispFavor / dispTotal;
         // Ensure minimum visible width
         if(flexAdverse < 0.15) { flexAdverse = 0.15; flexFavor = 0.85; }
         if(flexFavor   < 0.15) { flexFavor   = 0.15; flexAdverse = 0.85; }
         FileWriteString(h, StringFormat(
            "<div style='display:flex;align-items:center;width:100%%'>"
            "<div style='background:#dd2200;height:34px;flex:%.4f;border-radius:4px 0 0 4px;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:bold;color:white;min-width:60px'>%s</div>"
            "<div style='background:#2266dd;height:34px;flex:%.4f;border-radius:0 4px 4px 0;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:bold;color:white;min-width:60px'>%s</div>"
            "</div>\r\n",
            flexAdverse, FormatMs(avgAdverse), flexFavor, FormatMs(avgFavor)));
         FileWriteString(h, "</div>\r\n");

         // --- VERDICT ---
         if(ratio <= 1.2)
            FileWriteString(h, StringFormat(
               "<div style='text-align:center;margin:10px 0;font-size:15px;font-weight:bold;color:%s'>"
               "Equal execution &mdash; FAIR</div>\r\n", verdictClr));
         else
            FileWriteString(h, StringFormat(
               "<div style='text-align:center;margin:10px 0;font-size:15px;font-weight:bold;color:%s'>"
               "Stops took <span style='font-size:20px'>%.0f&times;</span> longer than limits &mdash; %s</div>\r\n",
               verdictClr, ratio, verdictTxt));

         // --- WAFFLE CHART — visual ratio ---
         if(ratio > 2.0)
         {
            int waffleTotal = (int)MathMin(ratio + 1, 300);  // Cap at 300 squares
            int waffleBlue = 1;  // Broker gets 1 unit
            int waffleRed = waffleTotal - waffleBlue;

            FileWriteString(h, "<div style='margin:12px 0;padding:10px;background:#111;border-radius:6px'>\r\n");
            FileWriteString(h, "<div style='text-align:center;font-size:12px;color:#aaa;margin-bottom:8px'>"
               "Each square = 1 unit of execution time. <b style='color:#ff4444'>Red</b> = stop-like orders. "
               "<b style='color:#4488ff'>Blue</b> = limit-like orders.</div>\r\n");
            FileWriteString(h, "<div style='display:flex;flex-wrap:wrap;gap:2px;justify-content:center'>\r\n");
            // Blue square first (broker's instant execution)
            FileWriteString(h, "<div style='width:10px;height:10px;background:#4488ff;border-radius:1px' title='Broker: 1 unit'></div>\r\n");
            // Red squares (your wait)
            for(int w = 0; w < waffleRed; w++)
               FileWriteString(h, "<div style='width:10px;height:10px;background:#dd2200;border-radius:1px'></div>\r\n");
            FileWriteString(h, "</div>\r\n");
            FileWriteString(h, StringFormat("<div style='text-align:center;font-size:11px;color:#888;margin-top:6px'>"
               "%.0f red squares for every 1 blue square &mdash; asymmetric delay benefitting the broker</div>\r\n", ratio));
            FileWriteString(h, "</div>\r\n");
         }

         // --- EXPLANATION ---
         if(ratio > 1.5)
         {
            FileWriteString(h, "<div style='margin-top:12px;padding:12px;background:#2a1a1a;border-left:3px solid #ff4444;font-size:12px;color:#ccc'>\r\n");
            FileWriteString(h, "<b>Why this matters:</b> Broker-profitable orders (stops, SL) are delayed significantly longer "
               "than broker-costly orders (limits, TP). ");
            FileWriteString(h, StringFormat("Here, stop-like orders execute in <b>%.0fms</b>, "
               "while limit-like orders execute in <b>%.0fms</b> &mdash; a <b>%.0f&times; difference</b>. ", avgAdverse, avgFavor, ratio));
            FileWriteString(h, "This asymmetry benefits the broker regardless of fill price. "
               "Counter orders held with this delay can fill <b>after</b> an EA has already closed positions on a retracement, "
               "creating unwanted new exposure against the trader. The fill price is irrelevant &mdash; "
               "the timing of arrival is what causes the damage.</div>\r\n");
         }

         FileWriteString(h, "</div>\r\n\r\n");
      }
   }

   // ===== PER-ORDER-TYPE EXECUTION LAG TABLE =====
   FileWriteString(h, "<h3>Execution Lag by Order Type &mdash; Full Breakdown</h3>\r\n");
   FileWriteString(h, "<p style='color:#888;font-size:12px'>Each pending order type measured separately. "
      "Buy/Sell stops and Buy/Sell limits should execute at similar speeds if the broker is fair.</p>\r\n");
   FileWriteString(h, "<table style='width:100%'>\r\n");
   FileWriteString(h, "<tr><th style='width:18%'>Order Type</th><th style='width:10%'>Count</th>"
      "<th style='width:14%'>Median Lag</th><th style='width:14%'>Mean Lag</th>"
      "<th style='width:10%'>Min</th><th style='width:10%'>Max</th>"
      "<th style='width:12%'>Standard</th><th style='width:12%'>Status</th></tr>\r\n");
   {
      int typeOrder[] = {2, 3, 4, 5, 6, 7, 0, 1, 8, 9};
      for(int ti = 0; ti < 10; ti++)
      {
         int t = typeOrder[ti];
         if(g_countByType[t] == 0) continue;
         int std2;
         if(t <= 1) std2 = STD_MARKET_GOOD_MS;
         else if(t <= 5) std2 = STD_FILL_GOOD_MS;
         else if(t <= 7) std2 = STD_TPSL_GOOD_MS;
         else if(t == 9) std2 = STD_SYNC_CLOSE_GOOD_MS;
         else std2 = STD_CLOSE_GOOD_MS;
         string status, clr;
         if(g_medianLag[t] <= (double)std2)
         { status = "PASS"; clr = "#00cc00"; }
         else if(g_medianLag[t] <= (double)std2 * 2.0)
         { status = "SLOW"; clr = "#ff8800"; }
         else
         { status = "FAIL"; clr = "#ff4444"; }
         FileWriteString(h, StringFormat("<tr><td><b>%s</b></td><td>%d</td>"
            "<td>%s</td><td>%s</td><td>%s</td><td>%s</td>"
            "<td>%dms</td><td style='color:%s;font-weight:bold'>%s</td></tr>\r\n",
            GetFillTypeName((ENUM_FILL_TYPE)t), g_countByType[t],
            FormatMs(g_medianLag[t]), FormatMs(g_meanLag[t]),
            FormatMs(g_minLag[t]), FormatMs(g_maxLag[t]),
            std2, clr, status));
      }
   }
   FileWriteString(h, "</table>\r\n\r\n");

   // ===== TP/SL MARKET TRIGGER ANALYSIS =====
   if(g_tpslTotalTriggers > 0)
   {
      FileWriteString(h, "<h3>TP/SL Market Trigger Analysis</h3>\r\n");
      FileWriteString(h, "<p style='color:#888;font-size:12px'>When your Take-Profit or Stop-Loss triggers at market, "
         "which direction does the fill go? A fair broker should show symmetric slippage on both.</p>\r\n");
      FileWriteString(h, "<div style='display:flex;gap:20px;margin:15px 0'>\r\n");
      // Favor box (TP)
      FileWriteString(h, StringFormat(
         "<div style='flex:1;background:#0a2a0a;border:2px solid #00cc00;border-radius:8px;padding:15px;text-align:center'>"
         "<div style='font-size:28px;color:#00cc00;font-weight:bold'>%.0f%%</div>"
         "<div style='color:#00cc00;font-size:14px'>Favorable (TP)</div>"
         "<div style='color:#888;font-size:12px;margin-top:5px'>%d of %d triggers</div>"
         "</div>\r\n", g_tpslFavorPct, g_tpslFavorTriggers, g_tpslTotalTriggers));
      // Adverse box (SL)
      FileWriteString(h, StringFormat(
         "<div style='flex:1;background:#2a0a0a;border:2px solid #ff4444;border-radius:8px;padding:15px;text-align:center'>"
         "<div style='font-size:28px;color:#ff4444;font-weight:bold'>%.0f%%</div>"
         "<div style='color:#ff4444;font-size:14px'>Adverse (SL)</div>"
         "<div style='color:#888;font-size:12px;margin-top:5px'>%d of %d triggers</div>"
         "</div>\r\n", g_tpslAdversePct, g_tpslAdverseTriggers, g_tpslTotalTriggers));
      FileWriteString(h, "</div>\r\n");

      // Slippage direction table
      FileWriteString(h, "<table style='width:100%'>\r\n");
      FileWriteString(h, "<tr><th>Slippage Direction</th><th>Count</th><th>% of Triggers</th><th>Assessment</th></tr>\r\n");
      int totalSlipped = g_tpslFavorSlip + g_tpslAdverseSlip + g_tpslNeutralSlip;
      if(totalSlipped > 0)
      {
         double favSlipPct = 100.0 * g_tpslFavorSlip / totalSlipped;
         double advSlipPct = 100.0 * g_tpslAdverseSlip / totalSlipped;
         double neuSlipPct = 100.0 * g_tpslNeutralSlip / totalSlipped;
         FileWriteString(h, StringFormat("<tr><td>Price Improvement (your favor)</td><td>%d</td>"
            "<td>%.0f%%</td><td style='color:#00cc00'>Good</td></tr>\r\n",
            g_tpslFavorSlip, favSlipPct));
         FileWriteString(h, StringFormat("<tr><td>Adverse Slippage (against you)</td><td>%d</td>"
            "<td>%.0f%%</td><td style='color:%s'>%s</td></tr>\r\n",
            g_tpslAdverseSlip, advSlipPct,
            (advSlipPct > favSlipPct * STD_SLIPPAGE_ASYM_MAX) ? "#ff4444" : "#00cc00",
            (advSlipPct > favSlipPct * STD_SLIPPAGE_ASYM_MAX) ? "Asymmetric" : "Normal"));
         FileWriteString(h, StringFormat("<tr><td>At Trigger Price (no slippage)</td><td>%d</td>"
            "<td>%.0f%%</td><td style='color:#00cc00'>Fair</td></tr>\r\n",
            g_tpslNeutralSlip, neuSlipPct));
      }
      FileWriteString(h, "</table>\r\n");

      // Asymmetry warning
      if(g_tpslSlipAsymRatio > STD_SLIPPAGE_ASYM_MAX)
      {
         FileWriteString(h, StringFormat("<div style='background:#2a1a1a;border:2px solid #ff4444;border-radius:8px;"
            "padding:12px;margin:10px 0;text-align:center'>"
            "<div style='color:#ff4444;font-weight:bold;font-size:14px'>"
            "ASYMMETRIC SLIPPAGE DETECTED: %.1f&times; more adverse than favorable</div>"
            "<div style='color:#ffcccc;font-size:12px;margin-top:5px'>"
            "2026 A-book standard: slippage ratio &le;%.1f&times;. "
            "Your broker slips orders against you %.1f&times; more often than in your favor.</div>"
            "</div>\r\n", g_tpslSlipAsymRatio, STD_SLIPPAGE_ASYM_MAX, g_tpslSlipAsymRatio));
      }
      FileWriteString(h, "\r\n");
   }

   // ===== CLUSTERING ANALYSIS vs 2026 A-BOOK STANDARDS =====
   {
      FileWriteString(h, "<h3>Fill Clustering Analysis vs 2026 A-Book Standards</h3>\r\n");
      FileWriteString(h, "<p style='color:#888;font-size:12px'>A genuine A-book broker routes each order individually to its liquidity provider. "
         "Clustering (multiple fills at the same time or same price) indicates the broker is holding and batching orders internally. "
         "Source: FX Global Code Principle 17, MiFID II RTS 27/28, ESMA Feb 2026 Supervisory Briefing.</p>\r\n");

      // Benchmark comparison table
      double clPct = g_clusterRatio * 100.0;
      double baPct = g_batchRatio * 100.0;

      FileWriteString(h, "<table style='width:100%'>\r\n");
      FileWriteString(h, "<tr><th style='width:30%'>Metric</th><th style='width:18%'>Measured</th>"
         "<th style='width:22%'>A-Book Standard</th><th style='width:15%'>Status</th><th style='width:15%'>Verdict</th></tr>\r\n");

      // Fill cluster ratio
      {
         string st, sc;
         if(clPct <= STD_CLUSTER_FAIR_PCT) { st = "PASS"; sc = "#00cc00"; }
         else if(clPct <= STD_CLUSTER_CAUTION_PCT) { st = "CAUTION"; sc = "#ff8800"; }
         else { st = "FAIL"; sc = "#ff4444"; }
         FileWriteString(h, StringFormat("<tr><td>Fill Cluster Ratio</td><td>%.0f%%</td>"
            "<td>&le;%.0f%% fair</td><td style='color:%s;font-weight:bold'>%s</td>"
            "<td style='color:%s'>%s</td></tr>\r\n",
            clPct, STD_CLUSTER_FAIR_PCT, sc, st, sc,
            (clPct > STD_CLUSTER_CAUTION_PCT) ? "Batch processing" : (clPct > STD_CLUSTER_FAIR_PCT) ? "Monitor" : "Normal"));
      }
      // Max cluster size
      {
         string st, sc;
         if((int)g_maxClusterSize <= STD_MAX_CLUSTER_FAIR) { st = "PASS"; sc = "#00cc00"; }
         else if((int)g_maxClusterSize <= STD_MAX_CLUSTER_MANIP) { st = "CAUTION"; sc = "#ff8800"; }
         else { st = "FAIL"; sc = "#ff4444"; }
         FileWriteString(h, StringFormat("<tr><td>Max Cluster Size</td><td>%d fills</td>"
            "<td>&le;%d normal</td><td style='color:%s;font-weight:bold'>%s</td>"
            "<td style='color:%s'>%s</td></tr>\r\n",
            (int)g_maxClusterSize, STD_MAX_CLUSTER_FAIR, sc, st, sc,
            ((int)g_maxClusterSize > STD_MAX_CLUSTER_MANIP) ? "Batching confirmed" : ((int)g_maxClusterSize > STD_MAX_CLUSTER_FAIR) ? "Suspicious" : "Normal"));
      }
      // Largest cluster as % of all fills
      {
         string st, sc;
         if(g_maxClusterPct <= 3.0) { st = "PASS"; sc = "#00cc00"; }
         else if(g_maxClusterPct <= 5.0) { st = "CAUTION"; sc = "#ff8800"; }
         else { st = "FAIL"; sc = "#ff4444"; }
         FileWriteString(h, StringFormat("<tr><td>Largest Cluster %% of Fills</td><td>%.1f%%</td>"
            "<td>&le;3%% normal</td><td style='color:%s;font-weight:bold'>%s</td>"
            "<td style='color:%s'>%s</td></tr>\r\n",
            g_maxClusterPct, sc, st, sc,
            (g_maxClusterPct > 5.0) ? "Concentration risk" : "Acceptable"));
      }
      // Price batch ratio — gated by batch classification
      // High batch ratio on a fast broker (FAIR classification) = normal market drift, not manipulation
      {
         string st, sc, verdict;
         if(g_batchClassification == "FAIR")
         {
            // Fast broker with symmetric execution — price drift is normal market microstructure
            st = "PASS"; sc = "#00cc00";
            verdict = (baPct > STD_BATCH_FAIR_PCT) ? "Market drift (fast fill)" : "Normal";
         }
         else if(baPct <= STD_BATCH_FAIR_PCT) { st = "PASS"; sc = "#00cc00"; verdict = "Normal"; }
         else if(baPct <= STD_BATCH_CAUTION_PCT) { st = "CAUTION"; sc = "#ff8800"; verdict = "Suspicious"; }
         else { st = "FAIL"; sc = "#ff4444"; verdict = "Price manipulation"; }
         FileWriteString(h, StringFormat("<tr><td>Price Batch Ratio</td><td>%.0f%%</td>"
            "<td>&le;%.0f%% fair</td><td style='color:%s;font-weight:bold'>%s</td>"
            "<td style='color:%s'>%s</td></tr>\r\n",
            baPct, STD_BATCH_FAIR_PCT, sc, st, sc, verdict));
      }
      // Slippage symmetry
      {
         string st, sc;
         if(g_tpslSlipAsymRatio <= STD_SLIPPAGE_ASYM_MAX) { st = "PASS"; sc = "#00cc00"; }
         else if(g_tpslSlipAsymRatio <= 2.0) { st = "CAUTION"; sc = "#ff8800"; }
         else { st = "FAIL"; sc = "#ff4444"; }
         FileWriteString(h, StringFormat("<tr><td>Slippage Symmetry</td><td>%.1f&times;</td>"
            "<td>&le;%.1f&times;</td><td style='color:%s;font-weight:bold'>%s</td>"
            "<td style='color:%s'>%s</td></tr>\r\n",
            g_tpslSlipAsymRatio, STD_SLIPPAGE_ASYM_MAX, sc, st, sc,
            (g_tpslSlipAsymRatio > 2.0) ? "Asymmetric" : (g_tpslSlipAsymRatio > STD_SLIPPAGE_ASYM_MAX) ? "Monitor" : "Symmetric"));
      }
      FileWriteString(h, "</table>\r\n");

      // Per-order-type clustering breakdown
      if(g_clusterCount > 0)
      {
         FileWriteString(h, "<h4>Clustering by Order Type</h4>\r\n");
         FileWriteString(h, "<p style='color:#888;font-size:12px'>Which pending order types are appearing in fill clusters? "
            "If stops are disproportionately clustered while limits are not, the broker is selectively batching.</p>\r\n");
         FileWriteString(h, "<table style='width:100%'>\r\n");
         FileWriteString(h, "<tr><th>Order Type</th><th>Total Fills</th><th>In Clusters</th><th>Cluster %</th><th>Assessment</th></tr>\r\n");
         int cTypes[] = {2, 3, 4, 5};
         for(int ci = 0; ci < 4; ci++)
         {
            int ct = cTypes[ci];
            if(g_countByType[ct] == 0) continue;
            string cst, csc;
            if(g_clusterByTypePct[ct] <= STD_CLUSTER_FAIR_PCT) { cst = "Normal"; csc = "#00cc00"; }
            else if(g_clusterByTypePct[ct] <= STD_CLUSTER_CAUTION_PCT) { cst = "Suspicious"; csc = "#ff8800"; }
            else { cst = "Excessive"; csc = "#ff4444"; }
            FileWriteString(h, StringFormat("<tr><td>%s</td><td>%d</td><td>%d</td>"
               "<td style='color:%s;font-weight:bold'>%.0f%%</td><td style='color:%s'>%s</td></tr>\r\n",
               GetFillTypeName((ENUM_FILL_TYPE)ct), g_countByType[ct], g_clusterByType[ct],
               csc, g_clusterByTypePct[ct], csc, cst));
         }
         FileWriteString(h, "</table>\r\n");

         // Asymmetric clustering check: stops clustered >> limits clustered
         double stopClustPct = 0, limClustPct = 0;
         if(g_countByType[2] + g_countByType[3] > 0)
            stopClustPct = 100.0 * (g_clusterByType[2] + g_clusterByType[3]) / (g_countByType[2] + g_countByType[3]);
         if(g_countByType[4] + g_countByType[5] > 0)
            limClustPct = 100.0 * (g_clusterByType[4] + g_clusterByType[5]) / (g_countByType[4] + g_countByType[5]);
         if(stopClustPct > limClustPct * 2.0 && stopClustPct > 15.0)
         {
            FileWriteString(h, StringFormat("<div style='background:#2a1a1a;border:2px solid #ff4444;border-radius:8px;"
               "padding:12px;margin:10px 0'>"
               "<div style='color:#ff4444;font-weight:bold'>ASYMMETRIC CLUSTERING: Stops %.0f%% vs Limits %.0f%%</div>"
               "<div style='color:#ffcccc;margin-top:5px'>Stop orders are disproportionately appearing in fill clusters. "
               "This is consistent with the broker selectively holding and batching stop order fills.</div>"
               "</div>\r\n", stopClustPct, limClustPct));
         }
      }

      // Overall cluster verdict box
      if(g_clusterVerdict == "MANIPULATION")
      {
         FileWriteString(h, "<div style='background:#2a0a0a;border:2px solid #ff4444;border-radius:8px;"
            "padding:15px;margin:15px 0;text-align:center'>"
            "<div style='font-size:18px;color:#ff4444;font-weight:bold'>CLUSTERING VERDICT: MANIPULATION</div>"
            "<div style='color:#ffcccc;margin-top:8px'>Fill clustering exceeds 2026 A-book benchmarks. "
            "This broker is holding and batching orders internally rather than routing them individually. "
            "This is devastating for trading EAs &mdash; clustered fills arrive simultaneously, "
            "causing the EA to receive multiple position updates at once and make decisions on stale data.</div>"
            "</div>\r\n");
      }
      else if(g_clusterVerdict == "CAUTION")
      {
         FileWriteString(h, "<div style='background:#1a1a0a;border:2px solid #ff8800;border-radius:8px;"
            "padding:15px;margin:15px 0;text-align:center'>"
            "<div style='font-size:16px;color:#ff8800;font-weight:bold'>CLUSTERING VERDICT: CAUTION</div>"
            "<div style='color:#ffddaa;margin-top:8px'>Fill clustering is above normal A-book levels. "
            "Monitor this broker closely &mdash; some batching detected that may affect EA execution quality.</div>"
            "</div>\r\n");
      }
      else
      {
         FileWriteString(h, "<div style='background:#0a2a0a;border:1px solid #00cc00;border-radius:8px;"
            "padding:12px;margin:15px 0;text-align:center'>"
            "<div style='color:#00cc00;font-weight:bold'>CLUSTERING VERDICT: FAIR</div>"
            "<div style='color:#88cc88;margin-top:5px'>Fill clustering within 2026 A-book standards. "
            "Orders appear to be routed individually.</div>"
            "</div>\r\n");
      }
      FileWriteString(h, "\r\n");
   }

   // --- BAR CHART: Execution Lag by Order Type vs Industry Standard ---
   FileWriteString(h, "<h3>Your Broker's Execution Time vs Industry Standard</h3>\r\n");

   // Summary line: count how many types exceed standard and note the pattern
   {
      int exceedCount = 0, exceedAdverse = 0, totalActive = 0;
      for(int t = 0; t < 10; t++)
      {
         if(g_countByType[t] == 0) continue;
         totalActive++;
         int std3;
         if(t <= 1) std3 = STD_MARKET_GOOD_MS;
         else if(t <= 5) std3 = STD_FILL_GOOD_MS;
         else if(t <= 7) std3 = STD_TPSL_GOOD_MS;
         else if(t == 9) std3 = STD_SYNC_CLOSE_GOOD_MS;
         else std3 = STD_CLOSE_GOOD_MS;
         if(g_medianLag[t] > (double)std3)
         {
            exceedCount++;
            // Types 2,3,7 = stops/SL (broker-profitable delay)
            if(t == 2 || t == 3 || t == 7) exceedAdverse++;
         }
      }
      if(exceedCount > 0 && exceedAdverse > 0)
         FileWriteString(h, StringFormat("<p style='color:#ff4444;font-size:14px;font-weight:bold;margin:10px 0'>"
            "%d of %d order types exceed industry standards &mdash; %s the types where the broker profits from your delay</p>\r\n",
            exceedCount, totalActive,
            (exceedAdverse == exceedCount) ? "all are" :
            (exceedAdverse > exceedCount / 2) ? "most are" : StringFormat("%d of %d are", exceedAdverse, exceedCount)));
      else if(exceedCount > 0)
         FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:14px;font-weight:bold;margin:10px 0'>"
            "%d of %d order types exceed industry standards</p>\r\n", exceedCount, totalActive));
   }

   FileWriteString(h, "<div style='margin:15px 0'>\r\n");
   double maxLagForChart = 0;
   for(int t = 0; t < 10; t++)
      if(g_countByType[t] > 0 && g_medianLag[t] > maxLagForChart) maxLagForChart = g_medianLag[t];
   if(maxLagForChart < 500) maxLagForChart = 500;
   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] == 0) continue;
      int stdGood2;
      if(t <= 1) stdGood2 = STD_MARKET_GOOD_MS;
      else if(t <= 5) stdGood2 = STD_FILL_GOOD_MS;
      else if(t <= 7) stdGood2 = STD_TPSL_GOOD_MS;
      else if(t == 9) stdGood2 = STD_SYNC_CLOSE_GOOD_MS;
      else stdGood2 = STD_CLOSE_GOOD_MS;

      double measured = g_medianLag[t];
      double scale = maxLagForChart;
      double stdMs = (double)stdGood2;
      double pctStd = (stdMs / scale) * 80;
      if(pctStd < 5) pctStd = 5;

      // Three-tone bar — all bars use same absolute pixel scale
      // Max bar area = 500px, all segments proportional to maxLagForChart
      double barMaxPx = 500.0;
      double pxPerMs = barMaxPx / scale;

      if(measured <= stdMs)
      {
         // Broker is better: green bar (broker) + yellow remainder (unused standard headroom)
         int greenPx = (int)MathMax(3, measured * pxPerMs);
         int yellowPx = (int)MathMax(1, (stdMs - measured) * pxPerMs);
         FileWriteString(h, StringFormat(
            "<div style='margin:5px 0;display:flex;align-items:center'>"
            "<span style='width:200px;flex-shrink:0;color:#aaa;font-size:12px'>%s (%d) <span style='color:#666'>[%dms]</span></span>"
            "<div style='background:#00cc00;height:24px;width:%dpx;border-radius:3px 0 0 3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:40px;overflow:hidden;white-space:nowrap'>%s</div>"
            "<div style='background:#ccaa00;height:24px;width:%dpx;border-radius:0 3px 3px 0;opacity:0.4'></div>"
            "</div>\r\n",
            GetFillTypeName((ENUM_FILL_TYPE)t), g_countByType[t], stdGood2, greenPx, FormatMs(measured), yellowPx));
      }
      else
      {
         // Broker is worse: yellow bar (standard) + red extension + excess label to the right
         int yellowPx = (int)MathMax(3, stdMs * pxPerMs);
         int redPx = (int)MathMax(2, (measured - stdMs) * pxPerMs);
         int pctAbove = (stdGood2 > 0) ? (int)MathRound(((measured - stdMs) / stdMs) * 100) : 0;
         FileWriteString(h, StringFormat(
            "<div style='margin:5px 0;display:flex;align-items:center'>"
            "<span style='width:200px;flex-shrink:0;color:#aaa;font-size:12px'>%s (%d) <span style='color:#666'>[%dms]</span></span>"
            "<div style='background:#ccaa00;height:24px;width:%dpx;border-radius:3px 0 0 3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:40px;overflow:hidden;white-space:nowrap'>%dms</div>"
            "<div style='background:#ff2200;height:24px;width:%dpx;border-radius:0 3px 3px 0'></div>"
            "<span style='margin-left:8px;font-size:11px;font-weight:bold;color:#ff4444;white-space:nowrap'>%s (+%d%%)</span>"
            "</div>\r\n",
            GetFillTypeName((ENUM_FILL_TYPE)t), g_countByType[t], stdGood2, yellowPx, stdGood2, redPx, FormatMs(measured), pctAbove));
      }
   }
   FileWriteString(h, "<div style='margin-top:5px;font-size:11px;color:#aaa'>"
      "<span style='color:#00cc00'>&#9632;</span> Broker (better than standard) &nbsp;&nbsp;"
      "<span style='color:#ccaa00'>&#9632;</span> Industry standard &nbsp;&nbsp;"
      "<span style='color:#ff2200'>&#9632;</span> Excess beyond standard</div>\r\n");
   FileWriteString(h, "</div>\r\n\r\n");

   // Financial Damage
   FileWriteString(h, "<h2>4. Financial Damage Assessment</h2><div class='section'>\r\n");
   if(g_batchClassification == "FAIR")
   {
      FileWriteString(h, "<div style='padding:12px;background:#0a2a0a;border:1px solid #00cc00;border-radius:6px;color:#00cc00;font-size:14px;margin:10px 0'>"
         "No broker-induced damage detected &mdash; all execution within 2026 industry standards.</div>\r\n");
   }
   else
   {
      FileWriteString(h, "<table><tr><th>Category</th><th>Amount</th></tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td>Lag-induced cost</td><td>%s</td></tr>\r\n", FormatMoney(g_totalAdverseSlipUSD)));
      FileWriteString(h, StringFormat("<tr><td>Close lag impact</td><td>%s</td></tr>\r\n", FormatMoney(MathAbs(g_totalFinancialDelta))));
      FileWriteString(h, StringFormat("<tr><td>Rounding skew</td><td>%s</td></tr>\r\n", FormatMoney(MathAbs(g_roundingErrorSum))));
      FileWriteString(h, StringFormat("<tr style='font-weight:bold;background:#2a1a1a'><td>TOTAL DAMAGE</td><td style='color:#ff4400'>%s</td></tr>\r\n", FormatMoney(totalDamage)));
      FileWriteString(h, "</table>\r\n\r\n");
   }

   // --- Annual Damage Projections ---
   // Only show damage when manipulation is actually detected.
   // Lag without drift = trigger fill (but asymmetric lag still causes out-of-sequence fill damage).
   // The tick-based sliding window measures POTENTIAL price movement during lag,
   // but if actual drift is zero, the broker fills at the correct price regardless of lag.
   if(g_batchClassification == "MANIPULATION")
   {
      // Previous Day Tick-Based Projection (primary)
      if(g_prevDayDataValid)
      {
         FileWriteString(h, "<h3>Projected Annual Damage (Previous Day Tick Data)</h3>\r\n");
         FileWriteString(h, StringFormat("<p style='color:#888;font-size:12px'>Based on %d ticks from %s (%d sliding windows of %.0f ms). "
            "Average price range during broker lag: <b>%.2f pips</b> (%.1f pts, %.5f). "
            "Slippage per lot: %s %s. This captures both volatile and quiet market periods.</p>\r\n",
            g_prevDayTickCount, TimeToString(g_prevDayStart, TIME_DATE), g_prevDayWindowCount,
            g_prevDayLagUsedMs, g_prevDayAvgRangePips, g_prevDayAvgRangePoints, g_prevDayAvgRangePrice,
            FormatMoney(g_prevDaySlippagePerLot), g_displayCurrency));
         FileWriteString(h, "<table><tr><th>Volume</th><th>Daily</th><th>Monthly</th><th>Annual</th></tr>\r\n");
         double pvVolumes[4]; pvVolumes[0]=1; pvVolumes[1]=5; pvVolumes[2]=10; pvVolumes[3]=50;
         string pvLabels[4]; pvLabels[0]="1 lot/day"; pvLabels[1]="5 lots/day"; pvLabels[2]="10 lots/day"; pvLabels[3]="50 lots/day";
         for(int v = 0; v < 4; v++)
         {
            double daily = g_prevDaySlippagePerLot * pvVolumes[v];
            FileWriteString(h, StringFormat("<tr><td>%s</td><td>%s</td><td>%s</td><td style='color:#ff8800'>%s</td></tr>\r\n",
               pvLabels[v], FormatMoney(daily), FormatMoney(daily * 21), FormatMoney(daily * 252)));
         }
         FileWriteString(h, "</table>\r\n\r\n");
      }

      // Test Session Per-Lot Projection
      FileWriteString(h, StringFormat("<h3>Projected Annual Damage (Test Session%s)</h3>\r\n",
         g_prevDayDataValid ? " &mdash; For Comparison" : ""));
      FileWriteString(h, "<table><tr><th>Volume</th><th>Daily</th><th>Monthly</th><th>Annual</th></tr>\r\n");
      double volumes2[4]; volumes2[0]=1; volumes2[1]=5; volumes2[2]=10; volumes2[3]=50;
      string volLabels2[4]; volLabels2[0]="1 lot/day"; volLabels2[1]="5 lots/day"; volLabels2[2]="10 lots/day"; volLabels2[3]="50 lots/day";
      for(int v = 0; v < 4; v++)
      {
         double daily = perLot * volumes2[v];
         FileWriteString(h, StringFormat("<tr><td>%s</td><td>%s</td><td>%s</td><td style='color:#ff8800'>%s</td></tr>\r\n",
            volLabels2[v], FormatMoney(daily), FormatMoney(daily * 21), FormatMoney(daily * 252)));
      }
      FileWriteString(h, "</table>\r\n\r\n");

      // Personal-scale daily damage callout
      double calloutPerLot = g_prevDayDataValid ? g_prevDaySlippagePerLot : perLot;
      if(calloutPerLot > 0.01)
      {
         double daily10 = calloutPerLot * 10;
         double annual10 = daily10 * 252;
         FileWriteString(h, StringFormat(
            "<div style='margin:15px 0;padding:16px;background:#2a1111;border:2px solid #ff4400;border-radius:8px;text-align:center'>"
            "<div style='font-size:14px;color:#ff8800;margin-bottom:6px'>At 10 lots/day, the broker extracts</div>"
            "<div style='font-size:28px;font-weight:bold;color:#ff2200'>%s per year</div>"
            "<div style='font-size:16px;color:#ff6644;margin-top:4px'>from your account through execution drift</div>"
            "<div style='font-size:13px;color:#ff8844;margin-top:8px'>That is <b>%s taken from you every trading day</b></div>"
            "</div>\r\n",
            FormatMoney(annual10), FormatMoney(daily10)));
      }

      // BAR CHART: Projected Annual Damage
      FileWriteString(h, "<h3>Projected Annual Damage by Volume</h3>\r\n");
      FileWriteString(h, "<div style='margin:15px 0'>\r\n");
      double barPerLot = g_prevDayDataValid ? g_prevDaySlippagePerLot : perLot;
      double maxAnnual = barPerLot * 50 * 252;
      if(maxAnnual < 1) maxAnnual = 1;
      for(int v = 0; v < 4; v++)
      {
         double annual = barPerLot * volumes2[v] * 252;
         double pctWidth = (annual / maxAnnual) * 80;
         if(pctWidth < 3) pctWidth = 3;
         string barColor = (v == 3) ? "#ff2200" : (v == 2) ? "#ff4400" : (v == 1) ? "#ff7700" : "#ff9900";
         FileWriteString(h, StringFormat(
            "<div style='margin:5px 0;display:flex;align-items:center'>"
            "<span style='width:140px;color:#aaa;font-size:12px'>%s</span>"
            "<div style='background:%s;height:24px;width:%.0f%%;border-radius:3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:50px;overflow:hidden;white-space:nowrap'>%s</div>"
            "</div>\r\n",
            volLabels2[v], barColor, pctWidth, FormatMoney(annual)));
      }
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // --- BAR CHART: Damage Breakdown ---
   FileWriteString(h, "<h3>Damage Breakdown</h3>\r\n");
   if(g_batchClassification == "FAIR")
   {
      FileWriteString(h, "<div style='margin:15px 0;padding:12px;background:#0a2a0a;border:1px solid #00cc00;border-radius:6px;color:#00cc00;font-size:14px'>"
         "No broker-induced damage detected &mdash; all execution within 2026 industry standards.</div></div>\r\n");
   }
   else
   {
      FileWriteString(h, "<div style='margin:15px 0'>\r\n");
      double dmgSlip = g_totalAdverseSlipUSD;
      double dmgClose = MathAbs(g_totalFinancialDelta);
      double dmgRound = MathAbs(g_roundingErrorSum);
      double maxDmg = MathMax(MathMax(dmgSlip, dmgClose), dmgRound);
      if(maxDmg < 0.01) maxDmg = 0.01;

      // Lag cost bar
      double pW = (dmgSlip / maxDmg) * 80; if(pW < 3) pW = 3;
      FileWriteString(h, StringFormat(
         "<div style='margin:5px 0;display:flex;align-items:center'>"
         "<span style='width:140px;color:#aaa;font-size:12px'>Lag-Induced Cost</span>"
         "<div style='background:#ff6644;height:24px;width:%.0f%%;border-radius:3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:50px;overflow:hidden;white-space:nowrap'>%s</div>"
         "</div>\r\n", pW, FormatMoney(dmgSlip)));

      // Close lag bar
      pW = (dmgClose / maxDmg) * 80; if(pW < 3) pW = 3;
      FileWriteString(h, StringFormat(
         "<div style='margin:5px 0;display:flex;align-items:center'>"
         "<span style='width:140px;color:#aaa;font-size:12px'>Close Lag Impact</span>"
         "<div style='background:#ff8844;height:24px;width:%.0f%%;border-radius:3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:50px;overflow:hidden;white-space:nowrap'>%s</div>"
         "</div>\r\n", pW, FormatMoney(dmgClose)));

      // Rounding bar
      pW = (dmgRound / maxDmg) * 80; if(pW < 3) pW = 3;
      FileWriteString(h, StringFormat(
         "<div style='margin:5px 0;display:flex;align-items:center'>"
         "<span style='width:140px;color:#aaa;font-size:12px'>Rounding Skew</span>"
         "<div style='background:#ffaa44;height:24px;width:%.0f%%;border-radius:3px;display:flex;align-items:center;padding-left:8px;font-size:11px;font-weight:bold;min-width:50px;overflow:hidden;white-space:nowrap'>%s</div>"
         "</div>\r\n", pW, FormatMoney(dmgRound)));

      FileWriteString(h, "</div></div>\r\n");
   }

   // Cycle Details
   FileWriteString(h, "<h2>5. Grid Cycle Details</h2><div class='section'>\r\n");
   FileWriteString(h, "<table><tr><th>Cycle</th><th>Spread</th><th>Spacing</th><th>Levels</th>");
   FileWriteString(h, "<th>Placed</th><th>Filled</th><th>TP</th><th>SL</th><th>Async Fills</th><th>Close Lag</th></tr>\r\n");
   for(int c = 0; c < g_cycleNum; c++)
   {
      int stragCount = g_cycles[c].closeFills - g_cycles[c].asyncFillCount;
      if(stragCount < 0) stragCount = 0;
      // Use appropriate standard: sync thresholds if all fills were sync, async if any async
      bool allSync = (g_cycles[c].asyncFillCount == 0 && stragCount > 0);
      int clStdSlow = allSync ? STD_SYNC_CLOSE_SLOW_MS : STD_CLOSE_SLOW_MS;
      int clStdManip = allSync ? STD_SYNC_CLOSE_MANIP_MS : STD_CLOSE_MANIP_MS;
      string clColor = (g_cycles[c].closeBrokerExecMs > clStdManip) ? "fail" :
                        (g_cycles[c].closeBrokerExecMs > clStdSlow) ? "warn" : "pass";
      string closeNote = allSync ? " (sync)" : "";
      FileWriteString(h, StringFormat("<tr><td>%d</td><td>%.1f</td><td>%.1f</td><td>%d</td>",
         g_cycles[c].cycleNum, g_cycles[c].spreadAtPlace, g_cycles[c].spacingPts, g_cycles[c].levelsPerSide));
      FileWriteString(h, StringFormat("<td>%d</td><td>%d</td><td>%d</td><td>%d</td><td>%d/%d%s</td><td class='%s'>%s%s</td></tr>\r\n",
         g_cycles[c].totalPlaced, g_cycles[c].totalFilled, g_cycles[c].tpTriggers, g_cycles[c].slTriggers,
         g_cycles[c].asyncFillCount, g_cycles[c].closeFills, (stragCount > 0) ? StringFormat(" (+%d sync)", stragCount) : "",
         clColor, FormatMs(g_cycles[c].closeBrokerExecMs, g_cycles[c].closeFills > 0), closeNote));
   }
   FileWriteString(h, "</table></div>\r\n");

   // Footer
   FileWriteString(h, "<h2>6. Evidence Files</h2><div class='section'>\r\n");
   FileWriteString(h, "<table><tr><th>File</th><th>Contents</th></tr>\r\n");
   FileWriteString(h, StringFormat("<tr><td><code>%s</code></td><td>Every fill/close event with ms timestamps, prices, lag, and cost</td></tr>\r\n", g_evidenceCsvName));
   FileWriteString(h, StringFormat("<tr><td><code>%s</code></td><td>Every market tick during test (bid, ask, spread, ms timestamps)</td></tr>\r\n", g_tickCsvName));
   FileWriteString(h, StringFormat("<tr><td><code>%s</code></td><td>Raw broker transaction stream - ALL OnTradeTransaction events</td></tr>\r\n", g_brokerLogName));
   FileWriteString(h, StringFormat("<tr><td><code>%s</code></td><td>MT5 deal &amp; order history with broker timestamps (DEAL_TIME_MSC)</td></tr>\r\n", g_histCsvName));
   FileWriteString(h, StringFormat("<tr><td><code>%s</code></td><td>Machine-readable analysis results</td></tr>\r\n", g_tomlName));
   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, StringFormat("<p style='margin-top:10px;color:#888'>Location: <code>%s</code></p>\r\n",
      TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files"));
   FileWriteString(h, "</div>\r\n");

   // ============================================================
   // ADDENDUM: LAYMAN'S GUIDE TO BROKER MANIPULATION
   // ============================================================
   FileWriteString(h, "<h2 style='margin-top:50px;border-top:3px solid #4a90d9;padding-top:20px'>Addendum: Understanding This Report (Non-Technical Guide)</h2>\r\n");

   FileWriteString(h, "<div class='section' style='font-size:15px;line-height:1.8'>\r\n");

   // --- WHAT IS A BROKER ---
   FileWriteString(h, "<h3 style='color:#4a90d9'>What Does a Broker Actually Do?</h3>\r\n");
   FileWriteString(h, "<p>When you trade currencies, gold, or other financial instruments online, you don't trade directly ");
   FileWriteString(h, "on the stock exchange. Instead, you use a <b>broker</b> &mdash; a company that acts as the middleman ");
   FileWriteString(h, "between you and the financial markets.</p>\r\n");
   FileWriteString(h, "<p>Think of it like buying a house through an estate agent. The agent is supposed to get you the ");
   FileWriteString(h, "best deal, but what if the agent secretly benefits when you pay <i>more</i>?</p>\r\n");
   FileWriteString(h, "<p>There are two types of brokers:</p>\r\n");
   FileWriteString(h, "<ul style='margin:10px 0'>\r\n");
   FileWriteString(h, "<li><b>A-Book (honest) broker:</b> Passes your order to a real bank or exchange. The broker earns a small ");
   FileWriteString(h, "commission regardless of whether you win or lose. They have no reason to cheat you.</li>\r\n");
   FileWriteString(h, "<li><b>B-Book (conflict of interest) broker:</b> Takes the opposite side of your trade themselves. ");
   FileWriteString(h, "When you <i>lose</i> money, the broker <i>keeps</i> it. This creates a direct financial incentive ");
   FileWriteString(h, "for the broker to make you lose.</li>\r\n");
   FileWriteString(h, "</ul>\r\n");
   FileWriteString(h, "<p>B-booking is not illegal on its own. But when a B-book broker uses technical tricks to ");
   FileWriteString(h, "<i>increase</i> your losses, that crosses the line into fraud.</p>\r\n\r\n");

   // --- HOW ORDERS WORK ---
   FileWriteString(h, "<h3 style='color:#4a90d9'>How a Trade Order Works (Simplified)</h3>\r\n");
   FileWriteString(h, "<p>Imagine you see gold priced at $2,000 and you want to buy. You click \"Buy\". Here's what ");
   FileWriteString(h, "should happen:</p>\r\n");
   FileWriteString(h, "<ol style='margin:10px 0'>\r\n");
   FileWriteString(h, "<li>Your computer sends the order to the broker's server</li>\r\n");
   FileWriteString(h, "<li>The broker processes the order (ideally instantly)</li>\r\n");
   FileWriteString(h, "<li>You get <b>filled</b> (your purchase is confirmed) at $2,000</li>\r\n");
   FileWriteString(h, "</ol>\r\n");
   FileWriteString(h, "<p>The entire process should take less than a tenth of a second (100 milliseconds). ");
   FileWriteString(h, "A millisecond is one-thousandth of a second &mdash; the blink of an eye takes about 300ms. ");
   FileWriteString(h, "Top A-book brokers in 2026 execute in 10-50ms &mdash; less than one-sixth of a blink.</p>\r\n\r\n");

   // ===== MANIPULATION TACTIC 1: FILL DELAY =====
   FileWriteString(h, "<h3 style='color:#ff4444'>Manipulation Tactic #1: Fill Delay (Order Holding)</h3>\r\n");
   FileWriteString(h, "<p>This is the most common and most damaging manipulation technique.</p>\r\n");
   FileWriteString(h, "<p><b>How it works:</b> When you place an order, the broker deliberately waits before ");
   FileWriteString(h, "confirming it. During this delay, the price moves. If the price moves against you (bad for ");
   FileWriteString(h, "you, good for the broker), they fill your order at the worse price. If the price moves in your ");
   FileWriteString(h, "favour, they may reject the order and ask you to try again.</p>\r\n");

   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 10px 0'><b>Example: Buying Gold</b></p>\r\n");
   FileWriteString(h, "<table style='width:100%'>\r\n");
   FileWriteString(h, "<tr><th style='width:50%'>Fair Broker (A-Book)</th><th>Manipulative Broker (B-Book)</th></tr>\r\n");
   FileWriteString(h, "<tr><td>\r\n");
   FileWriteString(h, "You click Buy at $2,000.00<br>\r\n");
   FileWriteString(h, "Broker processes immediately<br>\r\n");
   FileWriteString(h, "Filled at $2,000.00 (50ms)<br>\r\n");
   FileWriteString(h, "<b style='color:#00cc00'>Cost: $0</b>\r\n");
   FileWriteString(h, "</td><td>\r\n");
   FileWriteString(h, "You click Buy at $2,000.00<br>\r\n");
   FileWriteString(h, "Broker <span style='color:#ff4444'>waits 1.5 seconds</span><br>\r\n");
   FileWriteString(h, "Price rises to $2,000.50<br>\r\n");
   FileWriteString(h, "Filled at $2,000.50 (1,500ms)<br>\r\n");
   FileWriteString(h, "<b style='color:#ff4444'>Hidden cost: $0.50 per unit</b>\r\n");
   FileWriteString(h, "</td></tr></table>\r\n");
   FileWriteString(h, "<p style='margin:10px 0 0 0;color:#aaa'>The $0.50 price difference is caused by the <b>1.5-second lag</b> — the market moved while the broker held your order. ");
   FileWriteString(h, "Brokers call this &ldquo;market slippage&rdquo; but the lag that caused it is deliberate and constant regardless of market conditions. ");
   FileWriteString(h, "On a standard gold trade (1 lot = 100 ounces), that single delay costs you <b>$50</b>. ");
   FileWriteString(h, "If you trade once a day, that's <b>$12,600 per year</b> in hidden losses.</p>\r\n");
   FileWriteString(h, "</div>\r\n\r\n");

   // What this report measured
   FileWriteString(h, "<p><b>What this report measured:</b> We placed hundreds of test orders and timed exactly how ");
   FileWriteString(h, "long the broker took to fill each one. We subtracted the internet travel time (your computer ");
   FileWriteString(h, "to the broker's server and back) so we are measuring <i>only</i> how long the broker itself ");
   FileWriteString(h, "spent processing the order.</p>\r\n");

   FileWriteString(h, StringFormat("<p><b>Result for this broker:</b> Median fill delay was <b>%s</b> ",
      FormatMs((g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) / MathMax(1, g_countByType[2] + g_countByType[3]))));
   FileWriteString(h, StringFormat("(industry standard: under %dms). ", STD_FILL_GOOD_MS));
   double medStop = (g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) / MathMax(1, g_countByType[2] + g_countByType[3]);
   if(medStop > STD_FILL_MANIP_MS)
      FileWriteString(h, StringFormat("This <span style='color:#ff4444'><b>exceeds the accepted industry standard of %dms</b></span> and warrants investigation.</p>\r\n", STD_FILL_MANIP_MS));
   else if(medStop > STD_FILL_SLOW_MS)
      FileWriteString(h, "This is <span style='color:#ff8800'>above the recommended standard</span> and warrants further investigation.</p>\r\n");
   else
      FileWriteString(h, "This is within acceptable limits.</p>\r\n");

   // ===== TOPIC 2: STOP vs LIMIT EXECUTION MECHANICS =====
   FileWriteString(h, "<h3 style='color:#ff8800'>Topic #2: Stop vs Limit Execution Speed (Asymmetric Delay)</h3>\r\n");
   FileWriteString(h, "<p>Brokers claim the speed difference between stops and limits is &ldquo;structural&rdquo; &mdash; "
      "stops route through a liquidity provider while limits fill passively. <b>This excuse does not hold up.</b></p>\r\n");
   FileWriteString(h, "<p>The asymmetric delay benefits the broker regardless of fill price. Here is why:</p>\r\n");
   FileWriteString(h, "<ul>\r\n");
   FileWriteString(h, "<li><b>Stop orders</b> (broker-profitable) are delayed ~100-400ms</li>\r\n");
   FileWriteString(h, "<li><b>Limit orders</b> (broker-costly) fill near-instantly (~0-5ms)</li>\r\n");
   FileWriteString(h, "<li>The same asymmetric infrastructure delays <b>all</b> broker operations &mdash; including counter order fills</li>\r\n");
   FileWriteString(h, "</ul>\r\n");
   FileWriteString(h, "<p>Even if a delayed stop fills at the trigger price, the delay itself causes harm: "
      "when the broker delays fill confirmations, the EA does not know its true position count. "
      "Every calculation &mdash; profit, trailing stops, close decisions &mdash; is made on "
      "<b>incomplete data</b>. The EA's logic is perfect, but it is solving the wrong equation.</p>\r\n");

   double medLim = (g_medianLag[4] * g_countByType[4] + g_medianLag[5] * g_countByType[5]) / MathMax(1, g_countByType[4] + g_countByType[5]);
   double slRatio = (medLim > 0.001) ? medStop / medLim : (medStop > 0 ? 999.0 : 1.0);
   FileWriteString(h, StringFormat("<p><b>Result for this broker:</b> Stop orders took <b>%s</b>, limit orders took <b>%s</b>. ",
      FormatMs(medStop), FormatMs(medLim)));
   FileWriteString(h, StringFormat("That's a ratio of <b>%.1f&times;</b>. ", slRatio));
   if(slRatio > 2.0)
   {
      FileWriteString(h, "<span style='color:#ff4444'><b>ASYMMETRIC</b> &mdash; broker-profitable orders are delayed significantly longer. This asymmetry benefits the broker on all operations including counter fills arriving after EA closes.</span></p>\r\n");
      FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #4a90d9;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
      FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 8px 0'><b>Self-Benchmarking Principle</b></p>\r\n");
      FileWriteString(h, StringFormat("<p style='color:#ccc;margin:0'>When a broker shows different speeds for different order types, "
         "its fastest execution proves what its infrastructure can achieve. "
         "This broker processes limit orders in <b>%s</b> but takes <b>%s</b> for stop orders. "
         "The <b>%s</b> on limits proves the broker <i>can</i> process orders that fast. "
         "The <b>%s</b> on stops is therefore a <b>choice</b>, not a limitation. "
         "The broker's own best performance becomes the evidence against it.</p>\r\n",
         FormatMs(medLim), FormatMs(medStop), FormatMs(medLim), FormatMs(medStop)));
      FileWriteString(h, "</div>\r\n");
   }
   else
      FileWriteString(h, "This is within fair limits (ratio below 1.5&times; expected).</p>\r\n");
   FileWriteString(h, "\r\n");

   // ===== PATTERN 1: SYMMETRIC LAST-LOOK =====
   {
      // Calculate max measured lag for the symmetric example
      double p1Lag = 0;
      for(int t = 0; t < 10; t++)
         if(g_lagValidCount[t] > 0 && g_medianLag[t] > p1Lag) p1Lag = g_medianLag[t];
      bool p1Hypothetical = (p1Lag < 100);
      double p1LagShow = p1Hypothetical ? 250.0 : p1Lag;
      string p1LagStr = FormatMs(p1LagShow);
      string p1Note = p1Hypothetical
         ? StringFormat(" (Illustrative — this broker's actual max lag was %s)", FormatMs(p1Lag))
         : " (this broker's measured maximum lag)";

      FileWriteString(h, "<div style='margin:40px 0 0 0;padding:15px 0;border-top:3px solid #ff8800'>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:12px;font-weight:bold;letter-spacing:2px;text-transform:uppercase;margin-bottom:4px'>Pattern 1 &mdash; Price Manipulation</div>\r\n");
      FileWriteString(h, "<div style='color:#fff;font-size:20px;font-weight:bold;margin-bottom:4px'>Symmetric Lag: The Last-Look Window</div>\r\n");
      FileWriteString(h, "<div style='color:#aaa;font-size:13px'>Equal delay on all orders &mdash; but the delay itself is the weapon</div>\r\n");
      FileWriteString(h, "</div>\r\n");

      FileWriteString(h, "<p style='color:#ccc;font-size:13px;line-height:1.7;margin:12px 0'>"
         "A broker that delays <b>all</b> orders equally looks fair &mdash; there is no discrimination. "
         "But if that equal delay is <b>slow</b>, the broker has a <b>window</b> to inspect "
         "every order before confirming it. The market moves during that window. The broker sees which direction. "
         "Then it decides what price to give you.</p>\r\n");

      // What happens inside the window
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff8800;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:16px;font-weight:bold;text-align:center;margin:0 0 15px 0'>"
         "What Happens Inside the %s Window</p>\r\n", p1LagStr));
      FileWriteString(h, "<div style='display:flex;gap:12px;margin:10px 0'>\r\n");
      FileWriteString(h, "<div style='flex:1;background:#1a2a1a;border:1px solid #338833;border-radius:6px;padding:10px'>\r\n");
      FileWriteString(h, "<p style='color:#ff6666;font-weight:bold;margin:0 0 6px 0;font-size:12px'>If price rises (against your buy)</p>\r\n");
      FileWriteString(h, "<p style='font-size:11px;margin:0;color:#ccc'>Broker fills at <span style='color:#ff4444;font-weight:bold'>higher price</span>. You pay more. Broker/LP keeps the difference.</p>\r\n");
      FileWriteString(h, "</div>\r\n");
      FileWriteString(h, "<div style='flex:1;background:#1a1a2e;border:1px solid #4a90d9;border-radius:6px;padding:10px'>\r\n");
      FileWriteString(h, "<p style='color:#66cc66;font-weight:bold;margin:0 0 6px 0;font-size:12px'>If price drops (in your favor)</p>\r\n");
      FileWriteString(h, "<p style='font-size:11px;margin:0;color:#ccc'>Broker fills at <span style='color:#ff8800;font-weight:bold'>original price</span>. No improvement given. Or requotes you entirely.</p>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<p style='color:#ccc;font-size:13px;text-align:center;margin:10px 0 0 0'>"
         "<b>Result:</b> You absorb all adverse moves. You receive none of the favorable ones. This is <span style='color:#ff8800;font-weight:bold'>last-look</span>.</p>\r\n");
      FileWriteString(h, "</div>\r\n");

      // 10-trade comparison table
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff8800;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff8800;font-size:16px;font-weight:bold;text-align:center;margin:0 0 4px 0'>"
         "10 Gold Trades: Fast Broker vs Slow Symmetric Broker</p>\r\n");
      FileWriteString(h, StringFormat("<p style='font-size:11px;color:#888;text-align:center;margin-bottom:10px'>"
         "Same 10 buy orders, same market. Only difference: execution speed.%s</p>\r\n", p1Note));

      FileWriteString(h, "<div style='display:flex;gap:16px;margin:15px 0'>\r\n");

      // Fair broker column
      FileWriteString(h, "<div style='flex:1;background:#111827;border:2px solid #00cc00;border-radius:8px;padding:12px;overflow:hidden'>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:13px;font-weight:bold;text-align:center;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid #333'>&#9989; Fair Broker (30ms)</div>\r\n");
      FileWriteString(h, "<div style='text-align:center;font-size:10px;color:#888;margin-bottom:6px'>No time for price to move</div>\r\n");
      FileWriteString(h, "<table style='width:100%;border-collapse:collapse;font-size:11px'>\r\n");
      FileWriteString(h, "<tr><th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:8%'>#</th>"
         "<th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%'>Request</th>"
         "<th style='text-align:center;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%'>30ms later</th>"
         "<th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%'>Filled at</th>"
         "<th style='text-align:right;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:20%'>Cost</th></tr>\r\n");
      // 10 rows — fair broker always fills at request, $0 cost
      string fairPrices[] = {"$2,000.00","$2,001.20","$1,999.50","$2,002.00","$1,998.80",
                              "$2,003.10","$2,000.90","$2,004.00","$1,997.60","$2,001.50"};
      for(int i = 0; i < 10; i++)
      {
         FileWriteString(h, StringFormat("<tr><td style='padding:3px;color:#888'>%d</td>"
            "<td style='padding:3px'>%s</td>"
            "<td style='padding:3px;text-align:center;color:#888'>~same</td>"
            "<td style='padding:3px'>%s</td>"
            "<td style='padding:3px;text-align:right;color:#00cc00;font-weight:bold'>$0</td></tr>\r\n",
            i + 1, fairPrices[i], fairPrices[i]));
      }
      FileWriteString(h, "</table>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;padding:8px 3px;margin-top:6px;border-top:2px solid #444;font-size:12px;font-weight:bold'>"
         "<span style='flex:1'>Hidden cost:</span>"
         "<span style='font-size:15px;color:#00cc00'>$0.00</span></div>\r\n");
      FileWriteString(h, "</div>\r\n");

      // Slow symmetric broker column
      FileWriteString(h, "<div style='flex:1;background:#111827;border:2px solid #ff8800;border-radius:8px;padding:12px;overflow:hidden'>\r\n");
      FileWriteString(h, StringFormat("<div style='color:#ff8800;font-size:13px;font-weight:bold;text-align:center;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid #333'>&#9888; Slow Symmetric (%s)</div>\r\n", p1LagStr));
      FileWriteString(h, StringFormat("<div style='text-align:center;font-size:10px;color:#888;margin-bottom:6px'>Price moves in %s &mdash; broker fills accordingly</div>\r\n", p1LagStr));
      FileWriteString(h, "<table style='width:100%;border-collapse:collapse;font-size:11px'>\r\n");
      FileWriteString(h, StringFormat("<tr><th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:8%%'>#</th>"
         "<th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%%'>Request</th>"
         "<th style='text-align:center;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%%'>%s later</th>"
         "<th style='text-align:left;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:24%%'>Filled at</th>"
         "<th style='text-align:right;padding:4px 3px;color:#aaa;border-bottom:1px solid #333;font-size:10px;width:20%%'>Cost</th></tr>\r\n", p1LagStr));

      // Slow broker data: price moved during window, adverse fills at worse price, favorable no improvement
      string slowFills[]   = {"$2,000.40","$2,001.20","$1,999.80","$2,002.00","$1,999.30",
                               "$2,003.50","$2,000.90","$2,004.60","$1,997.60","$2,001.90"};
      string slowWindow[]  = {"$2,000.40 &#9650;","$2,000.90 &#9660;","$1,999.80 &#9650;","$2,001.50 &#9660;","$1,999.30 &#9650;",
                               "$2,003.50 &#9650;","$2,000.60 &#9660;","$2,004.60 &#9650;","$1,997.20 &#9660;","$2,001.90 &#9650;"};
      string slowWinClr[]  = {"#ff6666","#66cc66","#ff6666","#66cc66","#ff6666",
                               "#ff6666","#66cc66","#ff6666","#66cc66","#ff6666"};
      string slowCosts[]   = {"-$40","$0","-$30","$0","-$50","-$40","$0","-$60","$0","-$40"};
      string slowCostClr[] = {"#ff4444","#888","#ff4444","#888","#ff4444",
                               "#ff4444","#888","#ff4444","#888","#ff4444"};
      string slowFillClr[] = {"#ff4444","#ff8800","#ff4444","#ff8800","#ff4444",
                               "#ff4444","#ff8800","#ff4444","#ff8800","#ff4444"};
      for(int i = 0; i < 10; i++)
      {
         FileWriteString(h, StringFormat("<tr><td style='padding:3px;color:#888'>%d</td>"
            "<td style='padding:3px'>%s</td>"
            "<td style='padding:3px;text-align:center;color:%s'>%s</td>"
            "<td style='padding:3px;color:%s;font-weight:bold'>%s</td>"
            "<td style='padding:3px;text-align:right;color:%s;font-weight:bold'>%s</td></tr>\r\n",
            i + 1, fairPrices[i], slowWinClr[i], slowWindow[i], slowFillClr[i], slowFills[i], slowCostClr[i], slowCosts[i]));
      }
      FileWriteString(h, "</table>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;padding:8px 3px;margin-top:6px;border-top:2px solid #444;font-size:12px;font-weight:bold'>"
         "<span style='flex:1'>Hidden cost (1 lot = 100oz):</span>"
         "<span style='font-size:15px;color:#ff4444'>-$260</span></div>\r\n");
      FileWriteString(h, "</div>\r\n");
      FileWriteString(h, "</div>\r\n"); // end flex comparison

      FileWriteString(h, StringFormat("<p style='color:#ccc;font-size:13px;text-align:center;margin:10px 0'>"
         "Same 10 trades. Same market. Same <b>symmetric</b> %s delay.<br>"
         "Fast broker: <span style='color:#00cc00;font-weight:bold'>$0</span>. Slow broker: <span style='color:#ff4444;font-weight:bold'>$260</span>. "
         "Over 250 trading days: <span style='color:#ff4444;font-weight:bold'>$6,500/year</span> in hidden losses.</p>\r\n", p1LagStr));
      FileWriteString(h, "</div>\r\n"); // end section-box

      // Bar chart: Where Your Money Goes
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff4444;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;font-size:16px;font-weight:bold;text-align:center;margin:0 0 15px 0'>Where Your Money Goes &mdash; The Last-Look Tax</p>\r\n");
      FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:8px;padding:20px;margin:10px 0'>\r\n");
      FileWriteString(h, "<div style='display:flex;justify-content:center;gap:14px'>\r\n");

      // Fair broker bar
      FileWriteString(h, "<div style='flex:0 0 130px;text-align:center'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:8px;height:180px;padding-bottom:4px'>\r\n");
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:11px;font-weight:bold;margin-bottom:3px'>$0 cost</div>\r\n");
      FileWriteString(h, "<div style='width:60px;height:4px;background:#00cc00;border-radius:4px 4px 0 0;border:1px solid #00cc00'></div>\r\n");
      FileWriteString(h, "<div style='width:60px;height:120px;background:linear-gradient(to top,#333,#555);border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:#aaa;font-size:10px;font-weight:bold'>10 trades<br>$0 hidden<br>cost</span></div>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:12px;font-weight:bold;margin-top:6px'>Fair Broker</div>\r\n");
      FileWriteString(h, "<div style='color:#888;font-size:10px'>30ms &mdash; no window</div></div>\r\n");

      // Slow broker bars (adverse + no improvement)
      FileWriteString(h, "<div style='flex:0 0 200px;text-align:center'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:8px;height:180px;padding-bottom:4px'>\r\n");
      // Adverse bar
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:11px;font-weight:bold;margin-bottom:3px'>-$260</div>\r\n");
      FileWriteString(h, "<div style='width:60px;height:78px;background:linear-gradient(to top,#aa2222,#ff4444);border-radius:4px 4px 0 0;border:1px solid #ff4444;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:white;font-size:9px;font-weight:bold;text-align:center'>6 adverse<br>fills</span></div>\r\n");
      FileWriteString(h, "<div style='width:60px;height:120px;background:linear-gradient(to top,#333,#555);border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:#aaa;font-size:9px;font-weight:bold'>Price moved<br>against you<br>&rarr; you pay<br>MORE</span></div>\r\n");
      FileWriteString(h, "</div>\r\n");
      // Favorable bar (no improvement)
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:11px;font-weight:bold;margin-bottom:3px'>$0 saved</div>\r\n");
      FileWriteString(h, "<div style='width:60px;height:120px;background:linear-gradient(to top,#333,#555);border:1px solid #666;border-radius:4px 4px 0 0;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:#ff8800;font-size:9px;font-weight:bold;text-align:center'>Price moved<br>in your favor<br>&rarr; NO<br>improvement</span></div>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:12px;font-weight:bold;margin-top:6px'>Slow Symmetric Broker</div>\r\n");
      FileWriteString(h, StringFormat("<div style='color:#888;font-size:10px'>%s &mdash; last-look window</div></div>\r\n", p1LagStr));

      // Net result bar
      FileWriteString(h, "<div style='flex:0 0 130px;text-align:center'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:8px;height:180px;padding-bottom:4px'>\r\n");
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:13px;font-weight:bold;margin-bottom:3px'>-$260</div>\r\n");
      FileWriteString(h, "<div style='width:70px;height:78px;background:repeating-linear-gradient(45deg,#ff444440,#ff444440 4px,#aa222240 4px,#aa222240 8px);border-radius:4px 4px 0 0;border:2px solid #ff4444;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:#ff6666;font-size:11px;font-weight:bold;text-align:center'>NET<br>HIDDEN<br>COST</span></div>\r\n");
      FileWriteString(h, "<div style='width:70px;height:84px;background:linear-gradient(to top,#333,#444);border:1px solid #555;border-top:none;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:#888;font-size:9px;font-weight:bold;text-align:center'>per 10 trades<br>1 lot gold</span></div>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:12px;font-weight:bold;margin-top:6px'>Your Hidden Tax</div>\r\n");
      FileWriteString(h, "<div style='color:#888;font-size:10px'>$6,500/year</div></div>\r\n");

      FileWriteString(h, "</div></div>\r\n"); // end chart
      FileWriteString(h, "<p style='color:#ccc;font-size:13px;text-align:center;margin:10px 0 0 0'>"
         "<b>The pattern:</b> When price moves against you &rarr; full slippage absorbed.<br>"
         "When price moves in your favor &rarr; <b>zero improvement given</b>. That is last-look.</p>\r\n");
      FileWriteString(h, "</div>\r\n"); // end bar chart section

      // Analogy: Delayed Cash Register
      FileWriteString(h, "<div style='background:#1a2a1a;border:1px solid #338833;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
      FileWriteString(h, "<p style='color:#44aa44;font-weight:bold;margin-bottom:8px;font-size:14px'>&#128161; Analogy: The Delayed Cash Register</p>\r\n");
      FileWriteString(h, "<p style='color:#ccc;font-size:13px;line-height:1.7'>"
         "Imagine a shop where the cash register takes <b>5 minutes</b> to process every transaction. "
         "Seems fair: everyone waits equally. But during those 5 minutes, the shopkeeper <b>watches the ticker</b>. "
         "If the item's price went <b>up</b>, the shopkeeper charges the <b style='color:#88cc88'>new higher price</b>. "
         "If the price went <b>down</b>, the shopkeeper charges the <b style='color:#88cc88'>original price</b> anyway. "
         "The fairness is in the <b style='color:#88cc88'>wait time</b>. The unfairness is in the <b style='color:#88cc88'>price you pay</b>.</p>\r\n");
      FileWriteString(h, "</div>\r\n");

      // Key insight box
      FileWriteString(h, "<div style='background:#2a1a1a;border:2px solid #ff4444;border-radius:8px;padding:15px;margin:15px 0;text-align:center'>\r\n");
      FileWriteString(h, "<p style='color:#ff8800;font-size:14px;font-weight:bold;line-height:1.6;margin:0'>"
         "Symmetric lag means equal <b>waiting time</b>. It does NOT mean equal <b>outcome</b>.<br>"
         "The lag itself is the weapon &mdash; it creates the window.<br>"
         "What the broker does <em>inside</em> that window is what costs you money.</p>\r\n");
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== PATTERN 2: ASYMMETRIC SPEED DISCRIMINATION =====
   if(hasStructuralAsymmetry || g_vdpLagRatio > 2.0)
   {
      double p2Fast = g_vdpFavorMedian;
      double p2Slow = g_vdpAdverseMedian;
      if(p2Fast < 1.0) p2Fast = medLim;
      if(p2Slow < 1.0) p2Slow = medStop;
      string p2FastStr = FormatMs(p2Fast);
      string p2SlowStr = FormatMs(p2Slow);
      double p2FastPct = (p2Slow > 0) ? (p2Fast / p2Slow * 100.0) : 12.0;
      if(p2FastPct < 5) p2FastPct = 5;
      if(p2FastPct > 95) p2FastPct = 95;

      FileWriteString(h, "<div style='margin:40px 0 0 0;padding:15px 0;border-top:3px solid #ff8800'>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:12px;font-weight:bold;letter-spacing:2px;text-transform:uppercase;margin-bottom:4px'>Pattern 2 &mdash; Price Manipulation (Selective)</div>\r\n");
      FileWriteString(h, "<div style='color:#fff;font-size:20px;font-weight:bold;margin-bottom:4px'>Asymmetric Lag: The Broker's Profit Machine</div>\r\n");
      FileWriteString(h, "<div style='color:#aaa;font-size:13px'>Your losses are fast. Your wins are slow. That is not a coincidence.</div>\r\n");
      FileWriteString(h, "</div>\r\n");

      FileWriteString(h, "<p style='color:#ccc;font-size:13px;line-height:1.7;margin:12px 0'>"
         "With symmetric lag, the broker rigs every trade equally. With <b>asymmetric</b> lag, "
         "the broker goes further: <b>different speeds for different outcomes</b>. "
         "Losing trades? <b>Filled instantly</b> &mdash; locked in before you can react. "
         "Winning trades? <b>Delayed</b> &mdash; the price retraces, your profit is shaved. "
         "Your fastest execution proves what the broker <b>can</b> do. Your slowest proves what it <b>chooses</b> to do.</p>\r\n");

      // Two Speeds, One Broker
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff4444;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;font-size:16px;font-weight:bold;text-align:center;margin:0 0 15px 0'>Two Speeds, One Broker</p>\r\n");
      FileWriteString(h, "<div style='display:flex;gap:20px;margin:15px 0'>\r\n");

      // Fast lane (losing trades)
      FileWriteString(h, "<div style='flex:1;background:#111827;border:2px solid #00cc00;border-radius:8px;padding:12px;text-align:center'>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:13px;font-weight:bold;margin-bottom:6px'>&#9889; Losing Trades</div>\r\n");
      FileWriteString(h, StringFormat("<div style='color:#00cc00;font-size:22px;font-weight:bold;margin:4px 0'>%s</div>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<div style='background:#222;border-radius:10px;height:18px;position:relative;margin:8px 0;overflow:hidden'>"
         "<div style='height:100%%;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:bold;color:#fff;"
         "background:linear-gradient(90deg,#00cc00,#00aa00);width:%.0f%%'>%s</div></div>\r\n", p2FastPct, p2FastStr));
      FileWriteString(h, "<div style='font-size:10px;color:#888'>Filled instantly. No chance to cancel.<br>Your loss is locked in at full speed.</div>\r\n");
      FileWriteString(h, "</div>\r\n");

      // Slow lane (winning trades)
      FileWriteString(h, "<div style='flex:1;background:#111827;border:2px solid #ff4444;border-radius:8px;padding:12px;text-align:center'>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:13px;font-weight:bold;margin-bottom:6px'>&#9203; Winning Trades</div>\r\n");
      FileWriteString(h, StringFormat("<div style='color:#ff4444;font-size:22px;font-weight:bold;margin:4px 0'>%s</div>\r\n", p2SlowStr));
      FileWriteString(h, StringFormat("<div style='background:#222;border-radius:10px;height:18px;position:relative;margin:8px 0;overflow:hidden'>"
         "<div style='height:100%%;border-radius:10px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:bold;color:#fff;"
         "background:linear-gradient(90deg,#ff4444,#cc2222);width:100%%'>%s</div></div>\r\n", p2SlowStr));
      FileWriteString(h, "<div style='font-size:10px;color:#888'>Held and delayed. Price retraces.<br>Your profit is shaved or eliminated.</div>\r\n");
      FileWriteString(h, "</div></div>\r\n");

      FileWriteString(h, StringFormat("<p style='color:#ccc;font-size:13px;text-align:center;margin:10px 0 0 0'>"
         "<span style='color:#00cc00;font-weight:bold'>%s on losing trades</span> proves the infrastructure can do %s.<br>"
         "<span style='color:#ff4444;font-weight:bold'>%s on winning trades</span> is a <b>business decision</b>, not a limitation.</p>\r\n",
         p2FastStr, p2FastStr, p2SlowStr));
      FileWriteString(h, "</div>\r\n");

      // 10-trade table
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff4444;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;font-size:16px;font-weight:bold;text-align:center;margin:0 0 4px 0'>10 Gold Trades: What Asymmetric Lag Costs You</p>\r\n");
      FileWriteString(h, StringFormat("<p style='font-size:11px;color:#888;text-align:center;margin-bottom:8px'>"
         "Broker fills losses fast (%s) and delays wins (%s). Same trader, same market.</p>\r\n", p2FastStr, p2SlowStr));

      FileWriteString(h, "<table style='width:100%;border-collapse:collapse;font-size:11px;margin:12px 0'>\r\n");
      FileWriteString(h, "<tr><th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>#</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Dir</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Requested</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Outcome</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Speed</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Filled At</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Your P&amp;L</th>"
         "<th style='text-align:left;padding:6px 4px;color:#ff8800;border-bottom:2px solid #444;font-size:10px'>Broker Gets</th></tr>\r\n");

      // Trade data — 5 losses (fast) and 5 wins (slow/shaved)
      FileWriteString(h, StringFormat("<tr style='background:#2a1515'><td style='padding:5px 4px;border-bottom:1px solid #222'>1</td><td>Buy</td><td>$2,000.00</td><td style='color:#ff6666'>Price drops</td><td style='color:#00cc00'>%s &#9889;</td><td>$2,000.00</td><td style='color:#ff4444;font-weight:bold'>-$350</td><td style='color:#00cc00'>+$350</td></tr>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<tr style='background:#1a2a1a'><td style='padding:5px 4px;border-bottom:1px solid #222'>2</td><td>Buy</td><td>$2,001.20</td><td style='color:#66cc66'>Price rises</td><td style='color:#ff4444'>%s &#9203;</td><td style='color:#ff8800'>$2,001.50</td><td style='color:#aaa'>+$90</td><td style='color:#00cc00'>+$30</td></tr>\r\n", p2SlowStr));
      FileWriteString(h, StringFormat("<tr style='background:#2a1515'><td style='padding:5px 4px;border-bottom:1px solid #222'>3</td><td>Sell</td><td>$1,999.50</td><td style='color:#ff6666'>Price rises</td><td style='color:#00cc00'>%s &#9889;</td><td>$1,999.50</td><td style='color:#ff4444;font-weight:bold'>-$280</td><td style='color:#00cc00'>+$280</td></tr>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<tr style='background:#1a2a1a'><td style='padding:5px 4px;border-bottom:1px solid #222'>4</td><td>Buy</td><td>$2,002.00</td><td style='color:#66cc66'>Price rises</td><td style='color:#ff4444'>%s &#9203;</td><td style='color:#ff8800'>$2,002.40</td><td style='color:#aaa'>+$160</td><td style='color:#00cc00'>+$40</td></tr>\r\n", p2SlowStr));
      FileWriteString(h, StringFormat("<tr style='background:#2a1515'><td style='padding:5px 4px;border-bottom:1px solid #222'>5</td><td>Sell</td><td>$1,998.80</td><td style='color:#ff6666'>Price rises</td><td style='color:#00cc00'>%s &#9889;</td><td>$1,998.80</td><td style='color:#ff4444;font-weight:bold'>-$420</td><td style='color:#00cc00'>+$420</td></tr>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<tr style='background:#1a2a1a'><td style='padding:5px 4px;border-bottom:1px solid #222'>6</td><td>Buy</td><td>$2,003.10</td><td style='color:#66cc66'>Price rises</td><td style='color:#ff4444'>%s &#9203;</td><td style='color:#ff8800'>$2,003.60</td><td style='color:#aaa'>+$250</td><td style='color:#00cc00'>+$50</td></tr>\r\n", p2SlowStr));
      FileWriteString(h, StringFormat("<tr style='background:#2a1515'><td style='padding:5px 4px;border-bottom:1px solid #222'>7</td><td>Buy</td><td>$2,000.90</td><td style='color:#ff6666'>Price drops</td><td style='color:#00cc00'>%s &#9889;</td><td>$2,000.90</td><td style='color:#ff4444;font-weight:bold'>-$310</td><td style='color:#00cc00'>+$310</td></tr>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<tr style='background:#1a2a1a'><td style='padding:5px 4px;border-bottom:1px solid #222'>8</td><td>Sell</td><td>$2,004.00</td><td style='color:#66cc66'>Price drops</td><td style='color:#ff4444'>%s &#9203;</td><td style='color:#ff8800'>$2,003.50</td><td style='color:#aaa'>+$350</td><td style='color:#00cc00'>+$50</td></tr>\r\n", p2SlowStr));
      FileWriteString(h, StringFormat("<tr style='background:#2a1515'><td style='padding:5px 4px;border-bottom:1px solid #222'>9</td><td>Sell</td><td>$1,997.60</td><td style='color:#ff6666'>Price rises</td><td style='color:#00cc00'>%s &#9889;</td><td>$1,997.60</td><td style='color:#ff4444;font-weight:bold'>-$380</td><td style='color:#00cc00'>+$380</td></tr>\r\n", p2FastStr));
      FileWriteString(h, StringFormat("<tr style='background:#1a2a1a'><td style='padding:5px 4px;border-bottom:1px solid #222'>10</td><td>Buy</td><td>$2,001.50</td><td style='color:#66cc66'>Price rises</td><td style='color:#ff4444'>%s &#9203;</td><td style='color:#ff8800'>$2,001.90</td><td style='color:#aaa'>+$210</td><td style='color:#00cc00'>+$40</td></tr>\r\n", p2SlowStr));
      FileWriteString(h, "</table>\r\n");

      // P&L boxes
      FileWriteString(h, "<div style='display:flex;gap:20px;margin:15px 0'>\r\n");
      FileWriteString(h, "<div style='flex:1;border-radius:8px;padding:15px;text-align:center;background:#2a1515;border:2px solid #ff4444'>\r\n");
      FileWriteString(h, "<div style='color:#ff6666;font-size:12px;margin-bottom:6px'>&#128100; YOUR Net P&amp;L</div>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:26px;font-weight:bold'>-$680</div>\r\n");
      FileWriteString(h, "<div style='font-size:10px;color:#888;margin-top:5px'>5 losses locked in fast: -$1,740<br>5 wins shaved by delay: +$1,060</div>\r\n");
      FileWriteString(h, "</div>\r\n");
      FileWriteString(h, "<div style='flex:1;border-radius:8px;padding:15px;text-align:center;background:#1a2a1a;border:2px solid #00cc00'>\r\n");
      FileWriteString(h, "<div style='color:#66cc66;font-size:12px;margin-bottom:6px'>&#127970; BROKER Profit</div>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:26px;font-weight:bold'>+$1,950</div>\r\n");
      FileWriteString(h, "<div style='font-size:10px;color:#888;margin-top:5px'>B-book gains: +$1,740<br>Slippage skimmed: +$210</div>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "</div>\r\n"); // end trade table section

      // Bar chart: Your Loss Is Their Profit
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff4444;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;font-size:16px;font-weight:bold;text-align:center;margin:0 0 15px 0'>Your Loss Is Their Profit &mdash; Visualized</p>\r\n");
      FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:8px;padding:20px;margin:10px 0'>\r\n");
      FileWriteString(h, "<div style='display:flex;justify-content:center;align-items:flex-end;gap:16px'>\r\n");

      // YOUR SIDE
      FileWriteString(h, "<div style='text-align:center'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:8px;height:200px;padding-bottom:4px'>\r\n");
      // Your losses bar
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#ff4444;font-size:10px;font-weight:bold;margin-bottom:2px'>-$1,740</div>\r\n");
      FileWriteString(h, StringFormat("<div style='width:55px;height:145px;background:linear-gradient(to top,#aa2222,#ff4444);border-radius:4px 4px 0 0;border:1px solid #ff4444;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:white;font-size:8px;font-weight:bold;text-align:center'>5 losses<br>locked in<br>FAST<br>(%s)</span></div>\r\n", p2FastStr));
      FileWriteString(h, "</div>\r\n");
      // Your shaved wins bar
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#88aa44;font-size:10px;font-weight:bold;margin-bottom:2px'>+$1,060</div>\r\n");
      FileWriteString(h, StringFormat("<div style='width:55px;height:88px;background:linear-gradient(to top,#336622,#66aa33);border-radius:4px 4px 0 0;border:1px solid #88aa44;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:white;font-size:8px;font-weight:bold;text-align:center'>5 wins<br>SHAVED<br>by delay<br>(%s)</span></div>\r\n", p2SlowStr));
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<div style='margin-top:6px;padding:8px;background:#2a1515;border:2px solid #ff4444;border-radius:6px'>"
         "<div style='color:#ff6666;font-size:11px'>&#128100; YOU</div>"
         "<div style='color:#ff4444;font-size:20px;font-weight:bold'>-$680</div></div>\r\n");
      FileWriteString(h, "</div>\r\n");

      // Zero-sum arrow
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center;justify-content:center;height:200px;padding:0 8px'>\r\n");
      FileWriteString(h, "<div style='font-size:32px;color:#ff8800'>&#8644;</div>\r\n");
      FileWriteString(h, "<div style='font-size:10px;color:#888;margin-top:4px'>Zero-sum</div>\r\n");
      FileWriteString(h, "<div style='font-size:9px;color:#666'>Your loss =<br>their gain</div></div>\r\n");

      // BROKER SIDE
      FileWriteString(h, "<div style='text-align:center'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:8px;height:200px;padding-bottom:4px'>\r\n");
      // B-book gains bar
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#00cc00;font-size:10px;font-weight:bold;margin-bottom:2px'>+$1,740</div>\r\n");
      FileWriteString(h, "<div style='width:55px;height:145px;background:linear-gradient(to top,#008800,#00cc00);border-radius:4px 4px 0 0;border:1px solid #00cc00;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:white;font-size:8px;font-weight:bold;text-align:center'>B-book<br>profits<br>from your<br>losses</span></div>\r\n");
      FileWriteString(h, "</div>\r\n");
      // Slippage skimmed bar
      FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>\r\n");
      FileWriteString(h, "<div style='color:#44cc44;font-size:10px;font-weight:bold;margin-bottom:2px'>+$210</div>\r\n");
      FileWriteString(h, "<div style='width:55px;height:18px;background:linear-gradient(to top,#226622,#44cc44);border-radius:4px 4px 0 0;border:1px solid #44cc44;display:flex;align-items:center;justify-content:center'>"
         "<span style='color:white;font-size:7px;font-weight:bold'>skim</span></div>\r\n");
      FileWriteString(h, "</div></div>\r\n");
      FileWriteString(h, "<div style='margin-top:6px;padding:8px;background:#1a2a1a;border:2px solid #00cc00;border-radius:6px'>"
         "<div style='color:#66cc66;font-size:11px'>&#127970; BROKER</div>"
         "<div style='color:#00cc00;font-size:20px;font-weight:bold'>+$1,950</div></div>\r\n");
      FileWriteString(h, "</div>\r\n");

      FileWriteString(h, "</div>\r\n"); // end bar chart flex

      // Legend
      FileWriteString(h, "<div style='display:flex;justify-content:center;gap:16px;margin-top:14px;padding-top:10px;border-top:1px solid #333;flex-wrap:wrap'>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;gap:5px'><div style='width:14px;height:10px;background:#ff4444;border-radius:2px'></div><span style='color:#ff6666;font-size:10px'>Your losses (fast-filled)</span></div>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;gap:5px'><div style='width:14px;height:10px;background:#66aa33;border-radius:2px'></div><span style='color:#88aa44;font-size:10px'>Your wins (shaved by delay)</span></div>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;gap:5px'><div style='width:14px;height:10px;background:#00cc00;border-radius:2px'></div><span style='color:#00cc00;font-size:10px'>Broker B-book profit</span></div>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;gap:5px'><div style='width:14px;height:10px;background:#44cc44;border-radius:2px'></div><span style='color:#44cc44;font-size:10px'>Broker slippage skim</span></div>\r\n");
      FileWriteString(h, "</div>\r\n");
      FileWriteString(h, "</div>\r\n"); // end chart container
      FileWriteString(h, "<p style='color:#ccc;font-size:13px;text-align:center;margin:10px 0 0 0'>"
         "Every dollar you lose on fast-filled trades goes to the broker's B-book.<br>"
         "Every dollar shaved from delayed wins is additional slippage profit.<br>"
         "<b>On just 10 trades: you lose $680 &mdash; the broker gains $1,950.</b></p>\r\n");
      FileWriteString(h, "</div>\r\n"); // end bar chart section

      // Follow the Money flow diagram
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff8800;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff8800;font-size:16px;font-weight:bold;text-align:center;margin:0 0 15px 0'>Follow the Money</p>\r\n");
      FileWriteString(h, "<div style='display:flex;align-items:center;justify-content:center;gap:0;margin:15px 0;flex-wrap:wrap'>\r\n");
      FileWriteString(h, "<div style='background:#111827;border:1px solid #444;border-radius:8px;padding:8px 12px;text-align:center;min-width:100px'>"
         "<div style='font-size:10px;color:#888;margin-bottom:3px'>You place trade</div>"
         "<div style='font-size:12px;font-weight:bold;color:#ccc'>Buy @ $2,000</div></div>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:22px;padding:0 4px'>&rarr;</div>\r\n");
      FileWriteString(h, "<div style='background:#111827;border:1px solid #ff8800;border-radius:8px;padding:8px 12px;text-align:center;min-width:100px'>"
         "<div style='font-size:10px;color:#888;margin-bottom:3px'>Broker checks</div>"
         "<div style='font-size:12px;font-weight:bold;color:#ff8800'>Win or loss?</div></div>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:22px;padding:0 4px'>&rarr;</div>\r\n");
      FileWriteString(h, "<div style='display:flex;flex-direction:column;gap:8px'>\r\n");
      FileWriteString(h, "<div style='background:#111827;border:1px solid #00cc00;border-radius:8px;padding:8px 12px;text-align:center;min-width:100px'>"
         "<div style='font-size:10px;color:#888;margin-bottom:3px'>Your loss?</div>"
         "<div style='font-size:12px;font-weight:bold;color:#00cc00'>Fill FAST &#10004;</div></div>\r\n");
      FileWriteString(h, StringFormat("<div style='background:#111827;border:1px solid #ff4444;border-radius:8px;padding:8px 12px;text-align:center;min-width:100px'>"
         "<div style='font-size:10px;color:#888;margin-bottom:3px'>Your win?</div>"
         "<div style='font-size:12px;font-weight:bold;color:#ff4444'>HOLD %s</div></div>\r\n", p2SlowStr));
      FileWriteString(h, "</div>\r\n");
      FileWriteString(h, "<div style='color:#ff8800;font-size:22px;padding:0 4px'>&rarr;</div>\r\n");
      FileWriteString(h, "<div style='background:#2a1515;border:1px solid #ff4444;border-radius:8px;padding:8px 12px;text-align:center;min-width:100px'>"
         "<div style='font-size:10px;color:#888;margin-bottom:3px'>Net result</div>"
         "<div style='font-size:12px;font-weight:bold;color:#ff4444'>You lose. Always.</div></div>\r\n");
      FileWriteString(h, "</div></div>\r\n");

      // Rigged Roulette analogy
      FileWriteString(h, "<div style='background:#1a2a1a;border:1px solid #338833;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
      FileWriteString(h, "<p style='color:#44aa44;font-weight:bold;margin-bottom:8px;font-size:14px'>&#128161; Analogy: The Rigged Roulette Table</p>\r\n");
      FileWriteString(h, "<p style='color:#ccc;font-size:13px;line-height:1.7'>"
         "The ball settles in <b>2 seconds</b> when you bet on a losing number &mdash; locked in, no take-backs. "
         "But when you bet on a winning number, the wheel <b style='color:#88cc88'>&ldquo;malfunctions&rdquo;</b> for <b>30 seconds</b>. "
         "During those 30 seconds, the croupier subtly nudges the ball. You still win sometimes, "
         "but your payout is always smaller than it should be. "
         "The rigging is not in <b style='color:#88cc88'>what</b> you can bet on. It is in <b style='color:#88cc88'>how fast the ball settles</b>.</p>\r\n");
      FileWriteString(h, "</div>\r\n");

      // Self-Benchmark Principle
      FileWriteString(h, "<div style='background:#1a1a2e;border:2px dashed #ff8800;border-radius:8px;padding:15px;margin:15px 0;text-align:center'>\r\n");
      FileWriteString(h, "<p style='color:#ff8800;font-weight:bold;margin-bottom:8px;font-size:13px'>&#9878; The Self-Benchmark Principle</p>\r\n");
      FileWriteString(h, StringFormat("<p style='font-size:12px;line-height:1.7;color:#ccc;margin:0'>"
         "The broker's <b>own fastest execution</b> is the proof against it.<br>"
         "If they fill losses at <span style='color:#00cc00;font-weight:bold'>%s</span>, their systems <b>can</b> do %s.<br>"
         "If they fill wins at <span style='color:#ff4444;font-weight:bold'>%s</span>, that is a <b>choice</b>, not a limitation.<br>"
         "<span style='color:#ff8800;font-weight:bold'>The fastest speed sets the benchmark. Everything slower is intentional.</span></p>\r\n",
         p2FastStr, p2FastStr, p2SlowStr));
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== PATTERN 3: LAGGED FILL CONFIRMATIONS — EA BLINDNESS (UNIVERSAL) =====
   FileWriteString(h, "<div style='margin:40px 0 0 0;padding:15px 0;border-top:3px solid #ff8800'>\r\n");
   FileWriteString(h, "<div style='color:#ff8800;font-size:12px;font-weight:bold;letter-spacing:2px;text-transform:uppercase;margin-bottom:4px'>Pattern 3 &mdash; Information Manipulation (Universal)</div>\r\n");
   FileWriteString(h, "<div style='color:#fff;font-size:20px;font-weight:bold;margin-bottom:4px'>Lagged Fill Confirmations: EA Blindness</div>\r\n");
   FileWriteString(h, "<div style='color:#aaa;font-size:13px'>Applies to ALL lag &mdash; symmetric or asymmetric. ANY delay makes your EA fly blind.</div>\r\n");
   FileWriteString(h, "</div>\r\n");

   FileWriteString(h, "<p style='color:#ccc;font-size:13px;line-height:1.7;margin:12px 0'>Patterns 1 and 2 are about <b>price manipulation</b> &mdash; the broker uses delay to give you worse prices. "
      "This pattern is about <b>information manipulation</b> &mdash; the broker uses delay to make your EA blind to its true position.</p>\r\n");

   FileWriteString(h, "<div style='background:#1a1a2e;border:2px solid #ff4444;border-radius:10px;padding:20px;margin:20px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff4444;font-size:16px;font-weight:bold;margin:0 0 16px 0;text-align:center'>"
      "How Lagged Fill Confirmations Turn Your Profits Into Losses</p>\r\n");

   FileWriteString(h, "<p style='color:#ccc;font-size:14px;line-height:1.6'>Your EA sees the market price <b>in real time</b>. "
      "But when it sends orders, the broker <b>delays sending back fill confirmations</b>. "
      "Without confirmations, your EA doesn't know those positions exist &mdash; "
      "so it calculates profit, trailing stops, and close decisions on <b>incomplete data</b>. "
      "The EA's math is perfect &mdash; but it's solving the wrong equation.</p>\r\n");

   // --- 6-BAR CHART: 3 stages x 2 bars ---
   FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:8px;padding:20px;margin:18px 0'>\r\n");
   FileWriteString(h, "<div style='position:relative;padding:10px 10px 0 10px'>\r\n");
   FileWriteString(h, "<div style='display:flex;justify-content:center;gap:12px'>\r\n");

   // --- STAGE 1: EA sends orders, no confirmations back ---
   FileWriteString(h, "<div style='flex:1;max-width:280px;background:#0d0d1a;border:1px solid #333;border-radius:8px;padding:14px 10px'>\r\n");
   FileWriteString(h, "<div style='text-align:center;margin-bottom:12px'>"
      "<div style='color:#44ff44;font-size:13px;font-weight:bold'>STAGE 1</div>"
      "<div style='color:#aaa;font-size:11px'>EA sends orders &mdash; no confirmations</div></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:14px;height:170px;padding-bottom:4px'>\r\n");
   // EA's calculated P&L bar
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#44ff44;font-size:11px;font-weight:bold;margin-bottom:2px'>+$8</div>"
      "<div style='color:#44ff44;font-size:12px;font-weight:bold;margin-bottom:2px'>3 fills</div>"
      "<div style='width:56px;height:48px;background:linear-gradient(to top,#1a6622,#22cc44);border-radius:4px 4px 0 0;border:1px solid #44ff44;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:white;font-size:9px;font-weight:bold'>PROFIT</span></div>"
      "<div style='width:56px;height:60px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$100<br>BASE</span></div>"
      "<div style='color:#44ff44;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>EA's P&amp;L<br><span style='color:#888;font-size:9px'>(confirmed fills)</span></div>"
      "</div>\r\n");
   // Actual account bar
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#ff8800;font-size:11px;font-weight:bold;margin-bottom:2px'>+$5</div>"
      "<div style='color:#ff8800;font-size:12px;font-weight:bold;margin-bottom:2px'>5 fills</div>"
      "<div style='width:56px;height:30px;background:linear-gradient(to top,#1a6622,#22cc44);border-radius:4px 4px 0 0;border:1px solid #44ff44;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:white;font-size:8px;font-weight:bold'>+$8</span></div>"
      "<div style='width:56px;height:18px;background:#332200;border:2px dashed #ff8800;border-radius:0;border-top:none;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#ff8800;font-size:7px;font-weight:bold'>-$3 UNSEEN</span></div>"
      "<div style='width:56px;height:60px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$100<br>BASE</span></div>"
      "<div style='color:#ff8800;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>Actual P&amp;L<br><span style='color:#888;font-size:9px'>(all fills)</span></div>"
      "</div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close flex bar container
   FileWriteString(h, "<div style='text-align:center;color:#666;font-size:10px;margin-top:8px;border-top:1px solid #222;padding-top:6px'>"
      "EA thinks profit is <b style='color:#44ff44'>+$8</b><br>"
      "Account is actually <b style='color:#ff8800'>+$5</b><br>"
      "<span style='color:#ff8800'>2 fills unconfirmed</span></div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close stage 1

   // --- STAGE 2: Trail triggers — EA decides on wrong P&L ---
   FileWriteString(h, "<div style='flex:1;max-width:280px;background:#0d0d1a;border:1px solid #333;border-radius:8px;padding:14px 10px'>\r\n");
   FileWriteString(h, "<div style='text-align:center;margin-bottom:12px'>"
      "<div style='color:#ff8800;font-size:13px;font-weight:bold'>STAGE 2</div>"
      "<div style='color:#aaa;font-size:11px'>Trail triggers &mdash; EA decides on wrong P&amp;L</div></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:14px;height:170px;padding-bottom:4px'>\r\n");
   // EA's P&L bar with TRAIL HIT
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#ffcc00;font-size:10px;font-weight:bold;margin-bottom:1px'>TRAIL HIT!</div>"
      "<div style='color:#44ff44;font-size:12px;font-weight:bold;margin-bottom:2px'>+$5</div>"
      "<div style='width:56px;height:30px;background:linear-gradient(to top,#1a6622,#22cc44);border-radius:4px 4px 0 0;border:1px solid #44ff44;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:white;font-size:9px;font-weight:bold'>+$5</span></div>"
      "<div style='width:56px;height:60px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$100<br>BASE</span></div>"
      "<div style='color:#44ff44;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>EA's P&amp;L<br><span style='color:#888;font-size:9px'>(3 confirmed)</span></div>"
      "</div>\r\n");
   // Actual account bar — losing
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#ff4444;font-size:11px;font-weight:bold;margin-bottom:2px'>-$1</div>"
      "<div style='color:#ff8800;font-size:12px;font-weight:bold;margin-bottom:2px'>5 fills</div>"
      "<div style='width:56px;height:6px;background:linear-gradient(to top,#1a4422,#228833);border-radius:4px 4px 0 0;border:1px solid #44aa44;border-bottom:none'></div>"
      "<div style='width:56px;height:36px;background:repeating-linear-gradient(45deg,#ff444430,#ff444430 4px,#44111120 4px,#44111120 8px);border:1px dashed #ff4444;border-radius:0;display:flex;align-items:center;justify-content:center;border-bottom:none;border-top:none'>"
      "<span style='color:#ff6666;font-size:7px;font-weight:bold;text-align:center;line-height:1.2'>UNSEEN<br>FILLS<br>LOSING</span></div>"
      "<div style='width:56px;height:60px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$100<br>BASE</span></div>"
      "<div style='color:#ff4444;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>Actual P&amp;L<br><span style='color:#888;font-size:9px'>(all fills)</span></div>"
      "</div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close flex bar container
   FileWriteString(h, "<div style='text-align:center;color:#ff8800;font-size:10px;margin-top:8px;border-top:1px solid #222;padding-top:6px;font-weight:bold'>"
      "EA closes at <b style='color:#44ff44'>+$5</b><br>"
      "Account is actually <b style='color:#ff4444'>-$1</b></div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close stage 2

   // --- STAGE 3: Confirmations arrive — actual damage revealed ---
   FileWriteString(h, "<div style='flex:1;max-width:280px;background:#1a0a0a;border:2px solid #ff4444;border-radius:8px;padding:14px 10px'>\r\n");
   FileWriteString(h, "<div style='text-align:center;margin-bottom:12px'>"
      "<div style='color:#ff4444;font-size:13px;font-weight:bold'>STAGE 3</div>"
      "<div style='color:#aaa;font-size:11px'>Confirmations arrive &mdash; damage revealed</div></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:flex-end;justify-content:center;gap:14px;height:170px;padding-bottom:4px'>\r\n");
   // What EA thought
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#44ff44;font-size:11px;font-weight:bold;margin-bottom:2px'>+$5</div>"
      "<div style='color:#44ff44;font-size:12px;font-weight:bold;margin-bottom:2px'>3 fills</div>"
      "<div style='width:56px;height:30px;background:linear-gradient(to top,#1a6622,#22cc44);border-radius:4px 4px 0 0;border:1px solid #44ff44;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:white;font-size:9px;font-weight:bold'>+$5</span></div>"
      "<div style='width:56px;height:60px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$100<br>BASE</span></div>"
      "<div style='color:#888;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>EA thought<br><span style='color:#44ff44;font-size:9px'>&ldquo;+$5 profit&rdquo;</span></div>"
      "</div>\r\n");
   // Actual result — capital lost
   FileWriteString(h, "<div style='display:flex;flex-direction:column;align-items:center'>"
      "<div style='color:#ff4444;font-size:11px;font-weight:bold;margin-bottom:2px'>-$4!</div>"
      "<div style='color:#ff4444;font-size:12px;font-weight:bold;margin-bottom:2px'>5 fills</div>"
      "<div style='width:56px;height:24px;background:repeating-linear-gradient(45deg,#ff444440,#ff444440 4px,#44111140 4px,#44111140 8px);border-radius:4px 4px 0 0;border:1px solid #ff4444;border-bottom:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#ff6666;font-size:9px;font-weight:bold'>-$4 LOST</span></div>"
      "<div style='width:56px;height:36px;background:linear-gradient(to top,#333,#555);border-radius:0;border:1px solid #666;border-top:none;display:flex;align-items:center;justify-content:center'>"
      "<span style='color:#aaa;font-size:9px;font-weight:bold'>$96<br>left</span></div>"
      "<div style='color:#ff4444;font-size:10px;margin-top:4px;font-weight:bold;text-align:center'>Account<br><span style='color:#ff4444;font-size:9px'>actual result</span></div>"
      "</div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close flex bar container
   FileWriteString(h, "<div style='text-align:center;margin-top:8px;border-top:1px solid #442222;padding-top:6px'>"
      "<div style='color:#ff4444;font-size:13px;font-weight:bold'>EA calculated +$5 profit</div>"
      "<div style='color:#ff4444;font-size:15px;font-weight:bold;margin-top:2px'>Account shows -$4 LOSS</div>"
      "<div style='color:#ff8800;font-size:10px;margin-top:3px'>Unseen fills destroyed the profit<br>AND ate into your capital</div></div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close stage 3

   FileWriteString(h, "</div>\r\n"); // close 3-stage flex container
   FileWriteString(h, "</div>\r\n"); // close position:relative

   // Bar legend
   FileWriteString(h, "<div style='display:flex;justify-content:center;gap:20px;margin-top:14px;padding-top:10px;border-top:1px solid #333;flex-wrap:wrap'>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:center;gap:6px'>"
      "<div style='width:16px;height:12px;background:linear-gradient(to top,#333,#555);border:1px solid #666;border-radius:2px'></div>"
      "<span style='color:#aaa;font-size:12px'>Base ($100 entry)</span></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:center;gap:6px'>"
      "<div style='width:16px;height:12px;background:linear-gradient(to top,#1a6622,#22cc44);border:1px solid #44ff44;border-radius:2px'></div>"
      "<span style='color:#44ff44;font-size:12px'>Confirmed profit</span></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:center;gap:6px'>"
      "<div style='width:16px;height:12px;border:2px dashed #ff8800;border-radius:2px'></div>"
      "<span style='color:#ff8800;font-size:12px'>Unconfirmed fill losses (EA can't see)</span></div>\r\n");
   FileWriteString(h, "<div style='display:flex;align-items:center;gap:6px'>"
      "<div style='width:16px;height:12px;background:repeating-linear-gradient(45deg,#ff444433,#ff444433 3px,#ff222222 3px,#ff222222 6px);border:1px solid #ff4444;border-radius:2px'></div>"
      "<span style='color:#ff4444;font-size:12px'>Capital lost</span></div>\r\n");
   FileWriteString(h, "</div>\r\n"); // close legend

   // Damage callout
   FileWriteString(h, "<div style='text-align:center;margin-top:14px;padding:12px;background:#2a0a0a;border:1px solid #ff4444;border-radius:6px'>"
      "<span style='color:#ff4444;font-size:18px;font-weight:bold'>$9 per unit stolen by delayed confirmations</span><br>"
      "<span style='color:#ff8800;font-size:13px'>EA calculated +$5 profit &rarr; account shows -$4 loss</span></div>\r\n");

   FileWriteString(h, "</div>\r\n"); // close bar chart container

   // --- STEP BY STEP TABLE ---
   FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:6px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff9900;font-weight:bold;margin:0 0 10px 0'>Step by Step &mdash; What Goes Wrong:</p>\r\n");
   FileWriteString(h, "<table style='width:100%;font-size:13px;border-collapse:collapse'>\r\n");
   FileWriteString(h, "<tr><th style='text-align:left;color:#aaa;width:8%;padding:6px;border-bottom:1px solid #333'>Step</th>"
      "<th style='text-align:left;color:#44ff44;width:46%;padding:6px;border-bottom:1px solid #333'>What Your EA Knows (confirmed fills only)</th>"
      "<th style='text-align:left;color:#ff4444;width:46%;padding:6px;border-bottom:1px solid #333'>What Your Account Actually Has</th></tr>\r\n");
   FileWriteString(h, "<tr style='border-bottom:1px solid #222'>"
      "<td style='color:#44ff44;padding:6px;font-weight:bold'>1</td>"
      "<td style='color:#ccc;padding:6px'>Price climbing. EA sends 5 buy orders. Broker confirms 3 fills. EA calculates P&amp;L on <b>3 positions</b>.</td>"
      "<td style='color:#ff8800;padding:6px'>Account actually has <b>5 positions</b> &mdash; but 2 fill confirmations haven't arrived yet. EA doesn't know they exist.</td></tr>\r\n");
   FileWriteString(h, "<tr style='border-bottom:1px solid #222'>"
      "<td style='color:#44ff44;padding:6px;font-weight:bold'>2</td>"
      "<td style='color:#ccc;padding:6px'>EA sees price retracing. Trailing stop calculation based on <b>3 confirmed positions</b> shows +$5 &rarr; <b>trail triggers, EA closes.</b></td>"
      "<td style='color:#ff4444;padding:6px'>The 2 unseen positions are <b>losing money</b> as price drops. True account P&amp;L is already below what EA calculated.</td></tr>\r\n");
   FileWriteString(h, "<tr style='border-bottom:1px solid #222'>"
      "<td style='color:#ff8800;padding:6px;font-weight:bold'>3</td>"
      "<td style='color:#ccc;padding:6px'>EA closes 3 confirmed positions at profit. EA logs: <b>&ldquo;+$5 profit, good trade.&rdquo;</b></td>"
      "<td style='color:#ff4444;padding:6px'>3 profitable closes + 2 unconfirmed losing positions still open. Net P&amp;L is <b>negative</b>.</td></tr>\r\n");
   FileWriteString(h, "<tr style='border-bottom:1px solid #222'>"
      "<td style='color:#ff4444;padding:6px;font-weight:bold'>4</td>"
      "<td style='color:#ccc;padding:6px'>Delayed confirmations finally arrive. EA now sees: <b>&ldquo;Wait &mdash; I have 2 extra positions I didn't know about?&rdquo;</b></td>"
      "<td style='color:#ff4444;padding:6px'>Those 2 positions were filled at bad prices and are deep in the red. They <b>wipe out the +$5 profit and eat $4 of capital</b>.</td></tr>\r\n");
   FileWriteString(h, "<tr><td style='color:#ff4444;padding:6px;font-weight:bold'>5</td>"
      "<td colspan='2' style='padding:6px'><span style='color:#ff4444;font-size:15px;font-weight:bold'>EA calculated +$5 profit &rarr; Account shows -$4 LOSS</span>"
      "<span style='color:#888;font-size:12px;display:block;margin-top:4px'>The EA's logic was perfect. Its trailing stop worked correctly. "
      "But it was making decisions based on <b>3 confirmed fills instead of 5 actual fills</b>. "
      "The broker's delayed confirmations made the EA blind to its true position &mdash; and blind decisions lead to losses.</span></td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, "</div>\r\n"); // close step-by-step

   // --- ANALOGY ---
   FileWriteString(h, "<div style='background:#0d1a0d;border:1px solid #336633;border-radius:6px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#44ff44;font-weight:bold;margin:0 0 8px 0;font-size:14px'>Think of It Like This:</p>\r\n");
   FileWriteString(h, "<p style='color:#ccc;font-size:14px;line-height:1.7;margin:0'>"
      "You order <b>5 items from a supplier to resell</b> at a markup. It's cash on delivery &mdash; you pay when they arrive. "
      "The first <b>3 items arrive on time</b>. You pay for them, mark them up, sell them, and <b>make a nice profit</b>.<br><br>"
      "But you ordered 5 &mdash; and the supplier is still delivering the other 2. By the time the <b>last 2 items arrive</b>, "
      "the market price has <b>dropped</b>. You're obligated to pay the original price for them, but now you can "
      "<b>only sell them at a loss</b>. Those 2 late deliveries <b style='color:#ff4444'>wipe out all the profit</b> you made on the first 3 "
      "&mdash; and then some.<br><br>"
      "<b style='color:#ff8800'>The broker is that supplier.</b> Your EA ordered 5 positions. Only 3 confirmations came back on time. "
      "The EA calculated its profit on 3, made its decisions, and closed the trade. Then the 2 late confirmations arrived "
      "&mdash; positions you're committed to, at prices that are now underwater. You can't refuse them. "
      "They eat the profit and bite into your capital.</p>\r\n");
   FileWriteString(h, "</div>\r\n"); // close analogy

   // --- DOUBLE WHAMMY ---
   FileWriteString(h, "<div style='background:#1a1a0a;border:1px solid #665500;border-radius:6px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff8800;font-weight:bold;margin:0 0 8px 0;font-size:14px'>The Double Whammy &mdash; Clustering + Lag</p>\r\n");
   FileWriteString(h, "<p style='color:#ccc;font-size:14px;line-height:1.7;margin:0'>"
      "The broker's lag causes <b>two separate problems</b> that compound each other:</p>\r\n");
   FileWriteString(h, "<table style='width:100%;font-size:13px;border-collapse:collapse;margin:10px 0'>\r\n");
   FileWriteString(h, "<tr><td style='padding:8px;border:1px solid #333;width:50%;vertical-align:top'>"
      "<b style='color:#ff8800'>1. Fill Clustering</b><br>"
      "<span style='color:#ccc'>Because the broker holds orders, multiple fills arrive at the same time at the same price. "
      "This is the visible evidence &mdash; fills that should have been spread across different prices are <b>batched together</b>. "
      "Even if the broker spreads some fills to different prices to make it look natural, the clustering pattern is still detectable.</span>"
      "</td>\r\n");
   FileWriteString(h, "<td style='padding:8px;border:1px solid #333;width:50%;vertical-align:top'>"
      "<b style='color:#ff4444'>2. Blind EA Decisions</b><br>"
      "<span style='color:#ccc'>This is the real damage. Regardless of where the fills land, the <b>delayed confirmations</b> mean the EA doesn't know its true position size. "
      "It calculates trailing stops, profit targets, and close decisions on <b>incomplete data</b>. "
      "Every decision after a missing confirmation is wrong &mdash; not because the EA's logic is flawed, but because the inputs are incomplete.</span>"
      "</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, "<p style='color:#ff4444;font-size:13px;margin:8px 0 0 0'><b>Clustering is the symptom. Blind decisions are the damage. "
      "Both are caused by the same root: the broker holding your orders.</b></p>\r\n");
   FileWriteString(h, "</div>\r\n"); // close double whammy

   FileWriteString(h, "<p style='color:#ff8800;font-size:14px;line-height:1.6;margin:15px 0 0 0'><b>A fair broker confirms fills immediately.</b> "
      "Without instant confirmations, your EA cannot calculate its true position size, true profit, or true risk. "
      "Every trailing stop, every breakeven move, every close decision is made on <b>incomplete information</b>. "
      "The EA's logic is perfect &mdash; but perfect logic on partial data produces losses.</p>\r\n");
   FileWriteString(h, "</div>\r\n\r\n"); // close main container

   // ===== TOPIC 3: SL vs TP EXECUTION LAG =====
   FileWriteString(h, "<h3 style='color:#ff8800'>Topic #3: SL vs TP Execution &mdash; Asymmetric Delay</h3>\r\n");
   FileWriteString(h, "<p>Every trader sets two safety levels on their trades:</p>\r\n");
   FileWriteString(h, "<ul>\r\n");
   FileWriteString(h, "<li><b>Stop-Loss (SL):</b> \"Close my trade if I'm losing $X\" &mdash; delayed ~100-400ms (benefits broker)</li>\r\n");
   FileWriteString(h, "<li><b>Take-Profit (TP):</b> \"Close my trade if I'm winning $X\" &mdash; fills near-instantly ~0-5ms (costs broker)</li>\r\n");
   FileWriteString(h, "</ul>\r\n");
   FileWriteString(h, "<p>The broker processes orders that <b>cost</b> it (TP) instantly, but delays orders that <b>profit</b> it (SL). "
      "This asymmetry benefits the broker in two ways:</p>\r\n");
   FileWriteString(h, "<ol style='color:#ccc'>\r\n");
   FileWriteString(h, "<li><b>Direct slippage:</b> If the SL fills at market price after the delay, the trader loses the price movement during the hold.</li>\r\n");
   FileWriteString(h, "<li><b>Out-of-sequence fills:</b> SL fills held with lag can arrive <b>after</b> an EA has already closed positions on a retracement, "
      "creating unwanted new positions against the trader.</li>\r\n");
   FileWriteString(h, "</ol>\r\n");

   FileWriteString(h, "<div style='background:#2a1a1a;border:1px solid #553333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff4444;margin:0 0 10px 0'><b>Why &ldquo;Fills at Trigger Price&rdquo; Does NOT Make Lag Harmless</b></p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>Brokers argue that if a delayed fill arrives at the trigger price, there is no harm. "
      "<b>This is false.</b> The harm comes from <b>when</b> the fill arrives, not <b>what price</b> it arrives at.</p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>Both lag asymmetry and drift are <b>independent red flags</b>:</p>\r\n");
   FileWriteString(h, "<ul style='color:#ccc;margin:5px 0'>\r\n");
   FileWriteString(h, "<li style='color:#ff8800'><b>Asymmetric lag</b> &mdash; broker-profitable orders delayed longer than broker-costly orders. "
      "Delayed counter fills arrive after an EA has closed positions, creating unwanted exposure.</li>\r\n");
   FileWriteString(h, "<li style='color:#ff4444'><b>Execution drift</b> &mdash; fill price deviates from trigger/receipt price. "
      "Direct financial loss on every drifted fill.</li>\r\n");
   FileWriteString(h, "</ul>\r\n");

   // Concrete worked example — the out-of-sequence fill scenario
   FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:6px;padding:12px;margin:10px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff9900;margin:0 0 8px 0'><b>Worked Example: How a &ldquo;Perfect&rdquo; Trigger Fill Causes Losses</b></p>\r\n");
   FileWriteString(h, "<table style='width:100%;font-size:13px;margin:8px 0'>\r\n");
   FileWriteString(h, "<tr><th style='text-align:left;color:#44ff44;width:50%'>Fair Broker (5ms lag)</th>");
   FileWriteString(h, "<th style='text-align:left;color:#ff4444;width:50%'>Asymmetric Broker (300ms lag on stops)</th></tr>\r\n");

   FileWriteString(h, "<tr><td style='color:#ccc'>\r\n");
   FileWriteString(h, "1. EA has 5 buy positions in profit<br>\r\n");
   FileWriteString(h, "2. Sell stops trigger at $2,650<br>\r\n");
   FileWriteString(h, "3. Fills arrive in <b>5ms</b> at $2,650<br>\r\n");
   FileWriteString(h, "4. EA sees retracement, closes all buys<br>\r\n");
   FileWriteString(h, "5. Sell fills already processed &mdash; accounted for<br>\r\n");
   FileWriteString(h, "<b style='color:#44ff44'>Result: Clean exit, no surprises</b>\r\n");
   FileWriteString(h, "</td><td style='color:#ccc'>\r\n");
   FileWriteString(h, "1. EA has 5 buy positions in profit<br>\r\n");
   FileWriteString(h, "2. Sell stops trigger at $2,650<br>\r\n");
   FileWriteString(h, "3. Broker <span style='color:#ff4444'>holds sells for 300ms</span><br>\r\n");
   FileWriteString(h, "4. EA sees retracement, closes all buys<br>\r\n");
   FileWriteString(h, "5. <b style='color:#ff4444'>Delayed sell fills now arrive</b> at $2,650<br>\r\n");
   FileWriteString(h, "6. Trader has 5 unwanted short positions<br>\r\n");
   FileWriteString(h, "<b style='color:#ff4444'>Result: Unintended exposure, potential huge loss</b>\r\n");
   FileWriteString(h, "</td></tr></table>\r\n");

   FileWriteString(h, "<p style='color:#ff8800;font-size:12px;margin:6px 0 0 0'>"
      "Both fills were at the &ldquo;correct&rdquo; trigger price of $2,650. <b>The price was identical.</b> "
      "But the 300ms delay meant the sell fills arrived <b>after</b> the EA had already closed. "
      "The trader now holds positions they never intended. "
      "The lag &mdash; not the fill price &mdash; caused the damage.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   FileWriteString(h, "<p style='color:#ccc'>A fair broker processes <b>all</b> order types at the same speed. "
      "When broker-profitable orders are consistently delayed while broker-costly orders execute instantly, "
      "the delay itself is the mechanism of harm &mdash; regardless of fill price accuracy.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   FileWriteString(h, "<div style='background:#2a1a1a;border:1px solid #553333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff8800;margin:0 0 10px 0'><b>How Brokers Disguise Drift as \"Market Volatility\"</b></p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>When you complain about the price difference on a stop-loss, the broker will tell you: ");
   FileWriteString(h, "&ldquo;<i>That&rsquo;s normal market movement due to volatility. We have no control over the market price.</i>&rdquo; ");
   FileWriteString(h, "This is technically true &mdash; the broker does not control the market price. ");
   FileWriteString(h, "But <b>the broker controls how long they hold your order AND what price they fill at</b>. ");
   FileWriteString(h, "An honest broker with a slow server fills at the receipt price. A manipulating broker fills at the drifted price.</p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>If market volatility were truly the cause, it would affect ");
   FileWriteString(h, "<b>ALL order types equally</b>. Take-profits, limit orders, stop-losses, and stop orders ");
   FileWriteString(h, "all trigger at market price levels and all execute through the same trading infrastructure.</p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>The forensic test: compare execution lag across order types that ");
   FileWriteString(h, "<b>profit the broker</b> (stop-losses, stop orders) versus those that <b>cost the broker</b> ");
   FileWriteString(h, "(take-profits, limit orders).</p>\r\n");
   FileWriteString(h, "<ul style='color:#ccc'>\r\n");
   FileWriteString(h, "<li>If it were volatility: drift lag should be equal across all order types (same market conditions)</li>\r\n");
   FileWriteString(h, "<li>If it were honest slow execution: drift lag &asymp; 0 regardless of execution time (fills at receipt price)</li>\r\n");
   FileWriteString(h, "<li>If it were manipulation: <b>broker-profitable orders show high drift lag, broker-costly orders show zero drift</b></li>\r\n");
   FileWriteString(h, "</ul>\r\n");

   // Use actual measured data for the damning comparison
   FileWriteString(h, "<div style='background:#111;border:1px solid #444;border-radius:6px;padding:12px;margin:10px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff4444;margin:0 0 8px 0'><b>What This Test Measured</b></p>\r\n");
   FileWriteString(h, "<table style='width:100%;font-size:13px'>\r\n");
   FileWriteString(h, "<tr><th style='text-align:left;color:#ff8800;width:50%'>Stop-like Orders (route via LP)</th>");
   FileWriteString(h, "<th style='text-align:left;color:#44aaff;width:50%'>Limit-like Orders (passive fill)</th></tr>\r\n");
   FileWriteString(h, StringFormat("<tr><td style='color:#ff6644'>Stop orders: <b>%s</b> lag</td>", FormatMs(medStopLag)));
   FileWriteString(h, StringFormat("<td style='color:#44ff44'>Limit orders: <b>%s</b> lag</td></tr>\r\n", FormatMs(medLimitLag)));
   if(g_lagValidCount[7] > 0 && g_lagValidCount[6] > 0)
   {
      FileWriteString(h, StringFormat("<tr><td style='color:#ff6644'>Stop-loss (SL): <b>%s</b> lag</td>", FormatMs(medSLLag)));
      FileWriteString(h, StringFormat("<td style='color:#44ff44'>Take-profit (TP): <b>%s</b> lag</td></tr>\r\n", FormatMs(medTPLag)));
   }
   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, "<p style='color:#ff8800;font-size:12px;margin:6px 0 0 0'>Asymmetric lag between stop-like and limit-like orders always benefits the broker. "
      "Delayed counter fills arriving after EA close operations create unwanted exposure. "
      "Both the lag asymmetry and any price drift are independent red flags.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   FileWriteString(h, "<p style='color:#ccc'>A trigger-price fill does <b>not</b> make the lag harmless. "
      "The delay means counter fills (SL, stops) can arrive <b>after</b> the EA has already acted on a retracement &mdash; "
      "creating unwanted positions the trader never intended to hold. "
      "If the fill also drifts from the trigger price, that is additional damage on top of the timing harm.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   // Regulatory framework comparison
   FileWriteString(h, "<div style='background:#1a2a1a;border:1px solid #335533;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#66cc66;margin:0 0 10px 0'><b>Regulatory Standards &amp; Fair Practice Rules</b></p>\r\n");
   FileWriteString(h, "<p style='color:#ccc'>The execution behavior measured above must be assessed against established regulatory frameworks that govern broker conduct:</p>\r\n");
   FileWriteString(h, "<table style='width:100%;font-size:13px'>\r\n");
   FileWriteString(h, "<tr><th style='text-align:left;color:#66cc66'>Regulation</th><th style='text-align:left;color:#66cc66'>Requirement</th><th style='text-align:left;color:#66cc66'>Measured Behavior</th></tr>\r\n");

   // MiFID II
   FileWriteString(h, "<tr><td style='color:#aaa'><b>MiFID II Art. 27</b><br>(EU Best Execution)</td>");
   FileWriteString(h, "<td style='color:#ccc'>Brokers must take <b>all sufficient steps</b> to obtain the best possible result for clients, ");
   FileWriteString(h, "considering price, costs, speed, and likelihood of execution.</td>");
   FileWriteString(h, StringFormat("<td style='color:#ccc'>Stop orders held %.1fs while limits fill &lt;1ms. ", medStopLag / 1000.0));
   FileWriteString(h, "Speed of execution varies by <b>order type profitability to the broker</b>, not by market conditions.</td></tr>\r\n");

   // FCA COBS 11.2A
   FileWriteString(h, "<tr><td style='color:#aaa'><b>FCA COBS 11.2A</b><br>(UK Best Execution)</td>");
   FileWriteString(h, "<td style='color:#ccc'>Firms must not structure or charge commissions in a way which discriminates ");
   FileWriteString(h, "unfairly between execution venues. Execution must be <b>consistent and non-discriminatory</b> across order types.</td>");
   FileWriteString(h, "<td style='color:#ccc'>Systematic discrimination: broker-profitable orders (SL/stops) receive materially different ");
   FileWriteString(h, "execution speed than broker-costly orders (TP/limits).</td></tr>\r\n");

   // ESMA Guidelines
   FileWriteString(h, "<tr><td style='color:#aaa'><b>ESMA CFD Measures</b><br>(2018, renewed)</td>");
   FileWriteString(h, "<td style='color:#ccc'>CFD providers must act honestly, fairly, and professionally. ");
   FileWriteString(h, "<b>Asymmetric execution lag</b> &mdash; deliberately delaying only broker-profitable orders &mdash; constitutes an unfair practice.</td>");
   FileWriteString(h, "<td style='color:#ccc'>Holding stop orders with <b>asymmetric lag</b> guarantees adverse price movement ");
   FileWriteString(h, "on every broker-profitable fill. The lag is constant and intentional; the price movement is the broker's engineered profit.</td></tr>\r\n");

   // NFA (US)
   FileWriteString(h, "<tr><td style='color:#aaa'><b>NFA Rule 2-36(e)</b><br>(US Forex Dealers)</td>");
   FileWriteString(h, "<td style='color:#ccc'>Forex dealer members must observe <b>high standards of commercial honor</b> and ");
   FileWriteString(h, "just and equitable principles of trade. Price adjustments must be applied symmetrically.</td>");
   FileWriteString(h, "<td style='color:#ccc'>Order holding is applied selectively based on whether the fill profits or costs the broker. ");
   FileWriteString(h, "This is neither symmetric nor equitable.</td></tr>\r\n");

   // FSCA (South Africa)
   FileWriteString(h, "<tr><td style='color:#aaa'><b>FSCA FAIS Act</b><br>(South Africa)</td>");
   FileWriteString(h, "<td style='color:#ccc'>Financial service providers must act with due skill, care, and diligence, ");
   FileWriteString(h, "and treat clients <b>fairly</b> (Treating Customers Fairly / TCF framework).</td>");
   FileWriteString(h, "<td style='color:#ccc'>Selectively delaying order execution based on broker P&amp;L outcome ");
   FileWriteString(h, "is a direct violation of the fairness principle.</td></tr>\r\n");

   // ASIC (Australia)
   FileWriteString(h, "<tr><td style='color:#aaa'><b>Corporations Act s912A</b><br>(ASIC, Australia)</td>");
   FileWriteString(h, "<td style='color:#ccc'>AFSL holders must provide financial services <b>efficiently, honestly and fairly</b>. ");
   FileWriteString(h, "ASIC Product Intervention Order 2020/986 imposes leverage limits, mandatory margin close-out at 50%, and negative balance protection.</td>");
   FileWriteString(h, "<td style='color:#ccc'>Asymmetric execution — holding stop orders longer than limit orders — ");
   FileWriteString(h, "is neither honest nor fair. ASIC fined AGM Markets A$75M for unconscionable conduct in OTC derivatives.</td></tr>\r\n");

   FileWriteString(h, "</table>\r\n");

   FileWriteString(h, "<p style='color:#aaa;font-size:12px;margin-top:10px'><b>Key principle across all jurisdictions:</b> ");
   FileWriteString(h, "A broker acting as principal (B-book) has a direct <b>conflict of interest</b> with the client. ");
   FileWriteString(h, "Regulations require this conflict to be managed such that it does not disadvantage the client. ");
   FileWriteString(h, "When execution speed is demonstrably correlated with whether an order profits or costs the broker, ");
   FileWriteString(h, "the conflict is not being managed &mdash; it is being <b>exploited</b>.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   // TP/SL exec lag results
   if(g_countByType[6] > 0 || g_countByType[7] > 0)
   {
      FileWriteString(h, "<p><b>Execution lag (trigger to fill):</b> ");
      if(g_countByType[7] > 0)
         FileWriteString(h, StringFormat("Stop-loss exec: <b>%s</b> (n=%d). ", FormatMs(medSLLag), g_countByType[7]));
      if(g_countByType[6] > 0)
         FileWriteString(h, StringFormat("Take-profit exec: <b>%s</b> (n=%d). ", FormatMs(medTPLag), g_countByType[6]));
      FileWriteString(h, StringFormat("(Standard: &lt;%dms). ", STD_TPSL_GOOD_MS));
      // Check drift harmlessness for TP/SL narrative
      bool tpslNarrativeHarmless = false;
      {
         bool nTpH = false, nSlH = false;
         int nTpC = g_triggerFillCount[6] + g_marketFillCount[6];
         if(nTpC > 0) nTpH = ((double)g_triggerFillCount[6] / nTpC * 100.0 >= 99.0);
         else if(g_driftLagCount[6] > 0) nTpH = (g_driftLagSum[6] / g_driftLagCount[6] < 5.0);
         int nSlC = g_triggerFillCount[7] + g_marketFillCount[7];
         if(nSlC > 0) nSlH = ((double)g_triggerFillCount[7] / nSlC * 100.0 >= 99.0);
         else if(g_driftLagCount[7] > 0) nSlH = (g_driftLagSum[7] / g_driftLagCount[7] < 5.0);
         tpslNarrativeHarmless = nTpH && nSlH;
      }
      if(medSLLag > STD_TPSL_MANIP_MS || medTPLag > STD_TPSL_MANIP_MS)
      {
         if(tpslNarrativeHarmless)
            FileWriteString(h, StringFormat("<span style='color:#ccaa00'>Slow execution (%dms+) but fills at trigger price — no adverse effect.</span>", STD_TPSL_MANIP_MS));
         else
            FileWriteString(h, StringFormat("<span style='color:#ff4444'><b>FAIL — Exceeds industry standard (%dms).</b></span>", STD_TPSL_MANIP_MS));
      }
      else if(medSLLag > STD_TPSL_SLOW_MS || medTPLag > STD_TPSL_SLOW_MS)
      {
         if(tpslNarrativeHarmless)
            FileWriteString(h, "<span style='color:#ccaa00'>Above standard but fills at trigger price — no adverse effect.</span>");
         else
            FileWriteString(h, "<span style='color:#ff8800'>Above recommended standard.</span>");
      }
      else
         FileWriteString(h, "<span style='color:#00cc00'>Within acceptable limits.</span>");
      FileWriteString(h, "</p>\r\n");
   }
   FileWriteString(h, "\r\n");

   // ===== MANIPULATION TACTIC 4: CLOSE DELAY =====
   FileWriteString(h, "<h3 style='color:#ff4444'>Manipulation Tactic #4: Close Delay</h3>\r\n");
   FileWriteString(h, "<p>When you want to close (exit) a trade, the broker should do it immediately. But a B-book ");
   FileWriteString(h, "broker may deliberately slow down the closing process.</p>\r\n");
   FileWriteString(h, "<p><b>Why?</b> If you're trying to close a <i>winning</i> trade, every millisecond of delay ");
   FileWriteString(h, "gives the price a chance to move against you, reducing your profit. The broker keeps the ");
   FileWriteString(h, "difference.</p>\r\n");

   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 10px 0'><b>Example: Closing a Winning Trade</b></p>\r\n");
   FileWriteString(h, "<p>You bought gold at $2,000. It's now $2,005 and you want to lock in your $5 profit.</p>\r\n");
   FileWriteString(h, "<table style='width:100%'>\r\n");
   FileWriteString(h, "<tr><th>Fair Broker</th><th>Manipulative Broker</th></tr>\r\n");
   FileWriteString(h, "<tr><td>\r\n");
   FileWriteString(h, "You click Close<br>\r\n");
   FileWriteString(h, "Filled in 200ms at $2,005.00<br>\r\n");
   FileWriteString(h, "<b style='color:#00cc00'>You keep your full $5 profit</b>\r\n");
   FileWriteString(h, "</td><td>\r\n");
   FileWriteString(h, "You click Close<br>\r\n");
   FileWriteString(h, "Broker <span style='color:#ff4444'>waits 2 seconds</span><br>\r\n");
   FileWriteString(h, "Price drops to $2,004.20<br>\r\n");
   FileWriteString(h, "Filled at $2,004.20<br>\r\n");
   FileWriteString(h, "<b style='color:#ff4444'>You lost $0.80 of your profit</b><br>\r\n");
   FileWriteString(h, "The broker saved $0.80 they would have owed you\r\n");
   FileWriteString(h, "</td></tr></table>\r\n");
   FileWriteString(h, "</div>\r\n");

   // Async batch close result
   FileWriteString(h, StringFormat("<p><b>Async batch close:</b> Median delay was <b>%s</b> (%d fills, standard: under %dms). ",
      FormatMs(g_asyncCloseMedianLag), g_asyncCloseCount, STD_CLOSE_GOOD_MS));
   if(g_asyncCloseMedianLag > STD_CLOSE_MANIP_MS)
   {
      if(closeDriftHarmless)
         FileWriteString(h, StringFormat("<span style='color:#ccaa00'>Slow execution (%dms+) but no adverse price drift — no adverse effect.</span></p>\r\n", STD_CLOSE_MANIP_MS));
      else
         FileWriteString(h, StringFormat("<span style='color:#ff4444'><b>FAIL — Exceeds industry standard (%dms).</b></span></p>\r\n", STD_CLOSE_MANIP_MS));
   }
   else if(g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS)
   {
      if(closeDriftHarmless)
         FileWriteString(h, "<span style='color:#ccaa00'>Above standard but no adverse price drift — no adverse effect.</span></p>\r\n");
      else
         FileWriteString(h, "<span style='color:#ff8800'>WARNING — Above recommended standard.</span></p>\r\n");
   }
   else
      FileWriteString(h, "<span style='color:#00cc00'>PASS — Within acceptable limits.</span></p>\r\n");

   // Sync individual close result
   if(g_syncCloseCount > 0)
   {
      FileWriteString(h, StringFormat("<p><b>Sync individual close:</b> Median delay was <b>%s</b> (%d fills, standard: under %dms). ",
         FormatMs(g_syncCloseMedianLag), g_syncCloseCount, STD_SYNC_CLOSE_GOOD_MS));
      FileWriteString(h, "Sync closes are individual round-trip close requests — they should execute at market order speed. ");
      if(g_syncCloseMedianLag > STD_SYNC_CLOSE_MANIP_MS)
      {
         if(syncCloseDriftHarmless)
            FileWriteString(h, StringFormat("<span style='color:#ccaa00'>Slow execution (%dms+) but no adverse price drift — no adverse effect.</span></p>\r\n", STD_SYNC_CLOSE_MANIP_MS));
         else
            FileWriteString(h, StringFormat("<span style='color:#ff4444'><b>FAIL — Exceeds industry standard (%dms).</b></span></p>\r\n", STD_SYNC_CLOSE_MANIP_MS));
      }
      else if(g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS)
      {
         if(syncCloseDriftHarmless)
            FileWriteString(h, "<span style='color:#ccaa00'>Above standard but no adverse price drift — no adverse effect.</span></p>\r\n");
         else
            FileWriteString(h, "<span style='color:#ff8800'>WARNING — Slow individual close execution.</span></p>\r\n");
      }
      else
         FileWriteString(h, "<span style='color:#00cc00'>PASS — Within acceptable limits.</span></p>\r\n");
   }
   else
      FileWriteString(h, "<p style='color:#aaa'>All positions closed in async batch — no sync individual closes needed.</p>\r\n");

   // === Profit vs Loss close comparison (B-book smoking gun) ===
   double medCloseProfitLag = CalcMedianFromArray(g_closeProfitLags, g_closeProfitCount);
   double medCloseLossLag   = CalcMedianFromArray(g_closeLossLags, g_closeLossCount);
   double medStragProfitLag = CalcMedianFromArray(g_stragProfitLags, g_stragProfitCount);
   double medStragLossLag   = CalcMedianFromArray(g_stragLossLags, g_stragLossCount);

   if(g_closeProfitCount + g_closeLossCount + g_stragProfitCount + g_stragLossCount > 0)
   {
      FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #ff4444;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
      FileWriteString(h, "<p style='color:#ff4444;margin:0 0 10px 0;font-size:1.1em'><b>B-Book Smoking Gun: Profit vs Loss Close Speed</b></p>\r\n");
      FileWriteString(h, "<p>If the broker is an honest A-book, close execution should be identical regardless of whether ");
      FileWriteString(h, "the position is in profit or loss. A B-book broker pays winning trades from its own pocket, ");
      FileWriteString(h, "so it has incentive to delay profitable closes (hoping price reverses) while quickly closing ");
      FileWriteString(h, "losing trades (locking in the client's loss as broker revenue).</p>\r\n");

      FileWriteString(h, "<table class='data-table'>\r\n");
      FileWriteString(h, "<tr><th>Close Type</th><th>Profit Close</th><th>Loss Close</th><th>Ratio</th><th>Assessment</th></tr>\r\n");

      // Async batch closes
      if(g_closeProfitCount > 0 || g_closeLossCount > 0)
      {
         double asyncRatio = (medCloseLossLag > 0.001) ? medCloseProfitLag / medCloseLossLag :
                             (medCloseProfitLag > 0.001 && g_closeLossCount > 0) ? 999.0 : 0;
         string asyncAssess = (asyncRatio > 2.0) ? "FAIL" : (asyncRatio > 1.5) ? "SUSPICIOUS" : "FAIR";
         string asyncClass = (asyncRatio > 2.0) ? "fail" : (asyncRatio > 1.5) ? "warn" : "pass";
         FileWriteString(h, StringFormat("<tr><td>Async Batch</td><td>%s (%d)</td><td>%s (%d)</td><td>%.1f&times;</td><td class='%s'>%s</td></tr>\r\n",
            FormatMs(medCloseProfitLag, g_closeProfitCount>0), g_closeProfitCount,
            FormatMs(medCloseLossLag, g_closeLossCount>0), g_closeLossCount,
            asyncRatio, asyncClass, asyncAssess));
      }

      // Sync straggler closes
      if(g_stragProfitCount > 0 || g_stragLossCount > 0)
      {
         double stragRatio = (medStragLossLag > 0.001) ? medStragProfitLag / medStragLossLag :
                             (medStragProfitLag > 0.001 && g_stragLossCount > 0) ? 999.0 : 0;
         string stragAssess = (stragRatio > 2.0) ? "FAIL" : (stragRatio > 1.5) ? "SUSPICIOUS" : "FAIR";
         string stragClass = (stragRatio > 2.0) ? "fail" : (stragRatio > 1.5) ? "warn" : "pass";
         FileWriteString(h, StringFormat("<tr><td>Sync Straggler</td><td>%s (%d)</td><td>%s (%d)</td><td>%.1f&times;</td><td class='%s'>%s</td></tr>\r\n",
            FormatMs(medStragProfitLag, g_stragProfitCount>0), g_stragProfitCount,
            FormatMs(medStragLossLag, g_stragLossCount>0), g_stragLossCount,
            stragRatio, stragClass, stragAssess));
      }

      // Market test sync closes
      if(g_mktSyncCloseBuyMs > 0 && g_mktSyncCloseSellMs > 0)
      {
         double profitCloseMs = g_mktCloseBuyInProfit ? g_mktSyncCloseBuyMs : g_mktSyncCloseSellMs;
         double lossCloseMs   = g_mktCloseBuyInProfit ? g_mktSyncCloseSellMs : g_mktSyncCloseBuyMs;
         double mktRatio = (lossCloseMs > 0.001) ? profitCloseMs / lossCloseMs :
                           (profitCloseMs > 0.001) ? 999.0 : 0;
         string mktAssess = (mktRatio > 2.0) ? "FAIL" : (mktRatio > 1.5) ? "SUSPICIOUS" : "FAIR";
         string mktClass = (mktRatio > 2.0) ? "fail" : (mktRatio > 1.5) ? "warn" : "pass";
         FileWriteString(h, StringFormat("<tr><td>Sync Market Test</td><td>%s (1)</td><td>%s (1)</td><td>%.1f&times;</td><td class='%s'>%s</td></tr>\r\n",
            FormatMs(profitCloseMs), FormatMs(lossCloseMs), mktRatio, mktClass, mktAssess));
      }

      FileWriteString(h, "</table>\r\n");
      FileWriteString(h, "<p style='color:#aaa;font-size:0.9em'>Ratio = profit close time / loss close time. ");
      FileWriteString(h, "Fair broker: ratio ~1.0x. B-book: profit closes are significantly slower.</p>\r\n");
      FileWriteString(h, "</div>\r\n");
   }

   // Sync placement (market order) result
   if(g_countByType[0] > 0 || g_countByType[1] > 0)
   {
      FileWriteString(h, StringFormat("<p><b>Sync placement (market orders):</b> Median delay was <b>%s</b> (%d fills, standard: under %dms). ",
         FormatMs(medMarketLag), g_countByType[0] + g_countByType[1], STD_MARKET_GOOD_MS));
      // Check drift harmless for market orders (types 0-1)
      bool mktDriftHarmless = false;
      {
         double mktDriftSum = g_driftLagSum[0] + g_driftLagSum[1];
         int mktDriftCnt = g_driftLagCount[0] + g_driftLagCount[1];
         if(mktDriftCnt > 0) mktDriftHarmless = (mktDriftSum / mktDriftCnt < 5.0);
      }
      if(medMarketLag > STD_MARKET_MANIP_MS)
      {
         if(mktDriftHarmless)
            FileWriteString(h, StringFormat("<span style='color:#ccaa00'>Slow execution (%dms+) but no adverse price drift — no adverse effect.</span></p>\r\n", STD_MARKET_MANIP_MS));
         else
            FileWriteString(h, StringFormat("<span style='color:#ff4444'><b>FAIL — Exceeds industry standard (%dms).</b></span></p>\r\n", STD_MARKET_MANIP_MS));
      }
      else if(medMarketLag > STD_MARKET_SLOW_MS)
      {
         if(mktDriftHarmless)
            FileWriteString(h, "<span style='color:#ccaa00'>Above standard but no adverse price drift — no adverse effect.</span></p>\r\n");
         else
            FileWriteString(h, "<span style='color:#ff8800'>WARNING — Slow market order execution.</span></p>\r\n");
      }
      else
         FileWriteString(h, "<span style='color:#00cc00'>PASS — Within acceptable limits.</span></p>\r\n");
   }
   FileWriteString(h, "\r\n");

   // ===== MANIPULATION TACTIC 5: FILL CLUSTERING & BATCHING =====
   FileWriteString(h, "<h3 style='color:#ff4444'>Manipulation Tactic #5: Order Batching &amp; Fill Clustering</h3>\r\n");
   FileWriteString(h, "<p>This test measures two things:</p>\r\n");
   FileWriteString(h, "<p><b>1. Fill Clustering:</b> Do multiple fills share the exact same price, broker timestamp, ");
   FileWriteString(h, "and direction? This detects batch processing where the broker groups pending orders instead ");
   FileWriteString(h, "of filling them individually — a hallmark of B-book internalization.</p>\r\n");
   FileWriteString(h, "<p><b>2. Price Batching:</b> Did different pending orders (at different grid levels) all fill ");
   FileWriteString(h, "at the <i>same price</i>? This is direct evidence of the broker holding orders and executing ");
   FileWriteString(h, "them in a batch. If every order fills at its own trigger price, the broker processed them ");
   FileWriteString(h, "individually &mdash; no batching, no broker advantage.</p>\r\n");

   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 10px 0'><b>Understanding the Classification</b></p>\r\n");
   FileWriteString(h, "<p><b>FAIR:</b> All fills at trigger prices, no excessive lag.</p>\r\n");
   FileWriteString(h, "<p><b>MANIPULATION:</b> Excessive lag with fills at market price (not trigger price). The broker holds back orders ");
   FileWriteString(h, "beyond standard market practice AND fills at the drifted market price, causing financial damage.</p>\r\n");
   FileWriteString(h, "<p><b>Note:</b> Asymmetric lag between order types always benefits the broker. Even with trigger-price fills, ");
   FileWriteString(h, "delayed counter fills arriving after EA close operations create unwanted exposure against the trader.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   // Fill clustering result (same price + same timestamp + same direction)
   FileWriteString(h, StringFormat("<p><b>Fill Clustering:</b> %.0f%% of grid fills were clustered (%d clusters, max %d fills). ",
      g_clusterRatio * 100, g_clusterCount, (int)g_maxClusterSize));
   FileWriteString(h, StringFormat("A cluster = 2+ fills with the exact same fill price, same broker timestamp, same direction. "
      "Stops and limits are distinguished separately. Verdict: <b>%s</b>. ", g_clusterVerdict));
   if(g_clusterVerdict == "MANIPULATION")
      FileWriteString(h, "<span style='color:#ff4444'><b>Exceeds 2026 A-book benchmarks.</b></span></p>\r\n");
   else if(g_clusterVerdict == "CAUTION")
      FileWriteString(h, "<span style='color:#ff8800'>Above normal A-book levels — monitor closely.</span></p>\r\n");
   else
      FileWriteString(h, "<span style='color:#00cc00'>Within 2026 A-book standards.</span></p>\r\n");

   // Price batching result — color and message based on batch classification, not raw count
   FileWriteString(h, StringFormat("<p><b>Price Batching:</b> %d/%d fills landed at their trigger price (%.0f%% fair). ",
      g_fairFills, g_totalPricedFills,
      (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0));
   if(g_batchCount > 0 && g_batchClassification == "FAIR")
      FileWriteString(h, StringFormat("<span style='color:#00cc00'>%d price groups detected (%.1f pts avg drift, "
         "%.0f ms avg span) — normal market movement on a fast broker. No batch holding.</span></p>\r\n",
         g_batchCount, g_avgBatchAdvantagePts, g_avgBatchTimeSpanMs));
   else if(g_batchCount > 0 && g_batchClassification == "CAUTION")
      FileWriteString(h, StringFormat("<span style='color:#ff8800'><b>%d price batches detected — %.1f pts avg broker advantage, "
         "%.0f ms avg hold time.</b> Monitor closely.</span></p>\r\n",
         g_batchCount, g_avgBatchAdvantagePts, g_avgBatchTimeSpanMs));
   else if(g_batchCount > 0)
      FileWriteString(h, StringFormat("<span style='color:#ff4444'><b>%d price batches detected — %.1f pts avg broker advantage, "
         "%.0f ms avg hold time.</b></span></p>\r\n",
         g_batchCount, g_avgBatchAdvantagePts, g_avgBatchTimeSpanMs));
   else
      FileWriteString(h, "<span style='color:#00cc00'>No price batching — all orders filled at individual trigger prices.</span></p>\r\n");

   // Classification
   if(g_batchClassification == "MANIPULATION")
      FileWriteString(h, StringFormat("<p><b>Classification: <span style='color:#ff4444'>%s</span></b></p>\r\n", g_batchClassification));
   else if(g_batchClassification == "CAUTION")
      FileWriteString(h, StringFormat("<p><b>Classification: <span style='color:#ff8800'>%s</span></b></p>\r\n", g_batchClassification));
   else
      FileWriteString(h, StringFormat("<p><b>Classification: <span style='color:#00cc00'>%s</span></b></p>\r\n", g_batchClassification));
   FileWriteString(h, "\r\n");

   // ===== MANIPULATION TACTIC 6: PRICE ROUNDING =====
   FileWriteString(h, "<h3 style='color:#ff4444'>Manipulation Tactic #6: Price Rounding (Penny Shaving)</h3>\r\n");
   FileWriteString(h, "<p>This is the most subtle trick. When the broker calculates your profit or loss on each ");
   FileWriteString(h, "trade, tiny rounding differences occur. On a fair system, these round up and down equally ");
   FileWriteString(h, "&mdash; sometimes in your favour, sometimes in the broker's favour.</p>\r\n");
   FileWriteString(h, "<p>A manipulative broker rigs the rounding so it <i>always</i> (or mostly) favours them. ");
   FileWriteString(h, "Each individual difference is tiny &mdash; fractions of a cent &mdash; but across thousands of ");
   FileWriteString(h, "trades and thousands of clients, it adds up to significant money.</p>\r\n");

   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #333;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#4a90d9;margin:0 0 10px 0'><b>Analogy: The Fuel Pump</b></p>\r\n");
   FileWriteString(h, "<p>Imagine a petrol station whose pumps are calibrated to give you 0.995 litres for every ");
   FileWriteString(h, "\"1 litre\" on the display. You'd never notice the 0.5% shortage on a single fill, but ");
   FileWriteString(h, "across a million customers a year, the station steals thousands of litres of fuel.</p>\r\n");
   FileWriteString(h, "</div>\r\n");

   if(g_roundingErrorCount > 0)
   {
      FileWriteString(h, StringFormat("<p><b>Result for this broker:</b> Across %d closed trades, the cumulative rounding ",
         (int)g_roundingErrorCount));
      FileWriteString(h, StringFormat("error was <b>%+.4f %s</b>. ", g_roundingErrorSum, g_displayCurrency));
      if(g_roundingErrorSum < -0.01)
         FileWriteString(h, "<span style='color:#ff4444'>The rounding consistently favours the broker.</span></p>\r\n");
      else if(g_roundingErrorSum > 0.01)
         FileWriteString(h, "The rounding slightly favours the client (unusual but not harmful).</p>\r\n");
      else
         FileWriteString(h, "The rounding is approximately neutral, which is fair.</p>\r\n");
   }
   FileWriteString(h, "\r\n");

   // ===== ORDER REJECTION ANALYSIS =====
   if(g_rejectionCount > 0 || g_fillRejectionCount > 0)
   {
      // Compute stop/limit rejection counts for visualization (excluding stress, including fill rejections)
      int rejStopGrid = 0, rejLimitGrid = 0;
      for(int rx = 0; rx < g_rejectionCount; rx++)
      {
         if(StringFind(g_rejections[rx].orderType, "STRESS") >= 0) continue;
         if(StringFind(g_rejections[rx].orderType, "Stop") >= 0)  rejStopGrid++;
         if(StringFind(g_rejections[rx].orderType, "Limit") >= 0) rejLimitGrid++;
      }
      // Include fill rejections in totals for visualization
      rejStopGrid += g_fillRejStopTotal;
      rejLimitGrid += g_fillRejLimitTotal;

      // --- QUESTION HEADER for rejections ---
      if(rejStopGrid > 0 || rejLimitGrid > 0)
      {
         FileWriteString(h, "<h3 style='color:#ff8800;text-align:center;font-size:18px;margin:20px 0 5px 0'>"
            "Whose orders get rejected &mdash; yours, or the broker's?</h3>\r\n");

         FileWriteString(h, "<div style='margin:15px 0;padding:16px;background:#1a1a2a;border-radius:8px'>\r\n");

         // FAIR bar
         FileWriteString(h, "<div style='margin-bottom:4px;font-size:11px;color:#888;font-weight:bold'>FAIR REJECTION RATE (equal treatment):</div>\r\n");
         FileWriteString(h, "<div style='display:flex;align-items:center;width:100%;margin-bottom:12px'>"
            "<div style='background:#2a5a2a;height:24px;flex:0.5;border-radius:4px 0 0 4px;display:flex;align-items:center;justify-content:center;font-size:11px;color:#88cc88;border:1px solid #338833'>Your orders rejected</div>"
            "<div style='background:#2a5a2a;height:24px;flex:0.5;border-radius:0 4px 4px 0;display:flex;align-items:center;justify-content:center;font-size:11px;color:#88cc88;border:1px solid #338833;border-left:none'>Broker orders rejected</div>"
            "</div>\r\n");

         // ACTUAL bar — proportional stop vs limit rejections
         FileWriteString(h, "<div style='margin-bottom:4px;font-size:11px;color:#ff4444;font-weight:bold'>YOUR BROKER (measured):</div>\r\n");
         FileWriteString(h, "<div style='display:flex;justify-content:space-between;margin-bottom:4px;font-size:11px'>"
            "<span style='color:#ff4444;font-weight:bold'>Your Orders Rejected (Stops)</span>"
            "<span style='color:#4488ff;font-weight:bold'>Broker Orders Rejected (Limits)</span></div>\r\n");

         int totalRejBar = rejStopGrid + rejLimitGrid;
         if(totalRejBar < 1) totalRejBar = 1;
         double rejStopFlex = MathMax(0.02, (double)rejStopGrid / totalRejBar);
         double rejLimitFlex = MathMax(0.02, (double)rejLimitGrid / totalRejBar);
         FileWriteString(h, StringFormat(
            "<div style='display:flex;align-items:center;width:100%%'>"
            "<div style='background:#dd2200;height:34px;flex:%.4f;border-radius:4px 0 0 4px;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:bold;color:white;min-width:60px'>%d rejected</div>"
            "<div style='background:#2266dd;height:34px;flex:%.4f;border-radius:0 4px 4px 0;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:bold;color:white;min-width:60px'>%d rejected</div>"
            "</div>\r\n",
            rejStopFlex, rejStopGrid, rejLimitFlex, rejLimitGrid));

         // Verdict line
         if(rejStopGrid > 0 && rejLimitGrid == 0)
            FileWriteString(h, StringFormat("<div style='text-align:center;margin:10px 0;font-size:15px;font-weight:bold;color:#ff2200'>"
               "Only your orders were rejected (%d stop rejections, 0 limit rejections) &mdash; the broker's orders were never refused</div>\r\n",
               rejStopGrid));
         else if(rejLimitGrid > 0 && rejStopGrid > rejLimitGrid)
         {
            double rejRatioBar = (double)rejStopGrid / rejLimitGrid;
            FileWriteString(h, StringFormat("<div style='text-align:center;margin:10px 0;font-size:15px;font-weight:bold;color:#ff4400'>"
               "Your orders were rejected <span style='font-size:20px'>%.1f&times;</span> more often than the broker's</div>\r\n",
               rejRatioBar));
         }
         else
            FileWriteString(h, "<div style='text-align:center;margin:10px 0;font-size:14px;font-weight:bold;color:#44aa44'>"
               "Rejections distributed symmetrically &mdash; consistent with fair execution</div>\r\n");

         // Waffle chart for rejections (if asymmetric)
         if(rejStopGrid > 0 && (rejLimitGrid == 0 || (double)rejStopGrid / MathMax(1, rejLimitGrid) > 2.0))
         {
            int waffleRejTotal = rejStopGrid + rejLimitGrid;
            if(waffleRejTotal <= 100)
            {
               FileWriteString(h, "<div style='margin:12px 0;padding:10px;background:#111;border-radius:6px'>\r\n");
               FileWriteString(h, "<div style='text-align:center;font-size:12px;color:#aaa;margin-bottom:8px'>"
                  "Each square = 1 rejection. <b style='color:#ff4444'>Red</b> = your order rejected. "
                  "<b style='color:#4488ff'>Blue</b> = broker order rejected.</div>\r\n");
               FileWriteString(h, "<div style='display:flex;flex-wrap:wrap;gap:3px;justify-content:center'>\r\n");
               for(int w = 0; w < rejLimitGrid; w++)
                  FileWriteString(h, "<div style='width:14px;height:14px;background:#4488ff;border-radius:2px'></div>\r\n");
               for(int w = 0; w < rejStopGrid; w++)
                  FileWriteString(h, "<div style='width:14px;height:14px;background:#dd2200;border-radius:2px'></div>\r\n");
               FileWriteString(h, "</div>\r\n");
               if(rejLimitGrid == 0)
                  FileWriteString(h, StringFormat("<div style='text-align:center;font-size:11px;color:#888;margin-top:6px'>"
                     "%d red squares, 0 blue &mdash; every single rejection targeted your orders</div>\r\n", rejStopGrid));
               else
                  FileWriteString(h, StringFormat("<div style='text-align:center;font-size:11px;color:#888;margin-top:6px'>"
                     "%d red vs %d blue &mdash; your orders rejected %.1f&times; more often</div>\r\n",
                     rejStopGrid, rejLimitGrid, (double)rejStopGrid / rejLimitGrid));
               FileWriteString(h, "</div>\r\n");
            }
         }

         FileWriteString(h, "</div>\r\n\r\n");
      }

      if(g_rejectionCount > 0)
      {
      FileWriteString(h, "<h3>Order Placement Rejection Analysis</h3>\r\n");
      FileWriteString(h, "<div class='section'>\r\n");
      FileWriteString(h, StringFormat("<p>Total placement rejections: <b>%d</b> &mdash; Stop: %d | Limit: %d | Market: %d</p>\r\n",
         g_rejectionCount, g_rejStopTotal, g_rejLimitTotal, g_rejMarketTotal));
      FileWriteString(h, StringFormat("<p>Stop rejections &mdash; Manipulation: <b style='color:#ff4444'>%d</b> | "
         "Legitimate: %d</p>\r\n", g_rejStopManipulation, g_rejStopLegitimate));
      FileWriteString(h, StringFormat("<p>Limit rejections &mdash; Manipulation: <b style='color:#ff4444'>%d</b> | "
         "Legitimate: %d</p>\r\n", g_rejLimitManipulation, g_rejLimitLegitimate));
      if(g_rejTransientCount > 0)
         FileWriteString(h, StringFormat("<p style='color:#6688ff'>Transient (retry verified): <b>%d</b> &mdash; "
            "excluded from manipulation count</p>\r\n", g_rejTransientCount));

      // Classification breakdown boxes
      int cntSusp2 = 0, cntAsymDelay2 = 0, cntAsymReq2 = 0, cntLegit2 = 0, cntSymReq2 = 0, cntTransient2 = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         switch(g_rejections[r].classification)
         {
            case REJ_CLASS_SUSPICIOUS:        cntSusp2++; break;
            case REJ_CLASS_ASYMMETRIC_DELAY:  cntAsymDelay2++; break;
            case REJ_CLASS_ASYMMETRIC_REQUOTE:cntAsymReq2++; break;
            case REJ_CLASS_LEGITIMATE:        cntLegit2++; break;
            case REJ_CLASS_SYMMETRIC_REQUOTE: cntSymReq2++; break;
            case REJ_CLASS_TRANSIENT:         cntTransient2++; break;
         }
      }

      FileWriteString(h, "<div style='margin:15px 0'>\r\n");
      if(cntSusp2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#441111;border-left:4px solid #ff4444;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#ff4444'>Price Away from Level: %d</b><br>"
            "<span style='color:#ccc'>Order rejected while price was well away from the order level. "
            "No market condition can explain this rejection &mdash; the order was valid and properly distanced.</span></div>\r\n", cntSusp2));
      if(cntAsymDelay2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#442211;border-left:4px solid #ff8800;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#ff8800'>Asymmetric Delay: %d</b><br>"
            "<span style='color:#ccc'>Price moved past the order level before the broker processed it. However, the broker has "
            "measured asymmetric processing delay &mdash; stop orders are processed significantly slower than limit orders. "
            "The price only moved past the level <i>because</i> the broker artificially delayed processing. "
            "This is manufactured rejection, not market movement.</span></div>\r\n", cntAsymDelay2));
      if(cntAsymReq2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#443311;border-left:4px solid #ffaa00;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#ffaa00'>Asymmetric Requote: %d</b><br>"
            "<span style='color:#ccc'>Broker cited &ldquo;liquidity&rdquo; (requote) as the reason for rejection. "
            "However, requotes were applied selectively to stop orders while limit orders were not requoted. "
            "Genuine liquidity events affect all order types equally &mdash; selective requoting is manufactured.</span></div>\r\n", cntAsymReq2));
      if(cntLegit2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#113311;border-left:4px solid #44aa44;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#44aa44'>Legitimate: %d</b><br>"
            "<span style='color:#ccc'>Price genuinely moved past the order level during symmetric broker processing. "
            "No asymmetric delay detected &mdash; this is expected market behaviour during volatile conditions.</span></div>\r\n", cntLegit2));
      if(cntSymReq2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#112233;border-left:4px solid #4488cc;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#4488cc'>Symmetric Requote: %d</b><br>"
            "<span style='color:#ccc'>Both stop and limit orders requoted at similar rates &mdash; genuine liquidity event.</span></div>\r\n", cntSymReq2));
      if(cntTransient2 > 0)
         FileWriteString(h, StringFormat("<div style='background:#112244;border-left:4px solid #6688ff;padding:10px;margin:8px 0;border-radius:4px'>"
            "<b style='color:#6688ff'>Transient (Retry Verified): %d</b><br>"
            "<span style='color:#ccc'>Server rejected the order initially, but accepted the identical order %dms later on retry. "
            "This confirms a momentary server issue (rate limit, load spike, or glitch) &mdash; not deliberate blocking. "
            "Excluded from manipulation count.</span></div>\r\n", cntTransient2, InpRejRetryDelayMs));
      FileWriteString(h, "</div>\r\n");

      // Verdict
      if(g_rejectionVerdict != "" && StringFind(g_rejectionVerdict, "NONE") < 0)
         FileWriteString(h, StringFormat("<p class='fail'><b>VERDICT: %s</b></p>\r\n", g_rejectionVerdict));
      else
         FileWriteString(h, "<p style='color:#44aa44'><b>VERDICT:</b> No manipulative rejection patterns detected.</p>\r\n");

      // Rejection detail table with distance columns
      int gridRejCount = 0;
      for(int r = 0; r < g_rejectionCount; r++)
         if(StringFind(g_rejections[r].orderType, "STRESS") < 0) gridRejCount++;

      if(gridRejCount > 0 && gridRejCount <= 100)
      {
         FileWriteString(h, "<table><tr><th>#</th><th>Type</th><th>Retcode</th><th>Order Price</th>"
            "<th>Bid</th><th>Ask</th><th>Dist (pts)</th><th>Dist (sprd)</th>"
            "<th>Broker Reason</th><th>Measured Reason</th><th>Classification</th><th>Retry</th><th>Time</th></tr>\r\n");
         int row = 0;
         for(int r = 0; r < g_rejectionCount; r++)
         {
            if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
            string classStr2, rowClr2;
            switch(g_rejections[r].classification)
            {
               case REJ_CLASS_SUSPICIOUS:        classStr2 = "<b style='color:#ff4444'>PRICE AWAY</b>"; rowClr2 = " style='background:#331111'"; break;
               case REJ_CLASS_ASYMMETRIC_DELAY:  classStr2 = "<b style='color:#ff8800'>ASYM DELAY</b>"; rowClr2 = " style='background:#332211'"; break;
               case REJ_CLASS_ASYMMETRIC_REQUOTE:classStr2 = "<b style='color:#ffaa00'>ASYM REQUOTE</b>"; rowClr2 = " style='background:#332211'"; break;
               case REJ_CLASS_LEGITIMATE:        classStr2 = "<span style='color:#44aa44'>LEGITIMATE</span>"; rowClr2 = ""; break;
               case REJ_CLASS_SYMMETRIC_REQUOTE: classStr2 = "<span style='color:#4488cc'>SYM REQUOTE</span>"; rowClr2 = ""; break;
               case REJ_CLASS_TRANSIENT:         classStr2 = "<span style='color:#6688ff'>TRANSIENT</span>"; rowClr2 = " style='background:#111133'"; break;
               default:                          classStr2 = "UNCLASSIFIED"; rowClr2 = ""; break;
            }
            // Retry column
            string retryStr2;
            if(g_rejections[r].retrySucceeded)
               retryStr2 = StringFormat("<span style='color:#6688ff'>OK (#%d)</span>", g_rejections[r].retryAttempts);
            else if(g_rejections[r].retryAttempts > 0)
               retryStr2 = StringFormat("<span style='color:#ff4444'>FAIL (%d/%d)</span>", g_rejections[r].retryAttempts, InpRejRetryMax);
            else
               retryStr2 = "<span style='color:#666'>&mdash;</span>";

            FileWriteString(h, StringFormat("<tr%s><td>%d</td><td>%s</td><td>%d</td><td>%s</td>"
               "<td>%s</td><td>%s</td><td>%.1f</td><td>%.1f</td>"
               "<td style='font-size:11px'>%s</td><td style='font-size:11px'>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\r\n",
               rowClr2, ++row, g_rejections[r].orderType, g_rejections[r].retcode,
               DoubleToString(g_rejections[r].orderPrice, g_digits),
               DoubleToString(g_rejections[r].bidAtReject, g_digits),
               DoubleToString(g_rejections[r].askAtReject, g_digits),
               g_rejections[r].distPoints, g_rejections[r].distSpreads,
               g_rejections[r].brokerReason, g_rejections[r].measuredReason,
               classStr2, retryStr2, TimeToString(g_rejections[r].time, TIME_DATE | TIME_SECONDS)));
         }
         FileWriteString(h, "</table>\r\n");
      }

      // --- REJECTION DISTANCE CHART (pure CSS horizontal bars) ---
      if(gridRejCount > 0)
      {
         // Find max distance for scaling
         double chartMax = InpGridStartMult;
         for(int r = 0; r < g_rejectionCount; r++)
         {
            if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
            if(g_rejections[r].distSpreads > chartMax) chartMax = g_rejections[r].distSpreads;
         }
         chartMax *= 1.2;  // 20% padding

         FileWriteString(h, "<h4>Rejection Distance from Price (&times; spread)</h4>\r\n");
         FileWriteString(h, "<div style='position:relative; padding:20px 0 10px 0; margin:10px 0'>\r\n");

         // Reference line for grid start distance
         double refPct = (InpGridStartMult / chartMax) * 100.0;
         FileWriteString(h, StringFormat("<div style='position:absolute; left:200px; width:calc(100%% - 220px); "
            "top:0; bottom:0; pointer-events:none'>"
            "<div style='position:absolute; left:%.1f%%; top:0; bottom:0; "
            "border-left:2px dashed #ffaa00; z-index:1'>"
            "<span style='position:absolute; top:0px; left:4px; color:#ffaa00; font-size:11px; white-space:nowrap'>"
            "Min grid distance (%.0f&times; spread)</span></div></div>\r\n", refPct, InpGridStartMult));

         // Bars — colored by classification
         int barNum = 0;
         for(int r = 0; r < g_rejectionCount; r++)
         {
            if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
            barNum++;
            double barPct = (g_rejections[r].distSpreads / chartMax) * 100.0;
            if(barPct < 1) barPct = 1;
            string barColor2, classLabel2;
            switch(g_rejections[r].classification)
            {
               case REJ_CLASS_SUSPICIOUS:        barColor2 = "#ff4444"; classLabel2 = "PRICE AWAY"; break;
               case REJ_CLASS_ASYMMETRIC_DELAY:  barColor2 = "#ff8800"; classLabel2 = "ASYM DELAY"; break;
               case REJ_CLASS_ASYMMETRIC_REQUOTE:barColor2 = "#ffaa00"; classLabel2 = "ASYM REQUOTE"; break;
               case REJ_CLASS_LEGITIMATE:        barColor2 = "#44aa44"; classLabel2 = "LEGITIMATE"; break;
               case REJ_CLASS_SYMMETRIC_REQUOTE: barColor2 = "#4488cc"; classLabel2 = "SYM REQUOTE"; break;
               case REJ_CLASS_TRANSIENT:         barColor2 = "#6688ff"; classLabel2 = "TRANSIENT"; break;
               default:                          barColor2 = "#888888"; classLabel2 = "?"; break;
            }
            FileWriteString(h, StringFormat(
               "<div style='display:flex; align-items:center; margin:3px 0'>"
               "<div style='width:195px; text-align:right; padding-right:5px; font-size:12px; color:#ccc; white-space:nowrap'>%s #%d</div>"
               "<div style='flex:1; position:relative'>"
               "<div style='width:%.1f%%; background:%s; height:20px; border-radius:2px; position:relative'>"
               "<span style='position:absolute; right:4px; top:2px; font-size:11px; color:#fff; white-space:nowrap'>%.1f&times; &mdash; %s</span>"
               "</div></div></div>\r\n",
               g_rejections[r].orderType, barNum, barPct, barColor2,
               g_rejections[r].distSpreads, classLabel2));
         }

         // Legend
         FileWriteString(h, "<div style='margin-top:10px; font-size:12px'>"
            "<span style='color:#ff4444'>&#9608;</span> Price away (no reason) &nbsp;&nbsp;"
            "<span style='color:#ff8800'>&#9608;</span> Asymmetric delay (manufactured) &nbsp;&nbsp;"
            "<span style='color:#ffaa00'>&#9608;</span> Asymmetric requote &nbsp;&nbsp;"
            "<span style='color:#44aa44'>&#9608;</span> Legitimate &nbsp;&nbsp;"
            "<span style='color:#4488cc'>&#9608;</span> Symmetric requote &nbsp;&nbsp;"
            "<span style='color:#6688ff'>&#9608;</span> Transient (retry verified)</div>\r\n");
         FileWriteString(h, "</div>\r\n");
      }
      FileWriteString(h, "</div>\r\n\r\n");
      } // end if(g_rejectionCount > 0)
   }

   // ===== FILL REJECTIONS — BROKER CANCELLED PENDING ORDERS =====
   if(g_fillRejectionCount > 0)
   {
      FileWriteString(h, "<div class='section'>\r\n");
      FileWriteString(h, "<h3 style='color:#ff8800;text-align:center;font-size:18px;margin:20px 0 5px 0'>"
         "Did the broker accept your orders then refuse to fill them?</h3>\r\n");
      FileWriteString(h, StringFormat("<p style='text-align:center;color:#ff6644;font-size:15px;margin:5px 0 15px 0'>"
         "<b>%d pending orders</b> were accepted by the broker, placed on the server, "
         "then <b>cancelled instead of filled</b> when price reached them. "
         "The orders disappeared as if they were never placed.</p>\r\n", g_fillRejectionCount));

      // Summary counts
      FileWriteString(h, "<table><tr><th>Category</th><th>Stop Orders (yours)</th><th>Limit Orders (broker's)</th></tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td>Price Triggered — cancelled after trigger</td>"
         "<td style='color:%s'><b>%d</b></td><td>%d</td></tr>\r\n",
         g_fillRejStopTriggered > 0 ? "#ff4444" : "#44aa44",
         g_fillRejStopTriggered, g_fillRejLimitTriggered));
      FileWriteString(h, StringFormat("<tr><td>Pre-emptive — cancelled before trigger</td>"
         "<td style='color:%s'>%d</td><td>%d</td></tr>\r\n",
         g_fillRejStopPreemptive > 0 ? "#ff8800" : "#cccccc",
         g_fillRejStopPreemptive, g_fillRejLimitPreemptive));
      FileWriteString(h, StringFormat("<tr style='font-weight:bold'><td>Total</td>"
         "<td style='color:%s'>%d</td><td>%d</td></tr>\r\n",
         g_fillRejStopTotal > 0 ? "#ff4444" : "#cccccc",
         g_fillRejStopTotal, g_fillRejLimitTotal));
      FileWriteString(h, "</table>\r\n");

      // Verdict with psychological framing
      if(g_fillRejStopTriggered > 0 && g_fillRejLimitTriggered == 0)
      {
         FileWriteString(h, "<div style='background:#441111;border:2px solid #ff4444;border-radius:8px;"
            "padding:15px;margin:15px 0;text-align:center'>"
            "<div style='font-size:16px;color:#ff4444;font-weight:bold'>"
            "SELECTIVE FILL SUPPRESSION</div>"
            "<div style='color:#ffcccc;margin-top:8px'>Only YOUR stop orders were accepted then cancelled at trigger time. "
            "The broker's limit orders were always filled. The broker accepted the order, "
            "watched price reach it, then refused to fill it &mdash; "
            "your order disappeared as if it was never placed.</div>"
            "</div>\r\n");
      }
      else if(g_fillRejStopTriggered > 0)
      {
         FileWriteString(h, StringFormat("<div style='background:#441111;border:2px solid #ff8800;border-radius:8px;"
            "padding:15px;margin:15px 0;text-align:center'>"
            "<div style='font-size:16px;color:#ff8800;font-weight:bold'>"
            "ASYMMETRIC FILL SUPPRESSION</div>"
            "<div style='color:#ffddcc;margin-top:8px'>%d stop orders vs %d limit orders "
            "cancelled after price trigger. Your orders are disproportionately targeted.</div>"
            "</div>\r\n", g_fillRejStopTriggered, g_fillRejLimitTriggered));
      }

      // Fill rejection detail table
      if(g_fillRejectionCount <= 100)
      {
         FileWriteString(h, "<h4>Fill Rejection Detail &mdash; Broker Reason vs Measured Reason</h4>\r\n");
         FileWriteString(h, "<table><tr><th>#</th><th>Type</th><th>Order Price</th>"
            "<th>Bid</th><th>Ask</th><th>Dist (pts)</th><th>Triggered?</th>"
            "<th>Broker Reason</th><th>Measured Reason</th><th>Cycle</th></tr>\r\n");
         for(int r = 0; r < g_fillRejectionCount; r++)
         {
            bool isTriggered2 = (g_fillRejections[r].classification == FILLREJ_CLASS_PRICE_TRIGGERED);
            string trigStr = isTriggered2
               ? "<b style='color:#ff4444'>YES — TRIGGERED</b>"
               : "<span style='color:#ffaa00'>No</span>";
            string rowBg = isTriggered2 ? " style='background:#331111'" : "";
            FileWriteString(h, StringFormat("<tr%s><td>%d</td><td>%s</td><td>%s</td>"
               "<td>%s</td><td>%s</td><td>%.1f</td><td>%s</td>"
               "<td style='font-size:11px'>%s</td><td style='font-size:11px'>%s</td><td>%d</td></tr>\r\n",
               rowBg, r + 1, g_fillRejections[r].orderType,
               DoubleToString(g_fillRejections[r].orderPrice, g_digits),
               DoubleToString(g_fillRejections[r].bidAtCancel, g_digits),
               DoubleToString(g_fillRejections[r].askAtCancel, g_digits),
               g_fillRejections[r].distPoints, trigStr,
               g_fillRejections[r].brokerReason, g_fillRejections[r].measuredReason,
               g_fillRejections[r].cycleNum));
         }
         FileWriteString(h, "</table>\r\n");
      }

      FileWriteString(h, StringFormat("<p class='fail'><b>VERDICT: %s</b></p>\r\n", g_fillRejVerdict));
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== PHANTOM SPIKE DETECTION =====
   if(g_phantomSpikeCount > 0)
   {
      int slSpikes2 = 0;
      for(int s = 0; s < g_phantomSpikeCount; s++)
         if(g_phantomSpikes[s].triggeredSL) slSpikes2++;

      FileWriteString(h, "<h3>Phantom Spike Detection</h3>\r\n");
      FileWriteString(h, "<div class='section'>\r\n");
      FileWriteString(h, StringFormat("<p>Anomalous price spikes detected: <b>%d</b> (spread &gt;3&times; median)</p>\r\n",
         g_phantomSpikeCount));
      FileWriteString(h, StringFormat("<p>Median spread: %.1f pts | Mean spread: %.1f pts</p>\r\n",
         g_medianSpread / g_tickSize, g_meanSpread / g_tickSize));
      if(slSpikes2 > 0)
         FileWriteString(h, StringFormat("<p class='fail'><b>WARNING:</b> %d spike(s) coincided with Stop-Loss triggers within 2 seconds. "
            "This may indicate artificial price spikes designed to trigger SL orders.</p>\r\n", slSpikes2));
      else
         FileWriteString(h, "<p style='color:#00cc00'>No spikes coincided with SL triggers.</p>\r\n");
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== MARGIN VERIFICATION =====
   if(g_theoreticalMarginBuy > 0)
   {
      FileWriteString(h, "<h3>Margin Verification</h3>\r\n");
      FileWriteString(h, "<div class='section'>\r\n");
      FileWriteString(h, "<table><tr><th>Metric</th><th>Buy Only</th>");
      if(g_theoreticalMarginBoth > 0)
         FileWriteString(h, "<th>Both Open</th>");
      FileWriteString(h, "</tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td>Theoretical Margin</td><td>%.2f %s</td>", g_theoreticalMarginBuy, g_displayCurrency));
      if(g_theoreticalMarginBoth > 0)
         FileWriteString(h, StringFormat("<td>%.2f %s</td>", g_theoreticalMarginBoth, g_displayCurrency));
      FileWriteString(h, "</tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td>Actual Margin Charged</td><td>%.2f %s</td>", g_measuredMarginBuy, g_displayCurrency));
      if(g_theoreticalMarginBoth > 0)
         FileWriteString(h, StringFormat("<td>%.2f %s</td>", g_measuredMarginBoth, g_displayCurrency));
      FileWriteString(h, "</tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td>Discrepancy</td><td>%.2f (%.1f%%)</td>", g_marginDiscrepancyBuy, g_marginMarkupPctBuy));
      if(g_theoreticalMarginBoth > 0)
         FileWriteString(h, StringFormat("<td>%.2f (%.1f%%)</td>", g_marginDiscrepancyBoth, g_marginMarkupPctBoth));
      FileWriteString(h, "</tr></table>\r\n");
      if(MathAbs(g_marginMarkupPctBuy) > 10.0)
         FileWriteString(h, "<p style='color:#ff8800'><b>NOTE:</b> Margin charged deviates &gt;10% from theoretical. "
            "May indicate hidden margin markup or non-standard calculation.</p>\r\n");
      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== ORDER CAPACITY STRESS TEST =====
   {
      FileWriteString(h, "<h3>Order Capacity Stress Test</h3>\r\n");
      FileWriteString(h, "<div class='section'>\r\n");
      FileWriteString(h, StringFormat("<p>Batch size: %d orders per cycle (measured order limit) | Max cycles: %d</p>\r\n", (int)g_orderLimit, InpStressMaxCycles));

      // Limit results (baseline)
      string limResult = g_stressLimitBlocked ?
         StringFormat("<span class='fail'>BLOCKED at cycle %d</span>", g_stressLimitBlockedAt) :
         StringFormat("<span style='color:#00cc00'>%d cycles OK — no block</span>", g_stressCycleLimit);
      FileWriteString(h, StringFormat("<p><b>Limit Orders (baseline):</b> %s | Max verified: %d</p>\r\n",
         limResult, g_stressMaxVerifiedLimit));

      // Stop results
      string stpResult = g_stressStopBlocked ?
         StringFormat("<span class='fail'>BLOCKED at cycle %d</span>", g_stressStopBlockedAt) :
         StringFormat("<span style='color:#00cc00'>%d cycles OK — no block</span>", g_stressCycleStop);
      FileWriteString(h, StringFormat("<p><b>Stop Orders:</b> %s | Max verified: %d</p>\r\n",
         stpResult, g_stressMaxVerifiedStop));

      // Selective blocking verdict
      if(g_stressStopBlocked && !g_stressLimitBlocked)
      {
         FileWriteString(h, "<div style='background:#2a1a1a;border:2px solid #ff4400;border-radius:8px;padding:12px;margin:10px 0'>\r\n");
         FileWriteString(h, "<p style='color:#ff4400;font-weight:bold;margin:0'>SELECTIVE ORDER BLOCKING DETECTED</p>\r\n");
         FileWriteString(h, "<p style='color:#ccc;margin:5px 0 0 0'>The broker allows unlimited limit-order cycling (broker-favorable) "
            "but blocks stop-order cycling (broker-adverse). This is a deliberate capacity restriction that prevents traders from "
            "maintaining hedging and risk-management strategies using stop orders. ");
         FileWriteString(h, StringFormat("Limit orders completed %d cycles without interruption, while stop orders were blocked at cycle %d. ",
            g_stressCycleLimit, g_stressStopBlockedAt));
         FileWriteString(h, "This cannot be attributed to server load or order limits, as the same volume of limit orders was accepted.</p>\r\n");
         FileWriteString(h, "</div>\r\n");
      }
      else if(g_stressStopBlocked && g_stressLimitBlocked)
      {
         FileWriteString(h, "<p style='color:#ff8800'><b>Both order types were blocked.</b> ");
         FileWriteString(h, StringFormat("Limits at cycle %d, stops at cycle %d. ", g_stressLimitBlockedAt, g_stressStopBlockedAt));
         if(g_stressLimitBlockedAt > g_stressStopBlockedAt)
            FileWriteString(h, "Stops were blocked earlier than limits — still indicates asymmetric treatment.</p>\r\n");
         else
            FileWriteString(h, "Both blocked at similar cycle counts — may indicate general capacity limits.</p>\r\n");
      }
      else if(!g_stressStopBlocked && !g_stressLimitBlocked)
      {
         // Check if rejection rates are asymmetric before declaring "all clear"
         double limRejPre = (g_stressLimitTotalAttempts > 0) ? (100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts) : 0;
         double stpRejPre = (g_stressStopTotalAttempts > 0) ? (100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts) : 0;
         bool asymRejPre = (stpRejPre > limRejPre * 1.5 && stpRejPre > 10.0) ||
                            (limRejPre > stpRejPre * 1.5 && limRejPre > 10.0);
         if(asymRejPre)
            FileWriteString(h, "<p style='color:#ff8800'>Both order types completed all cycles, but with asymmetric rejection rates (see below).</p>\r\n");
         else if(limRejPre > 10.0 || stpRejPre > 10.0)
            FileWriteString(h, "<p style='color:#00cc00'>Both order types completed all cycles. Rejection rates are symmetric (legitimate rate limiting).</p>\r\n");
         else
            FileWriteString(h, "<p style='color:#00cc00'>No selective blocking detected. Both order types completed all cycles.</p>\r\n");
      }

      if(g_stressLastRetcode > 0 && (g_stressStopBlocked || g_stressLimitBlocked))
         FileWriteString(h, StringFormat("<p style='color:#888'>Last rejection return code: %d</p>\r\n", g_stressLastRetcode));

      // Rejection rate analysis — distinguish rate limiting (legitimate) from asymmetry (manipulation)
      {
         double limRejPctH = (g_stressLimitTotalAttempts > 0) ?
            (100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts) : 0;
         double stpRejPctH = (g_stressStopTotalAttempts > 0) ?
            (100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts) : 0;

         if(limRejPctH > 0.0 || stpRejPctH > 0.0)
         {
            FileWriteString(h, "<h4>Burst Placement Rejection Rate</h4>\r\n");
            FileWriteString(h, "<table><tr><th>Order Type</th><th>Attempts</th><th>Rejected</th><th>Rate</th></tr>\r\n");
            if(g_stressLimitTotalAttempts > 0)
            {
               string limClrR = (limRejPctH > 10.0) ? "#ff4400" : "#00cc00";
               FileWriteString(h, StringFormat("<tr><td>Limit Orders</td><td>%d</td><td>%d</td>"
                  "<td style='color:%s;font-weight:bold'>%.1f%%</td></tr>\r\n",
                  g_stressLimitTotalAttempts, g_stressLimitTotalRejects, limClrR, limRejPctH));
            }
            if(g_stressStopTotalAttempts > 0)
            {
               string stpClrR = (stpRejPctH > 10.0) ? "#ff4400" : "#00cc00";
               FileWriteString(h, StringFormat("<tr><td>Stop Orders</td><td>%d</td><td>%d</td>"
                  "<td style='color:%s;font-weight:bold'>%.1f%%</td></tr>\r\n",
                  g_stressStopTotalAttempts, g_stressStopTotalRejects, stpClrR, stpRejPctH));
            }
            FileWriteString(h, "</table>\r\n");

            if(limRejPctH > 10.0 || stpRejPctH > 10.0)
            {
               bool asymRejH = (stpRejPctH > limRejPctH * 1.5 && stpRejPctH > 10.0) ||
                                (limRejPctH > stpRejPctH * 1.5 && limRejPctH > 10.0);
               if(asymRejH)
               {
                  FileWriteString(h, "<div style='background:#2a1a1a;border:2px solid #ff4400;border-radius:8px;padding:12px;margin:10px 0'>\r\n");
                  FileWriteString(h, StringFormat("<p style='color:#ff4400;font-weight:bold;margin:0'>"
                     "ASYMMETRIC ORDER REJECTION: Stops %.0f%% vs Limits %.0f%%</p>\r\n", stpRejPctH, limRejPctH));
                  FileWriteString(h, "<p style='color:#ccc;margin:5px 0 0 0'>Both order types were placed under identical conditions "
                     "(same burst rate, same account). Asymmetric rejection rates indicate the broker's rate limiter treats "
                     "order types differently, which cannot be attributed to server load.</p>\r\n");
                  FileWriteString(h, "</div>\r\n");
               }
               else
               {
                  double totalRejPctH = 100.0 * (g_stressStopTotalRejects + g_stressLimitTotalRejects) /
                     MathMax(1, g_stressStopTotalAttempts + g_stressLimitTotalAttempts);
                  FileWriteString(h, StringFormat("<p style='color:#ff8800'>Rate limiting: %.0f%% of burst placements rejected. "
                     "Rates are symmetric (stops %.0f%% vs limits %.0f%%) &mdash; consistent with legitimate server-side "
                     "rate limiting rather than selective manipulation.</p>\r\n",
                     totalRejPctH, stpRejPctH, limRejPctH));
               }
            }
         }
      }

      // Throttle recovery time
      if(g_throttleRecoveryCount > 0)
      {
         FileWriteString(h, "<h4>Throttle Recovery Time</h4>\r\n");
         FileWriteString(h, "<p style='color:#aaa'>Time for broker to accept a new order after cleaning up a full stress batch. "
            "Measured between each cycle — simulates a scalping EA's wait time after heavy activity.</p>\r\n");
         FileWriteString(h, "<table><tr><th>Phase</th><th>Avg Recovery</th><th>Worst Case</th><th>Measurements</th></tr>\r\n");
         if(g_throttleLimitMeasurements > 0)
         {
            double limAvgHtml = g_throttleLimitTotalMs / g_throttleLimitMeasurements;
            string limClrH = (g_throttleLimitMaxMs > 500) ? "#ff4400" : (g_throttleLimitMaxMs > 100) ? "#ff8800" : "#00cc00";
            FileWriteString(h, StringFormat("<tr><td>Limit Orders</td><td style='color:%s'>%.0fms</td>"
               "<td style='color:%s'>%.0fms</td><td>%d</td></tr>\r\n",
               limClrH, limAvgHtml, limClrH, g_throttleLimitMaxMs, g_throttleLimitMeasurements));
         }
         if(g_throttleStopMeasurements > 0)
         {
            double stpAvgHtml = g_throttleStopTotalMs / g_throttleStopMeasurements;
            string stpClrH = (g_throttleStopMaxMs > 500) ? "#ff4400" : (g_throttleStopMaxMs > 100) ? "#ff8800" : "#00cc00";
            FileWriteString(h, StringFormat("<tr><td>Stop Orders</td><td style='color:%s'>%.0fms</td>"
               "<td style='color:%s'>%.0fms</td><td>%d</td></tr>\r\n",
               stpClrH, stpAvgHtml, stpClrH, g_throttleStopMaxMs, g_throttleStopMeasurements));
         }
         FileWriteString(h, "</table>\r\n");

         double worstHtml = MathMax(g_throttleLimitMaxMs, g_throttleStopMaxMs);
         if(worstHtml > 500)
         {
            FileWriteString(h, "<div style='background:#2a1a1a;border:2px solid #ff4400;border-radius:8px;padding:12px;margin:10px 0'>\r\n");
            FileWriteString(h, "<p style='color:#ff4400;font-weight:bold;margin:0'>SCALPING EA IMPACT</p>\r\n");
            FileWriteString(h, StringFormat("<p style='color:#ccc;margin:5px 0 0 0'>Broker throttle window up to %.0fms (%.1fs). "
               "A scalping EA requiring rapid order placement would be locked out for this duration after normal trading activity. "
               "During fast market moves, this delay can result in significant slippage or missed entries entirely.</p>\r\n",
               worstHtml, worstHtml / 1000.0));
            FileWriteString(h, "</div>\r\n");
         }
      }

      // EA Tuning Recommendations (optional — controlled by InpShowEATuning)
      if(InpShowEATuning && (g_safeAsyncBatchStop > 0 || g_safeAsyncBatchLimit > 0))
      {
         FileWriteString(h, "<h4>EA Tuning Recommendations</h4>\r\n");
         FileWriteString(h, "<p style='color:#aaa'>Measured values for configuring trading EAs to avoid rate-limiting:</p>\r\n");
         FileWriteString(h, "<table><tr><th>Metric</th><th>Stops</th><th>Limits</th></tr>\r\n");
         FileWriteString(h, StringFormat("<tr><td>Max Async Burst Accepted</td><td>%d</td><td>%d</td></tr>\r\n",
            g_stressMaxVerifiedStop, g_stressMaxVerifiedLimit));
         FileWriteString(h, StringFormat("<tr><td><b>Safe Async Batch (90%%)</b></td><td><b>%d</b></td><td><b>%d</b></td></tr>\r\n",
            g_safeAsyncBatchStop, g_safeAsyncBatchLimit));
         if(g_bufferFlushCount > 0)
         {
            FileWriteString(h, StringFormat("<tr><td>Buffer Flush Cost (sync place+delete)</td>"
               "<td colspan='2'>avg %.0fms | max %.0fms</td></tr>\r\n",
               g_bufferFlushAvgMs, g_bufferFlushMaxMs));
         }
         FileWriteString(h, "</table>\r\n");
         FileWriteString(h, "<div style='background:#1a2a1a;border:1px solid #00aa00;border-radius:8px;padding:12px;margin:10px 0'>\r\n");
         FileWriteString(h, "<p style='color:#00cc00;font-weight:bold;margin:0'>Recommended EA Pattern</p>\r\n");
         FileWriteString(h, StringFormat("<p style='color:#ccc;margin:5px 0 0 0'>Place up to <b>%d</b> orders async per burst. "
            "Then execute a sync place+delete of a throwaway order (~$1000 from price) to flush the broker's async "
            "pipeline (cost: ~%.0fms). This prevents rate-limiting rejections on subsequent batches.</p>\r\n",
            MathMin(g_safeAsyncBatchStop > 0 ? g_safeAsyncBatchStop : 999, g_safeAsyncBatchLimit > 0 ? g_safeAsyncBatchLimit : 999),
            g_bufferFlushAvgMs));
         FileWriteString(h, "</div>\r\n");
      }

      FileWriteString(h, "</div>\r\n\r\n");
   }

   // ===== WHY SYMMETRIC SLOW IS STILL A PROBLEM =====
   FileWriteString(h, "<h3 style='color:#ff8800'>Topic: Why Symmetric Slow Execution Is Still a Problem</h3>\r\n");
   FileWriteString(h, "<p>Some brokers show <b>equal</b> delays on all order types &mdash; stops, limits, TP, SL all execute at the same speed. "
      "This looks &ldquo;fair&rdquo; because there is no discrimination. But if that equal speed is <b>slow</b>, it is still a problem.</p>\r\n");
   FileWriteString(h, "<div style='background:#1a1a2e;border:1px solid #ff8800;border-radius:8px;padding:15px;margin:15px 0'>\r\n");
   FileWriteString(h, "<p style='color:#ff8800;margin:0 0 10px 0'><b>Three Tiers of Execution Speed</b></p>\r\n");
   FileWriteString(h, "<table style='width:100%'>\r\n");
   FileWriteString(h, "<tr><th style='width:25%'>Speed</th><th style='width:25%'>Symmetry</th><th>Meaning</th></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#00cc00'><b>Fast</b></span> (&lt;100ms)</td><td>Symmetric</td>"
      "<td><b>Fair.</b> True A-book/STP execution. No time for last-look. Top brokers in 2026 achieve 10-50ms.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#ff8800'><b>Slow</b></span> (100-300ms)</td><td>Symmetric</td>"
      "<td><b>Last-look risk.</b> Equal delay on all orders, but 100-300ms provides a window for the broker "
      "or its liquidity provider to inspect every order before confirming. They can check which direction the market "
      "moved during the delay and decide whether to fill or requote. Symmetry does not mean honesty when the baseline is slow.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#ff4444'><b>Any speed</b></span></td><td>Asymmetric</td>"
      "<td><b>Manipulation.</b> Different speeds for different order types means the broker is selectively holding orders. "
      "If stops take 250ms but limits fill in 30ms, the 30ms <i>proves</i> the infrastructure can handle 30ms. "
      "The 250ms on stops is a deliberate choice.</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");
   FileWriteString(h, "</div>\r\n");
   FileWriteString(h, "<p>The FX Global Code of Conduct (Principle 17) explicitly prohibits &ldquo;additional hold time&rdquo; "
      "beyond what is needed for price and validity checks. Industry leaders demonstrate this is achievable: "
      "Northern Trust completes checks within 3ms, XTX Markets operates at 0ms hold time. "
      "Hold times in the hundreds of milliseconds are indefensible &mdash; whether symmetric or not.</p>\r\n\r\n");

   // ===== HOW TO READ THE NUMBERS =====
   FileWriteString(h, "<h3 style='color:#4a90d9'>How to Read the Numbers in This Report</h3>\r\n");
   FileWriteString(h, "<table>\r\n");
   FileWriteString(h, "<tr><th>Term</th><th>What It Means</th></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Lag / Delay</b></td><td>How long the broker took to process an order, in milliseconds. ");
   FileWriteString(h, "Lower is better. Under 100ms is normal for A-book brokers. Over 500ms is suspicious.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Execution Drift</b></td><td>The price movement between when the broker received your order and when it was filled. ");
   FileWriteString(h, "Measured as <b>drift lag</b> (milliseconds for the market to move from the broker receipt price to the deal price). ");
   FileWriteString(h, "Zero drift means the fill price matched the receipt price. Non-zero drift = the broker caused a price impact. "
      "However, even zero-drift fills are harmful when lag is asymmetric &mdash; delayed counter fills can arrive after EA close operations.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Broker Receipt Price</b></td><td>The market price at the moment your instruction arrived at the broker's server ");
   FileWriteString(h, "(send time + client&ndash;server latency). This is the fair benchmark price &mdash; any difference between this and the deal price is drift caused by the broker.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Exec Quality</b></td><td>Classification based on drift lag: <span style='color:#00cc00'>PERFECT</span> (&lt;0.5ms), ");
   FileWriteString(h, "<span style='color:#00cc00'>GOOD</span> (&lt;5ms), <span style='color:#ff8800'>ACCEPTABLE</span> (&lt;50ms), ");
   FileWriteString(h, "<span style='color:#ff4444'>POOR</span> (&ge;50ms). Note: PERFECT drift does not exonerate asymmetric lag.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Asymmetric Lag</b></td><td>When the broker takes longer to fill orders that cost them money (your profits) ");
   FileWriteString(h, "than orders that make them money (your losses). This is the key B-book manipulation signal.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Broker Exec Time</b></td><td>The lag minus internet travel time. This is purely how long ");
   FileWriteString(h, "the broker's own server spent on your order. Internet delay is not the broker's fault; ");
   FileWriteString(h, "we remove it from all measurements.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Fill Clustering</b></td><td>Fills sharing the EXACT same fill price, same broker timestamp "
      "(DEAL_TIME_MSC), and same direction are grouped as a cluster. Stop and limit orders are tracked separately "
      "even at the same price. ");
   FileWriteString(h, StringFormat("2026 A-book standard: &le;%.0f%% = FAIR, &le;%.0f%% = CAUTION, &gt;%.0f%% = MANIPULATION. "
      "Max cluster size &le;%d = normal, &gt;%d = batch processing confirmed.</td></tr>\r\n",
      STD_CLUSTER_FAIR_PCT, STD_CLUSTER_CAUTION_PCT, STD_CLUSTER_CAUTION_PCT,
      STD_MAX_CLUSTER_FAIR, STD_MAX_CLUSTER_MANIP));
   FileWriteString(h, "<tr><td><b>Price Batching</b></td><td>Did different grid-level orders all fill at the same price? ");
   FileWriteString(h, "If yes, the broker held orders during its lag and filled them in a batch. ");
   FileWriteString(h, "If all orders fill at their trigger prices, there is no batching and no broker advantage.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Stop/Limit Ratio</b></td><td>How many times slower stops are than limits. ");
   FileWriteString(h, "Should be close to 1.0&times; (equal speed). Over 2&times; is suspicious. Over 3&times; indicates selective delay.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>TP/SL Exec Lag</b></td><td>How long the broker took to fill a Take-Profit or Stop-Loss after ");
   FileWriteString(h, StringFormat("the trigger price was reached (server-side). Standard: &lt;%dms good, &gt;%dms exceeds standard.</td></tr>\r\n",
      STD_TPSL_GOOD_MS, STD_TPSL_MANIP_MS));
   FileWriteString(h, "<tr><td><b>Sync Placement</b></td><td>How long the broker took to fill a market order (sync round-trip, ");
   FileWriteString(h, StringFormat("network latency removed). Standard: &lt;%dms good, &gt;%dms exceeds standard.</td></tr>\r\n",
      STD_MARKET_GOOD_MS, STD_MARKET_MANIP_MS));
   FileWriteString(h, "<tr><td><span style='color:#00cc00'><b>PASS</b></span></td><td>Within industry standards (MiFID II, FCA, ESMA). No action needed.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#ccaa00'><b>SLOW</b></span></td><td>Execution time exceeds standard. No adverse price drift detected on this fill, but asymmetric delay still harms the trader through out-of-sequence counter fills.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#ff8800'><b>WARN</b></span></td><td>Above recommended levels. Worth monitoring or questioning the broker.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><span style='color:#ff4444'><b>FAIL</b></span></td><td>Exceeds accepted industry standards. Warrants further investigation or regulatory complaint.</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   FileWriteString(h, "</div>\r\n\r\n");

   // ===== DATA PROVENANCE & VERIFICATION PROTOCOL =====
   FileWriteString(h, "<h2 style='color:#4a90d9'>Data Provenance &amp; Verification Protocol</h2>\r\n");
   FileWriteString(h, "<div class='section'>\r\n");

   FileWriteString(h, "<h3>Data Source Attestation</h3>\r\n");
   FileWriteString(h, "<table>\r\n");
   FileWriteString(h, "<tr><th>Element</th><th>Source</th><th>EA Control</th></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Fill Timestamps</b></td><td><code>DEAL_TIME_MSC</code> &mdash; server-side millisecond timestamp generated by the broker's trade server</td><td>Read-only. EA cannot modify.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Fill Prices</b></td><td><code>DEAL_PRICE</code> &mdash; actual execution price recorded by broker server</td><td>Read-only. EA cannot modify.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Live Prices</b></td><td><code>SymbolInfoTick()</code> &mdash; broker's live bid/ask feed</td><td>Read-only. EA cannot modify.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>CS Calibration</b></td><td>Round-trip latency via pending order place+delete, averaged across 2 passes</td><td>EA measures; cannot influence network path.</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Order Placement</b></td><td><code>OrderSend()</code> &mdash; standard MT5 trade request</td><td>EA places minimum-lot orders only.</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   FileWriteString(h, "<h3>Why This Data Cannot Be Fabricated</h3>\r\n");
   FileWriteString(h, "<ul style='color:#ccc;line-height:1.8'>\r\n");
   FileWriteString(h, "<li><b>Server-side timestamps:</b> <code>DEAL_TIME_MSC</code> is generated by the broker's MT5 trade server, not the client terminal. "
      "The EA reads these values after the fact &mdash; it has no mechanism to alter them.</li>\r\n");
   FileWriteString(h, "<li><b>Deal history is immutable:</b> Once a deal is recorded in MT5's history database, it cannot be modified by any EA, script, or indicator. "
      "The MT5 API provides read-only access to historical deal records.</li>\r\n");
   FileWriteString(h, "<li><b>Cross-validation:</b> Every measurement can be independently verified by exporting the account's deal history from MT5 "
      "(History tab → right-click → Export) and comparing <code>DEAL_TIME_MSC</code> timestamps against the EA's evidence CSV.</li>\r\n");
   FileWriteString(h, "<li><b>Open source:</b> The complete EA source code (.mq5) is available for inspection. Anyone can read every line, compile it, "
      "and verify it only reads MT5 API values &mdash; it contains no hardcoded biases or result manipulation.</li>\r\n");
   FileWriteString(h, "<li><b>Reproducible:</b> Multiple independent users running this EA on the same broker will produce statistically consistent results. "
      "The broker's execution profile is a property of their infrastructure, not this tool.</li>\r\n");
   FileWriteString(h, "</ul>\r\n");

   FileWriteString(h, "<h3>Independent Verification Steps</h3>\r\n");
   FileWriteString(h, "<div style='background:#1a1a2a;border:1px solid #333;border-radius:8px;padding:15px;margin:10px 0'>\r\n");
   FileWriteString(h, "<ol style='color:#ccc;line-height:2.0'>\r\n");
   FileWriteString(h, "<li>Download the EA source from any of these repositories:<br>\r\n");
   FileWriteString(h, "&bull; <a href='https://github.com/TraderJoe2026/ExecutionEdge' style='color:#4a90d9'>GitHub</a> &nbsp; ");
   FileWriteString(h, "&bull; <a href='https://sourceforge.net/projects/executionedge/' style='color:#4a90d9'>SourceForge</a></li>\r\n");
   FileWriteString(h, "<li>Inspect the source code &mdash; verify it only uses standard MT5 API calls</li>\r\n");
   FileWriteString(h, "<li>Compile with MetaEditor (the compiled .ex5 hash should match the published hash)</li>\r\n");
   FileWriteString(h, "<li>Open a demo <b>and</b> live account with the same broker</li>\r\n");
   FileWriteString(h, "<li>Run the EA on both accounts &mdash; compare the execution profiles</li>\r\n");
   FileWriteString(h, "<li>Run on a known A-book broker as a <b>control group</b> &mdash; expect FAIR verdict</li>\r\n");
   FileWriteString(h, "<li>Cross-check the evidence CSV against MT5's built-in deal history export</li>\r\n");
   FileWriteString(h, "<li>Verify file integrity: SHA-256 hashes are recorded in the TOML data file</li>\r\n");
   FileWriteString(h, "</ol>\r\n");
   FileWriteString(h, "</div>\r\n");

   FileWriteString(h, "<h3>File Integrity</h3>\r\n");
   FileWriteString(h, "<p style='color:#aaa'>SHA-256 hashes of all output files are recorded in the TOML data file (<code>[integrity]</code> section). "
      "To verify that no file has been tampered with after generation, recompute the SHA-256 hash of each file and compare against the recorded values.</p>\r\n");
   FileWriteString(h, StringFormat("<p style='color:#888;font-size:11px'>TOML file: <code>%s</code></p>\r\n", g_tomlName));

   FileWriteString(h, "<h3>Regulatory Standards Referenced</h3>\r\n");
   FileWriteString(h, "<table>\r\n");
   FileWriteString(h, "<tr><th>Standard</th><th>Authority</th><th>Relevance</th></tr>\r\n");
   FileWriteString(h, "<tr><td>MiFID II RTS 27/28</td><td>EU / ESMA</td><td>Best execution reporting requirements</td></tr>\r\n");
   FileWriteString(h, "<tr><td>COBS 11.2</td><td>FCA (UK)</td><td>Best execution obligations</td></tr>\r\n");
   FileWriteString(h, "<tr><td>COBS 4.2</td><td>FCA (UK)</td><td>Fair, clear, not misleading communications</td></tr>\r\n");
   FileWriteString(h, "<tr><td>FAIS Act</td><td>FSCA (South Africa)</td><td>Fair treatment of clients</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Corporations Act s912A</td><td>ASIC (Australia)</td><td>Efficient, honest and fair financial services</td></tr>\r\n");
   FileWriteString(h, "<tr><td>PIO 2020/986</td><td>ASIC (Australia)</td><td>CFD leverage limits, margin close-out, negative balance protection</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Article 24</td><td>MiFID II</td><td>Honest, fair, professional conduct</td></tr>\r\n");
   FileWriteString(h, "<tr><td>NFA Rule 2-36 / Notice 9064</td><td>NFA (US)</td><td>Symmetric slippage &amp; execution required</td></tr>\r\n");
   FileWriteString(h, "<tr><td>FX Global Code Principle 17</td><td>GFXC (2021)</td><td>No additional hold time on last look</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   // --- Enforcement Precedents ---
   FileWriteString(h, "<h3 style='color:#ff8800'>Enforcement Precedents &amp; Case Law</h3>\r\n");
   FileWriteString(h, "<p style='color:#aaa'>The execution behaviors measured in this report have been prosecuted by financial "
      "regulators worldwide. The following cases establish legal precedent.</p>\r\n");

   FileWriteString(h, "<table>\r\n");
   FileWriteString(h, "<tr><th>Broker</th><th>Year</th><th>Regulator</th><th>Fine</th><th>Violation</th></tr>\r\n");
   FileWriteString(h, "<tr><td><b>FXCM</b></td><td>2011</td><td>NFA</td><td>$2M + $8.3M restitution</td>"
      "<td>Retained 100% of positive slippage ($9.8M total), passed 100% of negative to clients</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>FXCM</b></td><td>2014</td><td>FCA</td><td>&pound;4M</td>"
      "<td>Retained ~&pound;6M in favorable price movements between order submission and execution</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>FXCM</b></td><td>2017</td><td>CFTC</td><td>$7M + permanent ban</td>"
      "<td>Concealed market maker relationship; ~$77M rebated while trading against clients</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a2a'><td><b>FXDD</b></td><td>2013</td><td>NFA + CFTC</td><td>$3.5M+</td>"
      "<td>Rejected orders moving &gt;2 pips in client's favor; filled with unlimited movement in FXDD's favor</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>Barclays</b></td><td>2015</td><td>NYDFS</td><td style='color:#ff4444'><b>$150M</b></td>"
      "<td>Last-look hold times in 'tens and hundreds of milliseconds'; rejected unprofitable trades, accepted profitable ones; cited 'technical issues' when questioned</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a2a'><td><b>GAIN Capital</b></td><td>2010</td><td>NFA</td><td>$459K</td>"
      "<td>Asymmetric slippage on MetaTrader; orders &gt;5 contracts disproportionately slipped against clients</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>IKON Global</b></td><td>2010</td><td>NFA</td><td>Regulatory action</td>"
      "<td>MetaTrader Virtual Dealer Plugin with asymmetric slippage settings (2007&ndash;2010)</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a2a'><td><b>AGM Markets</b></td><td>2020</td><td>ASIC</td><td style='color:#ff4444'><b>A$75M</b></td>"
      "<td>Systemic unconscionable conduct in OTC derivatives; ~10,000 clients lost A$32M combined</td></tr>\r\n");
   FileWriteString(h, "<tr><td><b>EuropeFX / USG</b></td><td>2024</td><td>ASIC</td><td>A$83M+ losses</td>"
      "<td>Systemic unconscionable conduct; 95&ndash;99% of customers lost money; companies profited directly from client losses</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a2a'><td><b>Big Four Banks</b></td><td>2016&ndash;17</td><td>ASIC</td><td>A$13M contributions</td>"
      "<td>Confidential FX order leaking to external participants; offers without commercial reason (NAB, CBA, Westpac, ANZ)</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   FileWriteString(h, "<div style='margin:12px 0;padding:14px;background:#1a1020;border-left:3px solid #ff8800;font-size:12px;color:#ccc'>\r\n");
   FileWriteString(h, "<b style='color:#ff8800'>Non-Delegable Duty of Execution</b><br><br>"
      "A broker's obligation to execute client orders fairly is a <b>statutory duty that cannot be transferred "
      "to a liquidity provider</b>. The legal maxim <i>delegatus non potest delegare</i> applies directly.<br><br>"
      "<b>MiFID II Art. 27:</b> The firm must take 'all sufficient steps' for best execution and demonstrate "
      "compliance &mdash; non-delegable. "
      "<b>FCA SYSC 8.1:</b> The firm 'remains fully responsible' after outsourcing; obligations to clients "
      "'must not be altered.' "
      "<b>FINRA Rule 5310:</b> 'No member can transfer to another person its obligation to provide best execution.' "
      "<b>ASIC s912A:</b> 'Efficiently, honestly and fairly' applies regardless of execution model. "
      "<b>FAIS Act s.2:</b> Services must be rendered 'with due skill, care and diligence, and in the interests of clients.'<br><br>"
      "When a broker operates a <b>B-book</b> (acts as principal), the broker IS the counterparty &mdash; "
      "there is no LP to blame. The inherent conflict of interest must be managed, not exploited "
      "(MiFID II Art. 23, FCA COBS 10A, FAIS Act s.3A).<br><br>"
      "<b>Precedent:</b> FXCM was permanently banned despite blaming its market maker. The CFTC found "
      "FXCM held an undisclosed interest in Effex Capital, receiving ~70% of profits from trading against "
      "clients. The 7th Circuit upheld these findings (<i>Effex Capital v. NFA</i>, 2019). "
      "CFTC Docket No. 17-04.</div>\r\n");

   // Benchmark table
   FileWriteString(h, "<h4>Regulatory Benchmark Summary</h4>\r\n");
   FileWriteString(h, "<table>\r\n");
   FileWriteString(h, "<tr><th>Metric</th><th style='color:#00cc00'>Fair</th><th style='color:#ff8800'>Suspicious</th><th style='color:#ff4444'>Manipulative</th><th>Precedent</th></tr>\r\n");
   FileWriteString(h, "<tr><td>Execution latency</td><td>&lt;100ms</td><td>100&ndash;200ms</td><td>&gt;200ms</td>"
      "<td>Barclays fined $150M for hold times in hundreds of ms</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Stop/Limit ratio</td><td>&lt;1.2&times;</td><td>1.2&ndash;1.5&times;</td><td>&gt;1.5&times;</td>"
      "<td>NFA Rule 9064: symmetric execution required</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Slippage symmetry</td><td>0.8&ndash;1.2</td><td>0.6&ndash;0.8</td><td>&lt;0.5</td>"
      "<td>FXCM fined for retaining 100% of favorable slippage</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Hold time / last look</td><td>&lt;5ms</td><td>5&ndash;50ms</td><td>&gt;50ms</td>"
      "<td>FX Global Code 2021; XTX operates at 0ms</td></tr>\r\n");
   FileWriteString(h, "<tr><td>Rejection asymmetry</td><td>Symmetric</td><td>Directional &gt;10%</td><td>Systematic</td>"
      "<td>FXDD rejected all &gt;2 pip favorable client moves</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   FileWriteString(h, "<p style='color:#888;font-size:11px;margin-top:8px'>All references are publicly available enforcement "
      "records. Case numbers: NFA 11-BCC-023 (FXCM), NFA 13-BCC-014 (FXDD), NYDFS Consent Order 18 Nov 2015 "
      "(Barclays), CFTC Docket 17-04 (FXCM ban), NFA 10-BCC-009 (GAIN Capital), "
      "ASIC 20-246MR (AGM Markets), ASIC 24-287MR (EuropeFX/USG), ASIC 16-455MR &amp; 17-065MR (Big Four Banks).</p>\r\n");

   FileWriteString(h, "</div>\r\n\r\n");

   // ===== VDP / ASYMMETRY DETECTION SECTION =====
   FileWriteString(h, "<div style='background:#1a0a0a;border:2px solid #aa0000;border-radius:8px;padding:20px;margin:20px 0'>\r\n");
   FileWriteString(h, "<h2 style='color:#ff4444;margin-top:0'>Virtual Dealer Plugin &amp; Asymmetry Analysis</h2>\r\n");

   FileWriteString(h, "<h3 style='color:#ff8800'>What is the Virtual Dealer Plugin (VDP)?</h3>\r\n");
   FileWriteString(h, "<p>The MetaTrader Virtual Dealer Plugin is a server-side tool available to all MT4/MT5 brokers. "
      "It intercepts client orders and applies:</p>\r\n");
   FileWriteString(h, "<ul>\r\n");
   FileWriteString(h, "<li><b>Configurable execution delays</b> &mdash; integer seconds (1-15s), separate settings for stops, SL, TP, limits</li>\r\n");
   FileWriteString(h, "<li><b>Price recheck during hold</b> &mdash; if price moves in client's favor, broker keeps improvement or rejects</li>\r\n");
   FileWriteString(h, "<li><b>Asymmetric slippage thresholds</b> &mdash; MaxProfitSlippagePips vs MaxLosingSlippagePips</li>\r\n");
   FileWriteString(h, "<li><b>Volume-based rejection</b> &mdash; large profitable orders automatically rejected</li>\r\n");
   FileWriteString(h, "<li><b>Per-account targeting</b> &mdash; specific traders can receive different execution</li>\r\n");
   FileWriteString(h, "</ul>\r\n");
   FileWriteString(h, "<p>Third-party clones (TradeToolsFX, FXLab DealerLogic, AzyPrime, Viktex) offer identical functionality. "
      "All invisible to the trader.</p>\r\n");

   FileWriteString(h, "<h3 style='color:#ff8800'>How This EA Detects VDP</h3>\r\n");
   FileWriteString(h, "<table style='width:100%;border-collapse:collapse;margin:10px 0'>\r\n");
   FileWriteString(h, "<tr style='background:#222'><th style='padding:6px;text-align:left;color:#ff8800'>Test</th>"
      "<th style='padding:6px;text-align:left;color:#ff8800'>Natural ECN/STP</th>"
      "<th style='padding:6px;text-align:left;color:#ff8800'>VDP-Manipulated</th></tr>\r\n");
   FileWriteString(h, "<tr><td style='padding:5px;color:#ccc'>Delay distribution</td>"
      "<td style='padding:5px;color:#44ff44'>Log-normal, continuous</td>"
      "<td style='padding:5px;color:#ff4444'>Spikes at whole seconds (1s, 2s, 3s)</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a1a'><td style='padding:5px;color:#ccc'>Delay magnitude</td>"
      "<td style='padding:5px;color:#44ff44'>20-200ms</td>"
      "<td style='padding:5px;color:#ff4444'>500-15,000ms</td></tr>\r\n");
   FileWriteString(h, "<tr><td style='padding:5px;color:#ccc'>Distribution shape</td>"
      "<td style='padding:5px;color:#44ff44'>Right-skewed tail (IQR/med &gt;1.0)</td>"
      "<td style='padding:5px;color:#ff4444'>Flat/uniform band (IQR/med &lt;0.5)</td></tr>\r\n");
   FileWriteString(h, "<tr style='background:#1a1a1a'><td style='padding:5px;color:#ccc'>Per-type delays</td>"
      "<td style='padding:5px;color:#44ff44'>No systematic difference</td>"
      "<td style='padding:5px;color:#ff4444'>Stops, SL, TP each configured separately</td></tr>\r\n");
   FileWriteString(h, "<tr><td style='padding:5px;color:#ccc'>Lag asymmetry</td>"
      "<td style='padding:5px;color:#44ff44'>Symmetric (&lt;2x)</td>"
      "<td style='padding:5px;color:#ff4444'>Broker-profitable orders &gt;2x slower</td></tr>\r\n");
   FileWriteString(h, "</table>\r\n");

   // Detection results
   FileWriteString(h, "<h3 style='color:#ff8800'>Detection Results</h3>\r\n");
   if(g_vdpAdverseCount < 3)
   {
      FileWriteString(h, "<p style='color:#888'>Insufficient data (fewer than 3 adverse fills measured).</p>\r\n");
   }
   else
   {
      string vdpClr = (g_vdpScore >= 50) ? "#ff4444" : (g_vdpLagRatio > 2.0) ? "#ff8800" : "#44ff44";
      FileWriteString(h, StringFormat("<p style='font-size:18px;color:%s'><b>VDP Score: %.0f/100 &mdash; %s</b></p>\r\n",
         vdpClr, g_vdpScore, g_vdpVerdict));
      FileWriteString(h, StringFormat("<p>Adverse fills (stops + SL): <b>%d fills</b>, median <b>%s</b></p>\r\n",
         g_vdpAdverseCount, FormatMs(g_vdpAdverseMedian)));
      FileWriteString(h, StringFormat("<p>Favorable fills (limits + TP): <b>%d fills</b>, median <b>%s</b></p>\r\n",
         g_vdpFavorCount, FormatMs(g_vdpFavorMedian)));

      string ratioClr = (g_vdpLagRatio > 2.0) ? "#ff4444" : "#44ff44";
      FileWriteString(h, StringFormat("<p>Lag asymmetry ratio: <b style='color:%s'>%.0fx</b> %s</p>\r\n",
         ratioClr, g_vdpLagRatio,
         g_vdpLagRatio > 2.0 ? "&mdash; ASYMMETRIC (broker-favorable)" : "&mdash; within tolerance"));

      FileWriteString(h, "<table style='width:100%;border-collapse:collapse;margin:10px 0'>\r\n");
      FileWriteString(h, "<tr style='background:#222'><th style='padding:5px;text-align:left;color:#ccc'>Test</th>"
         "<th style='padding:5px;text-align:left;color:#ccc'>Result</th>"
         "<th style='padding:5px;text-align:left;color:#ccc'>Status</th></tr>\r\n");
      FileWriteString(h, StringFormat("<tr><td style='padding:5px;color:#ccc'>Whole-second clustering</td>"
         "<td style='padding:5px;color:#ccc'>%.0f%% of adverse fills</td>"
         "<td style='padding:5px;color:%s'><b>%s</b></td></tr>\r\n",
         g_vdpWholeSecPct, g_vdpWholeSecCluster ? "#ff4444" : "#44ff44",
         g_vdpWholeSecCluster ? "DETECTED" : "Not detected"));
      FileWriteString(h, StringFormat("<tr style='background:#1a1a1a'><td style='padding:5px;color:#ccc'>Delay magnitude</td>"
         "<td style='padding:5px;color:#ccc'>Median %s</td>"
         "<td style='padding:5px;color:%s'><b>%s</b></td></tr>\r\n",
         FormatMs(g_vdpAdverseMedian), g_vdpDelayRange ? "#ff4444" : "#44ff44",
         g_vdpDelayRange ? "IN VDP RANGE" : "Normal range"));
      FileWriteString(h, StringFormat("<tr><td style='padding:5px;color:#ccc'>Distribution shape</td>"
         "<td style='padding:5px;color:#ccc'>IQR/median = %.2f</td>"
         "<td style='padding:5px;color:%s'><b>%s</b></td></tr>\r\n",
         g_vdpIQRatio, g_vdpFlatDistribution ? "#ff4444" : "#44ff44",
         g_vdpFlatDistribution ? "FLAT (configured)" : "Normal spread"));
      FileWriteString(h, StringFormat("<tr style='background:#1a1a1a'><td style='padding:5px;color:#ccc'>Order-type discrimination</td>"
         "<td style='padding:5px;color:#ccc'>Stops vs SL delay</td>"
         "<td style='padding:5px;color:%s'><b>%s</b></td></tr>\r\n",
         g_vdpOrderTypeDiscrim ? "#ff4444" : "#44ff44",
         g_vdpOrderTypeDiscrim ? "DETECTED" : "Not detected"));
      FileWriteString(h, StringFormat("<tr><td style='padding:5px;color:#ccc'>Lag asymmetry (&gt;2x)</td>"
         "<td style='padding:5px;color:#ccc'>%.0fx ratio</td>"
         "<td style='padding:5px;color:%s'><b>%s</b></td></tr>\r\n",
         g_vdpLagRatio, g_vdpLagRatio > 2.0 ? "#ff4444" : "#44ff44",
         g_vdpLagRatio > 2.0 ? "ASYMMETRIC" : "Symmetric"));
      FileWriteString(h, "</table>\r\n");

      // Conclusion
      if(g_vdpScore >= 50)
      {
         FileWriteString(h, "<div style='background:#330000;border:1px solid #ff0000;padding:12px;border-radius:6px;margin:10px 0'>\r\n");
         FileWriteString(h, "<p style='color:#ff4444;font-size:14px;margin:0'><b>CONCLUSION:</b> "
            "The execution pattern is consistent with Virtual Dealer Plugin intervention. "
            "The broker appears to apply configured execution delays that discriminate between "
            "order types, systematically disadvantaging the trader.</p>\r\n");
         FileWriteString(h, "</div>\r\n");
      }
      else if(g_vdpLagRatio > 2.0)
      {
         FileWriteString(h, "<div style='background:#332200;border:1px solid #ff8800;padding:12px;border-radius:6px;margin:10px 0'>\r\n");
         FileWriteString(h, StringFormat("<p style='color:#ff8800;font-size:14px;margin:0'><b>CONCLUSION:</b> "
            "VDP signatures not conclusive, but <b>%.0fx asymmetric execution</b> detected. "
            "Broker-profitable orders delayed %.0fx longer than broker-costly orders. "
            "This is a regulatory violation regardless of mechanism. "
            "When an EA closes positions on a retracement, delayed counter fills arrive afterward "
            "creating unwanted exposure.</p>\r\n", g_vdpLagRatio, g_vdpLagRatio));
         FileWriteString(h, "</div>\r\n");
      }
      else
      {
         if(violations >= 1)
         {
            FileWriteString(h, "<div style='background:#2a2a00;border:1px solid #ccaa00;padding:12px;border-radius:6px;margin:10px 0'>\r\n");
            FileWriteString(h, "<p style='color:#ccaa00;font-size:14px;margin:0'><b>CONCLUSION:</b> "
               "No significant asymmetry or VDP signatures detected. "
               "Execution is slow but consistent across all order types &mdash; this indicates "
               "slow broker infrastructure, not discriminatory B-book behavior.</p>\r\n");
            FileWriteString(h, "</div>\r\n");
         }
         else
         {
            FileWriteString(h, "<div style='background:#003300;border:1px solid #44ff44;padding:12px;border-radius:6px;margin:10px 0'>\r\n");
            FileWriteString(h, "<p style='color:#44ff44;font-size:14px;margin:0'><b>CONCLUSION:</b> "
               "No significant asymmetry or VDP signatures detected. "
               "Execution appears consistent with legitimate ECN/STP processing.</p>\r\n");
            FileWriteString(h, "</div>\r\n");
         }
      }
   }
   FileWriteString(h, "</div>\r\n\r\n");

   // Footer
   FileWriteString(h, "<p style='text-align:center;color:#555;margin-top:30px;font-size:12px'>");
   FileWriteString(h, StringFormat("BrokerForensicAnalyzer v%s | Open Source | Generated %s</p>\r\n",
      FA_VERSION, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)));
   FileWriteString(h, "</body></html>\r\n");

   FileClose(h);
   PrintFormat("HTML REPORT: %s", g_reportHtmName);
}


//+------------------------------------------------------------------+
//| GENERATE TOML — Machine-readable results                           |
//+------------------------------------------------------------------+
void GenerateTOML()
{
   int h = FileOpen(g_tomlName, FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("ERROR: Cannot create TOML file: %s", g_tomlName);
      return;
   }

   FileWriteString(h, "# BrokerForensicAnalyzer Results\r\n");
   FileWriteString(h, StringFormat("# Generated: %s\r\n", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)));
   FileWriteString(h, StringFormat("# EA Version: %s\r\n", FA_VERSION));
   FileWriteString(h, StringFormat("# MT5 Build: %d\r\n", TerminalInfoInteger(TERMINAL_BUILD)));
   FileWriteString(h, "# Data Source: All timestamps from DEAL_TIME_MSC (broker server-side, read-only)\r\n");
   FileWriteString(h, "# Open Source: Full .mq5 source available for independent code review\r\n\r\n");

   FileWriteString(h, "[environment]\r\n");
   FileWriteString(h, StringFormat("broker = \"%s\"\r\n", g_brokerName));
   FileWriteString(h, StringFormat("server = \"%s\"\r\n", g_serverName));
   FileWriteString(h, StringFormat("account = %d\r\n", (int)g_accountNumber));
   FileWriteString(h, StringFormat("currency = \"%s\"\r\n", g_accountCurrency));
   FileWriteString(h, StringFormat("report_currency = \"%s\"\r\n", g_displayCurrency));
   if(g_accountCurrency != "USD")
      FileWriteString(h, "currency_note = \"All monetary values shown as reported by platform. For sub-denomination accounts (e.g. USC/cents), apply appropriate conversion.\"\r\n");
   FileWriteString(h, StringFormat("symbol = \"%s\"\r\n", Symbol()));
   FileWriteString(h, StringFormat("leverage_reported = %d\r\n", (int)g_accountLeverage));
   if(g_verifiedLeverage > 0)
      FileWriteString(h, StringFormat("leverage_measured_buy = %.0f\r\n", g_verifiedLeverage));
   if(g_verifiedLeverageBoth > 0)
      FileWriteString(h, StringFormat("leverage_measured_both = %.0f\r\n", g_verifiedLeverageBoth));
   {
      string tomlMarginMode = "unknown";
      if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) tomlMarginMode = "retail_netting";
      else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) tomlMarginMode = "exchange";
      else if(g_accountMarginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) tomlMarginMode = "retail_hedging";
      FileWriteString(h, StringFormat("margin_mode = \"%s\"\r\n", tomlMarginMode));
   }
   if(g_measuredMarginBuy > 0)
      FileWriteString(h, StringFormat("margin_buy = %.2f\r\n", g_measuredMarginBuy));
   if(g_measuredMarginBoth > 0)
   {
      FileWriteString(h, StringFormat("margin_both = %.2f\r\n", g_measuredMarginBoth));
      FileWriteString(h, StringFormat("equity_both = %.2f\r\n", g_measuredEquityBoth));
   }
   if(g_calculatedHedgingRatio >= 0)
      FileWriteString(h, StringFormat("hedging_ratio = %.4f\r\n", g_calculatedHedgingRatio));
   FileWriteString(h, StringFormat("lot_size = %.2f\r\n", g_lotSize));
   FileWriteString(h, StringFormat("stops_level_points = %d\r\n", g_stopsLevel));
   {
      double stopsInPipsT = g_stopsLevel * g_point / g_pipSize;
      double freezeInPipsT = g_freezeLevel * g_point / g_pipSize;
      FileWriteString(h, StringFormat("stops_level_pips = %.1f\r\n", stopsInPipsT));
      FileWriteString(h, StringFormat("freeze_level_points = %d\r\n", g_freezeLevel));
      FileWriteString(h, StringFormat("freeze_level_pips = %.1f\r\n", freezeInPipsT));
      // Grade based on PIPS (normalized) — 0-5 ideal, 5-20 A-book caution, >20 restrictive
      string stopsGrade;
      if(stopsInPipsT < 0.01) stopsGrade = "IDEAL_NO_RESTRICTION";
      else if(stopsInPipsT <= 5.0) stopsGrade = "IDEAL_A_BOOK";
      else if(stopsInPipsT <= 20.0) stopsGrade = "A_BOOK_CAUTION";
      else stopsGrade = "UNUSUALLY_RESTRICTIVE";
      FileWriteString(h, StringFormat("stops_level_grade = \"%s\"\r\n", stopsGrade));
   }
   FileWriteString(h, StringFormat("tick_value = %.6f\r\n", g_tickValue));
   // tick_value_calc: fallback when broker reports 0 (common on cents accounts)
   {
      double tvCalc = g_tickValue;
      if(tvCalc <= 0.0 && g_contractSize > 0 && g_tickSize > 0)
      {
         double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         if(ask > 0.0)
            tvCalc = g_contractSize * g_tickSize / ask;
      }
      FileWriteString(h, StringFormat("tick_value_calc = %.6f\r\n", tvCalc));
   }
   FileWriteString(h, StringFormat("tick_size = %.6f\r\n", g_tickSize));
   FileWriteString(h, StringFormat("point = %.6f\r\n", g_point));
   FileWriteString(h, StringFormat("digits = %d\r\n", g_digits));
   FileWriteString(h, StringFormat("contract_size = %.2f\r\n", g_contractSize));
   FileWriteString(h, StringFormat("volume_max = %.2f\r\n", SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX)));
   FileWriteString(h, StringFormat("swap_long = %.6f\r\n", SymbolInfoDouble(Symbol(), SYMBOL_SWAP_LONG)));
   FileWriteString(h, StringFormat("swap_short = %.6f\r\n", SymbolInfoDouble(Symbol(), SYMBOL_SWAP_SHORT)));
   {
      int swapMode = (int)SymbolInfoInteger(Symbol(), SYMBOL_SWAP_MODE);
      string swapModeStr = "unknown";
      if(swapMode == SYMBOL_SWAP_MODE_POINTS)         swapModeStr = "points";
      else if(swapMode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL) swapModeStr = "currency_symbol";
      else if(swapMode == SYMBOL_SWAP_MODE_CURRENCY_MARGIN) swapModeStr = "currency_margin";
      else if(swapMode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT) swapModeStr = "currency_deposit";
      else if(swapMode == SYMBOL_SWAP_MODE_INTEREST_CURRENT) swapModeStr = "interest_current";
      else if(swapMode == SYMBOL_SWAP_MODE_INTEREST_OPEN)    swapModeStr = "interest_open";
      else if(swapMode == SYMBOL_SWAP_MODE_REOPEN_CURRENT)   swapModeStr = "reopen_current";
      else if(swapMode == SYMBOL_SWAP_MODE_REOPEN_BID)       swapModeStr = "reopen_bid";
      else if(swapMode == SYMBOL_SWAP_MODE_DISABLED)         swapModeStr = "disabled";
      FileWriteString(h, StringFormat("swap_mode = \"%s\"\r\n", swapModeStr));
   }
   {
      // Triple swap rollover day: SYMBOL_SWAP_ROLLOVER3DAYS
      // 0=Sunday, 1=Monday, ..., 6=Saturday. Most brokers use 3 (Wednesday).
      int rolloverDay = (int)SymbolInfoInteger(Symbol(), SYMBOL_SWAP_ROLLOVER3DAYS);
      string dayNames[] = {"sunday","monday","tuesday","wednesday","thursday","friday","saturday"};
      string dayStr = (rolloverDay >= 0 && rolloverDay <= 6) ? dayNames[rolloverDay] : "wednesday";
      FileWriteString(h, StringFormat("swap_rollover3_day = %d\r\n", rolloverDay));
      FileWriteString(h, StringFormat("swap_rollover3_day_name = \"%s\"\r\n", dayStr));
   }
   FileWriteString(h, StringFormat("stopout_level = %.2f\r\n", AccountInfoDouble(ACCOUNT_MARGIN_SO_SO)));
   {
      int soMode = (int)AccountInfoInteger(ACCOUNT_MARGIN_SO_MODE);
      FileWriteString(h, StringFormat("stopout_mode = \"%s\"\r\n", soMode == ACCOUNT_STOPOUT_MODE_PERCENT ? "percent" : "money"));
   }
   // Commission measured from calibration test trades (per lot per side, in account currency)
   // 0.0 = commission-free; value from DEAL_COMMISSION on market buy/sell test fills
   FileWriteString(h, StringFormat("commission_buy = %.6f\r\n", g_mktBuyCommission));
   FileWriteString(h, StringFormat("commission_sell = %.6f\r\n", g_mktSellCommission));
   {
      bool hasComm = (MathAbs(g_mktBuyCommission) > 0.000001 || MathAbs(g_mktSellCommission) > 0.000001);
      FileWriteString(h, StringFormat("commission_free = %s\r\n", hasComm ? "false" : "true"));
   }
   FileWriteString(h, StringFormat("currency_digits = %d\r\n", g_currencyDigits));
   FileWriteString(h, StringFormat("base_symbol = \"%s\"\r\n", g_baseSymbol));
   FileWriteString(h, StringFormat("standard_digits = %d\r\n", g_stdDigits));
   FileWriteString(h, StringFormat("pip_size = %.6f\r\n", g_pipSize));
   FileWriteString(h, StringFormat("pip_mult = %d\r\n", g_pipMult));
   FileWriteString(h, StringFormat("mt5_build = %d\r\n", g_mt5Build));
   FileWriteString(h, StringFormat("ea_version = \"%s\"\r\n\r\n", FA_VERSION));

   FileWriteString(h, "[broker_limits]\r\n");
   FileWriteString(h, StringFormat("order_limit = %d\r\n", (int)g_orderLimit));
   FileWriteString(h, StringFormat("max_positions_observed = %d\r\n", g_maxPositionsObserved));
   FileWriteString(h, StringFormat("max_pending_observed = %d\r\n", g_maxPendingObserved));
   FileWriteString(h, StringFormat("max_total_observed = %d\r\n", g_maxTotalObserved));
   FileWriteString(h, StringFormat("max_async_burst_stops = %d\r\n", g_stressMaxVerifiedStop));
   FileWriteString(h, StringFormat("max_async_burst_limits = %d\r\n", g_stressMaxVerifiedLimit));
   FileWriteString(h, "# order_limit: ACCOUNT_LIMIT_ORDERS (500=default if broker reports 0)\r\n");
   FileWriteString(h, "# max_async_burst: maximum orders accepted in a single async burst (stress test)\r\n\r\n");

   FileWriteString(h, "[timing]\r\n");
   FileWriteString(h, StringFormat("client_server_roundtrip_ms = %d\r\n", (int)g_clientServerRoundTripMs));
   FileWriteString(h, StringFormat("client_server_lag_ms = %d\r\n", (int)g_clientServerLagMs));
   FileWriteString(h, "cs_calibration_method = \"2pass_pending_order_market_test_avg\"\r\n");
   FileWriteString(h, "cs_calib_passes = 2\r\n");
   FileWriteString(h, StringFormat("cs_pass1_lag_ms = %d\r\n", (int)g_csPass1LagMs));
   FileWriteString(h, StringFormat("cs_pass2_lag_ms = %d\r\n", (int)g_csPass2LagMs));
   FileWriteString(h, StringFormat("cs_calib_place_rt_ms = %d\r\n", (int)g_csCalibPlaceRtMs));
   FileWriteString(h, StringFormat("cs_calib_delete_rt_ms = %d\r\n", (int)g_csCalibDeleteRtMs));
   {
      int gmtOffT = (int)((TimeCurrent() - TimeGMT()) / 3600);
      string tzT = (gmtOffT >= 0) ? StringFormat("UTC+%d", gmtOffT) : StringFormat("UTC%d", gmtOffT);
      FileWriteString(h, StringFormat("collection_start = \"%s\"\r\n", TimeToString(g_collectionStartTime, TIME_DATE | TIME_SECONDS)));
      FileWriteString(h, StringFormat("collection_end = \"%s\"\r\n", TimeToString(g_collectionEndTime, TIME_DATE | TIME_SECONDS)));
      FileWriteString(h, StringFormat("server_timezone = \"%s\"\r\n", tzT));
      long totSecsT = (long)(g_collectionEndTime - g_collectionStartTime);
      int hT = (int)(totSecsT / 3600); int mT = (int)((totSecsT % 3600) / 60); int sT = (int)(totSecsT % 60);
      string durT;
      if(hT > 0) durT = StringFormat("%dh %dm %ds", hT, mT, sT);
      else if(mT > 0) durT = StringFormat("%dm %ds", mT, sT);
      else durT = StringFormat("%ds", sT);
      FileWriteString(h, StringFormat("total_duration = \"%s\"\r\n", durT));
      FileWriteString(h, StringFormat("total_deals = %d\r\n", g_fillCount));
      int cltMinT = 60;
      FileWriteString(h, StringFormat("clt_minimum_deals = %d\r\n", cltMinT));
      FileWriteString(h, StringFormat("statistically_representative = %s\r\n\r\n", (g_fillCount >= cltMinT) ? "true" : "false"));
   }

   FileWriteString(h, "[timing.calibration]  # 2-pass averaged sync market test results\r\n");
   FileWriteString(h, StringFormat("open_buy_ms = %.1f\r\n", g_mktSyncOpenBuyMs));
   FileWriteString(h, StringFormat("open_sell_ms = %.1f\r\n", g_mktSyncOpenSellMs));
   FileWriteString(h, StringFormat("sl_buy_ms = %.1f\r\n", g_mktSyncSLBuyMs));
   FileWriteString(h, StringFormat("sl_sell_ms = %.1f\r\n", g_mktSyncSLSellMs));
   FileWriteString(h, StringFormat("tp_buy_ms = %.1f\r\n", g_mktSyncTPBuyMs));
   FileWriteString(h, StringFormat("tp_sell_ms = %.1f\r\n", g_mktSyncTPSellMs));
   FileWriteString(h, StringFormat("close_buy_ms = %.1f\r\n", g_mktSyncCloseBuyMs));
   FileWriteString(h, StringFormat("close_buy_pnl = %.2f\r\n", g_mktCloseBuyPnL));
   FileWriteString(h, StringFormat("close_buy_in_profit = %s\r\n", g_mktCloseBuyInProfit ? "true" : "false"));
   FileWriteString(h, StringFormat("close_sell_ms = %.1f\r\n", g_mktSyncCloseSellMs));
   FileWriteString(h, StringFormat("close_sell_pnl = %.2f\r\n", g_mktCloseSellPnL));
   FileWriteString(h, StringFormat("close_sell_in_profit = %s\r\n\r\n", g_mktCloseSellInProfit ? "true" : "false"));

   FileWriteString(h, "[timing.calibration_pass1]  # Raw pass 1 values before averaging\r\n");
   FileWriteString(h, StringFormat("open_buy_ms = %.1f\r\n", g_pass1SyncOpenBuyMs));
   FileWriteString(h, StringFormat("open_sell_ms = %.1f\r\n", g_pass1SyncOpenSellMs));
   FileWriteString(h, StringFormat("sl_buy_ms = %.1f\r\n", g_pass1SyncSLBuyMs));
   FileWriteString(h, StringFormat("sl_sell_ms = %.1f\r\n", g_pass1SyncSLSellMs));
   FileWriteString(h, StringFormat("tp_buy_ms = %.1f\r\n", g_pass1SyncTPBuyMs));
   FileWriteString(h, StringFormat("tp_sell_ms = %.1f\r\n", g_pass1SyncTPSellMs));
   FileWriteString(h, StringFormat("close_buy_ms = %.1f\r\n", g_pass1SyncCloseBuyMs));
   FileWriteString(h, StringFormat("close_sell_ms = %.1f\r\n\r\n", g_pass1SyncCloseSellMs));

   FileWriteString(h, "[test_parameters]\r\n");
   FileWriteString(h, StringFormat("total_cycles = %d\r\n", g_cycleNum));
   FileWriteString(h, StringFormat("grid_start_mult = %.1f\r\n", InpGridStartMult));
   FileWriteString(h, StringFormat("grid_levels_per_side = %d\r\n", GRID_LEVELS_PER_SIDE));
   FileWriteString(h, StringFormat("grid_spacing_pct = %.1f\r\n", InpGridSpacingPct));
   FileWriteString(h, StringFormat("dwell_seconds = %d\r\n", InpDwellSeconds));
   FileWriteString(h, StringFormat("total_fills = %d\r\n", g_fillCount));
   FileWriteString(h, StringFormat("total_lots = %.2f\r\n\r\n", g_totalLotsTraded));

   // Per-type statistics
   // Drift metrics measure deal price vs broker receipt price:
   //   Pending orders: receipt price = trigger price (broker's execution obligation)
   //   Market/close orders: receipt price = market bid/ask when broker received instruction
   //   CS lag excluded — network latency is not broker behavior
   //   Zero drift = fill at correct price (but asymmetric lag still harms via out-of-sequence fills)
   //   Non-zero drift = broker-caused price impact during holding time
   string typeNames[10];
   typeNames[0]="market_buy"; typeNames[1]="market_sell"; typeNames[2]="buy_stop"; typeNames[3]="sell_stop";
   typeNames[4]="buy_limit"; typeNames[5]="sell_limit"; typeNames[6]="take_profit"; typeNames[7]="stop_loss"; typeNames[8]="async_close"; typeNames[9]="sync_close";
   for(int t = 0; t < 10; t++)
   {
      if(g_countByType[t] == 0) continue;
      FileWriteString(h, StringFormat("[execution.%s]\r\n", typeNames[t]));
      FileWriteString(h, StringFormat("count = %d\r\n", g_countByType[t]));
      FileWriteString(h, StringFormat("median_lag_ms = %.1f\r\n", g_medianLag[t]));
      FileWriteString(h, StringFormat("mean_lag_ms = %.1f\r\n", g_meanLag[t]));
      FileWriteString(h, StringFormat("min_lag_ms = %.1f\r\n", g_minLag[t]));
      FileWriteString(h, StringFormat("max_lag_ms = %.1f\r\n", g_maxLag[t]));
      FileWriteString(h, StringFormat("mean_price_drift_signed = %.4f\r\n", g_meanSlipSigned[t]));
      FileWriteString(h, StringFormat("mean_price_drift_abs = %.4f\r\n", g_meanSlipAbs[t]));
      FileWriteString(h, StringFormat("total_lag_cost_usd = %.4f\r\n", g_totalSlipUSD[t]));
      // Drift lag: broker processing time for server-side triggers
      if(g_driftLagCount[t] > 0)
      {
         double meanDriftLag = g_driftLagSum[t] / g_driftLagCount[t];
         FileWriteString(h, StringFormat("mean_drift_lag_ms = %.1f\r\n", meanDriftLag));
         FileWriteString(h, StringFormat("drift_lag_measured_fills = %d\r\n", g_driftLagCount[t]));
      }

      // Fill model classification (server-side triggers only):
      // "trigger_price" = broker fills at trigger price (but timing still matters for EA operations)
      // "market_price"  = broker fills at market@dealTime → lag has financial impact
      int totalClassified = g_triggerFillCount[t] + g_marketFillCount[t];
      if(t >= 2 && t <= 7 && totalClassified > 0)
      {
         double trigPct = (double)g_triggerFillCount[t] / totalClassified * 100.0;
         string fillModel = (trigPct >= 90.0) ? "trigger_price" :
                            (trigPct >= 50.0) ? "mixed" : "market_price";
         FileWriteString(h, StringFormat("fill_model = \"%s\"  # %.0f%% trigger, %.0f%% market\r\n",
            fillModel, trigPct, 100.0 - trigPct));
         FileWriteString(h, StringFormat("trigger_fill_count = %d\r\n", g_triggerFillCount[t]));
         FileWriteString(h, StringFormat("market_fill_count = %d\r\n", g_marketFillCount[t]));
         bool hasImpact = (trigPct < 90.0);
         FileWriteString(h, StringFormat("lag_has_price_impact = %s\r\n", hasImpact ? "true" : "false"));
      }
      else if(t <= 1 || t >= 8)
      {
         // Market orders / close fills: drift lag thresholds
         double meanDL = (g_driftLagCount[t] > 0) ? g_driftLagSum[t] / g_driftLagCount[t] : -1;
         string execQuality = (meanDL < 0) ? "NO_DATA" :
                               (meanDL < 0.5) ? "PERFECT" :
                               (meanDL < 5.0) ? "GOOD" :
                               (meanDL < 50.0) ? "ACCEPTABLE" : "POOR";
         FileWriteString(h, StringFormat("execution_quality = \"%s\"\r\n", execQuality));
      }
      FileWriteString(h, "# drift_lag_ms: time for market to reach deal price from receipt price (0=perfect, volatility-independent)\r\n");
      FileWriteString(h, "# drift reference: broker receipt price (trigger for pending, market at receipt for market/close)\r\n\r\n");
   }

   // SL/TP placement lags (sync + async)
   {
      double medSyncSL  = CalcMedianFromArray(g_syncSLPlaceLags, g_syncSLPlaceCount);
      double medSyncTP  = CalcMedianFromArray(g_syncTPPlaceLags, g_syncTPPlaceCount);
      double medAsyncSL = CalcMedianFromArray(g_asyncSLPlaceLags, g_asyncSLPlaceCount);
      double medAsyncTP = CalcMedianFromArray(g_asyncTPPlaceLags, g_asyncTPPlaceCount);

      FileWriteString(h, "[execution.sl_placement]\r\n");
      FileWriteString(h, StringFormat("sync_count = %d\r\n", g_syncSLPlaceCount));
      FileWriteString(h, StringFormat("sync_median_ms = %.1f\r\n", medSyncSL));
      FileWriteString(h, StringFormat("async_count = %d\r\n", g_asyncSLPlaceCount));
      FileWriteString(h, StringFormat("async_median_ms = %.1f\r\n\r\n", medAsyncSL));

      FileWriteString(h, "[execution.tp_placement]\r\n");
      FileWriteString(h, StringFormat("sync_count = %d\r\n", g_syncTPPlaceCount));
      FileWriteString(h, StringFormat("sync_median_ms = %.1f\r\n", medSyncTP));
      FileWriteString(h, StringFormat("async_count = %d\r\n", g_asyncTPPlaceCount));
      FileWriteString(h, StringFormat("async_median_ms = %.1f\r\n\r\n", medAsyncTP));
   }

   // Async open (grid placement lag)
   {
      double tomlAsyncOpenMs = 0;
      if(g_gridEarliestSetupMsc > 0 && g_gridPlacedMs > 0)
      {
         long aoSendEpoch = (long)(g_epochMsOffset + g_gridPlacedMs);
         tomlAsyncOpenMs = (double)(g_gridEarliestSetupMsc - aoSendEpoch - (long)g_clientServerLagMs);
         if(tomlAsyncOpenMs < 0) tomlAsyncOpenMs = 0;
      }
      FileWriteString(h, "[execution.grid_placement]\r\n");
      FileWriteString(h, "# broker_exec = ORDER_TIME_SETUP_MSC - send_epoch - CS_lag (first grid order acknowledged)\r\n");
      FileWriteString(h, StringFormat("confirmed_orders = %d\r\n", g_gridOrdersConfirmed));
      FileWriteString(h, StringFormat("broker_exec_ms = %.1f\r\n\r\n", tomlAsyncOpenMs));
   }

   // Async vs Sync close breakdown
   // Both use same formula: broker_exec = DEAL_TIME_MSC - (send_epoch + CS_lag)
   // = broker_receive → broker_close (pure broker processing)
   // Async: send_epoch from batch trigger, majority of fills
   // Sync:  send_epoch from each individual PositionClose call
   FileWriteString(h, "[execution.async_close]\r\n");
   FileWriteString(h, "# broker_exec = DEAL_TIME_MSC - send_epoch - CS_lag (pure broker processing)\r\n");
   FileWriteString(h, StringFormat("count = %d\r\n", g_asyncCloseCount));
   FileWriteString(h, StringFormat("majority_threshold_pct = %.0f\r\n", CLOSE_MAJORITY_PCT * 100.0));
   FileWriteString(h, StringFormat("median_broker_exec_ms = %.1f\r\n", g_asyncCloseMedianLag));
   FileWriteString(h, StringFormat("mean_broker_exec_ms = %.1f\r\n", g_asyncCloseMeanLag));
   FileWriteString(h, StringFormat("standard_good_ms = %d\r\n", STD_CLOSE_GOOD_MS));
   FileWriteString(h, StringFormat("standard_slow_ms = %d\r\n", STD_CLOSE_SLOW_MS));
   FileWriteString(h, StringFormat("standard_manip_ms = %d\r\n", STD_CLOSE_MANIP_MS));
   string asyncAssessToml = (g_asyncCloseMedianLag > STD_CLOSE_MANIP_MS) ? "FAIL" :
                             (g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS) ? "WARNING" : "PASS";
   FileWriteString(h, StringFormat("assessment = \"%s\"\r\n", asyncAssessToml));
   // Close profit vs loss asymmetry (merged here — no separate section)
   FileWriteString(h, StringFormat("profit_median_ms = %.1f\r\n", CalcMedianFromArray(g_closeProfitLags, g_closeProfitCount)));
   FileWriteString(h, StringFormat("profit_count = %d\r\n", g_closeProfitCount));
   FileWriteString(h, StringFormat("loss_median_ms = %.1f\r\n", CalcMedianFromArray(g_closeLossLags, g_closeLossCount)));
   FileWriteString(h, StringFormat("loss_count = %d\r\n", g_closeLossCount));
   FileWriteString(h, StringFormat("straggler_profit_median_ms = %.1f\r\n", CalcMedianFromArray(g_stragProfitLags, g_stragProfitCount)));
   FileWriteString(h, StringFormat("straggler_profit_count = %d\r\n", g_stragProfitCount));
   FileWriteString(h, StringFormat("straggler_loss_median_ms = %.1f\r\n", CalcMedianFromArray(g_stragLossLags, g_stragLossCount)));
   FileWriteString(h, StringFormat("straggler_loss_count = %d\r\n\r\n", g_stragLossCount));

   FileWriteString(h, "[execution.sync_close]\r\n");
   FileWriteString(h, "# broker_exec = DEAL_TIME_MSC - send_epoch - CS_lag (same formula as async)\r\n");
   FileWriteString(h, StringFormat("count = %d\r\n", g_syncCloseCount));
   FileWriteString(h, StringFormat("median_broker_exec_ms = %.1f\r\n", g_syncCloseMedianLag));
   FileWriteString(h, StringFormat("mean_broker_exec_ms = %.1f\r\n", g_syncCloseMeanLag));
   FileWriteString(h, StringFormat("standard_good_ms = %d\r\n", STD_SYNC_CLOSE_GOOD_MS));
   FileWriteString(h, StringFormat("standard_slow_ms = %d\r\n", STD_SYNC_CLOSE_SLOW_MS));
   FileWriteString(h, StringFormat("standard_manip_ms = %d\r\n", STD_SYNC_CLOSE_MANIP_MS));
   if(g_syncCloseCount > 0)
   {
      string syncAssessToml = (g_syncCloseMedianLag > STD_SYNC_CLOSE_MANIP_MS) ? "FAIL" :
                               (g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS) ? "WARNING" : "PASS";
      FileWriteString(h, StringFormat("assessment = \"%s\"\r\n\r\n", syncAssessToml));
   }
   else
      FileWriteString(h, "assessment = \"N/A\"\r\n\r\n");

   // Close timestamp verification: deal price vs tick at DEAL_TIME_MSC
   // This validates broker timestamp honesty — does the price at DEAL_TIME_MSC match the deal price?
   // If yes: broker's timestamp is truthful. If no: broker may be backdating or fudging timestamps.
   // This is SEPARATE from execution drift (which measures receipt price vs deal price).
   FileWriteString(h, "[execution.close_timestamp_verification]\r\n");
   FileWriteString(h, "# Validates broker timestamp honesty: deal price vs market price at broker's claimed execution time\r\n");
   FileWriteString(h, "# tick_lookup_time = DEAL_TIME_MSC - epoch_offset + CS_lag (accounts for tick arrival delay)\r\n");
   FileWriteString(h, "# This is separate from execution drift — drift measures receipt-to-fill, this validates timestamps\r\n");
   FileWriteString(h, StringFormat("verified_fills = %d\r\n", g_closePriceVerifyCount));
   FileWriteString(h, StringFormat("mismatches = %d\r\n", g_closePriceMismatchCount));
   if(g_closePriceVerifyCount > 0)
   {
      FileWriteString(h, StringFormat("mean_abs_delta_pts = %.2f\r\n",
         g_closePriceVerifyAbsSum / g_closePriceVerifyCount));
      FileWriteString(h, StringFormat("max_abs_delta_pts = %.2f\r\n", g_closePriceVerifyMaxAbs));
      bool fastCloseExecToml = (g_asyncCloseMedianLag <= 20 && (g_syncCloseCount == 0 || g_syncCloseMedianLag <= 20));
      string verifyAssess;
      if(g_closePriceMismatchCount == 0) verifyAssess = "PASS";
      else if(g_closePriceMismatchCount <= 2) verifyAssess = "ACCEPTABLE";
      else if(fastCloseExecToml) verifyAssess = "NOTE";
      else verifyAssess = "FAIL";
      FileWriteString(h, StringFormat("assessment = \"%s\"\r\n", verifyAssess));
   }
   else
      FileWriteString(h, "assessment = \"NO_DATA\"\r\n");
   FileWriteString(h, "\r\n");

   // Asymmetric analysis
   double medStopLag = 0, medLimitLag = 0;
   if(g_countByType[2] > 0 || g_countByType[3] > 0)
      medStopLag = (g_medianLag[2] * g_countByType[2] + g_medianLag[3] * g_countByType[3]) /
                   MathMax(1, g_countByType[2] + g_countByType[3]);
   if(g_countByType[4] > 0 || g_countByType[5] > 0)
      medLimitLag = (g_medianLag[4] * g_countByType[4] + g_medianLag[5] * g_countByType[5]) /
                    MathMax(1, g_countByType[4] + g_countByType[5]);

   FileWriteString(h, "[analysis.asymmetry]\r\n");
   // Fill accuracy per type (primary metric)
   int tomlStopClass = g_triggerFillCount[2] + g_marketFillCount[2] + g_triggerFillCount[3] + g_marketFillCount[3];
   int tomlStopTrig = g_triggerFillCount[2] + g_triggerFillCount[3];
   int tomlLimClass = g_triggerFillCount[4] + g_marketFillCount[4] + g_triggerFillCount[5] + g_marketFillCount[5];
   int tomlLimTrig = g_triggerFillCount[4] + g_triggerFillCount[5];
   int tomlTPClass = g_triggerFillCount[6] + g_marketFillCount[6];
   int tomlSLClass = g_triggerFillCount[7] + g_marketFillCount[7];
   FileWriteString(h, StringFormat("stop_trigger_fill_pct = %.2f\r\n", (tomlStopClass > 0) ? (double)tomlStopTrig / tomlStopClass * 100 : -1));
   FileWriteString(h, StringFormat("limit_trigger_fill_pct = %.2f\r\n", (tomlLimClass > 0) ? (double)tomlLimTrig / tomlLimClass * 100 : -1));
   FileWriteString(h, StringFormat("tp_trigger_fill_pct = %.2f\r\n", (tomlTPClass > 0) ? (double)g_triggerFillCount[6] / tomlTPClass * 100 : -1));
   FileWriteString(h, StringFormat("sl_trigger_fill_pct = %.2f\r\n", (tomlSLClass > 0) ? (double)g_triggerFillCount[7] / tomlSLClass * 100 : -1));
   // Lag context
   FileWriteString(h, StringFormat("stop_median_lag_ms = %.1f\r\n", medStopLag));
   FileWriteString(h, StringFormat("limit_median_lag_ms = %.1f\r\n", medLimitLag));
   double slr = (medLimitLag > 0.001) ? medStopLag / medLimitLag : (medStopLag > 0.001 ? 999.0 : 0);
   FileWriteString(h, StringFormat("stop_limit_ratio = %.2f\r\n", slr));
   FileWriteString(h, StringFormat("sl_price_drift_abs = %.4f\r\n", g_meanSlipAbs[7]));
   FileWriteString(h, StringFormat("tp_price_drift_abs = %.4f\r\n", g_meanSlipAbs[6]));
   double tpslr = (g_meanSlipAbs[6] > 0.01) ? g_meanSlipAbs[7] / g_meanSlipAbs[6] : 0;
   FileWriteString(h, StringFormat("tpsl_ratio = %.2f\r\n", tpslr));
   FileWriteString(h, StringFormat("fill_async_close_ratio = %.2f\r\n",
      (medStopLag > 0.001 && g_asyncCloseMedianLag > 0.001) ? g_asyncCloseMedianLag / medStopLag : 0));
   FileWriteString(h, StringFormat("fill_sync_close_ratio = %.2f\r\n\r\n",
      (medStopLag > 0.001 && g_syncCloseMedianLag > 0.001) ? g_syncCloseMedianLag / medStopLag : 0));

   // Fill clustering (exact-match: same price + timestamp + direction + category)
   FileWriteString(h, "[analysis.fill_clustering]\r\n");
   FileWriteString(h, "cluster_method = \"exact_match_price_timestamp_direction_category\"\r\n");
   FileWriteString(h, StringFormat("clusters_detected = %d\r\n", g_clusterCount));
   FileWriteString(h, StringFormat("isolated_fills = %d\r\n", g_isolatedFills));
   FileWriteString(h, StringFormat("avg_cluster_size = %.1f\r\n", g_avgClusterSize));
   FileWriteString(h, StringFormat("max_cluster_size = %d\r\n", (int)g_maxClusterSize));
   FileWriteString(h, StringFormat("avg_inter_cluster_gap_ms = %.1f\r\n", g_avgInterClusterGap));
   FileWriteString(h, StringFormat("cluster_ratio = %.4f\r\n", g_clusterRatio));
   FileWriteString(h, StringFormat("cluster_verdict = \"%s\"\r\n\r\n", g_clusterVerdict));

   // Fill model classification (which pricing model does the broker use?)
   // broker.rs uses this to determine: fill = f(trigger_price, tick_at_deal, lag)
   FileWriteString(h, "[analysis.fill_model]\r\n");
   FileWriteString(h, StringFormat("total_classified = %d\r\n", g_fmTotal));
   FileWriteString(h, StringFormat("unclassifiable = %d\r\n", g_fmUnclassifiable));
   FileWriteString(h, StringFormat("last_tick_count = %d\r\n", g_fmLastTick));
   FileWriteString(h, StringFormat("last_tick_pct = %.1f\r\n",
      (g_fmTotal > 0) ? 100.0 * g_fmLastTick / g_fmTotal : 0));
   FileWriteString(h, StringFormat("trigger_price_count = %d\r\n", g_fmTrigger));
   FileWriteString(h, StringFormat("trigger_price_pct = %.1f\r\n",
      (g_fmTotal > 0) ? 100.0 * g_fmTrigger / g_fmTotal : 0));
   FileWriteString(h, StringFormat("lag_interpolated_count = %d\r\n", g_fmLagInterp));
   FileWriteString(h, StringFormat("lag_interpolated_pct = %.1f\r\n",
      (g_fmTotal > 0) ? 100.0 * g_fmLagInterp / g_fmTotal : 0));
   FileWriteString(h, StringFormat("worst_price_count = %d\r\n", g_fmWorstPrice));
   FileWriteString(h, StringFormat("worst_price_pct = %.1f\r\n",
      (g_fmTotal > 0) ? 100.0 * g_fmWorstPrice / g_fmTotal : 0));
   FileWriteString(h, StringFormat("dominant_model = \"%s\"\r\n", g_fmDominantModel));
   FileWriteString(h, StringFormat("regression_alpha = %.6f\r\n", g_fmAlpha));
   FileWriteString(h, StringFormat("regression_beta = %.6f\r\n", g_fmBeta));
   FileWriteString(h, "# fill_price ~ alpha * requested_price + beta * tick_at_deal\r\n\r\n");

   // Per-cluster detail arrays (for broker.rs regression with raw data)
   for(int ci = 0; ci < g_clusterDetailCount; ci++)
   {
      FileWriteString(h, "[[analysis.fill_clustering.cluster]]\r\n");
      FileWriteString(h, StringFormat("fill_price = %.5f\r\n", g_clusterDetails[ci].fillPrice));
      FileWriteString(h, StringFormat("deal_time_msc = %I64d\r\n", g_clusterDetails[ci].dealTimeMsc));
      FileWriteString(h, StringFormat("direction = \"%s\"\r\n", g_clusterDetails[ci].isBuy ? "buy" : "sell"));
      FileWriteString(h, StringFormat("category = \"%s\"\r\n", g_clusterDetails[ci].isLimit ? "limit" : "stop"));
      FileWriteString(h, StringFormat("member_count = %d\r\n", g_clusterDetails[ci].memberCount));
      FileWriteString(h, StringFormat("distinct_requested_prices = %d\r\n", g_clusterDetails[ci].distinctReqPrices));
      FileWriteString(h, StringFormat("is_same_level_cluster = %s\r\n",
         g_clusterDetails[ci].isSameLevelCluster ? "true" : "false"));
      FileWriteString(h, StringFormat("best_fit_model = \"%s\"\r\n", g_clusterDetails[ci].bestFitModel));
      FileWriteString(h, StringFormat("mean_lag_ms = %.1f\r\n", g_clusterDetails[ci].meanLagMs));
      FileWriteString(h, StringFormat("mean_slippage_pts = %.2f\r\n", g_clusterDetails[ci].meanSlippagePts));
      FileWriteString(h, StringFormat("mean_tick_delta_pts = %.2f\r\n", g_clusterDetails[ci].meanTickDeltaPts));
      FileWriteString(h, StringFormat("tick_drift_rate_pts_per_ms = %.6f\r\n", g_clusterDetails[ci].tickDriftRate));
      FileWriteString(h, StringFormat("residual_last_tick = %.2f\r\n", g_clusterDetails[ci].residualLastTick));
      FileWriteString(h, StringFormat("residual_trigger = %.2f\r\n", g_clusterDetails[ci].residualTrigger));
      FileWriteString(h, StringFormat("residual_lag_interpolated = %.2f\r\n", g_clusterDetails[ci].residualLagInterp));
      FileWriteString(h, StringFormat("residual_worst_price = %.2f\r\n", g_clusterDetails[ci].residualWorstPrice));

      // Member arrays — built via string concatenation
      int mc = g_clusterDetails[ci].memberCount;

      // member_requested_prices
      string arrStr = "[";
      for(int m = 0; m < mc; m++)
      {
         if(m > 0) arrStr += ", ";
         arrStr += DoubleToString(g_clusterDetails[ci].memReqPrices[m], 5);
      }
      arrStr += "]";
      FileWriteString(h, "member_requested_prices = " + arrStr + "\r\n");

      // member_lag_ms
      arrStr = "[";
      for(int m = 0; m < mc; m++)
      {
         if(m > 0) arrStr += ", ";
         arrStr += DoubleToString(g_clusterDetails[ci].memLagMs[m], 1);
      }
      arrStr += "]";
      FileWriteString(h, "member_lag_ms = " + arrStr + "\r\n");

      // member_slippage_pts
      arrStr = "[";
      for(int m = 0; m < mc; m++)
      {
         if(m > 0) arrStr += ", ";
         arrStr += DoubleToString(g_clusterDetails[ci].memSlipPts[m], 2);
      }
      arrStr += "]";
      FileWriteString(h, "member_slippage_pts = " + arrStr + "\r\n");

      // member_tick_at_deal
      arrStr = "[";
      for(int m = 0; m < mc; m++)
      {
         if(m > 0) arrStr += ", ";
         arrStr += DoubleToString(g_clusterDetails[ci].memTickAtDeal[m], 5);
      }
      arrStr += "]";
      FileWriteString(h, "member_tick_at_deal = " + arrStr + "\r\n");

      // member_price_verify_delta
      arrStr = "[";
      for(int m = 0; m < mc; m++)
      {
         if(m > 0) arrStr += ", ";
         arrStr += DoubleToString(g_clusterDetails[ci].memVerifyDelta[m], 2);
      }
      arrStr += "]";
      FileWriteString(h, "member_price_verify_delta = " + arrStr + "\r\n\r\n");
   }

   // Price-based batching (actual fill damage — for broker.rs emulation)
   FileWriteString(h, "[analysis.price_batching]\r\n");
   FileWriteString(h, StringFormat("total_priced_fills = %d\r\n", g_totalPricedFills));
   FileWriteString(h, StringFormat("fair_fills = %d\r\n", g_fairFills));
   FileWriteString(h, StringFormat("fair_fill_pct = %.2f\r\n",
      (g_totalPricedFills > 0) ? (double)g_fairFills / g_totalPricedFills * 100 : 0));
   FileWriteString(h, StringFormat("stop_fair_fills = %d\r\n", g_fairFillsStop));
   FileWriteString(h, StringFormat("stop_total_priced = %d\r\n", g_totalStopPriced));
   FileWriteString(h, StringFormat("stop_fair_pct = %.2f\r\n",
      (g_totalStopPriced > 0) ? (double)g_fairFillsStop / g_totalStopPriced * 100 : 0));
   FileWriteString(h, StringFormat("limit_fair_fills = %d\r\n", g_fairFillsLimit));
   FileWriteString(h, StringFormat("limit_total_priced = %d\r\n", g_totalLimitPriced));
   FileWriteString(h, StringFormat("limit_fair_pct = %.2f\r\n",
      (g_totalLimitPriced > 0) ? (double)g_fairFillsLimit / g_totalLimitPriced * 100 : 0));
   FileWriteString(h, StringFormat("batches_detected = %d\r\n", g_batchCount));
   FileWriteString(h, StringFormat("batched_fills = %d\r\n", g_totalBatchedFills));
   FileWriteString(h, StringFormat("individual_fills = %d\r\n", g_individualFills));
   FileWriteString(h, StringFormat("batch_ratio = %.4f\r\n", g_batchRatio));
   FileWriteString(h, StringFormat("avg_batch_size = %.1f\r\n", g_avgBatchSize));
   FileWriteString(h, StringFormat("max_batch_size = %d\r\n", g_maxBatchSize));
   FileWriteString(h, StringFormat("total_broker_advantage_pts = %.1f\r\n", g_batchAdvantagePts));
   FileWriteString(h, StringFormat("avg_broker_advantage_pts = %.2f\r\n", g_avgBatchAdvantagePts));
   FileWriteString(h, StringFormat("avg_batch_hold_ms = %.1f\r\n", g_avgBatchTimeSpanMs));
   FileWriteString(h, StringFormat("max_batch_hold_ms = %.1f\r\n", g_maxBatchTimeSpanMs));
   FileWriteString(h, StringFormat("median_batch_hold_ms = %.1f\r\n", g_medBatchTimeSpanMs));
   FileWriteString(h, StringFormat("classification = \"%s\"\r\n\r\n", g_batchClassification));

   // Rounding
   FileWriteString(h, "[analysis.rounding]\r\n");
   FileWriteString(h, StringFormat("error_count = %d\r\n", (int)g_roundingErrorCount));
   FileWriteString(h, StringFormat("cumulative_error = %.6f\r\n", g_roundingErrorSum));
   FileWriteString(h, StringFormat("abs_cumulative = %.6f\r\n", g_roundingErrorAbsSum));
   FileWriteString(h, StringFormat("max_error = %.6f\r\n", g_roundingErrorMax));
   FileWriteString(h, StringFormat("broker_profit_sum = %.6f\r\n", g_brokerProfitSum));
   FileWriteString(h, StringFormat("exact_profit_sum = %.6f\r\n\r\n", g_exactProfitSum));

   // Financial damage
   FileWriteString(h, "[financial_damage]\r\n");
   // Compute total damage consistently (same 5-component formula as PDF/HTML)
   double totalDamage = 0;
   if(g_batchClassification != "FAIR")
   {
      totalDamage = g_totalAdverseSlipUSD + MathAbs(g_totalFinancialDelta) + MathAbs(g_roundingErrorSum);
      if(g_countByType[2] > 0 && g_countByType[4] > 0)
      { double sL = (g_countByType[2]+g_countByType[3] > 0) ? (g_medianLag[2]*g_countByType[2]+g_medianLag[3]*g_countByType[3])/(g_countByType[2]+g_countByType[3]) : 0;
        double lL = (g_countByType[4]+g_countByType[5] > 0) ? (g_medianLag[4]*g_countByType[4]+g_medianLag[5]*g_countByType[5])/(g_countByType[4]+g_countByType[5]) : 0;
        double exL = sL - lL; if(exL > 0) totalDamage += (exL / 1000.0) * 0.5 * g_totalLotsTraded * g_tickValue; }
      if(g_countByType[6] > 0 && g_countByType[7] > 0)
      { double exS = g_meanSlipAbs[7] - g_meanSlipAbs[6]; if(exS > 0) totalDamage += (exS / g_tickSize) * g_tickValue * g_lotSize * g_countByType[7]; }
   }
   FileWriteString(h, StringFormat("adverse_lag_cost_usd = %.4f\r\n", g_totalAdverseSlipUSD));
   FileWriteString(h, StringFormat("adverse_lag_cost_pips = %.2f\r\n", g_totalAdverseSlipPips));
   FileWriteString(h, StringFormat("adverse_fill_count = %d\r\n", g_adverseFillCount));
   FileWriteString(h, StringFormat("stop_adverse_usd = %.4f\r\n", g_stopAdverseSlipUSD));
   FileWriteString(h, StringFormat("stop_adverse_pips = %.2f\r\n", g_stopAdverseSlipPips));
   FileWriteString(h, StringFormat("stop_adverse_count = %d\r\n", g_stopAdverseFillCount));
   FileWriteString(h, StringFormat("limit_adverse_usd = %.4f\r\n", g_limitAdverseSlipUSD));
   FileWriteString(h, StringFormat("limit_adverse_pips = %.2f\r\n", g_limitAdverseSlipPips));
   FileWriteString(h, StringFormat("limit_adverse_count = %d\r\n", g_limitAdverseFillCount));
   FileWriteString(h, StringFormat("close_lag_impact_usd = %.4f\r\n", MathAbs(g_totalFinancialDelta)));
   FileWriteString(h, StringFormat("rounding_skew_usd = %.6f\r\n", MathAbs(g_roundingErrorSum)));
   FileWriteString(h, StringFormat("total_damage_usd = %.4f\r\n", totalDamage));
   double perLot = (g_totalLotsTraded > 0) ? totalDamage / g_totalLotsTraded : 0;
   FileWriteString(h, StringFormat("damage_per_lot = %.4f\r\n", perLot));
   FileWriteString(h, StringFormat("projected_annual_1lot = %.2f\r\n\r\n", perLot * 252));

   // Previous day tick-based damage projection
   if(g_prevDayDataValid)
   {
      FileWriteString(h, "[financial_damage.prev_day_projection]\r\n");
      FileWriteString(h, StringFormat("date = \"%s\"\r\n", TimeToString(g_prevDayStart, TIME_DATE)));
      FileWriteString(h, StringFormat("tick_count = %d\r\n", g_prevDayTickCount));
      FileWriteString(h, StringFormat("sliding_windows = %d\r\n", g_prevDayWindowCount));
      FileWriteString(h, StringFormat("lag_window_ms = %.0f\r\n", g_prevDayLagUsedMs));
      FileWriteString(h, StringFormat("avg_range_pips = %.2f\r\n", g_prevDayAvgRangePips));
      FileWriteString(h, StringFormat("avg_range_points = %.1f\r\n", g_prevDayAvgRangePoints));
      FileWriteString(h, StringFormat("avg_range_price = %.5f\r\n", g_prevDayAvgRangePrice));
      FileWriteString(h, StringFormat("slippage_per_lot = %.4f\r\n", g_prevDaySlippagePerLot));
      FileWriteString(h, StringFormat("annual_1lot = %.2f\r\n", g_prevDayAnnualDamage1));
      FileWriteString(h, StringFormat("annual_10lot = %.2f\r\n\r\n", g_prevDayAnnualDamage10));
   }

   // Verdict — compute derived values for scoring
   double medTPToml = g_medianLag[6];
   double medSLToml = g_medianLag[7];
   double medMarketToml = 0;
   {
      int nMkt = g_countByType[0] + g_countByType[1];
      if(nMkt > 0)
         medMarketToml = (g_medianLag[0]*g_countByType[0] + g_medianLag[1]*g_countByType[1]) / MathMax(1, nMkt);
   }
   int violations = 0;
   bool hasAsymmetry = false;
   if(medStopLag > STD_FILL_MANIP_MS) violations += 2; else if(medStopLag > STD_FILL_SLOW_MS) violations++;
   if(g_asyncCloseMedianLag > STD_CLOSE_MANIP_MS) violations += 2; else if(g_asyncCloseMedianLag > STD_CLOSE_SLOW_MS) violations++;
   if(g_syncCloseCount > 0) { if(g_syncCloseMedianLag > STD_SYNC_CLOSE_MANIP_MS) violations += 2; else if(g_syncCloseMedianLag > STD_SYNC_CLOSE_SLOW_MS) violations++; }
   // Stop/limit and SL/TP asymmetric lag — always benefits broker
   bool hasStructuralAsymmetryToml = (slr > 2.0) || (tpslr > 1.5);
   if(hasStructuralAsymmetryToml) violations++;  // Asymmetric lag is itself a violation
   if(medTPToml > STD_TPSL_MANIP_MS || medSLToml > STD_TPSL_MANIP_MS) violations += 2;
   else if(medTPToml > STD_TPSL_SLOW_MS || medSLToml > STD_TPSL_SLOW_MS) violations++;
   if(medMarketToml > STD_MARKET_MANIP_MS) violations += 2; else if(medMarketToml > STD_MARKET_SLOW_MS) violations++;
   if(g_batchClassification == "MANIPULATION" && g_roundingErrorSum < -0.01 && g_roundingErrorCount > 5) { violations++; hasAsymmetry = true; }
   // Batch/cluster ratio: only count violations when their own analysis flags a problem
   // A "FAIR" classification means the batch/cluster ratio is normal for this broker's execution speed
   if(g_batchClassification != "FAIR")
   { if(g_batchRatio > 0.60) { violations += 2; } else if(g_batchRatio > 0.30) { violations++; } }
   // Clustering: only count as independent violation when asymmetry exists
   if(g_clusterVerdict != "FAIR" && hasAsymmetry)
   { if(g_clusterRatio * 100.0 > STD_CLUSTER_CAUTION_PCT) { violations += 2; } else if(g_clusterRatio * 100.0 > STD_CLUSTER_FAIR_PCT) { violations++; } }

   string verdict;
   if(hasAsymmetry)
   {
      if(violations >= 6) verdict = "MULTIPLE A-BOOK STANDARDS BREACHED";
      else if(violations >= 4) verdict = "A-BOOK STANDARDS BREACHED";
      else if(violations >= 2) verdict = "SUSPICIOUS — ASYMMETRIC EXECUTION";
      else verdict = "FAIR EXECUTION";
   }
   else
   {
      if(violations >= 4) verdict = "SLOW EXECUTION — EXCEEDS A-BOOK STANDARDS";
      else if(violations >= 1) verdict = "SLOW EXECUTION";
      else verdict = "FAIR EXECUTION";
   }

   FileWriteString(h, "[verdict]\r\n");
   FileWriteString(h, StringFormat("result = \"%s\"\r\n", verdict));
   FileWriteString(h, StringFormat("violations = %d\r\n", violations));
   FileWriteString(h, StringFormat("has_asymmetry = %s\r\n", hasAsymmetry ? "true" : "false"));
   FileWriteString(h, StringFormat("total_damage_usd = %.4f\r\n\r\n", totalDamage));

   // Cycle details
   for(int c = 0; c < g_cycleNum; c++)
   {
      FileWriteString(h, StringFormat("[cycle.%d]\r\n", g_cycles[c].cycleNum));
      FileWriteString(h, StringFormat("spread = %.1f\r\n", g_cycles[c].spreadAtPlace));
      FileWriteString(h, StringFormat("spacing = %.1f\r\n", g_cycles[c].spacingPts));
      FileWriteString(h, StringFormat("levels_per_side = %d\r\n", g_cycles[c].levelsPerSide));
      FileWriteString(h, StringFormat("placed = %d\r\n", g_cycles[c].totalPlaced));
      FileWriteString(h, StringFormat("filled = %d\r\n", g_cycles[c].totalFilled));
      FileWriteString(h, StringFormat("tp_triggers = %d\r\n", g_cycles[c].tpTriggers));
      FileWriteString(h, StringFormat("sl_triggers = %d\r\n", g_cycles[c].slTriggers));
      FileWriteString(h, StringFormat("close_fills = %d\r\n", g_cycles[c].closeFills));
      FileWriteString(h, StringFormat("async_fills = %d\r\n", g_cycles[c].asyncFillCount));
      FileWriteString(h, StringFormat("close_majority_lag_ms = %.1f\r\n", g_cycles[c].closeLagMs));
      FileWriteString(h, StringFormat("close_broker_exec_ms = %.1f\r\n", g_cycles[c].closeBrokerExecMs));
      FileWriteString(h, StringFormat("financial_delta = %.4f\r\n\r\n", g_cycles[c].financialDelta));
   }

   // --- Order Rejection Analysis ---
   FileWriteString(h, "[analysis.order_rejections]\r\n");
   FileWriteString(h, StringFormat("total_rejections = %d\r\n", g_rejectionCount));
   FileWriteString(h, StringFormat("stop_rejections = %d\r\n", g_rejStopTotal));
   FileWriteString(h, StringFormat("limit_rejections = %d\r\n", g_rejLimitTotal));
   FileWriteString(h, StringFormat("market_rejections = %d\r\n", g_rejMarketTotal));
   FileWriteString(h, StringFormat("stop_manipulation = %d\r\n", g_rejStopManipulation));
   FileWriteString(h, StringFormat("stop_legitimate = %d\r\n", g_rejStopLegitimate));
   FileWriteString(h, StringFormat("limit_manipulation = %d\r\n", g_rejLimitManipulation));
   FileWriteString(h, StringFormat("limit_legitimate = %d\r\n", g_rejLimitLegitimate));
   FileWriteString(h, StringFormat("transient_count = %d\r\n", g_rejTransientCount));
   FileWriteString(h, StringFormat("persistent_count = %d\r\n", g_rejPersistentCount));
   FileWriteString(h, StringFormat("grid_start_distance_spreads = %.1f\r\n", InpGridStartMult));

   // Count by classification type
   {
      int tCntSusp = 0, tCntAsymD = 0, tCntAsymR = 0, tCntLeg = 0, tCntSymR = 0, tCntTransient = 0;
      double manipDistArr3[];
      int manipCount3 = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         switch(g_rejections[r].classification)
         {
            case REJ_CLASS_SUSPICIOUS:        tCntSusp++; break;
            case REJ_CLASS_ASYMMETRIC_DELAY:  tCntAsymD++; break;
            case REJ_CLASS_ASYMMETRIC_REQUOTE:tCntAsymR++; break;
            case REJ_CLASS_LEGITIMATE:        tCntLeg++; break;
            case REJ_CLASS_SYMMETRIC_REQUOTE: tCntSymR++; break;
            case REJ_CLASS_TRANSIENT:         tCntTransient++; break;
         }
         // Collect distances for manipulation classes
         if(g_rejections[r].classification >= REJ_CLASS_SUSPICIOUS &&
            g_rejections[r].classification <= REJ_CLASS_ASYMMETRIC_REQUOTE)
         {
            ArrayResize(manipDistArr3, manipCount3 + 1);
            manipDistArr3[manipCount3++] = g_rejections[r].distSpreads;
         }
      }
      FileWriteString(h, StringFormat("class_price_away = %d\r\n", tCntSusp));
      FileWriteString(h, StringFormat("class_asymmetric_delay = %d\r\n", tCntAsymD));
      FileWriteString(h, StringFormat("class_asymmetric_requote = %d\r\n", tCntAsymR));
      FileWriteString(h, StringFormat("class_legitimate = %d\r\n", tCntLeg));
      FileWriteString(h, StringFormat("class_symmetric_requote = %d\r\n", tCntSymR));
      FileWriteString(h, StringFormat("class_transient = %d\r\n", tCntTransient));

      if(manipCount3 > 0)
      {
         ArraySort(manipDistArr3);
         FileWriteString(h, StringFormat("manipulation_median_distance_spreads = %.2f\r\n", manipDistArr3[manipCount3 / 2]));
         FileWriteString(h, StringFormat("manipulation_max_distance_spreads = %.2f\r\n", manipDistArr3[manipCount3 - 1]));
      }
   }

   if(g_rejectionVerdict != "")
      FileWriteString(h, StringFormat("verdict = \"%s\"\r\n", g_rejectionVerdict));
   else
      FileWriteString(h, "verdict = \"NONE\"\r\n");
   FileWriteString(h, "\r\n");

   // Per-rejection detail array (grid rejections only)
   {
      int tRow = 0;
      for(int r = 0; r < g_rejectionCount; r++)
      {
         if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
         tRow++;
         FileWriteString(h, "[[analysis.order_rejections.detail]]\r\n");
         FileWriteString(h, StringFormat("order_type = \"%s\"\r\n", g_rejections[r].orderType));
         FileWriteString(h, StringFormat("retcode = %d\r\n", g_rejections[r].retcode));
         FileWriteString(h, StringFormat("order_price = %.5f\r\n", g_rejections[r].orderPrice));
         FileWriteString(h, StringFormat("bid = %.5f\r\n", g_rejections[r].bidAtReject));
         FileWriteString(h, StringFormat("ask = %.5f\r\n", g_rejections[r].askAtReject));
         FileWriteString(h, StringFormat("distance_points = %.1f\r\n", g_rejections[r].distPoints));
         FileWriteString(h, StringFormat("distance_spreads = %.1f\r\n", g_rejections[r].distSpreads));
         FileWriteString(h, StringFormat("price_passed = %s\r\n", g_rejections[r].pricePassed ? "true" : "false"));
         FileWriteString(h, StringFormat("broker_reason = \"%s\"\r\n", g_rejections[r].brokerReason));
         FileWriteString(h, StringFormat("measured_reason = \"%s\"\r\n", g_rejections[r].measuredReason));
         string classTag = "";
         switch(g_rejections[r].classification)
         {
            case REJ_CLASS_SUSPICIOUS:        classTag = "PRICE_AWAY"; break;
            case REJ_CLASS_ASYMMETRIC_DELAY:  classTag = "ASYMMETRIC_DELAY"; break;
            case REJ_CLASS_ASYMMETRIC_REQUOTE:classTag = "ASYMMETRIC_REQUOTE"; break;
            case REJ_CLASS_LEGITIMATE:        classTag = "LEGITIMATE"; break;
            case REJ_CLASS_SYMMETRIC_REQUOTE: classTag = "SYMMETRIC_REQUOTE"; break;
            case REJ_CLASS_TRANSIENT:         classTag = "TRANSIENT"; break;
            default:                          classTag = "UNCLASSIFIED"; break;
         }
         FileWriteString(h, StringFormat("classification = \"%s\"\r\n", classTag));
         FileWriteString(h, StringFormat("retry_attempts = %d\r\n", g_rejections[r].retryAttempts));
         FileWriteString(h, StringFormat("retry_succeeded = %s\r\n", g_rejections[r].retrySucceeded ? "true" : "false"));
         FileWriteString(h, StringFormat("retry_last_retcode = %d\r\n", g_rejections[r].retryRetcode));
         FileWriteString(h, StringFormat("time = \"%s\"\r\n", TimeToString(g_rejections[r].time, TIME_DATE | TIME_SECONDS)));
         FileWriteString(h, "\r\n");
      }
   }

   // --- Fill Rejections (broker cancelled pending orders) ---
   FileWriteString(h, "[analysis.fill_rejections]\r\n");
   FileWriteString(h, StringFormat("total_fill_rejections = %d\r\n", g_fillRejectionCount));
   FileWriteString(h, StringFormat("stop_fill_rejections = %d\r\n", g_fillRejStopTotal));
   FileWriteString(h, StringFormat("limit_fill_rejections = %d\r\n", g_fillRejLimitTotal));
   FileWriteString(h, StringFormat("stop_price_triggered = %d\r\n", g_fillRejStopTriggered));
   FileWriteString(h, StringFormat("limit_price_triggered = %d\r\n", g_fillRejLimitTriggered));
   FileWriteString(h, StringFormat("stop_preemptive = %d\r\n", g_fillRejStopPreemptive));
   FileWriteString(h, StringFormat("limit_preemptive = %d\r\n", g_fillRejLimitPreemptive));
   FileWriteString(h, StringFormat("verdict = \"%s\"\r\n", g_fillRejVerdict));
   FileWriteString(h, "\r\n");

   // Per-fill-rejection detail array
   for(int r = 0; r < g_fillRejectionCount; r++)
   {
      FileWriteString(h, "[[analysis.fill_rejections.detail]]\r\n");
      FileWriteString(h, StringFormat("order_type = \"%s\"\r\n", g_fillRejections[r].orderType));
      FileWriteString(h, StringFormat("order_ticket = %I64u\r\n", g_fillRejections[r].orderTicket));
      FileWriteString(h, StringFormat("order_price = %.5f\r\n", g_fillRejections[r].orderPrice));
      FileWriteString(h, StringFormat("bid_at_cancel = %.5f\r\n", g_fillRejections[r].bidAtCancel));
      FileWriteString(h, StringFormat("ask_at_cancel = %.5f\r\n", g_fillRejections[r].askAtCancel));
      FileWriteString(h, StringFormat("distance_points = %.1f\r\n", g_fillRejections[r].distPoints));
      FileWriteString(h, StringFormat("price_triggered = %s\r\n", g_fillRejections[r].priceCrossed ? "true" : "false"));
      FileWriteString(h, StringFormat("order_state = %d\r\n", (int)g_fillRejections[r].orderState));
      FileWriteString(h, StringFormat("order_reason = %d\r\n", (int)g_fillRejections[r].orderReason));
      FileWriteString(h, StringFormat("broker_reason = \"%s\"\r\n", g_fillRejections[r].brokerReason));
      FileWriteString(h, StringFormat("measured_reason = \"%s\"\r\n", g_fillRejections[r].measuredReason));
      string fillRejClass = "";
      switch(g_fillRejections[r].classification)
      {
         case FILLREJ_CLASS_PRICE_TRIGGERED: fillRejClass = "PRICE_TRIGGERED"; break;
         case FILLREJ_CLASS_PREEMPTIVE:      fillRejClass = "PREEMPTIVE"; break;
         case FILLREJ_CLASS_EA_INITIATED:    fillRejClass = "EA_INITIATED"; break;
         default:                            fillRejClass = "UNCLASSIFIED"; break;
      }
      FileWriteString(h, StringFormat("classification = \"%s\"\r\n", fillRejClass));
      FileWriteString(h, StringFormat("cycle = %d\r\n", g_fillRejections[r].cycleNum));
      FileWriteString(h, "\r\n");
   }

   // --- Phantom Spike Detection ---
   FileWriteString(h, "[analysis.phantom_spikes]\r\n");
   FileWriteString(h, StringFormat("total_spikes = %d\r\n", g_phantomSpikeCount));
   FileWriteString(h, StringFormat("median_spread = %.2f\r\n", g_medianSpread / g_tickSize));
   FileWriteString(h, StringFormat("mean_spread = %.2f\r\n", g_meanSpread / g_tickSize));
   {
      int slTriggered = 0;
      for(int s = 0; s < g_phantomSpikeCount; s++)
         if(g_phantomSpikes[s].triggeredSL) slTriggered++;
      FileWriteString(h, StringFormat("sl_triggered_spikes = %d\r\n", slTriggered));
      if(slTriggered > 0)
         FileWriteString(h, "warning = \"Anomalous price spikes detected that coincided with SL triggers\"\r\n");
   }
   FileWriteString(h, "\r\n");

   // --- Margin Verification ---
   FileWriteString(h, "[analysis.margin_verification]\r\n");
   if(g_theoreticalMarginBuy > 0)
   {
      FileWriteString(h, StringFormat("theoretical_margin_buy = %.2f\r\n", g_theoreticalMarginBuy));
      FileWriteString(h, StringFormat("actual_margin_buy = %.2f\r\n", g_measuredMarginBuy));
      FileWriteString(h, StringFormat("discrepancy_buy = %.2f\r\n", g_marginDiscrepancyBuy));
      FileWriteString(h, StringFormat("markup_pct_buy = %.1f\r\n", g_marginMarkupPctBuy));
      if(g_theoreticalMarginBoth > 0)
      {
         FileWriteString(h, StringFormat("theoretical_margin_both = %.2f\r\n", g_theoreticalMarginBoth));
         FileWriteString(h, StringFormat("actual_margin_both = %.2f\r\n", g_measuredMarginBoth));
         FileWriteString(h, StringFormat("discrepancy_both = %.2f\r\n", g_marginDiscrepancyBoth));
         FileWriteString(h, StringFormat("markup_pct_both = %.1f\r\n", g_marginMarkupPctBoth));
      }
      if(MathAbs(g_marginMarkupPctBuy) > 10.0)
         FileWriteString(h, "warning = \"Margin charged deviates >10% from theoretical calculation\"\r\n");
   }
   else
      FileWriteString(h, "status = \"insufficient data\"\r\n");
   FileWriteString(h, "\r\n");

   // --- Order Capacity Stress Test ---
   FileWriteString(h, "[analysis.stress_test]\r\n");
   FileWriteString(h, StringFormat("batch_size = %d\r\n", (int)g_orderLimit));
   FileWriteString(h, StringFormat("max_cycles = %d\r\n", InpStressMaxCycles));
   FileWriteString(h, StringFormat("limit_cycles_completed = %d\r\n", g_stressCycleLimit));
   FileWriteString(h, StringFormat("limit_blocked = %s\r\n", g_stressLimitBlocked ? "true" : "false"));
   if(g_stressLimitBlocked)
      FileWriteString(h, StringFormat("limit_blocked_at_cycle = %d\r\n", g_stressLimitBlockedAt));
   FileWriteString(h, StringFormat("limit_max_verified = %d\r\n", g_stressMaxVerifiedLimit));
   FileWriteString(h, StringFormat("stop_cycles_completed = %d\r\n", g_stressCycleStop));
   FileWriteString(h, StringFormat("stop_blocked = %s\r\n", g_stressStopBlocked ? "true" : "false"));
   if(g_stressStopBlocked)
      FileWriteString(h, StringFormat("stop_blocked_at_cycle = %d\r\n", g_stressStopBlockedAt));
   FileWriteString(h, StringFormat("stop_max_verified = %d\r\n", g_stressMaxVerifiedStop));
   FileWriteString(h, StringFormat("limit_placement_attempts = %d\r\n", g_stressLimitTotalAttempts));
   FileWriteString(h, StringFormat("limit_placement_rejections = %d\r\n", g_stressLimitTotalRejects));
   if(g_stressLimitTotalAttempts > 0)
      FileWriteString(h, StringFormat("limit_rejection_pct = %.1f\r\n",
         100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts));
   FileWriteString(h, StringFormat("stop_placement_attempts = %d\r\n", g_stressStopTotalAttempts));
   FileWriteString(h, StringFormat("stop_placement_rejections = %d\r\n", g_stressStopTotalRejects));
   if(g_stressStopTotalAttempts > 0)
      FileWriteString(h, StringFormat("stop_rejection_pct = %.1f\r\n",
         100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts));
   if(g_stressStopBlocked && !g_stressLimitBlocked)
      FileWriteString(h, "selective_blocking = \"STOP_ORDERS_ONLY — broker blocks stop-order cycling while allowing limit-order cycling\"\r\n");
   else if(g_stressStopBlocked && g_stressLimitBlocked)
      FileWriteString(h, "selective_blocking = \"BOTH — broker blocks all order type cycling\"\r\n");
   else if(!g_stressStopBlocked && g_stressLimitBlocked)
      FileWriteString(h, "selective_blocking = \"LIMIT_ORDERS_ONLY — unusual, limits blocked but stops allowed\"\r\n");
   else
      FileWriteString(h, "selective_blocking = \"NONE — both order types cycled without blocking\"\r\n");
   {
      double limRP = (g_stressLimitTotalAttempts > 0) ? (100.0 * g_stressLimitTotalRejects / g_stressLimitTotalAttempts) : 0;
      double stpRP = (g_stressStopTotalAttempts > 0) ? (100.0 * g_stressStopTotalRejects / g_stressStopTotalAttempts) : 0;
      bool throttled = (limRP > 10.0 || stpRP > 10.0);
      bool asymThrottle = throttled && ((stpRP > limRP * 1.5) || (limRP > stpRP * 1.5));
      if(asymThrottle)
         FileWriteString(h, StringFormat("burst_rejection = \"ASYMMETRIC — stop %.0f%% vs limit %.0f%% (manipulation indicator)\"\r\n", stpRP, limRP));
      else if(throttled)
         FileWriteString(h, StringFormat("burst_rejection = \"SYMMETRIC_RATE_LIMIT — %.0f%% (legitimate server protection)\"\r\n",
            100.0 * (g_stressStopTotalRejects + g_stressLimitTotalRejects) /
            MathMax(1, g_stressStopTotalAttempts + g_stressLimitTotalAttempts)));
      else
         FileWriteString(h, "burst_rejection = \"NONE\"\r\n");
   }
   if(g_stressLastRetcode > 0 && (g_stressStopBlocked || g_stressLimitBlocked))
      FileWriteString(h, StringFormat("last_rejection_retcode = %d\r\n", g_stressLastRetcode));
   // Throttle lockout measurements (only present if broker actually imposed post-activity lockout)
   if(g_throttleRecoveryCount > 0)
   {
      if(g_throttleLimitMeasurements > 0)
      {
         FileWriteString(h, StringFormat("limit_lockout_avg_ms = %.0f\r\n",
            g_throttleLimitTotalMs / g_throttleLimitMeasurements));
         FileWriteString(h, StringFormat("limit_lockout_max_ms = %.0f\r\n", g_throttleLimitMaxMs));
         FileWriteString(h, StringFormat("limit_lockout_events = %d\r\n", g_throttleLimitMeasurements));
      }
      if(g_throttleStopMeasurements > 0)
      {
         FileWriteString(h, StringFormat("stop_lockout_avg_ms = %.0f\r\n",
            g_throttleStopTotalMs / g_throttleStopMeasurements));
         FileWriteString(h, StringFormat("stop_lockout_max_ms = %.0f\r\n", g_throttleStopMaxMs));
         FileWriteString(h, StringFormat("stop_lockout_events = %d\r\n", g_throttleStopMeasurements));
      }
   }
   FileWriteString(h, "\r\n");

   // --- EA Tuning Data (for configuring trading EAs based on measured broker behavior) ---
   FileWriteString(h, "[analysis.ea_tuning]\r\n");
   FileWriteString(h, StringFormat("max_async_burst_stops = %d\r\n", g_stressMaxVerifiedStop));
   FileWriteString(h, StringFormat("max_async_burst_limits = %d\r\n", g_stressMaxVerifiedLimit));
   FileWriteString(h, StringFormat("safe_async_batch_stops = %d\r\n", g_safeAsyncBatchStop));
   FileWriteString(h, StringFormat("safe_async_batch_limits = %d\r\n", g_safeAsyncBatchLimit));
   if(g_bufferFlushCount > 0)
   {
      FileWriteString(h, StringFormat("buffer_flush_avg_ms = %.0f\r\n", g_bufferFlushAvgMs));
      FileWriteString(h, StringFormat("buffer_flush_max_ms = %.0f\r\n", g_bufferFlushMaxMs));
      FileWriteString(h, StringFormat("buffer_flush_measurements = %d\r\n", g_bufferFlushCount));
   }
   FileWriteString(h, "# Recommended pattern: place up to safe_async_batch orders async,\r\n");
   FileWriteString(h, "# then sync place+delete a throwaway order to flush broker pipeline,\r\n");
   FileWriteString(h, "# then repeat. This avoids rate-limiting rejections.\r\n");
   FileWriteString(h, "\r\n");

   // Evidence files
   FileWriteString(h, "[files]\r\n");
   FileWriteString(h, StringFormat("evidence_csv = \"%s\"\r\n", g_evidenceCsvName));
   FileWriteString(h, StringFormat("tick_csv = \"%s\"\r\n", g_tickCsvName));
   FileWriteString(h, StringFormat("report_pdf = \"%s\"\r\n", g_reportPdfName));
   if(InpWriteHTML)
      FileWriteString(h, StringFormat("report_htm = \"%s\"\r\n", g_reportHtmName));
   FileWriteString(h, StringFormat("toml = \"%s\"\r\n", g_tomlName));

   FileWriteString(h, StringFormat("broker_log = \"%s\"\r\n", g_brokerLogName));
   FileWriteString(h, StringFormat("trade_history = \"%s\"\r\n", g_histCsvName));
   if(InpShowEATuning && g_calibCsvName != "")
      FileWriteString(h, StringFormat("calibration_csv = \"%s\"\r\n", g_calibCsvName));

   // VDP detection results
   FileWriteString(h, "\r\n[vdp_detection]\r\n");
   FileWriteString(h, StringFormat("score = %.0f\r\n", g_vdpScore));
   FileWriteString(h, StringFormat("verdict = \"%s\"\r\n", g_vdpVerdict));
   FileWriteString(h, StringFormat("adverse_median_ms = %.1f\r\n", g_vdpAdverseMedian));
   FileWriteString(h, StringFormat("favorable_median_ms = %.1f\r\n", g_vdpFavorMedian));
   FileWriteString(h, StringFormat("lag_ratio = %.2f\r\n", g_vdpLagRatio));
   FileWriteString(h, StringFormat("adverse_count = %d\r\n", g_vdpAdverseCount));
   FileWriteString(h, StringFormat("favorable_count = %d\r\n", g_vdpFavorCount));
   FileWriteString(h, StringFormat("whole_sec_cluster_pct = %.1f\r\n", g_vdpWholeSecPct));
   FileWriteString(h, StringFormat("whole_sec_detected = %s\r\n", g_vdpWholeSecCluster ? "true" : "false"));
   FileWriteString(h, StringFormat("delay_in_vdp_range = %s\r\n", g_vdpDelayRange ? "true" : "false"));
   FileWriteString(h, StringFormat("flat_distribution = %s\r\n", g_vdpFlatDistribution ? "true" : "false"));
   FileWriteString(h, StringFormat("iqr_ratio = %.3f\r\n", g_vdpIQRatio));
   FileWriteString(h, StringFormat("order_type_discrimination = %s\r\n", g_vdpOrderTypeDiscrim ? "true" : "false"));
   FileWriteString(h, StringFormat("flags_triggered = %d\r\n", g_vdpFlagsTriggered));

   FileClose(h);
   PrintFormat("TOML DATA: %s", g_tomlName);
}


//+------------------------------------------------------------------+
//| GENERATE TRADE HISTORY — MT5 deal + order history export          |
//+------------------------------------------------------------------+
void GenerateTradeHistory()
{
   int h = FileOpen(g_histCsvName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
   {
      PrintFormat("ERROR: Cannot create trade history: %s", g_histCsvName);
      return;
   }

   //--- SECTION 1: Deal History
   FileWriteString(h, "# DEAL HISTORY\n");
   FileWriteString(h, "DealTicket,OrderTicket,Time,TimeMs,Symbol,Type,Entry,Reason,"
      "Price,Volume,Profit,Commission,Swap,Fee,PositionID,Magic,Comment\n");

   if(HistorySelect(g_collectionStartTime, TimeCurrent()))
   {
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dTicket = HistoryDealGetTicket(i);
         if(dTicket == 0) continue;

         long   dOrder  = HistoryDealGetInteger(dTicket, DEAL_ORDER);
         long   dTime   = HistoryDealGetInteger(dTicket, DEAL_TIME);
         long   dTimeMs = HistoryDealGetInteger(dTicket, DEAL_TIME_MSC);
         string dSym    = HistoryDealGetString(dTicket, DEAL_SYMBOL);
         long   dType   = HistoryDealGetInteger(dTicket, DEAL_TYPE);
         long   dEntry  = HistoryDealGetInteger(dTicket, DEAL_ENTRY);
         long   dReason = HistoryDealGetInteger(dTicket, DEAL_REASON);
         double dPrice  = HistoryDealGetDouble(dTicket, DEAL_PRICE);
         double dVol    = HistoryDealGetDouble(dTicket, DEAL_VOLUME);
         double dProfit = HistoryDealGetDouble(dTicket, DEAL_PROFIT);
         double dComm   = HistoryDealGetDouble(dTicket, DEAL_COMMISSION);
         double dSwap   = HistoryDealGetDouble(dTicket, DEAL_SWAP);
         double dFee    = HistoryDealGetDouble(dTicket, DEAL_FEE);
         long   dPosId  = HistoryDealGetInteger(dTicket, DEAL_POSITION_ID);
         long   dMagic  = HistoryDealGetInteger(dTicket, DEAL_MAGIC);
         string dCmt    = HistoryDealGetString(dTicket, DEAL_COMMENT);
         StringReplace(dCmt, ",", ";");

         FileWriteString(h, StringFormat(
            "%I64u,%d,%s,%I64d,%s,%d,%d,%d,%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%d,%s\n",
            dTicket, (int)dOrder,
            TimeToString((datetime)dTime, TIME_DATE|TIME_SECONDS), dTimeMs,
            dSym, (int)dType, (int)dEntry, (int)dReason,
            dPrice, dVol, dProfit, dComm, dSwap, dFee,
            (int)dPosId, (int)dMagic, dCmt));
      }
      PrintFormat("TRADE HISTORY: %d deals exported", totalDeals);
   }

   //--- SECTION 2: Order History
   FileWriteString(h, "\n# ORDER HISTORY\n");
   FileWriteString(h, "OrderTicket,TimeSetup,TimeSetupMs,TimeDone,TimeDoneMs,"
      "Symbol,Type,State,PriceOpen,PriceCurrent,PriceSL,PriceTP,"
      "Volume,VolumeCurrent,PositionID,Magic,Reason,Comment\n");

   int totalOrders = HistoryOrdersTotal();
   for(int i = 0; i < totalOrders; i++)
   {
      ulong oTicket = HistoryOrderGetTicket(i);
      if(oTicket == 0) continue;

      long   oSetup    = HistoryOrderGetInteger(oTicket, ORDER_TIME_SETUP);
      long   oSetupMs  = HistoryOrderGetInteger(oTicket, ORDER_TIME_SETUP_MSC);
      long   oDone     = HistoryOrderGetInteger(oTicket, ORDER_TIME_DONE);
      long   oDoneMs   = HistoryOrderGetInteger(oTicket, ORDER_TIME_DONE_MSC);
      string oSym      = HistoryOrderGetString(oTicket, ORDER_SYMBOL);
      long   oType     = HistoryOrderGetInteger(oTicket, ORDER_TYPE);
      long   oState    = HistoryOrderGetInteger(oTicket, ORDER_STATE);
      double oPrOpen   = HistoryOrderGetDouble(oTicket, ORDER_PRICE_OPEN);
      double oPrCur    = HistoryOrderGetDouble(oTicket, ORDER_PRICE_CURRENT);
      double oPrSL     = HistoryOrderGetDouble(oTicket, ORDER_SL);
      double oPrTP     = HistoryOrderGetDouble(oTicket, ORDER_TP);
      double oVol      = HistoryOrderGetDouble(oTicket, ORDER_VOLUME_INITIAL);
      double oVolCur   = HistoryOrderGetDouble(oTicket, ORDER_VOLUME_CURRENT);
      long   oPosId    = HistoryOrderGetInteger(oTicket, ORDER_POSITION_ID);
      long   oMagic    = HistoryOrderGetInteger(oTicket, ORDER_MAGIC);
      long   oReason   = HistoryOrderGetInteger(oTicket, ORDER_REASON);
      string oCmt      = HistoryOrderGetString(oTicket, ORDER_COMMENT);
      StringReplace(oCmt, ",", ";");

      FileWriteString(h, StringFormat(
         "%I64u,%s,%I64d,%s,%I64d,%s,%d,%d,%.5f,%.5f,%.5f,%.5f,%.4f,%.4f,%d,%d,%d,%s\n",
         oTicket,
         TimeToString((datetime)oSetup, TIME_DATE|TIME_SECONDS), oSetupMs,
         TimeToString((datetime)oDone, TIME_DATE|TIME_SECONDS), oDoneMs,
         oSym, (int)oType, (int)oState, oPrOpen, oPrCur, oPrSL, oPrTP,
         oVol, oVolCur, (int)oPosId, (int)oMagic, (int)oReason, oCmt));
   }
   PrintFormat("TRADE HISTORY: %d orders exported", totalOrders);

   FileClose(h);
   PrintFormat("TRADE HISTORY FILE: %s", g_histCsvName);
}


//+------------------------------------------------------------------+
//| SHA-256 HASH OF FILE (reads from Common Files folder)             |
//+------------------------------------------------------------------+
string ComputeFileSHA256(string filename)
{
   int fh = FileOpen(filename, FILE_READ | FILE_BIN | FILE_COMMON);
   if(fh == INVALID_HANDLE) return "FILE_NOT_FOUND";

   ulong fSize = (ulong)FileSize(fh);
   if(fSize <= 0) { FileClose(fh); return "EMPTY_FILE"; }
   if(fSize > 50 * 1024 * 1024) { FileClose(fh); return "FILE_TOO_LARGE"; }

   uchar data[];
   ArrayResize(data, (int)fSize);
   FileReadArray(fh, data);
   FileClose(fh);

   uchar hash[];
   uchar key[];  // empty key for hash mode
   if(CryptEncode(CRYPT_HASH_SHA256, data, key, hash) <= 0)
      return "HASH_ERROR";

   string hex = "";
   for(int i = 0; i < ArraySize(hash); i++)
      hex += StringFormat("%02x", hash[i]);
   return hex;
}

//+------------------------------------------------------------------+
//| SHA-256 HASH OF STRING DATA                                       |
//+------------------------------------------------------------------+
string ComputeDataSHA256(string data)
{
   uchar dataArr[];
   StringToCharArray(data, dataArr, 0, WHOLE_ARRAY, CP_UTF8);
   int len = ArraySize(dataArr);
   if(len > 0 && dataArr[len - 1] == 0) len--;  // strip null terminator
   if(len > 0) ArrayResize(dataArr, len);

   uchar hash[];
   uchar key[];
   if(CryptEncode(CRYPT_HASH_SHA256, dataArr, key, hash) <= 0)
      return "HASH_ERROR";

   string hex = "";
   for(int i = 0; i < ArraySize(hash); i++)
      hex += StringFormat("%02x", hash[i]);
   return hex;
}

//+------------------------------------------------------------------+
//| WRITE INTEGRITY HASHES — appends [integrity] to TOML after all    |
//| files are generated                                                |
//+------------------------------------------------------------------+
void WriteIntegrityHashes()
{
   // Compute hashes of all output files
   string hashEvidence = ComputeFileSHA256(g_evidenceCsvName);
   string hashTicks    = ComputeFileSHA256(g_tickCsvName);
   string hashPdf      = ComputeFileSHA256(g_reportPdfName);
   string hashHtml     = InpWriteHTML ? ComputeFileSHA256(g_reportHtmName) : "";
   string hashHistory  = ComputeFileSHA256(g_histCsvName);
   string hashBrokerLog = ComputeFileSHA256(g_brokerLogName);

   // Build measurement fingerprint: hash of key numeric values
   // This proves the measurements haven't been altered — anyone running
   // the same EA on the same account gets the same fingerprint
   string fingerprint = "";
   for(int t = 0; t < 10; t++)
      fingerprint += StringFormat("t%d:n=%d,med=%.2f;", t, g_countByType[t], g_medianLag[t]);
   fingerprint += StringFormat("fills=%d;cycles=%d;lots=%.4f;cslag=%.1f;",
      g_fillCount, g_cycleNum, g_totalLotsTraded, g_clientServerLagMs);
   fingerprint += StringFormat("acct=%d;sym=%s;broker=%s",
      (int)g_accountNumber, Symbol(), g_brokerName);
   string hashFingerprint = ComputeDataSHA256(fingerprint);

   // Reopen TOML in append mode
   int h = FileOpen(g_tomlName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("WARNING: Cannot reopen TOML for integrity hashes: %s", g_tomlName);
      return;
   }
   FileSeek(h, 0, SEEK_END);

   FileWriteString(h, "\r\n[integrity]\r\n");
   FileWriteString(h, "# SHA-256 hashes of all output files for tamper detection\r\n");
   FileWriteString(h, "# Verify: compare these hashes against the actual files\r\n");
   FileWriteString(h, StringFormat("ea_version = \"%s\"\r\n", FA_VERSION));
   FileWriteString(h, StringFormat("generated_utc = \"%s\"\r\n",
      TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS)));
   FileWriteString(h, StringFormat("terminal_build = %d\r\n", TerminalInfoInteger(TERMINAL_BUILD)));
   FileWriteString(h, StringFormat("measurement_fingerprint = \"%s\"\r\n", hashFingerprint));
   FileWriteString(h, StringFormat("evidence_csv_sha256 = \"%s\"\r\n", hashEvidence));
   FileWriteString(h, StringFormat("tick_csv_sha256 = \"%s\"\r\n", hashTicks));
   FileWriteString(h, StringFormat("report_pdf_sha256 = \"%s\"\r\n", hashPdf));
   if(InpWriteHTML)
      FileWriteString(h, StringFormat("report_htm_sha256 = \"%s\"\r\n", hashHtml));
   FileWriteString(h, StringFormat("trade_history_sha256 = \"%s\"\r\n", hashHistory));
   FileWriteString(h, StringFormat("broker_log_sha256 = \"%s\"\r\n", hashBrokerLog));

   FileWriteString(h, "\r\n[integrity.provenance]\r\n");
   FileWriteString(h, "# Data source attestation\r\n");
   FileWriteString(h, "timestamp_source = \"DEAL_TIME_MSC — server-side millisecond timestamp generated by broker trade server\"\r\n");
   FileWriteString(h, "timestamp_access = \"HistoryDealGetInteger(ticket, DEAL_TIME_MSC) — read-only MT5 API, cannot be modified by EA\"\r\n");
   FileWriteString(h, "price_source = \"SymbolInfoTick() — broker's live price feed, read-only\"\r\n");
   FileWriteString(h, "cs_calibration = \"Round-trip latency measured via pending order place+delete sequence, averaged across 2 passes\"\r\n");
   FileWriteString(h, "ea_interference = \"none — EA only places orders and reads results, cannot alter server timestamps or fill prices\"\r\n");

   FileClose(h);
   PrintFormat("INTEGRITY: SHA-256 hashes appended to %s", g_tomlName);
}


//+------------------------------------------------------------------+
//| MEASURE THROTTLE RECOVERY TIME                                     |
//| After stress cycle cleanup, probe how long until broker accepts    |
//| a new order. This measures the real-world cost to scalping EAs:    |
//| how long you're locked out after heavy order activity.             |
//+------------------------------------------------------------------+
double MeasureThrottleRecovery(bool isLimitPhase)
{
   double ask2 = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double bid2 = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point2 = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits2 = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double probePrice;
   ENUM_ORDER_TYPE probeType;

   if(isLimitPhase)
   {
      probePrice = NormalizeDouble(bid2 - 50000 * point2, digits2);
      probeType = ORDER_TYPE_BUY_LIMIT;
   }
   else
   {
      probePrice = NormalizeDouble(ask2 + 50000 * point2, digits2);
      probeType = ORDER_TYPE_BUY_STOP;
   }

   ulong probeStart = GetTickCount64();
   int probeAttempts = 0;
   double recoveryMs = 0;
   bool wasThrottled = false;  // True only if broker rejected at least one probe

   // Probe loop: try every 50ms until accepted or 30s timeout
   for(int attempt = 0; attempt < 600; attempt++)  // 600 × 50ms = 30s max
   {
      probeAttempts++;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = Symbol();
      req.volume       = g_lotSize;
      req.price        = probePrice;
      req.type         = probeType;
      req.magic        = InpMagicNumber + 9000;
      req.comment      = "FA_THROTTLE_PROBE";
      req.type_filling = g_fillType;

      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
      {
         recoveryMs = (double)(GetTickCount64() - probeStart);

         // Clean up probe order
         MqlTradeRequest dreq = {};
         MqlTradeResult  dres = {};
         dreq.action = TRADE_ACTION_REMOVE;
         dreq.order  = res.order;
         if(!OrderSend(dreq, dres)) {} // Best-effort cleanup

         break;
      }

      // Rejected — broker is actually throttling
      wasThrottled = true;
      if(attempt == 0)
         PrintFormat("Throttle probe: first attempt rejected (retcode %d) — measuring recovery...",
            (int)res.retcode);

      Sleep(50);  // 50ms between probes for fine-grained measurement
   }

   // If we never got accepted within 30s, record 30000ms
   if(wasThrottled && recoveryMs == 0)
      recoveryMs = (double)(GetTickCount64() - probeStart);

   // Only record as throttle if broker actually rejected the first attempt.
   // If first attempt succeeded, recoveryMs is just normal OrderSend latency — not throttling.
   if(!wasThrottled)
   {
      PrintFormat("Throttle probe: accepted on first attempt — no throttle [%s phase]",
         isLimitPhase ? "LIMIT" : "STOP");
      return 0;
   }

   // Store measurement (only genuine throttle events)
   if(g_throttleRecoveryCount < THROTTLE_MAX_SAMPLES)
   {
      ArrayResize(g_throttleRecoveryMs, g_throttleRecoveryCount + 1);
      ArrayResize(g_throttleRecoveryAttempts, g_throttleRecoveryCount + 1);
      g_throttleRecoveryMs[g_throttleRecoveryCount] = recoveryMs;
      g_throttleRecoveryAttempts[g_throttleRecoveryCount] = probeAttempts;
      g_throttleRecoveryCount++;
   }

   // Update phase stats
   if(isLimitPhase)
   {
      g_throttleLimitMeasurements++;
      g_throttleLimitTotalMs += recoveryMs;
      if(recoveryMs > g_throttleLimitMaxMs) g_throttleLimitMaxMs = recoveryMs;
   }
   else
   {
      g_throttleStopMeasurements++;
      g_throttleStopTotalMs += recoveryMs;
      if(recoveryMs > g_throttleStopMaxMs) g_throttleStopMaxMs = recoveryMs;
   }

   PrintFormat("THROTTLE DETECTED: %.0fms recovery (%d attempts) [%s phase]",
      recoveryMs, probeAttempts, isLimitPhase ? "LIMIT" : "STOP");

   return recoveryMs;
}


//+------------------------------------------------------------------+
//| MEASURE BUFFER FLUSH COST                                          |
//| Sync place+delete round-trip: the cost of flushing the broker's   |
//| async pipeline. Trading EAs can use this to pace their orders.     |
//| Also computes safe async batch sizes from stress test results.    |
//+------------------------------------------------------------------+
void MeasureBufferFlush()
{
   double ask2 = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point2 = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits2 = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double flushPrice = NormalizeDouble(ask2 + 50000 * point2, digits2);  // $500 away

   // Do 5 sync place+delete cycles and measure each
   ArrayResize(g_bufferFlushMs, 5);
   g_bufferFlushCount = 0;
   g_bufferFlushMaxMs = 0;
   double totalMs = 0;

   for(int i = 0; i < 5; i++)
   {
      ulong startMs = GetTickCount64();

      // Sync place
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = Symbol();
      req.volume       = g_lotSize;
      req.price        = flushPrice;
      req.type         = ORDER_TYPE_BUY_STOP;
      req.magic        = InpMagicNumber + 9000;
      req.comment      = "FA_FLUSH_PROBE";
      req.type_filling = g_fillType;

      if(!OrderSend(req, res) || res.retcode != TRADE_RETCODE_DONE)
      {
         PrintFormat("Buffer flush probe %d: place failed (retcode %d)", i + 1, (int)res.retcode);
         Sleep(200);
         continue;
      }

      // Sync delete
      MqlTradeRequest dreq = {};
      MqlTradeResult  dres = {};
      dreq.action = TRADE_ACTION_REMOVE;
      dreq.order  = res.order;
      if(!OrderSend(dreq, dres)) {} // Best-effort

      double flushMs = (double)(GetTickCount64() - startMs);
      g_bufferFlushMs[g_bufferFlushCount] = flushMs;
      g_bufferFlushCount++;
      totalMs += flushMs;
      if(flushMs > g_bufferFlushMaxMs) g_bufferFlushMaxMs = flushMs;

      Sleep(100);  // Brief pause between measurements
   }

   if(g_bufferFlushCount > 0)
      g_bufferFlushAvgMs = totalMs / g_bufferFlushCount;

   // Compute safe async batch sizes (90% of measured max accepted)
   g_safeAsyncBatchStop  = (int)MathFloor(g_stressMaxVerifiedStop * 0.9);
   g_safeAsyncBatchLimit = (int)MathFloor(g_stressMaxVerifiedLimit * 0.9);

   PrintFormat("BUFFER FLUSH: avg %.0fms, max %.0fms (%d measurements)",
      g_bufferFlushAvgMs, g_bufferFlushMaxMs, g_bufferFlushCount);
   PrintFormat("SAFE ASYNC BATCH: stops %d (90%% of %d) | limits %d (90%% of %d)",
      g_safeAsyncBatchStop, g_stressMaxVerifiedStop,
      g_safeAsyncBatchLimit, g_stressMaxVerifiedLimit);
}


//+------------------------------------------------------------------+
//| TRACK ORDER REJECTION                                              |
//+------------------------------------------------------------------+
void TrackRejection(int retcode, string orderType, double orderPrice=0, double bidNow=0, double askNow=0)
{
   if(retcode == TRADE_RETCODE_DONE) return;  // Not a rejection

   // Get current prices if not provided
   if(bidNow == 0) bidNow = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   if(askNow == 0) askNow = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spreadNow = askNow - bidNow;

   int idx = g_rejectionCount;
   ArrayResize(g_rejections, idx + 1);
   g_rejections[idx].retcode      = retcode;
   g_rejections[idx].orderType    = orderType;
   g_rejections[idx].time         = TimeCurrent();
   g_rejections[idx].orderPrice   = orderPrice;
   g_rejections[idx].bidAtReject  = bidNow;
   g_rejections[idx].askAtReject  = askNow;
   g_rejections[idx].spreadAtReject = spreadNow;

   // Calculate distance from relevant price
   // BuyStop/BuyLimit → distance from ask; SellStop/SellLimit → distance from bid
   double distAbs = 0;
   bool pricePassed = false;
   if(orderPrice > 0)
   {
      bool isStop  = (StringFind(orderType, "Stop") >= 0);
      bool isLimit = (StringFind(orderType, "Limit") >= 0);
      bool isBuy   = (StringFind(orderType, "Buy") >= 0);

      if(isBuy && isStop)
      {
         // BuyStop above ask — should be orderPrice > ask
         distAbs = orderPrice - askNow;
         pricePassed = (askNow >= orderPrice);  // Price reached/passed the stop level
      }
      else if(!isBuy && isStop)
      {
         // SellStop below bid — should be orderPrice < bid
         distAbs = bidNow - orderPrice;
         pricePassed = (bidNow <= orderPrice);  // Price reached/passed the stop level
      }
      else if(isBuy && isLimit)
      {
         // BuyLimit below bid — should be orderPrice < bid
         distAbs = bidNow - orderPrice;
         pricePassed = (bidNow <= orderPrice);  // Price dropped to/below limit level
      }
      else if(!isBuy && isLimit)
      {
         // SellLimit above ask — should be orderPrice > ask
         distAbs = orderPrice - askNow;
         pricePassed = (askNow >= orderPrice);  // Price rose to/above limit level
      }
   }

   g_rejections[idx].distPoints   = distAbs / g_point;
   g_rejections[idx].distSpreads  = (spreadNow > 0) ? (distAbs / spreadNow) : 0;
   g_rejections[idx].pricePassed  = pricePassed;
   g_rejections[idx].classification = REJ_CLASS_UNCLASSIFIED;  // Classified later by ClassifyRejections()
   g_rejections[idx].measuredReason = "";  // Set by ClassifyRejections()
   g_rejections[idx].retryAttempts  = 0;
   g_rejections[idx].retrySucceeded = false;
   g_rejections[idx].retryRetcode   = 0;

   // Broker's stated reason (human-readable explanation of retcode)
   switch(retcode)
   {
      case 10004: g_rejections[idx].brokerReason = "Requote — broker claims price changed (liquidity)"; break;
      case 10006: g_rejections[idx].brokerReason = "Rejected — broker refused without specific reason"; break;
      case 10007: g_rejections[idx].brokerReason = "Cancelled by broker"; break;
      case 10010: g_rejections[idx].brokerReason = "Request timeout — broker did not respond in time"; break;
      case 10011: g_rejections[idx].brokerReason = "Invalid price — broker claims price is wrong"; break;
      case 10013: g_rejections[idx].brokerReason = "Invalid request — broker claims order parameters invalid"; break;
      case 10014: g_rejections[idx].brokerReason = "Invalid volume"; break;
      case 10015: g_rejections[idx].brokerReason = "Invalid stops — broker claims stop level too close"; break;
      case 10016: g_rejections[idx].brokerReason = "Trading disabled by broker"; break;
      case 10018: g_rejections[idx].brokerReason = "Market closed"; break;
      case 10019: g_rejections[idx].brokerReason = "Insufficient funds"; break;
      case 10021: g_rejections[idx].brokerReason = "No changes to order"; break;
      case 10030: g_rejections[idx].brokerReason = "Order limit reached"; break;
      default:    g_rejections[idx].brokerReason = StringFormat("Retcode %d — unspecified broker error", retcode); break;
   }
   g_rejectionCount++;

   // Log rejection to ForensicBrokerLog CSV for complete audit trail
   if(g_brokerLogHandle != INVALID_HANDLE)
   {
      ulong logMs = GetTickCount64();
      ulong logEpoch = g_epochMsOffset + logMs;
      string reason = g_rejections[idx].brokerReason;
      StringReplace(reason, ",", ";");  // Sanitize commas for CSV
      string dtRej = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
      FileWriteString(g_brokerLogHandle, StringFormat(
         "%I64u,%I64u,%s,REJECTED,0,0,%s,0,,,%.5f,0.00,,,,,,retcode=%d|type=%s|bid=%.5f|ask=%.5f|spread=%.5f|dist=%.1fpts|reason=%s\n",
         logMs, logEpoch, dtRej, Symbol(), orderPrice, retcode, orderType,
         bidNow, askNow, spreadNow, g_rejections[idx].distPoints, reason));
   }

   // Count by order type (classification happens post-statistics)
   if(StringFind(orderType, "Stop") >= 0)
      g_rejStopTotal++;
   else if(StringFind(orderType, "Limit") >= 0)
      g_rejLimitTotal++;
   else
      g_rejMarketTotal++;

   string retcodeStr =
      retcode == 10004 ? "REQUOTE" :
      retcode == 10006 ? "REJECTED" :
      retcode == 10007 ? "CANCELED" :
      retcode == 10010 ? "REQUEST_TIMEOUT" :
      retcode == 10011 ? "INVALID_PRICE" :
      retcode == 10013 ? "INVALID_REQUEST" :
      retcode == 10014 ? "INVALID_VOLUME" :
      retcode == 10015 ? "INVALID_STOPS" :
      retcode == 10016 ? "TRADE_DISABLED" :
      retcode == 10018 ? "MARKET_CLOSED" :
      retcode == 10019 ? "NO_MONEY" :
      retcode == 10021 ? "NO_CHANGES" :
      retcode == 10030 ? "LIMIT_ORDERS" :
      IntegerToString(retcode);

   PrintFormat("REJECTION: %s retcode=%d (%s) price=%s dist=%.1f pts (%.1f spreads) %s",
      orderType, retcode, retcodeStr, DoubleToString(orderPrice, g_digits),
      g_rejections[idx].distPoints, g_rejections[idx].distSpreads,
      pricePassed ? "[PRICE_PASSED]" : "[PRICE_AWAY]");
}


//+------------------------------------------------------------------+
//| CLASSIFY REJECTIONS — post-statistics analysis                     |
//| Uses measured broker asymmetry to determine if rejections are      |
//| manipulation vs legitimate market conditions                       |
//+------------------------------------------------------------------+
void ClassifyRejections(double medStopLag, double medLimitLag, double stopLimitRatio)
{
   if(g_rejectionCount == 0) return;

   // Reset counters
   g_rejStopManipulation = 0;
   g_rejStopLegitimate = 0;
   g_rejLimitManipulation = 0;
   g_rejLimitLegitimate = 0;
   g_rejTransientCount = 0;
   g_rejPersistentCount = 0;

   // Determine if broker has measured asymmetric processing
   bool hasAsymmetricDelay = (stopLimitRatio > 1.5);  // Stops processed >50% slower than limits
   bool hasExcessiveStopDelay = (medStopLag > 50);     // >50ms stop processing = abnormal

   // Count requotes by type for symmetry check
   int stopRequotes = 0, limitRequotes = 0;
   int stopRejects = 0, limitRejects = 0;
   for(int r = 0; r < g_rejectionCount; r++)
   {
      if(StringFind(g_rejections[r].orderType, "STRESS") >= 0) continue;
      bool isStop = (StringFind(g_rejections[r].orderType, "Stop") >= 0);
      bool isLimit = (StringFind(g_rejections[r].orderType, "Limit") >= 0);
      if(g_rejections[r].retcode == 10004)  // REQUOTE
      {
         if(isStop)  stopRequotes++;
         if(isLimit) limitRequotes++;
      }
      if(g_rejections[r].retcode == 10006)  // REJECTED
      {
         if(isStop)  stopRejects++;
         if(isLimit) limitRejects++;
      }
   }

   // Requote asymmetry: are requotes applied selectively?
   bool requoteAsymmetric = false;
   if(stopRequotes > 0 || limitRequotes > 0)
   {
      if(stopRequotes > 0 && limitRequotes == 0)
         requoteAsymmetric = true;   // Only stops requoted
      else if(stopRequotes > limitRequotes * 3 && stopRequotes > 3)
         requoteAsymmetric = true;   // 3:1+ ratio
   }

   // Now classify each rejection
   for(int r = 0; r < g_rejectionCount; r++)
   {
      if(StringFind(g_rejections[r].orderType, "STRESS") >= 0)
      {
         g_rejections[r].classification = REJ_CLASS_UNCLASSIFIED;
         continue;
      }

      // --- Transient early-exit: retry succeeded → exclude from manipulation ---
      if(g_rejections[r].retrySucceeded)
      {
         g_rejections[r].classification = REJ_CLASS_TRANSIENT;
         g_rejections[r].measuredReason = StringFormat("TRANSIENT — retry succeeded on attempt #%d (original retcode %d, retry retcode %d). "
            "Server accepted the same order %.0fms later — original rejection was a momentary server issue, not manipulation",
            g_rejections[r].retryAttempts, g_rejections[r].retcode, g_rejections[r].retryRetcode,
            (double)g_rejections[r].retryAttempts * InpRejRetryDelayMs);
         g_rejTransientCount++;
         continue;
      }

      // If retries were attempted but all failed → persistent
      if(g_rejections[r].retryAttempts > 0 && !g_rejections[r].retrySucceeded)
         g_rejPersistentCount++;

      bool isStop = (StringFind(g_rejections[r].orderType, "Stop") >= 0);
      bool isLimit = (StringFind(g_rejections[r].orderType, "Limit") >= 0);
      bool pp = g_rejections[r].pricePassed;
      int rc = g_rejections[r].retcode;

      if(!pp)
      {
         // Price was well away from order level — no legitimate reason to reject
         g_rejections[r].classification = REJ_CLASS_SUSPICIOUS;
         g_rejections[r].measuredReason = StringFormat("Price was %.1f spreads away from order level — no market reason for rejection",
            g_rejections[r].distSpreads);
      }
      else if(pp && isStop && hasAsymmetricDelay)
      {
         // Price passed the stop level, BUT broker has proven asymmetric delay.
         // The price only passed BECAUSE the broker artificially delayed processing.
         // This is manufactured rejection — the broker held the order until price moved past it.
         g_rejections[r].classification = REJ_CLASS_ASYMMETRIC_DELAY;
         g_rejections[r].measuredReason = StringFormat("Price passed order level, BUT broker delays stops %.0fms vs limits %.0fms (%.1fx ratio) — "
            "price only moved past BECAUSE broker held the order",
            medStopLag, medLimitLag, stopLimitRatio);
      }
      else if(rc == 10004 && requoteAsymmetric && isStop)
      {
         // Requote applied selectively to stops — "liquidity" excuse is asymmetric
         g_rejections[r].classification = REJ_CLASS_ASYMMETRIC_REQUOTE;
         g_rejections[r].measuredReason = StringFormat("Broker cites liquidity (requote), but stops requoted %dx vs limits %dx — "
            "genuine liquidity affects both types equally",
            stopRequotes, limitRequotes);
      }
      else if(rc == 10004 && !requoteAsymmetric)
      {
         // Requote applied symmetrically to both types — genuine liquidity issue
         g_rejections[r].classification = REJ_CLASS_SYMMETRIC_REQUOTE;
         g_rejections[r].measuredReason = "Requotes applied symmetrically to stops and limits — consistent with genuine liquidity event";
      }
      else if(pp && !hasAsymmetricDelay)
      {
         // Price genuinely passed during symmetric processing — legitimate
         g_rejections[r].classification = REJ_CLASS_LEGITIMATE;
         g_rejections[r].measuredReason = StringFormat("Price genuinely moved past order level during symmetric processing (stop lag %.0fms, limit lag %.0fms)",
            medStopLag, medLimitLag);
      }
      else
      {
         // Default: if price passed and we're uncertain, but stops are clearly targeted
         if(isStop && hasExcessiveStopDelay)
         {
            g_rejections[r].classification = REJ_CLASS_ASYMMETRIC_DELAY;
            g_rejections[r].measuredReason = StringFormat("Price passed order level with excessive stop delay (%.0fms) — "
               "broker held stop order processing until price moved past it", medStopLag);
         }
         else
         {
            g_rejections[r].classification = REJ_CLASS_LEGITIMATE;
            g_rejections[r].measuredReason = "No measured evidence of manipulation — rejection appears consistent with market conditions";
         }
      }

      // Tally
      bool isManip = (g_rejections[r].classification >= REJ_CLASS_SUSPICIOUS &&
                      g_rejections[r].classification <= REJ_CLASS_ASYMMETRIC_REQUOTE);
      if(isStop)
      {
         if(isManip) g_rejStopManipulation++;
         else        g_rejStopLegitimate++;
      }
      else if(isLimit)
      {
         if(isManip) g_rejLimitManipulation++;
         else        g_rejLimitLegitimate++;
      }
   }

   // Build verdict string
   int totalManip = g_rejStopManipulation + g_rejLimitManipulation;
   int totalLegit = g_rejStopLegitimate + g_rejLimitLegitimate;
   int totalClassified = totalManip + totalLegit;  // Excludes transient + unclassified

   // Transient-aware verdict
   if(g_rejTransientCount == g_rejectionCount)
   {
      // ALL rejections were transient — no manipulation
      g_rejectionVerdict = StringFormat("NONE — all %d rejections were transient (retry verified, excluded from analysis)",
         g_rejTransientCount);
   }
   else if(totalManip == 0 && g_rejectionCount > 0)
   {
      if(g_rejTransientCount > 0)
         g_rejectionVerdict = StringFormat("NONE — %d transient (retry verified, excluded), remaining %d have legitimate explanations",
            g_rejTransientCount, totalClassified);
      else
         g_rejectionVerdict = "NONE — all rejections have legitimate explanations";
   }
   else if(g_rejStopManipulation > 0 && g_rejLimitManipulation == 0)
   {
      string transientNote = (g_rejTransientCount > 0) ?
         StringFormat(" (%d transient excluded)", g_rejTransientCount) : "";
      g_rejectionVerdict = StringFormat("SELECTIVE_MANIPULATION — %d stop rejections classified as manipulation, 0 limit rejections%s",
         g_rejStopManipulation, transientNote);
   }
   else if(g_rejStopManipulation > g_rejLimitManipulation * 3 && g_rejStopManipulation > 3)
   {
      string transientNote = (g_rejTransientCount > 0) ?
         StringFormat(" (%d transient excluded)", g_rejTransientCount) : "";
      g_rejectionVerdict = StringFormat("ASYMMETRIC_MANIPULATION — %d stop vs %d limit manipulative rejections%s",
         g_rejStopManipulation, g_rejLimitManipulation, transientNote);
   }
   else if(totalManip > 0)
   {
      string transientNote = (g_rejTransientCount > 0) ?
         StringFormat(" (%d transient excluded)", g_rejTransientCount) : "";
      g_rejectionVerdict = StringFormat("MANIPULATION — %d rejections classified as manipulative (%d stop, %d limit)%s",
         totalManip, g_rejStopManipulation, g_rejLimitManipulation, transientNote);
   }
   else
      g_rejectionVerdict = "NONE";

   PrintFormat("REJECTION CLASSIFICATION: %s", g_rejectionVerdict);
   PrintFormat("  Stop: %d manipulation, %d legitimate | Limit: %d manipulation, %d legitimate",
      g_rejStopManipulation, g_rejStopLegitimate, g_rejLimitManipulation, g_rejLimitLegitimate);
   if(g_rejTransientCount > 0)
      PrintFormat("  Transient (retry verified): %d — excluded from manipulation count", g_rejTransientCount);
   if(g_rejPersistentCount > 0)
      PrintFormat("  Persistent (retry failed): %d — classified normally", g_rejPersistentCount);
   if(hasAsymmetricDelay)
      PrintFormat("  Broker asymmetry: stop lag %.0fms vs limit lag %.0fms (ratio %.1fx) — "
         "price-passed rejections reclassified as MANIPULATION",
         medStopLag, medLimitLag, stopLimitRatio);
   if(requoteAsymmetric)
      PrintFormat("  Requote asymmetry: %d stop requotes vs %d limit requotes — asymmetric liquidity excuse",
         stopRequotes, limitRequotes);
}


//+------------------------------------------------------------------+
//| TRACK FILL REJECTION — broker cancelled a pending grid order       |
//| Called from OnTradeTransaction when HISTORY_ADD shows a grid order |
//| was CANCELED/REJECTED/EXPIRED without filling                      |
//+------------------------------------------------------------------+
void TrackFillRejection(ulong orderTicket, long orderState, long orderReason, long doneMsc)
{
   // Find matching grid order
   int gridIdx = -1;
   for(int i = 0; i < g_gridSize; i++)
   {
      if(g_grid[i].ticket == orderTicket)
      { gridIdx = i; break; }
   }
   if(gridIdx < 0) return;  // Not our grid order

   // Skip if this was EA-initiated deletion (during close phase)
   // During STATE_GRID_WAIT, we never delete orders — any deletion is broker-initiated
   // (EA only deletes in STATE_GRID_CLOSE / STATE_GRID_VERIFY)

   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double spread = ask - bid;

   // Distance from price at cancellation
   double distAbs = 0;
   if(g_grid[gridIdx].isLimit)
   {
      if(g_grid[gridIdx].isBuy)
         distAbs = MathAbs(ask - g_grid[gridIdx].price);  // BuyLimit: ask vs order
      else
         distAbs = MathAbs(bid - g_grid[gridIdx].price);  // SellLimit: bid vs order
   }
   else
   {
      if(g_grid[gridIdx].isBuy)
         distAbs = MathAbs(ask - g_grid[gridIdx].price);  // BuyStop: ask vs order
      else
         distAbs = MathAbs(bid - g_grid[gridIdx].price);  // SellStop: bid vs order
   }

   int idx = g_fillRejectionCount;
   ArrayResize(g_fillRejections, idx + 1);
   g_fillRejections[idx].orderTicket   = orderTicket;
   g_fillRejections[idx].orderPrice    = g_grid[gridIdx].price;
   g_fillRejections[idx].isLimit       = g_grid[gridIdx].isLimit;
   g_fillRejections[idx].isBuy         = g_grid[gridIdx].isBuy;
   g_fillRejections[idx].priceCrossed  = g_grid[gridIdx].priceCrossed;
   g_fillRejections[idx].placeTimeMs   = g_grid[gridIdx].placeTimeMs;
   g_fillRejections[idx].triggerTimeMs = g_grid[gridIdx].triggerTimeMs;
   g_fillRejections[idx].cancelTimeMs  = GetTickCount64();
   g_fillRejections[idx].cancelTimeMsc = doneMsc;
   g_fillRejections[idx].orderState    = orderState;
   g_fillRejections[idx].orderReason   = orderReason;
   g_fillRejections[idx].bidAtCancel   = bid;
   g_fillRejections[idx].askAtCancel   = ask;
   g_fillRejections[idx].spreadAtCancel = spread;
   g_fillRejections[idx].distPoints    = distAbs / g_point;
   g_fillRejections[idx].cycleNum      = g_cycleNum;
   g_fillRejections[idx].classification = FILLREJ_CLASS_UNCLASSIFIED;
   g_fillRejections[idx].measuredReason = "";  // Set by ClassifyFillRejections()

   // Determine order type string
   if(g_grid[gridIdx].isLimit)
      g_fillRejections[idx].orderType = g_grid[gridIdx].isBuy ? "BuyLimit" : "SellLimit";
   else
      g_fillRejections[idx].orderType = g_grid[gridIdx].isBuy ? "BuyStop" : "SellStop";

   // Broker's stated reason from ORDER_STATE
   switch((int)orderState)
   {
      case ORDER_STATE_CANCELED:  g_fillRejections[idx].brokerReason = "Cancelled — broker removed order without filling"; break;
      case ORDER_STATE_REJECTED:  g_fillRejections[idx].brokerReason = "Rejected — broker refused to execute at trigger"; break;
      case ORDER_STATE_EXPIRED:   g_fillRejections[idx].brokerReason = "Expired — broker claims order validity period ended"; break;
      default: g_fillRejections[idx].brokerReason = StringFormat("Unknown state %d", (int)orderState); break;
   }

   // Append ORDER_REASON detail
   string reasonDetail = "";
   switch((int)orderReason)
   {
      case ORDER_REASON_CLIENT: reasonDetail = " (client request)"; break;
      case ORDER_REASON_EXPERT: reasonDetail = " (EA request)"; break;
      case ORDER_REASON_SL:     reasonDetail = " (stop loss)"; break;
      case ORDER_REASON_TP:     reasonDetail = " (take profit)"; break;
      default: reasonDetail = StringFormat(" (reason=%d)", (int)orderReason); break;
   }
   g_fillRejections[idx].brokerReason += reasonDetail;

   // Count by type
   if(g_grid[gridIdx].isLimit)
      g_fillRejLimitTotal++;
   else
      g_fillRejStopTotal++;

   g_fillRejectionCount++;

   // Log to evidence CSV
   LogEvidence(g_cycleNum, "FILL_REJECT", g_fillRejections[idx].orderType, orderTicket,
      g_grid[gridIdx].price, 0, bid, ask, g_fillRejections[idx].distPoints, 0, 0, 0,
      StringFormat("state=%d reason=%d priceCrossed=%s trigMs=%I64u",
         (int)orderState, (int)orderReason,
         g_grid[gridIdx].priceCrossed ? "YES" : "NO",
         g_grid[gridIdx].triggerTimeMs));
}


//+------------------------------------------------------------------+
//| CLASSIFY FILL REJECTIONS — called after statistics are computed    |
//| Uses measured execution asymmetry to determine if fill rejections  |
//| are manipulation or legitimate                                     |
//+------------------------------------------------------------------+
void ClassifyFillRejections(double medStopLag, double medLimitLag, double stopLimitRatio)
{
   if(g_fillRejectionCount == 0)
   {
      g_fillRejVerdict = "NONE";
      return;
   }

   bool hasAsymmetricDelay = (stopLimitRatio > 1.5);

   g_fillRejStopTriggered = 0;
   g_fillRejLimitTriggered = 0;
   g_fillRejStopPreemptive = 0;
   g_fillRejLimitPreemptive = 0;

   for(int r = 0; r < g_fillRejectionCount; r++)
   {
      bool isStop = !g_fillRejections[r].isLimit;
      bool triggered = g_fillRejections[r].priceCrossed;

      if(triggered)
      {
         // Price reached the order level — broker should have filled but didn't
         g_fillRejections[r].classification = FILLREJ_CLASS_PRICE_TRIGGERED;

         if(isStop && hasAsymmetricDelay)
         {
            g_fillRejections[r].measuredReason = StringFormat(
               "Price REACHED order level (trigger confirmed) — broker cancelled instead of filling. "
               "Combined with %.0fms stop delay vs %.0fms limit delay (%.1fx ratio), "
               "this is deliberate fill suppression of stop orders",
               medStopLag, medLimitLag, stopLimitRatio);
         }
         else if(isStop)
         {
            g_fillRejections[r].measuredReason =
               "Price REACHED order level but broker cancelled instead of filling. "
               "Stop order disappeared after trigger - order was accepted, price was valid, "
               "but broker refused to honor it";
         }
         else
         {
            g_fillRejections[r].measuredReason =
               "Price REACHED limit order level but broker cancelled instead of filling. "
               "This affects the broker's own favorable orders - unusual";
         }

         if(isStop) g_fillRejStopTriggered++;
         else       g_fillRejLimitTriggered++;
      }
      else
      {
         // Price never reached the order — broker cancelled preemptively
         g_fillRejections[r].classification = FILLREJ_CLASS_PREEMPTIVE;

         if(isStop)
         {
            g_fillRejections[r].measuredReason = StringFormat(
               "Broker cancelled stop order BEFORE price reached level (%.1f pts away). "
               "Order was accepted, then removed — broker pre-emptively eliminated the order",
               g_fillRejections[r].distPoints);
         }
         else
         {
            g_fillRejections[r].measuredReason = StringFormat(
               "Broker cancelled limit order before price reached level (%.1f pts away)",
               g_fillRejections[r].distPoints);
         }

         if(isStop) g_fillRejStopPreemptive++;
         else       g_fillRejLimitPreemptive++;
      }
   }

   // Determine verdict
   int totalStopFillRej = g_fillRejStopTriggered + g_fillRejStopPreemptive;
   int totalLimitFillRej = g_fillRejLimitTriggered + g_fillRejLimitPreemptive;

   if(g_fillRejStopTriggered > 0 && g_fillRejLimitTriggered == 0)
      g_fillRejVerdict = "SELECTIVE_FILL_SUPPRESSION";
   else if(g_fillRejStopTriggered > 0 && totalStopFillRej > totalLimitFillRej * 3)
      g_fillRejVerdict = "ASYMMETRIC_FILL_SUPPRESSION";
   else if(g_fillRejStopTriggered > 0 || g_fillRejStopPreemptive > 0)
      g_fillRejVerdict = "FILL_SUPPRESSION";
   else if(totalLimitFillRej > 0 && totalStopFillRej == 0)
      g_fillRejVerdict = "UNUSUAL — only limit orders cancelled";
   else
      g_fillRejVerdict = "PRESENT — review needed";

   PrintFormat("FILL REJECTION CLASSIFICATION: %s", g_fillRejVerdict);
   PrintFormat("  Stops: %d triggered + %d preemptive = %d | Limits: %d triggered + %d preemptive = %d",
      g_fillRejStopTriggered, g_fillRejStopPreemptive, totalStopFillRej,
      g_fillRejLimitTriggered, g_fillRejLimitPreemptive, totalLimitFillRej);
}


//+------------------------------------------------------------------+
//| ANALYZE PHANTOM SPIKES in tick buffer                              |
//| Detects anomalous price spikes that could trigger SL              |
//+------------------------------------------------------------------+
void AnalyzePhantomSpikes()
{
   if(g_tickBufCount < 50) return;  // Need enough data for statistics

   // Linearize the circular buffer into a working array
   // ONLY include ticks from the grid phase (exclude stress test period)
   int rawN = g_tickBufCount;
   double linBid[], linAsk[];
   ulong  linMs[];
   int n = 0;
   ArrayResize(linBid, rawN);
   ArrayResize(linAsk, rawN);
   ArrayResize(linMs, rawN);
   for(int i = 0; i < rawN; i++)
   {
      int ci = (g_tickBufHead - rawN + i + TICK_BUF_SIZE) % TICK_BUF_SIZE;
      ulong tickMs = g_tickBuf[ci].timeMs;

      // Skip stress-test-period ticks — they are noise, not genuine phantom spikes
      if(g_gridPhaseEndMs > 0 && tickMs >= g_gridPhaseEndMs)
         continue;

      linBid[n] = g_tickBuf[ci].bid;
      linAsk[n] = g_tickBuf[ci].ask;
      linMs[n]  = tickMs;
      n++;
   }
   ArrayResize(linBid, n);
   ArrayResize(linAsk, n);
   ArrayResize(linMs, n);

   if(n < 50)
   {
      PrintFormat("PHANTOM SPIKES: only %d grid-phase ticks in buffer (need 50) — skipping analysis", n);
      return;
   }

   PrintFormat("PHANTOM SPIKES: analyzing %d grid-phase ticks (%d stress-phase ticks excluded)",
      n, rawN - n);

   // Phase 1: Compute median and std dev of spread
   double spreads[];
   ArrayResize(spreads, n);
   double spreadSum = 0;
   for(int i = 0; i < n; i++)
   {
      spreads[i] = linAsk[i] - linBid[i];
      spreadSum += spreads[i];
   }
   g_meanSpread = spreadSum / n;

   // Sort spreads for median
   double sortedSpreads[];
   ArrayCopy(sortedSpreads, spreads);
   ArraySort(sortedSpreads);
   g_medianSpread = sortedSpreads[n / 2];

   // Std dev of spread
   double spreadVar = 0;
   for(int i = 0; i < n; i++)
      spreadVar += (spreads[i] - g_meanSpread) * (spreads[i] - g_meanSpread);
   double spreadStd = MathSqrt(spreadVar / n);
   if(spreadStd < g_tickSize) spreadStd = g_tickSize;  // Floor

   // Phase 2: Compute rolling price mean and std for Z-score
   int window = MathMin(100, n / 4);
   if(window < 20) window = 20;

   g_phantomSpikeCount = 0;
   ArrayResize(g_phantomSpikes, 0);

   for(int i = window; i < n; i++)
   {
      double midPrice = (linBid[i] + linAsk[i]) / 2;
      double curSpread = linAsk[i] - linBid[i];

      // Rolling mean/std of mid price
      double sum = 0, sumSq = 0;
      for(int j = i - window; j < i; j++)
      {
         double mid = (linBid[j] + linAsk[j]) / 2;
         sum += mid;
         sumSq += mid * mid;
      }
      double rollingMean = sum / window;
      double rollingVar = (sumSq / window) - (rollingMean * rollingMean);
      double rollingStd = MathSqrt(MathMax(0, rollingVar));
      if(rollingStd < g_tickSize) rollingStd = g_tickSize;

      double zScore = MathAbs(midPrice - rollingMean) / rollingStd;

      // Spike criteria: spread must be anomalous (>3x median) — this is the "phantom" part.
      // Z-score > 3 alone is just normal price movement, NOT a phantom spike.
      // A real phantom spike = broker briefly widens spread to trigger SL then reverts.
      bool spreadAnomaly = (curSpread > g_medianSpread * 3.0);
      bool isSpike = spreadAnomaly;  // Spread widening is mandatory for phantom spike

      if(isSpike)
      {
         int idx = g_phantomSpikeCount;
         ArrayResize(g_phantomSpikes, idx + 1);
         g_phantomSpikes[idx].timeMs       = linMs[i];
         g_phantomSpikes[idx].bid          = linBid[i];
         g_phantomSpikes[idx].ask          = linAsk[i];
         g_phantomSpikes[idx].spread       = curSpread;
         g_phantomSpikes[idx].medianSpread = g_medianSpread;
         g_phantomSpikes[idx].zScore       = zScore;
         g_phantomSpikes[idx].triggeredSL  = false;  // Check below
         g_phantomSpikeCount++;
      }
   }

   // Phase 3: Check if any spike coincided with an SL trigger
   // CRITICAL FIX: spike timeMs is GetTickCount64() (boot-relative), while
   // dealTimeMsc is Unix epoch ms. Convert spike time to epoch for comparison.
   for(int s = 0; s < g_phantomSpikeCount; s++)
   {
      // Convert spike GetTickCount64 → epoch ms
      ulong spikeEpochMs = g_epochMsOffset + g_phantomSpikes[s].timeMs;

      for(int f = 0; f < g_fillCount; f++)
      {
         if(g_fills[f].fillType != FILL_SL) continue;
         // Spike within 2 seconds of SL fill
         ulong slEpochMs = (ulong)g_fills[f].dealTimeMsc;
         if(slEpochMs > 0 && spikeEpochMs > 0)
         {
            ulong diff = (slEpochMs > spikeEpochMs) ? (slEpochMs - spikeEpochMs) : (spikeEpochMs - slEpochMs);
            if(diff < 2000)
            {
               g_phantomSpikes[s].triggeredSL = true;
               break;
            }
         }
      }
   }

   int slSpikes = 0;
   for(int s = 0; s < g_phantomSpikeCount; s++)
      if(g_phantomSpikes[s].triggeredSL) slSpikes++;

   PrintFormat("PHANTOM SPIKES: %d detected, %d coincided with SL triggers", g_phantomSpikeCount, slSpikes);
}


//+------------------------------------------------------------------+
//| COMPUTE MARGIN VERIFICATION                                        |
//| Compare actual margin charged vs theoretical calculation           |
//+------------------------------------------------------------------+
void ComputeMarginVerification()
{
   if(g_measuredMarginBuy <= 0) return;

   // Theoretical margin = (lots × contract_size × price) / leverage
   double contractSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
   double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);  // Use current price as approximation
   double leverage = (double)g_accountLeverage;

   if(leverage <= 0 || contractSize <= 0) return;

   g_theoreticalMarginBuy = (g_lotSize * contractSize * price) / leverage;

   g_marginDiscrepancyBuy = g_measuredMarginBuy - g_theoreticalMarginBuy;
   if(g_theoreticalMarginBuy > 0)
      g_marginMarkupPctBuy = (g_marginDiscrepancyBuy / g_theoreticalMarginBuy) * 100.0;

   if(g_measuredMarginBoth > 0)
   {
      // For both sides, theoretical depends on hedging model
      // Netting/hedged: margin ≈ single side. Gross: margin = 2x
      if(g_calculatedHedgingRatio >= 0 && g_calculatedHedgingRatio < 0.55)
         g_theoreticalMarginBoth = g_theoreticalMarginBuy;  // Netted
      else
         g_theoreticalMarginBoth = g_theoreticalMarginBuy * 2.0;  // Gross

      g_marginDiscrepancyBoth = g_measuredMarginBoth - g_theoreticalMarginBoth;
      if(g_theoreticalMarginBoth > 0)
         g_marginMarkupPctBoth = (g_marginDiscrepancyBoth / g_theoreticalMarginBoth) * 100.0;
   }

   PrintFormat("MARGIN VERIFY: theoretical=%.2f actual=%.2f diff=%.2f (%.1f%%)",
      g_theoreticalMarginBuy, g_measuredMarginBuy, g_marginDiscrepancyBuy, g_marginMarkupPctBuy);
}
