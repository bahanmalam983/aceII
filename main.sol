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
