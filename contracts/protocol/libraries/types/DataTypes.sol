// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library DataTypes {
  struct ReserveData {
    // 存储该储备资产的全套核心配置信息（含启用状态、抵押权限、风控系数等行为规则）
    ReserveConfigurationMap configuration;
    // 流动性指数（供应指数），以ray（10^27）为单位，用于计算用户aToken的应计利息（aToken余额=初始余额×该指数）
    uint128 liquidityIndex;
    // 当前供应利率，以ray（10^27）为单位，是用户存入该资产提供流动性时，当前可获得的年化利率（动态更新）
    uint128 currentLiquidityRate;
    // 可变借款指数，以ray（10^27）为单位，用于计算用户可变利率债务的应计利息（可变债务余额=初始余额×该指数）
    uint128 variableBorrowIndex;
    // 当前可变借款利率，以ray（10^27）为单位，是用户以可变利率模式借款时，当前适用的年化利率（随市场流动性波动）
    uint128 currentVariableBorrowRate;
    // 当前稳定借款利率，以ray（10^27）为单位，是用户以稳定利率模式借款时，当前适用的年化利率（借款时锁定，极端场景小幅调整）
    uint128 currentStableBorrowRate;
    // 该储备资产最后一次状态（利率、指数等）更新的时间戳，是计算利息累积的核心时间基准
    uint40 lastUpdateTimestamp;
    // 储备资产ID，代表该资产在协议活跃储备资产列表中的位置索引，用于快速定位数据
    uint16 id;
    // 该储备资产对应的aToken合约地址（计息存款凭证，用户存入底层资产后获得，余额随流动性指数复利增长）
    address aTokenAddress;
    // 该储备资产对应的稳定债务代币合约地址（用户稳定利率借款时的债务凭证，还款时需销毁对应代币）
    address stableDebtTokenAddress;
    // 该储备资产对应的可变债务代币合约地址（用户可变利率借款时的债务凭证，余额随可变借款指数增长）
    address variableDebtTokenAddress;
    // 该储备资产的利率策略合约地址，内置利率定价模型（基于流动性使用率），决定各类利率的动态调整逻辑
    address interestRateStrategyAddress;
    // 累积归属协议国库的手续费余额（已按资产精度缩放），来自借款利息分成，是协议核心收入来源
    uint128 accruedToTreasury;
    // 无抵押aToken余额，指通过跨链桥等特殊功能铸造的、未对应实际底层资产的aToken（特殊场景使用）
    uint128 unbacked;
    // 隔离模式总债务，指用户在隔离模式下，以该资产为抵押所借的未偿还债务总额（用于隔离模式风险管控）
    uint128 isolationModeTotalDebt;
  }

  struct ReserveConfigurationMap {
    //bit 0-15: LTV
    //bit 16-31: Liq. threshold
    //bit 32-47: Liq. bonus
    //bit 48-55: Decimals
    //bit 56: reserve is active
    //bit 57: reserve is frozen
    //bit 58: borrowing is enabled
    //bit 59: stable rate borrowing enabled
    //bit 60: asset is paused
    //bit 61: borrowing in isolation mode is enabled
    //bit 62: siloed borrowing enabled
    //bit 63: flashloaning enabled
    //bit 64-79: reserve factor
    //bit 80-115 borrow cap in whole tokens, borrowCap == 0 => no cap
    //bit 116-151 supply cap in whole tokens, supplyCap == 0 => no cap
    //bit 152-167 liquidation protocol fee
    //bit 168-175 eMode category
    //bit 176-211 unbacked mint cap in whole tokens, unbackedMintCap == 0 => minting disabled
    //bit 212-251 debt ceiling for isolation mode with (ReserveConfiguration::DEBT_CEILING_DECIMALS) decimals
    //bit 252-255 unused

    uint256 data;
  }

  struct UserConfigurationMap {
    /**
     * @dev Bitmap of the users collaterals and borrows. It is divided in pairs of bits, one pair per asset.
     * The first bit indicates if an asset is used as collateral by the user, the second whether an
     * asset is borrowed by the user.
     */
    uint256 data;
  }

  struct EModeCategory {
    // each eMode category has a custom ltv and liquidation threshold
    uint16 ltv;
    uint16 liquidationThreshold;
    uint16 liquidationBonus;
    // each eMode category may or may not have a custom oracle to override the individual assets price oracles
    address priceSource;
    string label;
  }

  enum InterestRateMode {
    NONE,
    STABLE,
    VARIABLE
  }

  struct ReserveCache {
    uint256 currScaledVariableDebt;
    uint256 nextScaledVariableDebt;
    uint256 currPrincipalStableDebt;
    uint256 currAvgStableBorrowRate;
    uint256 currTotalStableDebt;
    uint256 nextAvgStableBorrowRate;
    uint256 nextTotalStableDebt;
    uint256 currLiquidityIndex;
    uint256 nextLiquidityIndex;
    uint256 currVariableBorrowIndex;
    uint256 nextVariableBorrowIndex;
    uint256 currLiquidityRate;
    uint256 currVariableBorrowRate;
    uint256 reserveFactor;
    ReserveConfigurationMap reserveConfiguration;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    uint40 reserveLastUpdateTimestamp;
    uint40 stableDebtLastUpdateTimestamp;
  }

  struct ExecuteLiquidationCallParams {
    uint256 reservesCount;
    uint256 debtToCover;
    address collateralAsset;
    address debtAsset;
    address user;
    bool receiveAToken;
    address priceOracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
  }

  struct ExecuteSupplyParams {
    address asset;
    uint256 amount;
    address onBehalfOf;
    uint16 referralCode;
  }

  struct ExecuteBorrowParams {
    address asset;
    address user;
    address onBehalfOf;
    uint256 amount;
    InterestRateMode interestRateMode;
    uint16 referralCode;
    bool releaseUnderlying;
    uint256 maxStableRateBorrowSizePercent;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
  }

  struct ExecuteRepayParams {
    address asset;
    uint256 amount;
    InterestRateMode interestRateMode;
    address onBehalfOf;
    bool useATokens;
  }

  struct ExecuteWithdrawParams {
    address asset;
    uint256 amount;
    address to;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
  }

  struct ExecuteSetUserEModeParams {
    uint256 reservesCount;
    address oracle;
    uint8 categoryId;
  }

  struct FinalizeTransferParams {
    address asset;
    address from;
    address to;
    uint256 amount;
    uint256 balanceFromBefore;
    uint256 balanceToBefore;
    uint256 reservesCount;
    address oracle;
    uint8 fromEModeCategory;
  }

  struct FlashloanParams {
    address receiverAddress;
    address[] assets;
    uint256[] amounts;
    uint256[] interestRateModes;
    address onBehalfOf;
    bytes params;
    uint16 referralCode;
    uint256 flashLoanPremiumToProtocol;
    uint256 flashLoanPremiumTotal;
    uint256 maxStableRateBorrowSizePercent;
    uint256 reservesCount;
    address addressesProvider;
    uint8 userEModeCategory;
    bool isAuthorizedFlashBorrower;
  }

  struct FlashloanSimpleParams {
    address receiverAddress;
    address asset;
    uint256 amount;
    bytes params;
    uint16 referralCode;
    uint256 flashLoanPremiumToProtocol;
    uint256 flashLoanPremiumTotal;
  }

  struct FlashLoanRepaymentParams {
    uint256 amount;
    uint256 totalPremium;
    uint256 flashLoanPremiumToProtocol;
    address asset;
    address receiverAddress;
    uint16 referralCode;
  }

  struct CalculateUserAccountDataParams {
    // 用户配置映射：存储该用户的借贷资产配置（如哪些资产作为抵押、哪些资产存在借款等）
    UserConfigurationMap userConfig;
    // 协议中活跃储备资产的总数量：用于遍历所有储备资产，核对用户的借贷持仓情况
    uint256 reservesCount;
    // 目标用户的钱包地址：指定需要计算账户数据的用户身份
    address user;
    // 价格预言机合约地址：用于获取各类资产的实时市场价格（计算资产/债务的美元价值等）
    address oracle;
    // 用户的加密模式（EMode）分类ID：EMode是同类高相关性资产的优化风控模式，该ID指定用户当前所属的EMode类别
    uint8 userEModeCategory;
  }

  struct ValidateBorrowParams {
    ReserveCache reserveCache;
    UserConfigurationMap userConfig;
    address asset;
    address userAddress;
    uint256 amount;
    InterestRateMode interestRateMode;
    uint256 maxStableLoanPercent;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
    bool isolationModeActive;
    address isolationModeCollateralAddress;
    uint256 isolationModeDebtCeiling;
  }

  struct ValidateLiquidationCallParams {
    ReserveCache debtReserveCache;
    uint256 totalDebt;
    uint256 healthFactor;
    address priceOracleSentinel;
  }

  struct CalculateInterestRatesParams {
    uint256 unbacked;
    uint256 liquidityAdded;
    uint256 liquidityTaken;
    uint256 totalStableDebt;
    uint256 totalVariableDebt;
    uint256 averageStableBorrowRate;
    uint256 reserveFactor;
    address reserve;
    address aToken;
  }

  struct InitReserveParams {
    address asset;
    address aTokenAddress;
    address stableDebtAddress;
    address variableDebtAddress;
    address interestRateStrategyAddress;
    uint16 reservesCount;
    uint16 maxNumberReserves;
  }
}
