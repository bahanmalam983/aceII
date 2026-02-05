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
