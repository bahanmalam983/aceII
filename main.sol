// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title aceII — Onchain yield mathematics and rate curves
/// @notice Precision yield and APR/APY calculators with ray math and configurable curves.
/// @dev Uses 1e27 (ray) and 1e36 scaling to avoid truncation in nested compounding.
contract aceII {

    // -------------------------------------------------------------------------
    // Constants (scale factors and fixed math bounds)
    // -------------------------------------------------------------------------

    uint256 internal constant RAY_SCALE = 1e27;
    uint256 internal constant HIGH_PRECISION = 1e36;
    uint256 internal constant SECONDS_PER_YEAR = 31_557_600;
    uint256 internal constant PERIODS_CAP = 365;
    uint256 internal constant MAX_RATE_PERCENT = 1e29;
    uint256 internal constant FLOOR_UTIL = 0.65e27;

    // -------------------------------------------------------------------------
    // Immutable config (set at deployment)
    // -------------------------------------------------------------------------

    address public immutable governor;
    address public immutable feeSink;
    address public immutable fallbackKeeper;

    // -------------------------------------------------------------------------
    // Mutable state
    // -------------------------------------------------------------------------

    uint256 public protocolFeeBps;
    uint256 public lastSnapshotBlock;
    uint256 public curveKinkUtil;
    uint256 public curveSlopeBelow;
    uint256 public curveSlopeAbove;
    uint256 public baseRatePerSecRay;

    // -------------------------------------------------------------------------
    // Errors (unique to this contract)
    // -------------------------------------------------------------------------

    error AceII_DenomZero();
    error AceII_Overflow();
    error AceII_NotGovernor();
    error AceII_NotKeeper();
    error AceII_RateOutOfBounds();
    error AceII_UtilOutOfRange();
    error AceII_PeriodsTooHigh();
    error AceII_BpsOverHundred();

    // -------------------------------------------------------------------------
    // Events (unique naming)
    // -------------------------------------------------------------------------

    event CurveParamsUpdated(uint256 kinkUtil, uint256 slopeBelow, uint256 slopeAbove, uint256 baseRay);
    event YieldSnapshot(uint256 indexed epoch, uint256 aprRay, uint256 apyRay, uint256 utilRay);
    event FeeBpsChanged(uint256 previousBps, uint256 newBps);
    event KeeperSnapshot(uint256 blockNum, uint256 borrowRateRay);

    // -------------------------------------------------------------------------
    // Constructor — authority and sinks set at deploy; no args required
    // -------------------------------------------------------------------------

    constructor() {
        governor = msg.sender;
        feeSink = address(0x8A3fC2d1E9b4F7a0c6D2e5B8f1A3d9C7e4F0b2A);
        fallbackKeeper = address(0x2F7e1B9c4A6d0E8f3a5C2b7D1e9F4A0c6B3d8E5);
        protocolFeeBps = 25;
        curveKinkUtil = 0.80e27;
        curveSlopeBelow = 0.04e27;
        curveSlopeAbove = 0.60e27;
        baseRatePerSecRay = 1584407172113525096151; // ~5% APR in per-second ray
        lastSnapshotBlock = block.number;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyGovernor() {
        if (msg.sender != governor) revert AceII_NotGovernor();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != governor && msg.sender != fallbackKeeper) revert AceII_NotKeeper();
        _;
    }

    // -------------------------------------------------------------------------
    // Admin: curve and fee config
    // -------------------------------------------------------------------------

    function setCurve(
        uint256 kinkUtil_,
        uint256 slopeBelow_,
        uint256 slopeAbove_,
        uint256 baseRay_
    ) external onlyGovernor {
        if (kinkUtil_ > RAY_SCALE) revert AceII_UtilOutOfRange();
        if (baseRay_ > MAX_RATE_PERCENT) revert AceII_RateOutOfBounds();
        curveKinkUtil = kinkUtil_;
        curveSlopeBelow = slopeBelow_;
        curveSlopeAbove = slopeAbove_;
        baseRatePerSecRay = baseRay_;
        emit CurveParamsUpdated(kinkUtil_, slopeBelow_, slopeAbove_, baseRay_);
    }

    function setProtocolFeeBps(uint256 bps) external onlyGovernor {
        if (bps > 10_000) revert AceII_BpsOverHundred();
        uint256 prev = protocolFeeBps;
        protocolFeeBps = bps;
        emit FeeBpsChanged(prev, bps);
    }

    // -------------------------------------------------------------------------
    // Pure: ray math helpers
    // -------------------------------------------------------------------------

    function rayMul(uint256 a, uint256 b) public pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        uint256 c = a * b;
        if (c / a != b) revert AceII_Overflow();
        return c / RAY_SCALE;
    }

    function rayDiv(uint256 a, uint256 b) public pure returns (uint256) {
        if (b == 0) revert AceII_DenomZero();
        return (a * RAY_SCALE) / b;
    }

    function rayPow(uint256 x, uint256 n) public pure returns (uint256) {
        if (n == 0) return RAY_SCALE;
        if (n == 1) return x;
        uint256 z = x;
        for (uint256 i = 2; i <= n; i++) {
            z = rayMul(z, x);
        }
        return z;
    }

    // -------------------------------------------------------------------------
    // Pure: utilization (ray)
    // -------------------------------------------------------------------------

    function utilizationRay(
        uint256 totalCash,
        uint256 totalBorrows
    ) public pure returns (uint256) {
        if (totalCash == 0 && totalBorrows == 0) return 0;
        if (totalCash == 0) return RAY_SCALE;
        return rayDiv(totalBorrows, totalCash + totalBorrows);
    }

    // -------------------------------------------------------------------------
    // Pure: kinked borrow rate (per second, ray)
    // -------------------------------------------------------------------------

    function borrowRatePerSecRay(
        uint256 totalCash,
        uint256 totalBorrows,
        uint256 kinkUtil,
        uint256 slopeBelow,
        uint256 slopeAbove,
        uint256 baseRay
    ) public pure returns (uint256) {
        uint256 u = utilizationRay(totalCash, totalBorrows);
        if (u == 0) return baseRay;
        if (u <= kinkUtil) {
            uint256 factor = rayDiv(u, kinkUtil);
            return baseRay + rayMul(slopeBelow, factor);
        }
        uint256 excess = u - kinkUtil;
        uint256 denom = RAY_SCALE - kinkUtil;
        if (denom == 0) return baseRay + slopeBelow;
        uint256 factor = rayDiv(excess, denom);
        return baseRay + slopeBelow + rayMul(slopeAbove, factor);
    }

    function currentBorrowRateRay(uint256 totalCash, uint256 totalBorrows) external view returns (uint256) {
        return borrowRatePerSecRay(
            totalCash,
            totalBorrows,
            curveKinkUtil,
            curveSlopeBelow,
            curveSlopeAbove,
            baseRatePerSecRay
        );
    }

    // -------------------------------------------------------------------------
    // Pure: APR (per year) from per-second rate in ray
    // -------------------------------------------------------------------------

    function ratePerSecToAprRay(uint256 ratePerSecRay) public pure returns (uint256) {
        return rayMul(ratePerSecRay, SECONDS_PER_YEAR);
    }

    // -------------------------------------------------------------------------
    // Pure: APY from APR with compounding periods per year (ray)
    // -------------------------------------------------------------------------

    function aprToApyRay(uint256 aprRay, uint256 periodsPerYear) public pure returns (uint256) {
        if (periodsPerYear == 0) revert AceII_DenomZero();
        if (periodsPerYear > PERIODS_CAP) revert AceII_PeriodsTooHigh();
        uint256 onePlusR = RAY_SCALE + rayDiv(aprRay, periodsPerYear);
        uint256 compounded = rayPow(onePlusR, periodsPerYear);
        if (compounded < RAY_SCALE) return 0;
        return compounded - RAY_SCALE;
    }

    // -------------------------------------------------------------------------
    // Pure: future value (ray) — principal * (1 + rate)^periods
    // -------------------------------------------------------------------------

    function futureValueRay(
        uint256 principalRay,
        uint256 ratePerPeriodRay,
        uint256 periods
    ) public pure returns (uint256) {
        if (periods == 0) return principalRay;
        uint256 onePlusR = RAY_SCALE + ratePerPeriodRay;
        uint256 factor = rayPow(onePlusR, periods);
        return rayMul(principalRay, factor);
    }

    // -------------------------------------------------------------------------
    // Pure: present value (ray) — futureValue / (1 + rate)^periods
    // -------------------------------------------------------------------------

    function presentValueRay(
        uint256 futureValueRay,
        uint256 ratePerPeriodRay,
