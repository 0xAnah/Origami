pragma solidity 0.8.19;
// SPDX-License-Identifier: AGPL-3.0-or-later
// Origami (investments/lovToken/managers/IOrigamiLovTokenFlashAndBorrowManager.sol)

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOrigamiLovTokenFlashAndBorrowManager } from "contracts/interfaces/investments/lovToken/managers/IOrigamiLovTokenFlashAndBorrowManager.sol";
import { IOrigamiOracle } from "contracts/interfaces/common/oracle/IOrigamiOracle.sol";
import { IOrigamiSwapper } from "contracts/interfaces/common/swappers/IOrigamiSwapper.sol";
import { IOrigamiLovTokenManager } from "contracts/interfaces/investments/lovToken/managers/IOrigamiLovTokenManager.sol";
import { IOrigamiFlashLoanProvider } from "contracts/interfaces/common/flashLoan/IOrigamiFlashLoanProvider.sol";

import { CommonEventsAndErrors } from "contracts/libraries/CommonEventsAndErrors.sol";
import { OrigamiAbstractLovTokenManager } from "contracts/investments/lovToken/managers/OrigamiAbstractLovTokenManager.sol";
import { OrigamiMath } from "contracts/libraries/OrigamiMath.sol";
import { Range } from "contracts/libraries/Range.sol";
import { DynamicFees } from "contracts/libraries/DynamicFees.sol";
import { IOrigamiBorrowAndLend } from "contracts/interfaces/common/borrowAndLend/IOrigamiBorrowAndLend.sol";

/**
 * @title Origami LovToken Flash And Borrow Manager
 * @notice The `reserveToken` is deposited by users and supplied into a money market as collateral
 * Upon a rebalanceDown (to decrease the A/L), `debtToken` is borrowed (via a flashloan), swapped into `reserveToken` and added
 * back in as more collateral.
 * @dev `reserveToken`, `debtToken` must be 18 decimals. If other precision is needed later
 * then this contract can be extended
 */
contract OrigamiLovTokenFlashAndBorrowManager is IOrigamiLovTokenFlashAndBorrowManager, OrigamiAbstractLovTokenManager {
    using SafeERC20 for IERC20;
    using OrigamiMath for uint256;

    /**
     * @notice reserveToken that this lovToken levers up on
     * This is also the asset which users deposit/exit with in this lovToken manager
     */
    IERC20 private immutable _reserveToken;

    /**
     * @notice The asset which lovToken borrows from the money market to increase the A/L ratio
     */
    IERC20 private immutable _debtToken;

    /**
     * @notice The contract responsible for borrow/lend via external markets
     */
    IOrigamiBorrowAndLend public borrowLend;

    /**
     * @notice The Origami flashLoan provider contract, which may be via Aave/Spark/Balancer/etc
     */
    IOrigamiFlashLoanProvider public override flashLoanProvider;

    /**
     * @notice The swapper for `debtToken` <--> `reserveToken`
     */
    IOrigamiSwapper public override swapper;

    /**
     * @notice The oracle to convert `debtToken` <--> `reserveToken`
     */
    IOrigamiOracle public debtTokenToReserveTokenOracle;

    /**
     * @dev Internal struct used to abi.encode params through a flashloan request
     */
    enum RebalanceCallbackType {
        REBALANCE_DOWN,
        REBALANCE_UP
    }

    constructor(
        address _initialOwner,
        address _reserveToken_,
        address _debtToken_,
        address _lovToken,
        address _flashLoanProvider,
        address _borrowLend
    ) payable OrigamiAbstractLovTokenManager(_initialOwner, _lovToken) {    // GAS SAVING
        _reserveToken = IERC20(_reserveToken_);
        _debtToken = IERC20(_debtToken_);
        flashLoanProvider = IOrigamiFlashLoanProvider(_flashLoanProvider);
        borrowLend = IOrigamiBorrowAndLend(_borrowLend);

        // Validate the decimals of the tokens
        {
            uint256 _decimals = IERC20Metadata(_lovToken).decimals();
            if (IERC20Metadata(_reserveToken_).decimals() != _decimals) revert CommonEventsAndErrors.InvalidToken(_reserveToken_);
            if (IERC20Metadata(_debtToken_).decimals() != _decimals) revert CommonEventsAndErrors.InvalidToken(_debtToken_);
        }
    }

    /**
     * @notice Set the swapper responsible for `debtToken` <--> `reserveToken` swaps
     */
    function setSwapper(address _swapper) external override onlyElevatedAccess {
        if (_swapper == address(0)) revert CommonEventsAndErrors.InvalidAddress(_swapper);

        // Update the approval's for both `reserveToken` and `debtToken`
        address _oldSwapper = address(swapper);
        if (_oldSwapper != address(0)) {
            _reserveToken.forceApprove(_oldSwapper, 0);
            _debtToken.forceApprove(_oldSwapper, 0);
        }
        _reserveToken.forceApprove(_swapper, type(uint256).max);
        _debtToken.forceApprove(_swapper, type(uint256).max);

        emit SwapperSet(_swapper);
        swapper = IOrigamiSwapper(_swapper);
    }

    /**
     * @notice Set the `debtToken` <--> `reserveToken` oracle configuration 
     */
    function setOracle(address oracle) external override onlyElevatedAccess {
        if (oracle == address(0)) revert CommonEventsAndErrors.InvalidAddress(address(0));
        debtTokenToReserveTokenOracle = IOrigamiOracle(oracle);
        emit OracleSet(oracle);
    }

    /**
     * @notice Set the Origami flash loan provider
     */
    function setFlashLoanProvider(address provider) external override onlyElevatedAccess {
        if (provider == address(0)) revert CommonEventsAndErrors.InvalidAddress(address(0));
        flashLoanProvider = IOrigamiFlashLoanProvider(provider);
        emit FlashLoanProviderSet(provider);
    }

    /**
     * @notice Set the Origami Borrow/Lend position holder
     */
    function setBorrowLend(address _address) external override onlyElevatedAccess {
        if (_address == address(0)) revert CommonEventsAndErrors.InvalidAddress(address(0));
        borrowLend = IOrigamiBorrowAndLend(_address);
        emit BorrowLendSet(_address);
    }

    /**
     * @notice Increase the A/L by reducing liabilities. Flash loan and repay debt, and withdraw collateral to repay the flash loan
     */
    function rebalanceUp(RebalanceUpParams calldata params) external override onlyElevatedAccess {
        flashLoanProvider.flashLoan(
            _debtToken,
            params.flashLoanAmount, 
            abi.encode(
                RebalanceCallbackType.REBALANCE_UP,
                false,
                abi.encode(params)
            )
        );
    }

    /**
     * @notice Force a rebalanceUp ignoring A/L ceiling/floor
     * @dev Separate function to above to have stricter control on who can force
     */
    function forceRebalanceUp(RebalanceUpParams calldata params) external override onlyElevatedAccess {
        flashLoanProvider.flashLoan(
            _debtToken,
            params.flashLoanAmount, 
            abi.encode(
                RebalanceCallbackType.REBALANCE_UP,
                true,
                abi.encode(params)
            )
        );
    }

    /**
     * @notice Decrease the A/L by increasing liabilities. Flash loan `debtToken` swap to `reserveToken`
     * and add as collateral into a money market. Then borrow `debtToken` to repay the flash loan.
     */
    function rebalanceDown(RebalanceDownParams calldata params) external override onlyElevatedAccess {
        flashLoanProvider.flashLoan(
            _debtToken,
            params.flashLoanAmount, 
            abi.encode(
                RebalanceCallbackType.REBALANCE_DOWN,
                false,
                abi.encode(params)
            )
        );
    }
    
    /**
     * @notice Force a rebalanceDown ignoring A/L ceiling/floor
     * @dev Separate function to above to have stricter control on who can force
     */
    function forceRebalanceDown(RebalanceDownParams calldata params) external override onlyElevatedAccess {
        flashLoanProvider.flashLoan(
            _debtToken,
            params.flashLoanAmount, 
            abi.encode(
                RebalanceCallbackType.REBALANCE_DOWN,
                true,
                abi.encode(params)
            )
        );
    }

    /**
     * @notice Recover accidental donations. `collateralSupplyToken` can only be recovered for amounts greater than the 
     * internally tracked balance.
     * @param token Token to recover
     * @param to Recipient address
     * @param amount Amount to recover
     */
    function recoverToken(address token, address to, uint256 amount) external override onlyElevatedAccess {
        emit CommonEventsAndErrors.TokenRecovered(to, token, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice The total balance of reserve tokens this lovToken holds.
     */
    function reservesBalance() public override(OrigamiAbstractLovTokenManager,IOrigamiLovTokenManager) view returns (uint256) {
        return borrowLend.suppliedBalance();
    }

    /**
     * @notice The underlying token this investment wraps. In this case, it's the `reserveToken`
     */
    function baseToken() external override view returns (address) {
        return address(_reserveToken);
    }

    /**
     * @notice The set of accepted tokens which can be used to invest. 
     * Only the `reserveToken` in this instance
     */
    function acceptedInvestTokens() external override view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(_reserveToken);
    }

    /**
     * @notice The set of accepted tokens which can be used to exit into.
     * Only the `reserveToken` in this instance
     */
    function acceptedExitTokens() external override view returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = address(_reserveToken);
    }

    /**
     * @notice The reserveToken that the lovToken levers up on
     */
    function reserveToken() public override(OrigamiAbstractLovTokenManager,IOrigamiLovTokenManager) view returns (address) {
        return address(_reserveToken);
    }

    /**
     * @notice The asset which lovToken borrows to increase the A/L ratio
     */
    function debtToken() external override view returns (address) {
        return address(_debtToken);
    }

    /**
     * @notice The debt of the lovToken to the money market, converted into the `reserveToken`
     * @dev Use the Oracle `debtPriceType` to value any debt in terms of the reserve token
     */
    function liabilities(IOrigamiOracle.PriceType debtPriceType) public override(OrigamiAbstractLovTokenManager,IOrigamiLovTokenManager) view returns (uint256) {
        // In [debtToken] terms.
        uint256 debt = borrowLend.debtBalance();
        if (debt == 0) return 0;

        // Convert the [debtToken] into the [reserveToken] terms
        return debtTokenToReserveTokenOracle.convertAmount(
            address(_debtToken),
            debt,
            debtPriceType, 
            OrigamiMath.Rounding.ROUND_UP
        );
    }

    /**
     * @notice Invoked from IOrigamiFlashLoanProvider once a flash loan is successfully
     * received, to the msg.sender of `flashLoan()`
     * @param token The ERC20 token which has been borrowed
     * @param amount The amount which has been borrowed
     * @param fee The flashloan fee amount (in the same token)
     * @param params Client specific abi encoded params which are passed through from the original `flashLoan()` call
     */
    function flashLoanCallback(
        IERC20 token,
        uint256 amount,
        uint256 fee,
        bytes calldata params
    ) external override returns (bool) {
        if (msg.sender != address(flashLoanProvider)) revert CommonEventsAndErrors.InvalidAccess();
        if (address(token) != address(_debtToken)) revert CommonEventsAndErrors.InvalidToken(address(token));

        // Decode the type & params and call the relevant callback function.
        // Each function must result in the `amount + fee` sitting in this contract such that it can be
        // transferred back to the flash loan provider.
        (RebalanceCallbackType _rebalanceType, bool force, bytes memory _rebalanceParams) = abi.decode(
            params, 
            (RebalanceCallbackType, bool, bytes)
        );
        
        if (_rebalanceType == RebalanceCallbackType.REBALANCE_DOWN) {
            (RebalanceDownParams memory _rdParams) = abi.decode(_rebalanceParams, (RebalanceDownParams));
            _rebalanceDownFlashLoanCallback(
                amount, 
                fee, 
                _rdParams,
                force
            );
        } else {
            (RebalanceUpParams memory _ruParams) = abi.decode(_rebalanceParams, (RebalanceUpParams));
            _rebalanceUpFlashLoanCallback(
                amount, 
                fee, 
                _ruParams,
                force
            );
        }

        // Transfer the total flashloan amount + fee back to the `flashLoanProvider` for repayment
        _debtToken.safeTransfer(msg.sender, amount+fee);
        return true;
    }

    /**
     * @dev Handle the rebalanceUp once the flash loan amount has been received
     */
    function _rebalanceUpFlashLoanCallback(
        uint256 flashLoanAmount, 
        uint256 fee, 
        RebalanceUpParams memory params, 
        bool force
    ) internal {
        if (flashLoanAmount != params.flashLoanAmount) revert CommonEventsAndErrors.InvalidParam();

        // Get the current A/L to check for oracle prices, and so we can compare that the new A/L is higher after the rebalance
        Cache memory cache = populateCache(IOrigamiOracle.PriceType.SPOT_PRICE);
        uint128 alRatioBefore = _assetToLiabilityRatio(cache);

        uint256 totalDebtRepaid = flashLoanAmount;
        uint256 flashRepayAmount = flashLoanAmount + fee;
        IOrigamiBorrowAndLend _borrowLend = borrowLend;

        // Repay the [debtToken]
        {
            _debtToken.safeTransfer(address(_borrowLend), flashLoanAmount);
            // No need to check the withdrawnAmount returned, the amount passed in can never be type(uint256).max, so this will
            // be the exact `amount`
            (uint256 amountRepaid, /*uint256 withdrawnAmount*/) = _borrowLend.repayAndWithdraw(flashLoanAmount, params.collateralToWithdraw, address(this));

            // Repaying less than what was asked is only allowed in force mode.
            // This will only happen when there is no more debt in the money market, ie we are fully delevered
            if (!force) {
                if (amountRepaid != flashLoanAmount) revert CommonEventsAndErrors.InvalidAmount(address(_debtToken), flashLoanAmount);
            }
        }
        
        // Swap from [reserveToken] to [debtToken]
        // The expected amount of [debtToken] received after swapping from [reserveToken]
        // needs to at least cover the total flash loan amount + fee
        {
            uint256 debtTokenReceived = swapper.execute(_reserveToken, params.collateralToWithdraw, _debtToken, params.swapData);
            if (debtTokenReceived < flashRepayAmount) {
                revert CommonEventsAndErrors.Slippage(flashRepayAmount, debtTokenReceived);
            }
        }

        // If over the threshold, return any surplus [debtToken] from the swap to the borrowLend
        // And pay down residual debt
        {
            uint256 surplusAfterSwap = _debtToken.balanceOf(address(this)) - flashRepayAmount;
            uint256 borrowLendSurplus = _debtToken.balanceOf(address(_borrowLend));
            uint256 totalSurplus = borrowLendSurplus + surplusAfterSwap;
            if (totalSurplus > params.repaySurplusThreshold) {
                if (surplusAfterSwap != 0) {
                    _debtToken.safeTransfer(address(_borrowLend), surplusAfterSwap);
                }
                totalDebtRepaid += _borrowLend.repay(totalSurplus);
            }
        }

        // Validate that the new A/L is still within the `rebalanceALRange` and expected slippage range
        uint128 alRatioAfter = _validateAfterRebalance(
            cache, 
            alRatioBefore, 
            params.minNewAL, 
            params.maxNewAL, 
            AlValidationMode.HIGHER_THAN_BEFORE, 
            force,
            _borrowLend     // GAS SAVING
        );

        emit RebalanceUp(
            flashLoanAmount,
            params.collateralToWithdraw,
            totalDebtRepaid,
            alRatioBefore,
            alRatioAfter,
            force
        );
    }

    /**
     * @dev Handle the rebalanceDown once the flash loan amount has been received
     */
    function _rebalanceDownFlashLoanCallback(
        uint256 flashLoanAmount, 
        uint256 fee, 
        RebalanceDownParams memory params,
        bool force
    ) internal {
        if (flashLoanAmount != params.flashLoanAmount) revert CommonEventsAndErrors.InvalidParam();

        // Get the current A/L to check for oracle prices, and so we can compare that the new A/L is lower after the rebalance
        Cache memory cache = populateCache(IOrigamiOracle.PriceType.SPOT_PRICE);
        uint128 alRatioBefore = _assetToLiabilityRatio(cache);

        // Swap from the `debtToken` to the `reserveToken`, 
        // based on the quotes obtained off chain
        uint256 collateralSupplied = swapper.execute(_debtToken, flashLoanAmount, _reserveToken, params.swapData);
        if (collateralSupplied < params.minExpectedReserveToken) {
            revert CommonEventsAndErrors.Slippage(params.minExpectedReserveToken, collateralSupplied);
        }

        // Supply `reserveToken` into the money market, and borrow `debtToken`
        uint256 borrowAmount = flashLoanAmount + fee;
        IOrigamiBorrowAndLend _borrowLend = borrowLend;     // GAS SAVING: cache state variable read more than once in function
        _reserveToken.safeTransfer(address(_borrowLend), collateralSupplied);
        _borrowLend.supplyAndBorrow(collateralSupplied, borrowAmount, address(this));

        uint128 alRatioAfter = _validateAfterRebalance(
            cache, 
            alRatioBefore, 
            params.minNewAL, 
            params.maxNewAL, 
            AlValidationMode.LOWER_THAN_BEFORE, 
            force,
            _borrowLend     // GAS SAVING
        );

        emit RebalanceDown(
            flashLoanAmount,
            collateralSupplied,
            borrowAmount,
            alRatioBefore,
            alRatioAfter,
            force
        );
    }

    /**
     * @notice The current deposit fee based on market conditions.
     * Deposit fees are applied to the portion of lovToken shares the depositor 
     * would have received. Instead that fee portion isn't minted (benefiting remaining users)
     * @dev represented in basis points
     */
    function _dynamicDepositFeeBps() internal override view returns (uint256) {
        return DynamicFees.dynamicFeeBps(
            DynamicFees.FeeType.DEPOSIT_FEE,
            debtTokenToReserveTokenOracle,
            address(_reserveToken),
            _minDepositFeeBps,
            _feeLeverageFactor
        );
    }

    /**
     * @notice The current exit fee based on market conditions.
     * Exit fees are applied to the lovToken shares the user is exiting. 
     * That portion is burned prior to being redeemed (benefiting remaining users)
     * @dev represented in basis points
     */
    function _dynamicExitFeeBps() internal override view returns (uint256) {
        return DynamicFees.dynamicFeeBps(
            DynamicFees.FeeType.EXIT_FEE,
            debtTokenToReserveTokenOracle,
            address(_reserveToken),
            _minExitFeeBps,
            _feeLeverageFactor
        );
    }

    /**
     * @notice Deposit a number of `fromToken` into the `reserveToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _depositIntoReserves(address fromToken, uint256 fromTokenAmount) internal override returns (uint256 newReservesAmount) {
        if (fromToken == address(_reserveToken)) {
            newReservesAmount = fromTokenAmount;

            // Supply into the money market
            IOrigamiBorrowAndLend _borrowLend = borrowLend;   // GAS SAVING: state variable with multiple reads should be cached in stack variable.
            _reserveToken.safeTransfer(address(_borrowLend), fromTokenAmount);
            _borrowLend.supply(fromTokenAmount);
        } else {
            revert CommonEventsAndErrors.InvalidToken(fromToken);
        }
    }

    /**
     * @notice Calculate the amount of `reserveToken` will be deposited given an amount of `fromToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _previewDepositIntoReserves(address fromToken, uint256 fromTokenAmount) internal override view returns (uint256 newReservesAmount) {
        return fromToken == address(_reserveToken) ? fromTokenAmount : 0;
    }
    
    /**
     * @notice Maximum amount of `fromToken` that can be deposited into the `reserveToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _maxDepositIntoReserves(address fromToken) internal override view returns (uint256 fromTokenAmount) {
        if (fromToken == address(_reserveToken)) {
            (uint256 _supplyCap,, uint256 _available) = borrowLend.availableToSupply();
            return _supplyCap == 0 ? MAX_TOKEN_AMOUNT : _available;
        }

        // Anything else returns 0
    }

    /**
     * @notice Calculate the number of `toToken` required in order to mint a given number of `reserveToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _previewMintReserves(address toToken, uint256 reservesAmount) internal override view returns (uint256 newReservesAmount) {
        return toToken == address(_reserveToken) ? reservesAmount : 0;
    }

    /**
     * @notice Redeem a number of `reserveToken` into `toToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _redeemFromReserves(uint256 reservesAmount, address toToken, address recipient) internal override returns (uint256 toTokenAmount) {
        if (toToken == address(_reserveToken)) {
            toTokenAmount = reservesAmount;
            // No need to check the return amount, the amount passed in can never be type(uint256).max, so this will
            // be the exact `amount`
            borrowLend.withdraw(reservesAmount, recipient);
        } else {
            revert CommonEventsAndErrors.InvalidToken(toToken);
        }
    }

    /**
     * @notice Calculate the number of `toToken` recevied if redeeming a number of `reserveToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _previewRedeemFromReserves(uint256 reservesAmount, address toToken) internal override view returns (uint256 toTokenAmount) {
        return toToken == address(_reserveToken) ? reservesAmount : 0;
    }

    /**
     * @notice Maximum amount of `reserveToken` that can be redeemed to `toToken`
     * This vault only accepts where `fromToken` == `reserveToken`
     */
    function _maxRedeemFromReserves(address toToken) internal override view returns (uint256 reservesAmount) {
        // If the A/L range is invalid, then return 0
        IOrigamiBorrowAndLend _borrowLend = borrowLend;
        if (!_borrowLend.isSafeAlRatio(userALRange.floor)) return 0;

        if (toToken == address(_reserveToken)) {
            // The max number of reserveToken available for redemption is the minimum
            // of our position (the reserves balance) and what's available to withdraw from the money market (the balance
            // of the reserve token within the collateralSupplyToken)
            uint256 _reservesBalance = _borrowLend.suppliedBalance();
            uint256 _availableInAave = _borrowLend.availableToWithdraw();
            reservesAmount = _reservesBalance < _availableInAave ? _reservesBalance : _availableInAave;
        }

        // Anything else returns 0
    }

    /**
     * @notice Calculate the max number of reserves allowed before the user debt ceiling is hit, 
     * taking into consideration any current liabiltiies
     * @dev Use the Oracle `debtPriceType` to value any debt in terms of the reserve token
     */
    function _maxUserReserves(IOrigamiOracle.PriceType debtPriceType) internal override view returns (uint256) {
        // In [debtToken] terms - eg Aave's debtToken variable debt token
        uint256 debt = borrowLend.debtBalance();

        // If no debt, then unlimited reserves can be added
        if (debt == 0) return MAX_TOKEN_AMOUNT;

        // Convert the [debtToken] into the [reserveToken] terms
        // Round down so max available liabilities are always conservatively lower
        // The cross rate oracle price should be rounded down if the numerator, up if the denominator
        uint256 debtInReserveToken = debtTokenToReserveTokenOracle.convertAmount(
            address(_debtToken),
            debt,
            debtPriceType, 
            OrigamiMath.Rounding.ROUND_DOWN
        );

        // Calc how many reserves to hit the user AL ceiling
        // Round down for the remaining reserves capacity
        return debtInReserveToken.mulDiv(
            userALRange.ceiling, 
            PRECISION, 
            OrigamiMath.Rounding.ROUND_DOWN
        );
    }

    function _validateAfterRebalance(
        Cache memory cache, 
        uint128 alRatioBefore, 
        uint128 minNewAL, 
        uint128 maxNewAL,
        AlValidationMode alValidationMode,
        bool force,
        IOrigamiBorrowAndLend _borrowLend   // GAS SAVING
    ) private returns (uint128 alRatioAfter) {
        // Validate that the new A/L is still within the `rebalanceALRange`
        // Need to recalculate both the assets and liabilities in the cache
        cache.assets = _borrowLend.suppliedBalance();   // GAS SAVING
        cache.liabilities = liabilities(IOrigamiOracle.PriceType.SPOT_PRICE);
        alRatioAfter = _assetToLiabilityRatio(cache);

        // Ensure the A/L is within the expected slippage range
        {
            if (alRatioAfter < minNewAL) revert ALTooLow(alRatioBefore, alRatioAfter, minNewAL);
            if (alRatioAfter > maxNewAL) revert ALTooHigh(alRatioBefore, alRatioAfter, maxNewAL);
        }

        if (!force)
            _validateALRatio(rebalanceALRange, alRatioBefore, alRatioAfter, alValidationMode);
    }

    /**
     * @dev Revert if the range is invalid comparing to upstrea Aave/Spark
     */
    function _validateAlRange(Range.Data storage range) internal override view {
        if (!borrowLend.isSafeAlRatio(range.floor)) revert Range.InvalidRange(range.floor, range.ceiling);
    }
}
