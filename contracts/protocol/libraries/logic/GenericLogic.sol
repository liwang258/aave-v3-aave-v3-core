// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {IPriceOracleGetter} from '../../../interfaces/IPriceOracleGetter.sol';
import {ReserveConfiguration} from '../configuration/ReserveConfiguration.sol';
import {UserConfiguration} from '../configuration/UserConfiguration.sol';
import {PercentageMath} from '../math/PercentageMath.sol';
import {WadRayMath} from '../math/WadRayMath.sol';
import {DataTypes} from '../types/DataTypes.sol';
import {ReserveLogic} from './ReserveLogic.sol';
import {EModeLogic} from './EModeLogic.sol';

/**
 * @title GenericLogic library
 * @author Aave
 * @notice Implements protocol-level logic to calculate and validate the state of a user
 */
library GenericLogic {
  using ReserveLogic for DataTypes.ReserveData;
  using WadRayMath for uint256;
  using PercentageMath for uint256;
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
  using UserConfiguration for DataTypes.UserConfigurationMap;

  struct CalculateUserAccountDataVars {
    uint256 assetPrice;
    uint256 assetUnit;
    uint256 userBalanceInBaseCurrency;
    uint256 decimals;
    uint256 ltv;
    uint256 liquidationThreshold;
    uint256 i;
    uint256 healthFactor;
    uint256 totalCollateralInBaseCurrency;
    uint256 totalDebtInBaseCurrency;
    uint256 avgLtv;
    uint256 avgLiquidationThreshold;
    uint256 eModeAssetPrice;
    uint256 eModeLtv;
    uint256 eModeLiqThreshold;
    uint256 eModeAssetCategory;
    address currentReserveAddress;
    bool hasZeroLtvCollateral;
    bool isInEModeCategory;
  }

  /**
   * @notice Calculates the user data across the reserves.
   * @dev It includes the total liquidity/collateral/borrow balances in the base currency used by the price feed,
   * the average Loan To Value, the average Liquidation Ratio, and the Health factor.
   * @param reservesData The state of all the reserves
   * @param reservesList The addresses of all the active reserves
   * @param eModeCategories The configuration of all the efficiency mode categories
   * @param params Additional parameters needed for the calculation
   * @return 用户总抵押价值（以价格预言机基准货币计价）,所有用户用作抵押的资产，按实时价格折算后的总价值，是借款额度的计算基础
   * @return 用户总债务价值（以价格预言机基准货币计价）,用户所有稳定利率 + 可变利率借款，按实时价格折算后的总负债
   * @return 用户平均贷款价值比（LTV）,加权平均值（按各抵押资产价值加权），决定用户最大可借款额度（可借额度 = 总抵押价值 × 平均 LTV）
   * @return 用户平均清算阈值	,加权平均值（按各抵押资产价值加权），触发清算的临界值（当总债务价值≥总抵押价值 × 清算阈值时，可被清算）
   * @return 用户账户健康因子,核心风控指标，计算公式：(总抵押价值 × 平均清算阈值) ÷ 总债务价值；健康因子＜1 时，账户可被清算
   * @return 用户是否持有零 LTV 抵押资产,零 LTV 资产无法用于借款，仅作持仓，该标识用于判断用户是否具备借款资格

   */
  function calculateUserAccountData(
    // 存储所有储备资产的状态映射：键=储备资产地址，值=该资产的ReserveData状态（核心状态载体）
    mapping(address => DataTypes.ReserveData) storage reservesData,
    // 存储所有活跃储备资产的地址映射：键=储备资产ID（对应ReserveData.id），值=储备资产合约地址，用于遍历资产
    mapping(uint256 => address) storage reservesList,
    // 存储所有效率模式（EMode）类别的配置映射：键=EMode类别ID，值=EMode配置信息，用于优化风控计算
    mapping(uint8 => DataTypes.EModeCategory) storage eModeCategories,
    // 用户账户数据计算的附加参数：包含用户配置、资产数量、用户地址等（前文已详解）
    DataTypes.CalculateUserAccountDataParams memory params
  ) internal view returns (uint256, uint256, uint256, uint256, uint256, bool) {
    if (params.userConfig.isEmpty()) {
      //若用户未配置任何抵押资产或借款资产（userConfig为空），直接返回默认值
      //返回默认值说明：总抵押 / 总债务 / 平均 LTV / 平均清算阈值均为 0，健康因子为最大值（无债务时健康度极高），无零 LTV 资产
      return (0, 0, 0, 0, type(uint256).max, false);
    }
    //声明局部变量容器vars，用于存储遍历过程中的临时数据（如资产价格、抵押价值、债务价值等），避免重复查询
    CalculateUserAccountDataVars memory vars;

    if (params.userEModeCategory != 0) {
      //逻辑: 若用户启用了 EMode（效率模式，同类高相关性资产优化），则加载该 EMode 类别的 LTV、清算阈值及统一资产价格
      //作用：优化同类资产（如 ETH 系、稳定币系）的风控计算，提升效率并降低清算风险
      (vars.eModeLtv, vars.eModeLiqThreshold, vars.eModeAssetPrice) = EModeLogic
        .getEModeConfiguration(
          eModeCategories[params.userEModeCategory],
          IPriceOracleGetter(params.oracle)
        );
    }

    while (vars.i < params.reservesCount) {
      // 跳过用户未抵押且未借款的资产，提升遍历效率
      if (!params.userConfig.isUsingAsCollateralOrBorrowing(vars.i)) {
        unchecked {
          ++vars.i;
        }
        continue;
      }

      vars.currentReserveAddress = reservesList[vars.i];
      // 获取当前储备资产地址，跳过无效地址
      if (vars.currentReserveAddress == address(0)) {
        unchecked {
          ++vars.i;
        }
        continue;
      }
      // 获取当前储备资产的完整状态（核心关联ReserveData结构体）
      DataTypes.ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];
      // 从ReserveData的配置中提取该资产的风控参数与属性
      (
        vars.ltv,
        vars.liquidationThreshold,
        ,
        vars.decimals,
        ,
        vars.eModeAssetCategory
      ) = currentReserve.configuration.getParams();
      // 计算资产单位（10^小数位数，用于金额缩放）
      unchecked {
        vars.assetUnit = 10 ** vars.decimals;
      }
      // 确定资产价格：优先使用EMode统一价格，否则从预言机获取实时价格
      vars.assetPrice = vars.eModeAssetPrice != 0 &&
        params.userEModeCategory == vars.eModeAssetCategory
        ? vars.eModeAssetPrice
        : IPriceOracleGetter(params.oracle).getAssetPrice(vars.currentReserveAddress);
      // ------------- 计算用户抵押资产价值 -------------
      if (vars.liquidationThreshold != 0 && params.userConfig.isUsingAsCollateral(vars.i)) {
        // 计算该资产的用户持仓价值（基准货币计价）
        vars.userBalanceInBaseCurrency = _getUserBalanceInBaseCurrency(
          params.user,
          currentReserve,
          vars.assetPrice,
          vars.assetUnit
        );
        // 累加至总抵押价值
        vars.totalCollateralInBaseCurrency += vars.userBalanceInBaseCurrency;
        // 判断是否属于当前EMode类别
        vars.isInEModeCategory = EModeLogic.isInEModeCategory(
          params.userEModeCategory,
          vars.eModeAssetCategory
        );
        // 累加加权平均LTV（若资产LTV非零）
        if (vars.ltv != 0) {
          vars.avgLtv +=
            vars.userBalanceInBaseCurrency *
            (vars.isInEModeCategory ? vars.eModeLtv : vars.ltv);
        } else {
          // 标记存在零LTV资产
          vars.hasZeroLtvCollateral = true;
        }
        // 累加加权平均清算阈值
        vars.avgLiquidationThreshold +=
          vars.userBalanceInBaseCurrency *
          (vars.isInEModeCategory ? vars.eModeLiqThreshold : vars.liquidationThreshold);
      }
      // ------------- 计算用户借款债务价值 -------------
      if (params.userConfig.isBorrowing(vars.i)) {
        // 计算该资产的用户债务价值（基准货币计价），累加至总债务价值
        vars.totalDebtInBaseCurrency += _getUserDebtInBaseCurrency(
          params.user,
          currentReserve,
          vars.assetPrice,
          vars.assetUnit
        );
      }
      // 遍历下一个资产（unchecked避免溢出检查，提升效率）
      unchecked {
        ++vars.i;
      }
    }
    // 计算平均LTV（总加权LTV ÷ 总抵押价值，避免除零）
    unchecked {
      vars.avgLtv = vars.totalCollateralInBaseCurrency != 0
        ? vars.avgLtv / vars.totalCollateralInBaseCurrency
        : 0;
      // 计算平均清算阈值（总加权清算阈值 ÷ 总抵押价值，避免除零）
      vars.avgLiquidationThreshold = vars.totalCollateralInBaseCurrency != 0
        ? vars.avgLiquidationThreshold / vars.totalCollateralInBaseCurrency
        : 0;
    }
    // 计算健康因子：无债务时为最大值，否则按风控公式计算
    vars.healthFactor = (vars.totalDebtInBaseCurrency == 0)
      ? type(uint256).max
      : (vars.totalCollateralInBaseCurrency.percentMul(vars.avgLiquidationThreshold)).wadDiv(
        vars.totalDebtInBaseCurrency
      );
    return (
      vars.totalCollateralInBaseCurrency,
      vars.totalDebtInBaseCurrency,
      vars.avgLtv,
      vars.avgLiquidationThreshold,
      vars.healthFactor,
      vars.hasZeroLtvCollateral
    );
  }

  /**
   * @notice Calculates the maximum amount that can be borrowed depending on the available collateral, the total debt
   * and the average Loan To Value
   * @param totalCollateralInBaseCurrency The total collateral in the base currency used by the price feed
   * @param totalDebtInBaseCurrency The total borrow balance in the base currency used by the price feed
   * @param ltv The average loan to value
   * @return The amount available to borrow in the base currency of the used by the price feed
   */
  function calculateAvailableBorrows(
    uint256 totalCollateralInBaseCurrency,
    uint256 totalDebtInBaseCurrency,
    uint256 ltv
  ) internal pure returns (uint256) {
    uint256 availableBorrowsInBaseCurrency = totalCollateralInBaseCurrency.percentMul(ltv);

    if (availableBorrowsInBaseCurrency < totalDebtInBaseCurrency) {
      return 0;
    }

    availableBorrowsInBaseCurrency = availableBorrowsInBaseCurrency - totalDebtInBaseCurrency;
    return availableBorrowsInBaseCurrency;
  }

  /**
   * @notice Calculates total debt of the user in the based currency used to normalize the values of the assets
   * @dev This fetches the `balanceOf` of the stable and variable debt tokens for the user. For gas reasons, the
   * variable debt balance is calculated by fetching `scaledBalancesOf` normalized debt, which is cheaper than
   * fetching `balanceOf`
   * @param user The address of the user
   * @param reserve The data of the reserve for which the total debt of the user is being calculated
   * @param assetPrice The price of the asset for which the total debt of the user is being calculated
   * @param assetUnit The value representing one full unit of the asset (10^decimals)
   * @return The total debt of the user normalized to the base currency
   */
  function _getUserDebtInBaseCurrency(
    address user,
    DataTypes.ReserveData storage reserve,
    uint256 assetPrice,
    uint256 assetUnit
  ) private view returns (uint256) {
    // fetching variable debt
    uint256 userTotalDebt = IScaledBalanceToken(reserve.variableDebtTokenAddress).scaledBalanceOf(
      user
    );
    if (userTotalDebt != 0) {
      userTotalDebt = userTotalDebt.rayMul(reserve.getNormalizedDebt());
    }

    userTotalDebt = userTotalDebt + IERC20(reserve.stableDebtTokenAddress).balanceOf(user);

    userTotalDebt = assetPrice * userTotalDebt;

    unchecked {
      return userTotalDebt / assetUnit;
    }
  }

  /**
   * @notice Calculates total aToken balance of the user in the based currency used by the price oracle
   * @dev For gas reasons, the aToken balance is calculated by fetching `scaledBalancesOf` normalized debt, which
   * is cheaper than fetching `balanceOf`
   * @param user The address of the user
   * @param reserve The data of the reserve for which the total aToken balance of the user is being calculated
   * @param assetPrice The price of the asset for which the total aToken balance of the user is being calculated
   * @param assetUnit The value representing one full unit of the asset (10^decimals)
   * @return The total aToken balance of the user normalized to the base currency of the price oracle
   */
  function _getUserBalanceInBaseCurrency(
    address user,
    DataTypes.ReserveData storage reserve,
    uint256 assetPrice,
    uint256 assetUnit
  ) private view returns (uint256) {
    uint256 normalizedIncome = reserve.getNormalizedIncome();
    uint256 balance = (
      IScaledBalanceToken(reserve.aTokenAddress).scaledBalanceOf(user).rayMul(normalizedIncome)
    ) * assetPrice;

    unchecked {
      return balance / assetUnit;
    }
  }
}
