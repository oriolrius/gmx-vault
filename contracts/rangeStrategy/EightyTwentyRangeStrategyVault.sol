// SPDX-License-Identifier: GPL-2.0-or-later
/*
  Eighty Twenty Strategy
  1. 80% of the liquidity is allocated to the base range
  2. 20% of the liquidity is allocated to the range above the base range
  3. If the net position is above the base range, the vault will sell the excess tokens to bring the position back to the base range
  4. If the net position is below the base range, the vault will buy the excess tokens to bring the position back to the base range
  5. If the net position is within the base range, the vault will do nothing
  6. If the net position is above the range above the base range, the vault will close the position
  7. The vault will not open a position above the range above the base range
  */
pragma solidity ^0.8.9;

import { IClearingHouse } from '@ragetrade/core/contracts/interfaces/IClearingHouse.sol';
import { IClearingHouseStructures } from '@ragetrade/core/contracts/interfaces/clearinghouse/IClearingHouseStructures.sol';
import { IClearingHouseEnums } from '@ragetrade/core/contracts/interfaces/clearinghouse/IClearingHouseEnums.sol';
import { SignedMath } from '@ragetrade/core/contracts/libraries/SignedMath.sol';
import { SignedFullMath } from '@ragetrade/core/contracts/libraries/SignedFullMath.sol';

import { ClearingHouseExtsload } from '@ragetrade/core/contracts/extsloads/ClearingHouseExtsload.sol';
import { FullMath } from '@uniswap/v3-core-0.8-support/contracts/libraries/FullMath.sol';

import { BaseVault } from '../base/BaseVault.sol';
import { Logic } from '../libraries/Logic.sol';
import { SafeCast } from '../libraries/SafeCast.sol';

abstract contract EightyTwentyRangeStrategyVault is BaseVault {
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;
    using SignedMath for int256;
    using SignedFullMath for int256;
    using FullMath for uint256;
    using ClearingHouseExtsload for IClearingHouse;

    error ETRS_INVALID_CLOSE();

    int24 public baseTickLower;
    int24 public baseTickUpper;
    uint128 public baseLiquidity;
    bool public isReset;
    uint16 public closePositionSlippageSqrtToleranceBps;
    uint16 private resetPositionThresholdBps;
    uint64 public minNotionalPositionToCloseThreshold;
    uint64 private constant SQRT_PRICE_FACTOR_PIPS = 800000; // scaled by 1e6

    struct EightyTwentyRangeStrategyVaultInitParams {
        BaseVaultInitParams baseVaultInitParams;
        uint16 closePositionSlippageSqrtToleranceBps;
        uint16 resetPositionThresholdBps;
        uint64 minNotionalPositionToCloseThreshold;
    }

    /* solhint-disable-next-line func-name-mixedcase */
    function __EightyTwentyRangeStrategyVault_init(EightyTwentyRangeStrategyVaultInitParams memory params)
        internal
        onlyInitializing
    {
        __BaseVault_init(params.baseVaultInitParams);
        closePositionSlippageSqrtToleranceBps = params.closePositionSlippageSqrtToleranceBps;
        resetPositionThresholdBps = params.resetPositionThresholdBps;
        minNotionalPositionToCloseThreshold = params.minNotionalPositionToCloseThreshold;
        emit Logic.EightyTwentyParamsUpdated(
            params.closePositionSlippageSqrtToleranceBps,
            params.resetPositionThresholdBps,
            params.minNotionalPositionToCloseThreshold
        );
    }

    /*
      Allows the owner of the contract to update certain parameters related to the trading strategy.
    */
    function setEightTwentyParams(
        uint16 _closePositionSlippageSqrtToleranceBps,
        uint16 _resetPositionThresholdBps,
        uint64 _minNotionalPositionToCloseThreshold
    ) external onlyOwner {
        closePositionSlippageSqrtToleranceBps = _closePositionSlippageSqrtToleranceBps;
        resetPositionThresholdBps = _resetPositionThresholdBps;
        minNotionalPositionToCloseThreshold = _minNotionalPositionToCloseThreshold;
        emit Logic.EightyTwentyParamsUpdated(
            _closePositionSlippageSqrtToleranceBps,
            _resetPositionThresholdBps,
            _minNotionalPositionToCloseThreshold
        );
    }

    /*
        RANGE STRATEGY
    */

    /* 
    The function checks if the current price is within the target rebalance range, and if not, it assesses whether a reset is needed. If a reset is necessary, it recursively checks if the reset state falls within the rebalance range. This process ensures that the portfolio remains within the desired range even after rebalancing.

    The logic follows these steps:
      1. First, it calls the **`isValidRebalanceRangeWithoutCheckReset`** function from the **`Logic`** contract. This function checks if the current price is within the target rebalance range. The **`rageVPool`**, **`ethPoolId`**, **`rebalancePriceThresholdBps`**, **`baseTickLower`**, and **`baseTickUpper`** are parameters used in this check.
      2. If the current price is within the rebalance range (isValid is true), it means the portfolio is in a suitable state, and there is no need to rebalance.
      3. If the current price is not within the rebalance range (isValid is false), it means the portfolio is outside the desired range, and a rebalance might be needed.
      4. The code then proceeds to check whether a reset is required by calling the **`checkIsReset`** function. The **`vaultMarketValue`** is used as a parameter in this check. The purpose of this check is to determine if the portfolio needs to be reset to a predefined base state.
      5. If **`checkIsReset`** returns true (indicating a reset is needed), the code goes back to step 1 and checks if the reset price (after rebalancing) falls within the target rebalance range. This is done by recursively calling **`_isValidRebalanceRange`** again, now with the updated **`vaultMarketValue`** and the new rebalanced state.
      6. The process repeats until either the portfolio is rebalanced and stays within the desired range (isValid is true) or no reset is required (checkIsReset returns false). At that point, the function will return true, indicating that either no rebalance is needed, or the portfolio has been successfully rebalanced back into the target range.

    */
    /// @inheritdoc BaseVault
    function _isValidRebalanceRange(int256 vaultMarketValue) internal view override returns (bool isValid) {
        isValid = Logic.isValidRebalanceRangeWithoutCheckReset(
            rageVPool,
            rageClearingHouse.getTwapDuration(ethPoolId),
            rebalancePriceThresholdBps,
            baseTickLower,
            baseTickUpper
        );

        if (!isValid) {
            isValid = checkIsReset(vaultMarketValue);
        }
    }

    /*
    The checkIsReset function determines if a reset is required based on the current pool price and the notional value of the token in the vault. A reset is needed when the current pool price deviates significantly from the price recorded at the last reset. The function calculates the absolute price deviation and compares it against a predefined threshold to make this determination.

    In the checkIsReset function, the protocol can efficiently determine if a reset is necessary to maintain the desired price range and trading stability in the 80 20 strategy.

      1. Get the current Time-Weighted Average Price (TWAP) of the pool using the function **`_getTwapSqrtPriceX96()`** from the **`rageClearingHouse.sol`** contract.
      2. Get the notional value of the token held in the vault using the function **`_getTokenNotionalAbs()`** from the **`rageClearingHouse.sol`** contract.
      3. Calculate the absolute price deviation between the current TWAP price and the price recorded at the last reset using the function **`absUint()`** from the **`typeUtils.sol`** library.
      4. Check if the absolute price deviation is greater than a predefined threshold to determine if a reset is required.
      5. If the absolute price deviation is above the threshold, return **`true`**, indicating that a reset is needed. Otherwise, return **`false`**.
    */
    function checkIsReset(int256 vaultMarketValue) internal view returns (bool _isReset) {
        int256 netPosition = rageClearingHouse.getAccountNetTokenPosition(rageAccountNo, ethPoolId);

        uint256 netPositionNotional = _getTokenNotionalAbs(netPosition, _getTwapSqrtPriceX96());
        //To Reset if netPositionNotional > 20% of vaultMarketValue
        _isReset = netPositionNotional > vaultMarketValue.absUint().mulDiv(resetPositionThresholdBps, 1e4);
    }

    /*
      The _afterDepositRanges function is called after a deposit of funds into the protocol by an account. Responsible for updating the tick ranges of liquidity positions in the pool for which the account has provided collateral.

      The purpose of this function is to adjust the liquidity positions' tick ranges based on the change in the account's collateral balance after a deposit. The function ensures that the liquidity provided remains properly balanced within the specified tick range constraints.

        1. Determine the pool ID to which the deposit was made. This information is already available in the function's context.
        2. Get the pool's tick range limits and other relevant settings from the protocol using functions like **`getPoolSettings`** and **`getVPoolAndTwapDuration`**.
        3. Get the account's current collateral balance and the deposited amount.
        4. Calculate the updated account's collateral balance after the deposit.
        5. Calculate the net change in the collateral balance due to the deposit (account's new collateral balance - previous collateral balance).
        6. Calculate the equivalent changes in base and quote amounts using tick calculations and the pool's settings.
        7. Update the account's liquidity positions' tick ranges based on the calculated changes to ensure that the provided liquidity remains within the desired tick range.
        8. Perform necessary adjustments and validations to ensure the updated tick ranges are within acceptable boundaries.
        9. If the tick ranges have been adjusted, update the relevant liquidity positions in the pool to reflect the new tick range settings.

    */
    /// @inheritdoc BaseVault
    function _afterDepositRanges(uint256 amountAfterDeposit, uint256 amountDeposited) internal virtual override {
        int256 depositMarketValue = getMarketValue(amountDeposited).toInt256();

        // add collateral token based on updated market value - so that adding more liquidity does not cause issues
        _settleCollateral(depositMarketValue);

        IClearingHouseStructures.LiquidityChangeParams memory liquidityChangeParam;
        if (baseLiquidity == 0 && amountAfterDeposit == amountDeposited) {
            // No range present - calculate range params and add new range
            uint160 twapSqrtPriceX96 = _getTwapSqrtPriceX96();
            (baseTickLower, baseTickUpper, baseLiquidity) = Logic.getUpdatedBaseRangeParams(
                twapSqrtPriceX96,
                depositMarketValue,
                SQRT_PRICE_FACTOR_PIPS
            );
            liquidityChangeParam = _getLiquidityChangeParams(baseTickLower, baseTickUpper, baseLiquidity.toInt128());
        } else {
            // Range Present - Add to base range based on the additional assets deposited
            liquidityChangeParam = _getLiquidityChangeParamsAfterDepositWithdraw(
                amountAfterDeposit - amountDeposited,
                amountDeposited,
                false
            );
            // assert(liquidityChangeParam.liquidityDelta > 0);

            baseLiquidity += uint128(liquidityChangeParam.liquidityDelta);
        }
        //Update range on rage core
        rageClearingHouse.updateRangeOrder(rageAccountNo, ethPoolId, liquidityChangeParam);
    }

    /*
      Handles the necessary updates in liquidity and collateral before a user withdraws funds from the pool. It adjusts the base liquidity, checks if the position is fully withdrawn, updates the order, and settles the collateral based on the updated market value of assets.

        1. The function takes two parameters as input:
            - **`amountBeforeWithdraw`**: The total amount of funds in the user's account before the withdrawal.
            - **`amountWithdrawn`**: The amount the user intends to withdraw from the pool.
        2. It calculates the **`liquidityChangeParam`** by calling the **`_getLiquidityChangeParamsAfterDepositWithdraw`** function. This function is responsible for computing the change in liquidity after the withdrawal, based on the **`amountBeforeWithdraw`** and **`amountWithdrawn`**. The third argument **`true`** indicates that this is a withdrawal operation.
        3. It updates the **`baseLiquidity`** by subtracting the negative value of **`liquidityChangeParam.liquidityDelta`**. This effectively removes the withdrawn liquidity from the **`baseLiquidity`**.
        4. It checks if the **`baseLiquidity`** becomes zero after the withdrawal. If the liquidity becomes zero, it means the position has been fully withdrawn, and the variable **`liquidityChangeParam.closeTokenPosition`** is set to **`true`**.
        5. The function then calls **`rageClearingHouse.updateRangeOrder`** to update the order for the given **`rageAccountNo`** and **`ethPoolId`** using the updated **`liquidityChangeParam`**. This update reflects the change in liquidity due to the withdrawal.
        6. Finally, it calculates the **`depositMarketValue`** by calling the **`getMarketValue`** function with **`amountWithdrawn`** as an argument and converting it to **`int256`**. The **`getMarketValue`** function likely calculates the market value of the assets represented by the **`amountWithdrawn`**.
        7. It calls the **`_settleCollateral`** function with **`depositMarketValue`** as an argument. The **`_settleCollateral`** function presumably settles the collateral based on the updated market value of assets, where a negative value indicates the withdrawal of collateral.
    */
    /// @inheritdoc BaseVault
    function _beforeWithdrawRanges(uint256 amountBeforeWithdraw, uint256 amountWithdrawn) internal virtual override {
        // Remove from base range based on the collateral removal
        IClearingHouseStructures.LiquidityChangeParams
            memory liquidityChangeParam = _getLiquidityChangeParamsAfterDepositWithdraw(
                amountBeforeWithdraw,
                amountWithdrawn,
                true
            );
        // assert(liquidityChangeParam.liquidityDelta < 0);
        baseLiquidity -= uint128(-liquidityChangeParam.liquidityDelta);

        //In case liquidity is becoming 0 then remove the remaining position
        //Remaining position should not lead to high slippage since threshold check is done before withdrawal
        if (baseLiquidity == 0) liquidityChangeParam.closeTokenPosition = true;
        rageClearingHouse.updateRangeOrder(rageAccountNo, ethPoolId, liquidityChangeParam);

        // Settle collateral based on updated market value of assets
        int256 depositMarketValue = getMarketValue(amountWithdrawn).toInt256();
        _settleCollateral(-depositMarketValue);
    }

    /*
      This function is called before closing the position within the trading range. It swaps the tokens in the range based on the specified slippage tolerance.

        1. The **`tokensToTrade`** parameter represents the amount of tokens that need to be traded or adjusted before closing the position.
        2. If **`tokensToTrade`** is positive, it indicates that the strategy has an excess amount of token 0 compared to the desired target. To bring the position in line with the target, the strategy will sell the excess token 0 in exchange for token 1.
        3. If **`tokensToTrade`** is negative, it means that the strategy has a deficit of token 0 compared to the desired target. To balance the position, the strategy will buy the required amount of token 0 using token 1.
        4. The amount of token 0 to be bought or sold is equal to the absolute value of **`tokensToTrade`**.
        5. The strategy will call the **`_swapToken`** function to perform the token swap. Inside **`_swapToken`**, there is a call to **`_swap`** to execute the actual token exchange.
        6. The **`_swap`** function, in turn, calls **`_swapExactTokenForToken`**, which is responsible for conducting the swap operation using the Uniswap router or a similar mechanism.
        7. The Uniswap router allows the strategy to swap tokens efficiently and at the prevailing market rate.
    */
    /// @inheritdoc BaseVault
    function _beforeWithdrawClosePositionRanges(int256 tokensToTrade) internal override {
        if (tokensToTrade != 0) {
            _swapToken(tokensToTrade, 0);
        }
    }

    /*
      It is called when there is a need to adjust the position due to changes in the market conditions or to maintain the desired asset allocation.

        1. The function takes two parameters:
          - **`netTraderPosition`**: This represents the net position of the trader in the market. A positive value indicates a long position (more base asset), while a negative value indicates a short position (more quote asset).
          - **`vaultMarketValue`**: This represents the current market value of the vault's assets.
        2. The function first checks if a reset is needed by calling the **`checkIsReset`** function with the **`vaultMarketValue`**. A reset is typically performed when the market conditions deviate significantly from the desired strategy, and a full realignment is required.
        3. Next, the function retrieves a list of liquidity change parameters using the **`_getLiquidityChangeParamsOnRebalance`** function. This list contains instructions on how the liquidity of the position should be adjusted to rebalance it.
        4. The function then iterates through the **`liquidityChangeParamList`** to execute the required liquidity changes for each range in the strategy.
        5. The **`rageClearingHouse.updateRangeOrder`** function is called inside the loop to update the order book with the new liquidity settings for each range. This ensures that the position is adjusted as per the strategy's rebalancing requirements.
        6. After updating the liquidity for all ranges, the function checks if a reset was needed (**`isReset`** is true). If a reset was performed, it calls **`_closeTokenPositionOnReset`** to close the entire token position and realign the strategy completely.
    */

    /// @inheritdoc BaseVault
    function _rebalanceRanges(int256 netTraderPosition, int256 vaultMarketValue) internal override {
        isReset = checkIsReset(vaultMarketValue);
        IClearingHouseStructures.LiquidityChangeParams[2]
            memory liquidityChangeParamList = _getLiquidityChangeParamsOnRebalance(vaultMarketValue);

        for (uint8 i = 0; i < liquidityChangeParamList.length; i++) {
            if (liquidityChangeParamList[i].liquidityDelta == 0) break;
            rageClearingHouse.updateRangeOrder(rageAccountNo, ethPoolId, liquidityChangeParamList[i]);
        }

        if (isReset) _closeTokenPositionOnReset(netTraderPosition);
    }

    /*
      This function is called when a reset is required in the 80-20 strategy. A reset is typically triggered when the market conditions deviate significantly from the desired strategy, and the entire position needs to be closed to realign it with the target allocation.

        1. The function takes one parameter:
          - **`netTraderPosition`**: This represents the net position of the trader in the market. A positive value indicates a long position (more base asset), while a negative value indicates a short position (more quote asset).
        2. It first checks if a reset is valid. If a reset is not valid, it reverts the transaction with the **`ETRS_INVALID_CLOSE`** error, preventing unauthorized resets.
        3. The function calculates the amount of tokens to trade (**`tokensToTrade`**) to close the entire position. For a reset, this amount is equal to the absolute value of **`netTraderPosition`**.
        4. It then obtains the square root of the TWAP (Time-Weighted Average Price) of the pool using **`_getTwapSqrtPriceX96`** function. TWAP is used to get an accurate price representation over a period of time to determine the notional value of the tokens to be traded.
        5. The function calculates the absolute notional value of the **`tokensToTrade`** using **`_getTokenNotionalAbs`** function. The notional value is the value of an asset based on its quantity and the current market price.
        6. If the notional value of **`tokensToTrade`** is greater than the **`minNotionalPositionToCloseThreshold`**, the function proceeds to close the position.
        7. Inside the closing logic, it calls **`_closeTokenPosition`** function to perform the actual closing of the token position with specified slippage tolerance.
        8. After closing the token position, it checks if the entire position was closed (**`tokensToTrade`** is equal to **`vTokenAmountOut`**). If so, it sets **`isReset`** to false, indicating that the reset is completed.
        9. If the notional value of **`tokensToTrade`** is less than or equal to the **`minNotionalPositionToCloseThreshold`**, it skips the closing logic and sets **`isReset`** to false directly.
        10. Finally, the function emits a **`TokenPositionClosed`** event to notify external observers about the closure of the token position.

    */

    /// @inheritdoc BaseVault
    function _closeTokenPositionOnReset(int256 netTraderPosition) internal override {
        if (!isReset) revert ETRS_INVALID_CLOSE();
        int256 tokensToTrade = -netTraderPosition;
        uint160 sqrtTwapPriceX96 = _getTwapSqrtPriceX96();
        uint256 tokensToTradeNotionalAbs = _getTokenNotionalAbs(tokensToTrade, sqrtTwapPriceX96);

        if (tokensToTradeNotionalAbs > minNotionalPositionToCloseThreshold) {
            (int256 vTokenAmountOut, ) = _closeTokenPosition(
                tokensToTrade,
                sqrtTwapPriceX96,
                closePositionSlippageSqrtToleranceBps
            );

            //If whole position is closed then reset is done
            if (tokensToTrade == vTokenAmountOut) isReset = false;
        } else {
            isReset = false;
        }

        emit Logic.TokenPositionClosed();
    }

    /*
      Close a position on the Rage Clearing House by swapping tokens. In summary, _closeTokenPosition is a helper function used to close a position on the Rage Clearing House. It calculates the slippage tolerance, sets the price limit for the swap, and then executes the swap using _swapToken, returning the resulting token amounts.

        1. **`tokensToTrade`**: The amount of tokens to be traded. This parameter can be positive (indicating a long position to be closed) or negative (indicating a short position to be closed).
        2. **`sqrtPriceX96`**: The square root of the price in X96 format. This parameter is used to set a price limit for the swap to prevent excessive slippage.
        3. **`slippageSqrtToleranceBps`**: The slippage tolerance of the square root price, specified in basis points (BPS). This parameter determines how much price slippage is allowed during the swap.
        4. **`vTokenAmountOut`**: The amount of tokens (base asset) that will be received after the swap. This represents the number of base tokens that will be obtained by closing the position.
        5. **`vQuoteAmountOut`**: The amount of quote tokens that will be received after the swap. This represents the number of quote tokens (counter asset) that will be obtained by closing the position.
        6. Inside the function, it calculates the **`sqrtPriceLimitX96`** based on the direction of the trade (**`tokensToTrade > 0`** or **`tokensToTrade <= 0`**). If **`tokensToTrade`** is positive, it sets the **`sqrtPriceLimitX96`** by adding the slippage tolerance to the current **`sqrtPriceX96`**. If **`tokensToTrade`** is negative, it sets the **`sqrtPriceLimitX96`** by subtracting the slippage tolerance from the current **`sqrtPriceX96`**.
        7. After calculating the **`sqrtPriceLimitX96`**, it calls the **`_swapToken`** function to perform the token swap operation.
        8. The **`_swapToken`** function is responsible for executing the actual token swap with the specified slippage tolerance.
        9. The function returns the resulting **`vTokenAmountOut`** and **`vQuoteAmountOut`**, which represent the amounts of tokens and quote tokens received after the swap, respectively.

    */

    /// @notice Close position on rage clearing house
    /// @param tokensToTrade Amount of tokens to trade
    /// @param sqrtPriceX96 Sqrt of price in X96
    /// @param slippageSqrtToleranceBps Slippage tolerance of sqrt price
    /// @return vTokenAmountOut amount of tokens on close
    /// @return vQuoteAmountOut amount of quote on close
    function _closeTokenPosition(
        int256 tokensToTrade,
        uint160 sqrtPriceX96,
        uint16 slippageSqrtToleranceBps
    ) internal returns (int256 vTokenAmountOut, int256 vQuoteAmountOut) {
        uint160 sqrtPriceLimitX96;

        if (tokensToTrade > 0) {
            sqrtPriceLimitX96 = uint256(sqrtPriceX96).mulDiv(1e4 + slippageSqrtToleranceBps, 1e4).toUint160();
        } else {
            sqrtPriceLimitX96 = uint256(sqrtPriceX96).mulDiv(1e4 - slippageSqrtToleranceBps, 1e4).toUint160();
        }
        (vTokenAmountOut, vQuoteAmountOut) = _swapToken(tokensToTrade, sqrtPriceLimitX96);
    }

    /*
      Helper function used to swap tokens on the Rage Clearing House. It creates the necessary SwapParams, calls the rageClearingHouse.swapToken function, and returns the resulting token amounts. The purpose of this function is to abstract the swapping process and make the code more modular and readable.

        1. **`tokensToTrade`**: The amount of tokens to be traded. This parameter can be positive (indicating tokens to be sold) or negative (indicating tokens to be bought).
        2. **`sqrtPriceLimitX96`**: The square root of the price limit for the swap in X96 format. This parameter is used to control the slippage and protect against excessive price changes during the swap.
        3. **`vTokenAmountOut`**: The amount of tokens (base asset) that will be received after the swap. This represents the number of base tokens that will be obtained from the trade.
        4. **`vQuoteAmountOut`**: The amount of quote tokens (counter asset) that will be received after the swap. This represents the number of quote tokens that will be obtained from the trade.
        5. Inside the function, it creates a **`SwapParams`** struct with the following parameters:
            - **`amount`**: The amount of tokens to be traded (**`tokensToTrade`**).
            - **`sqrtPriceLimit`**: The square root of the price limit for the swap (**`sqrtPriceLimitX96`**).
            - **`isNotional`**: A boolean flag that indicates whether the swap is notional. In this case, it is set to **`false`**.
            - **`isPartialAllowed`**: A boolean flag that indicates whether partial fills are allowed in the swap. In this case, it is set to **`true`**.
            - **`settleProfit`**: A boolean flag that indicates whether to settle the profit. In this case, it is set to **`false`**.
        6. After creating the **`SwapParams`** struct, it calls the **`rageClearingHouse.swapToken`** function to perform the token swap operation.
        7. The **`rageClearingHouse.swapToken`** function executes the swap based on the provided parameters and returns the resulting **`vTokenAmountOut`** and **`vQuoteAmountOut`**, which represent the amounts of tokens and quote tokens received after the swap, respectively.
    */

    function _swapToken(int256 tokensToTrade, uint160 sqrtPriceLimitX96)
        internal
        returns (int256 vTokenAmountOut, int256 vQuoteAmountOut)
    {
        IClearingHouseStructures.SwapParams memory swapParams = IClearingHouseStructures.SwapParams({
            amount: tokensToTrade,
            sqrtPriceLimit: sqrtPriceLimitX96,
            isNotional: false,
            isPartialAllowed: true,
            settleProfit: false
        });
        (vTokenAmountOut, vQuoteAmountOut) = rageClearingHouse.swapToken(rageAccountNo, ethPoolId, swapParams);
    }

    /*
      Determining the changes in liquidity parameters during a rebalancing event.  It calculates the changes needed to remove the old base range and add the new base range based on the updated market conditions. These parameters are used to adjust the liquidity of the base range to ensure proper functioning of the strategy during rebalancing.

        1. **`vaultMarketValue`**: The market value of the vault in USDC. This value is used to determine the appropriate liquidity changes based on the rebalance.
        2. **`liquidityChangeParamList`**: An array of **`IClearingHouseStructures.LiquidityChangeParams`** that will store the liquidity change parameters for the base range.
        3. It initializes the **`liqCount`** variable to keep track of the number of liquidity change parameters in the **`liquidityChangeParamList`**.
        4. If the **`baseLiquidity`** (current liquidity of the base range) is greater than 0, it means that there is an existing base range that needs to be removed during the rebalance. It calculates the liquidity change parameters for the current base range and stores them in the **`liquidityChangeParamList`**.
        5. It calculates the **`twapSqrtPriceX96`** which represents the square root of the time-weighted average price of the pool.
        6. It calls **`Logic.getUpdatedBaseRangeParams`** to determine the updated parameters for the base range. This function takes into account the **`twapSqrtPriceX96`**, **`vaultMarketValue`**, and **`SQRT_PRICE_FACTOR_PIPS`** (a constant factor) to calculate the new **`baseTickLower`**, **`baseTickUpper`**, and **`baseLiquidityUpdate`** values. The base liquidity (**`baseLiquidity`**) is updated based on these new parameters.
        7. If there are no existing ranges (**`baseLiquidity == 0`**) or if a reset is required (**`isReset`** is true), it means that a new base liquidity value needs to be set based on the **`baseLiquidityUpdate`**.
        8. It stores the new base range's liquidity change parameters in the **`liquidityChangeParamList`**.
        9. Finally, the function returns the **`liquidityChangeParamList`**, which contains the liquidity change parameters for removing the old base range and adding the new base range during the rebalance event.

    */

    /// @notice Get liquidity change params on rebalance
    /// @param vaultMarketValue Market value of vault in USDC
    /// @return liquidityChangeParamList Liquidity change params
    function _getLiquidityChangeParamsOnRebalance(int256 vaultMarketValue)
        internal
        returns (IClearingHouseStructures.LiquidityChangeParams[2] memory liquidityChangeParamList)
    {
        // Get net token position
        // Remove reabalance
        // Add new rebalance range
        // Update base range liquidity
        uint8 liqCount = 0;

        if (baseLiquidity > 0) {
            // assert(baseTickLower != 0);
            // assert(baseTickUpper != 0);
            // assert(baseLiquidity != 0);
            //Remove previous range
            liquidityChangeParamList[liqCount] = _getLiquidityChangeParams(
                baseTickLower,
                baseTickUpper,
                -baseLiquidity.toInt128()
            );
            liqCount++;
        }
        uint160 twapSqrtPriceX96 = _getTwapSqrtPriceX96();

        uint128 baseLiquidityUpdate;
        (baseTickLower, baseTickUpper, baseLiquidityUpdate) = Logic.getUpdatedBaseRangeParams(
            twapSqrtPriceX96,
            vaultMarketValue,
            SQRT_PRICE_FACTOR_PIPS
        );

        // If (there are no ranges) || (netPositionNotional > 20% of vault market value) then update base liquidity otherwise carry forward same liquidity value
        if (baseLiquidity == 0 || isReset) {
            baseLiquidity = baseLiquidityUpdate;
        }

        //Add new range
        liquidityChangeParamList[liqCount] = _getLiquidityChangeParams(
            baseTickLower,
            baseTickUpper,
            baseLiquidity.toInt128()
        );
        liqCount++;
    }

    /*
      Used to simulate the effects of a withdrawal on the liquidity of the base range in the vault. It takes an input parameter assets, which represents the amount of asset tokens to be withdrawn.

      It returns two values:
        - **`adjustedAssets`**: The adjusted amount of asset tokens after considering the impact of the withdrawal on the base range liquidity.
        - **`tokensToTrade`**: The amount of tokens that need to be traded to adjust the liquidity after the withdrawal.
      It internally calls the **`Logic.simulateBeforeWithdraw`** function to calculate these values. The **`Logic.simulateBeforeWithdraw`** function takes the address of the vault (**`address(this)`**) and the total assets in the vault (**`totalAssets()`**) as inputs, along with the **`assets`** parameter, and returns the adjusted amount of assets and the tokens that need to be traded to maintain the liquidity.
    */
    function _simulateBeforeWithdrawRanges(uint256 assets)
        internal
        view
        override
        returns (uint256 adjustedAssets, int256 tokensToTrade)
    {
        return Logic.simulateBeforeWithdraw(address(this), totalAssets(), assets);
    }

    /*
      Calculates the liquidity change parameters needed when depositing or withdrawing assets.

        The function takes the following parameters:
          1. **`uint256 amountBefore`**: This is the amount of asset tokens held in the vault before the deposit or withdrawal.
          2. **`uint256 amountDelta`**: This is the change in the amount of asset tokens resulting from the deposit or withdrawal. It is positive for deposits and negative for withdrawals.
          3. **`bool isWithdraw`**: A boolean flag indicating whether the operation is a withdrawal (true) or a deposit (false).

        The function returns an instance of the **`IClearingHouseStructures.LiquidityChangeParams`** struct, which contains the calculated liquidity change parameters.

        The **`liquidityChangeParam`** returned by the function contains the necessary parameters to update the liquidity range of the vault based on the deposit or withdrawal operation. These parameters are then used to adjust the liquidity of the vault accordingly, ensuring that the strategy maintains its desired liquidity range while performing deposits or withdrawals.

        Here's how the function works:
          1. It calculates the **`liquidityDelta`** as the change in base liquidity resulting from the deposit or withdrawal. The formula used is **`liquidityDelta = baseLiquidity.toInt256().mulDiv(amountDelta, amountBefore).toInt128()`**. This formula calculates the change in liquidity by multiplying the base liquidity of the vault by the ratio of **`amountDelta`** to **`amountBefore`**.
          2. If the operation is a withdrawal (indicated by **`isWithdraw`** being true), the **`liquidityDelta`** is negated to represent a decrease in base liquidity due to the withdrawal.
          3. The function then calls the **`_getLiquidityChangeParams`** function, passing the **`baseTickLower`**, **`baseTickUpper`**, and **`liquidityDelta`** as arguments to obtain the final **`liquidityChangeParam`**.
    */
    /// @notice Get liquidity change params on deposit
    /// @param amountBefore Amount of asset tokens after deposit
    /// @param amountDelta Amount of asset tokens deposited
    /// @param isWithdraw True if withdraw else deposit
    function _getLiquidityChangeParamsAfterDepositWithdraw(
        uint256 amountBefore,
        uint256 amountDelta,
        bool isWithdraw
    ) internal view returns (IClearingHouseStructures.LiquidityChangeParams memory liquidityChangeParam) {
        int128 liquidityDelta = baseLiquidity.toInt256().mulDiv(amountDelta, amountBefore).toInt128();
        if (isWithdraw) liquidityDelta = -liquidityDelta;
        liquidityChangeParam = _getLiquidityChangeParams(baseTickLower, baseTickUpper, liquidityDelta);
    }

    /*
      This internal function returns a **`LiquidityChangeParams`** struct that represents the changes in liquidity for a given range. It is used to create and return a new instance of the **`IClearingHouseStructures.LiquidityChangeParams`** struct, which represents the liquidity change parameters for a given range in the liquidity pool.
        
        The function takes the following parameters:        
          1. **`int24 tickLower`**: The lower tick of the range for which the liquidity change parameters are being created.
          2. **`int24 tickUpper`**: The upper tick of the range for which the liquidity change parameters are being created.
          3. **`int128 liquidityDelta`**: The liquidity delta of the range, representing the change in liquidity for this range.        
        The function returns an instance of the **`IClearingHouseStructures.LiquidityChangeParams`** struct, which contains the provided parameters and some default values for other fields.
        
        Here's what the function does:
          1. It creates a new instance of the **`IClearingHouseStructures.LiquidityChangeParams`** struct and initializes its fields using the provided parameters. The fields initialized are **`tickLower`**, **`tickUpper`**, and **`liquidityDelta`**.
          2. The fields **`feeGrowthGlobal0`**, **`feeGrowthGlobal1`**, **`ticked`**, **`limitOrderType`**, and **`settleProfit`** are initialized with default values.
          3. The initialized **`liquidityChangeParam`** struct is then returned.
        
        The function is a utility function used to conveniently create a new instance of the **`IClearingHouseStructures.LiquidityChangeParams`** struct with the provided parameters and some default values for other fields. The returned **`liquidityChangeParam`** is later used to update the liquidity range of the vault in the **`rageClearingHouse.updateRangeOrder`** function call inside the **`_getLiquidityChangeParamsOnRebalance`** function and other parts of the strategy where liquidity changes need to be applied.
    */
    /// @notice Get liquidity change params struct
    /// @param tickLower Lower tick of range
    /// @param tickUpper Upper tick of range
    /// @param liquidityDelta Liquidity delta of range
    function _getLiquidityChangeParams(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal pure returns (IClearingHouseStructures.LiquidityChangeParams memory liquidityChangeParam) {
        liquidityChangeParam = IClearingHouseStructures.LiquidityChangeParams(
            tickLower,
            tickUpper,
            liquidityDelta,
            0,
            0,
            false,
            IClearingHouseEnums.LimitOrderType.NONE,
            false
        );
    }
}
