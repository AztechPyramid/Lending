// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {Ownable} from "./dependencies/openzeppelin/contracts/Ownable.sol";
import {IERC20} from "./dependencies/openzeppelin/contracts/IERC20.sol";
import {SafeERC20} from "./dependencies/openzeppelin/contracts/SafeERC20.sol";
import {ReentrancyGuard} from "./dependencies/openzeppelin/contracts/ReentrancyGuard.sol";
import {IPriceOracleGetter} from "./interfaces/IPriceOracleGetter.sol";
import {PercentageMath} from "./protocol/libraries/math/PercentageMath.sol";
import {Initializable} from "./dependencies/openzeppelin/upgradeability/Initializable.sol";

/**
 * @title SimpleLendingPoolStorage
 * @author Custom Implementation
 * @notice Storage contract for SimpleLendingPool to facilitate upgrades
 */
contract SimpleLendingPoolStorage {
    using PercentageMath for uint256;

    // Constants
    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // 1.0
    uint256 public constant LIQUIDATION_CLOSE_FACTOR = 5000; // 50%
    uint256 public constant LIQUIDATION_PENALTY = 1000; // 10% (increased from 5% for better liquidator incentives)
    uint256 public constant INTEREST_RATE_DIVISOR = 10000; // 100% = 10000
    uint256 public constant MAX_BORROW_RATE = 3000; // 30% APY max
    uint256 public constant MAX_RESERVE_FACTOR = 3000; // 30% max
    
    // Dynamic interest rate constants
    uint256 public constant BASE_BORROW_RATE = 100; // 1% base rate
    uint256 public constant SLOPE_1 = 400; // 4% increase per 100% utilization up to optimal
    uint256 public constant SLOPE_2 = 4000; // 40% increase per 100% utilization above optimal
    uint256 public constant OPTIMAL_UTILIZATION_RATE = 8000; // 80% optimal utilization

    // User account data
    struct UserAccount {
        uint256 deposited;     // Total amount of tokens deposited
        uint256 borrowed;      // Total amount of tokens borrowed
        uint256 lastUpdateTimestamp; // Last time the interest was calculated
        bool isCollateral;     // Whether this asset is used as collateral
    }

    // Reserve data
    struct ReserveData {
        uint256 totalDeposits;        // Total deposits of this asset
        uint256 totalBorrows;         // Total borrows of this asset
        uint256 liquidityRate;        // Current liquidity rate (APY for lenders)
        uint256 borrowRate;           // Current borrow rate (APY for borrowers)
        uint256 lastUpdateTimestamp;  // Last time the reserve was updated
        bool isActive;                // Is this reserve active
        uint256 loanToValueRatio;     // The LTV for this asset (in percentage * 100, e.g. 75% = 7500)
        uint256 liquidationThreshold; // The liquidation threshold (in percentage * 100)
        uint256 maxCapacity;          // Maximum deposit capacity
        uint256 reserveFactor;        // Percentage of interest that goes to protocol (e.g. 1000 = 10%)
    }

    // State variables
    mapping(address => ReserveData) public reserves;
    mapping(address => mapping(address => UserAccount)) public userAccounts; // token -> user -> account
    address[] public supportedTokens;
    address public oracle;
    
    // User tracking - list of tokens each user has interacted with
    mapping(address => address[]) public userTokens;
    mapping(address => mapping(address => bool)) internal hasInteracted;
    
    // Fees recipient
    address public feeRecipient;
    
    // Total collected fees per token
    mapping(address => uint256) public collectedFees;
    
    // Emergency flags
    bool public paused;
    mapping(address => bool) public emergencyWithdrawEnabled;
    
    // Validation layer events
    event ValidationSuccess(address indexed token, address indexed user, string action);
    event ValidationWarning(address indexed token, address indexed user, string action, string warning);
    event ValidationFailed(address indexed token, address indexed user, string action, string reason);
    
    // Pozisyon raporlama sonuçlarını daha kolay işlemek için struct
    struct UserPositionSummary {
        uint256 totalCollateralUSD;
        uint256 totalBorrowsUSD;
        uint256 healthFactor;
        uint256 availableBorrowsUSD;
        uint8 riskLevel; // 0: safe, 1: medium risk, 2: high risk, 3: liquidation imminent
    }
    
    // Gap for future variables
    uint256[48] private __gap; // Gap'i 50'den 48'e düşürdük (2 yeni değişken ekledik)
}

/**
 * @title SimpleLendingPool
 * @author Custom Implementation
 * @notice A simple lending pool that allows users to deposit and borrow assets with cross-asset collateral
 */
contract SimpleLendingPool is SimpleLendingPoolStorage, Ownable, ReentrancyGuard, Initializable {
    using SafeERC20 for IERC20;
    using PercentageMath for uint256;

    // Events
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount, address indexed repayer);
    event ReserveActivated(address indexed token);
    event ReserveDeactivated(address indexed token);
    event LiquidationCall(address indexed user, address indexed collateralToken, uint256 collateralAmount, address indexed debtToken, uint256 debtAmount, address liquidator);
    event CollateralEnabled(address indexed user, address indexed token);
    event CollateralDisabled(address indexed user, address indexed token);
    event InterestRateUpdated(address indexed token, uint256 liquidityRate, uint256 borrowRate);
    event HealthFactorChanged(address indexed user, uint256 healthFactorBefore, uint256 healthFactorAfter);
    event FeeCollected(address indexed token, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ReserveFactorUpdated(address indexed token, uint256 oldFactor, uint256 newFactor);
    event MaxCapacityUpdated(address indexed token, uint256 oldCapacity, uint256 newCapacity);
    event EmergencyWithdrawEnabled(address indexed token, bool enabled);
    event EmergencyWithdraw(address indexed user, address indexed token, uint256 amount);

    // Modifiers
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }
    
    modifier validToken(address token) {
        require(reserves[token].isActive, "Token not active");
        _;
    }
    
    modifier onlyEmergencyEnabled(address token) {
        require(emergencyWithdrawEnabled[token] || paused, "Emergency withdraw not enabled");
        _;
    }

    /**
     * @notice Constructor - disables initializer for implementation contract
     */
    constructor() {
        // Bu fonksiyon implementation kontratı için initializer'ları devre dışı bırakır
        // Fakat Hardhat ile test ederken gerekli değil, o yüzden kaldırıyorum
        // _disableInitializers();
    }

    /**
     * @notice Initializer function (replaces constructor for upgradeable contracts)
     * @param _oracle The address of the price oracle
     * @param _feeRecipient The address that receives protocol fees
     */
    function initialize(address _oracle, address _feeRecipient) external initializer {
        require(_oracle != address(0), "Invalid oracle address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        oracle = _oracle;
        feeRecipient = _feeRecipient;
        paused = false;
    }

    /**
     * @notice Updates the fee recipient address
     * @param _feeRecipient The new fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        require(_feeRecipient != address(0), "Invalid fee recipient address");
        address oldRecipient = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(oldRecipient, _feeRecipient);
    }
    
    /**
     * @notice Updates the reserve factor for a token
     * @param token The address of the token
     * @param newReserveFactor The new reserve factor
     */
    function setReserveFactor(address token, uint256 newReserveFactor) external onlyOwner validToken(token) {
        require(newReserveFactor <= MAX_RESERVE_FACTOR, "Reserve factor too high");
        uint256 oldFactor = reserves[token].reserveFactor;
        reserves[token].reserveFactor = newReserveFactor;
        emit ReserveFactorUpdated(token, oldFactor, newReserveFactor);
    }
    
    /**
     * @notice Updates the maximum capacity for a token
     * @param token The address of the token
     * @param maxCapacity The new maximum capacity
     */
    function setMaxCapacity(address token, uint256 maxCapacity) external onlyOwner validToken(token) {
        uint256 oldCapacity = reserves[token].maxCapacity;
        reserves[token].maxCapacity = maxCapacity;
        emit MaxCapacityUpdated(token, oldCapacity, maxCapacity);
    }
    
    /**
     * @notice Enables or disables emergency withdrawals for a token
     * @param token The address of the token
     * @param enabled Whether emergency withdrawals are enabled
     */
    function setEmergencyWithdraw(address token, bool enabled) external onlyOwner validToken(token) {
        emergencyWithdrawEnabled[token] = enabled;
        emit EmergencyWithdrawEnabled(token, enabled);
    }

    /**
     * @notice Adds a new token to the supported tokens list
     * @param token The address of the token
     * @param liquidityRate The initial liquidity rate (APY for lenders)
     * @param borrowRate The initial borrow rate (APY for borrowers)
     * @param loanToValueRatio The loan to value ratio for this asset
     * @param liquidationThreshold The liquidation threshold for this asset
     * @param maxCapacity The maximum capacity for this token
     * @param reserveFactor The reserve factor for this token
     */
    function addSupportedToken(
        address token,
        uint256 liquidityRate,
        uint256 borrowRate,
        uint256 loanToValueRatio,
        uint256 liquidationThreshold,
        uint256 maxCapacity,
        uint256 reserveFactor
    ) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(reserves[token].isActive == false, "Token already supported");
        require(loanToValueRatio <= liquidationThreshold, "LTV must be <= liquidation threshold");
        require(liquidationThreshold <= 10000, "Liquidation threshold too high");
        require(reserveFactor <= MAX_RESERVE_FACTOR, "Reserve factor too high");
        
        // For this particular project, limit LTV to 30% max
        require(loanToValueRatio <= 3000, "LTV cannot exceed 30%");

        reserves[token] = ReserveData({
            totalDeposits: 0,
            totalBorrows: 0,
            liquidityRate: liquidityRate,
            borrowRate: borrowRate,
            lastUpdateTimestamp: block.timestamp,
            isActive: true,
            loanToValueRatio: loanToValueRatio,
            liquidationThreshold: liquidationThreshold,
            maxCapacity: maxCapacity,
            reserveFactor: reserveFactor
        });

        supportedTokens.push(token);
        emit ReserveActivated(token);
    }

    /**
     * @notice Deactivates a token
     * @param token The address of the token
     */
    function deactivateToken(address token) external onlyOwner validToken(token) {
        reserves[token].isActive = false;
        emit ReserveDeactivated(token);
    }

    /**
     * @notice Sets the paused state of the contract
     * @param _paused The new paused state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    /**
     * @notice Deposits tokens into the lending pool
     * @param token The address of the token
     * @param amount The amount to deposit
     * @param useAsCollateral Whether to use this token as collateral
     */
    function deposit(address token, uint256 amount, bool useAsCollateral) external nonReentrant whenNotPaused validToken(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        ReserveData storage reserve = reserves[token];
        
        // Check max capacity
        if (reserve.maxCapacity > 0) {
            require(reserve.totalDeposits + amount <= reserve.maxCapacity, "Deposit would exceed max capacity");
        }

        _updateUserInterest(token, msg.sender);
        _updateReserveInterest(token);
        
        // Track user token interaction
        _trackUserToken(msg.sender, token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        userAccounts[token][msg.sender].deposited += amount;
        userAccounts[token][msg.sender].isCollateral = useAsCollateral;
        reserve.totalDeposits += amount;
        
        // Update interest rates
        _updateInterestRatesOnAction(token);

        emit Deposit(msg.sender, token, amount);
        
        if (useAsCollateral) {
            emit CollateralEnabled(msg.sender, token);
        }
    }
    
    /**
     * @notice Withdraws tokens from the lending pool
     * @param token The address of the token
     * @param amount The amount to withdraw
     */
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused validToken(token) {
        require(amount > 0, "Amount must be greater than 0");

        _updateUserInterest(token, msg.sender);
        _updateReserveInterest(token);

        UserAccount storage account = userAccounts[token][msg.sender];
        require(account.deposited >= amount, "Insufficient balance");

        // Calculate new deposit amount after withdrawal
        uint256 newDeposit = account.deposited - amount;
        
        // Check global health factor after withdrawal if token is used as collateral
        if (account.isCollateral) {
            (uint256 totalCollateralUSD, uint256 totalBorrowsUSD, uint256 healthFactorBefore) = 
                _calculateUserGlobalData(msg.sender, token, newDeposit);
                
            require(totalBorrowsUSD == 0 || healthFactorBefore >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD, 
                "Withdrawal would leave insufficient collateral");
                
            account.deposited = newDeposit;
            reserves[token].totalDeposits -= amount;
            
            (,, uint256 healthFactorAfter) = _calculateUserGlobalData(msg.sender, address(0), 0);
            
            if (healthFactorBefore != healthFactorAfter) {
                emit HealthFactorChanged(msg.sender, healthFactorBefore, healthFactorAfter);
            }
        } else {
            account.deposited = newDeposit;
            reserves[token].totalDeposits -= amount;
        }

        // Update interest rates
        _updateInterestRatesOnAction(token);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @notice Borrows tokens from the lending pool
     * @param token The address of the token
     * @param amount The amount to borrow
     */
    function borrow(address token, uint256 amount) external nonReentrant whenNotPaused validToken(token) {
        require(amount > 0, "Amount must be greater than 0");
        require(reserves[token].totalDeposits - reserves[token].totalBorrows >= amount, 
            "Not enough liquidity");

        _updateUserInterest(token, msg.sender);
        _updateReserveInterest(token);
        
        // Track user token interaction
        _trackUserToken(msg.sender, token);

        UserAccount storage account = userAccounts[token][msg.sender];
        uint256 newBorrowed = account.borrowed + amount;
        
        // Calculate new health factor considering all collateral
        (uint256 totalCollateralUSD, uint256 totalBorrowsUSD, uint256 healthFactorBefore) = 
            _calculateUserGlobalDataWithNewBorrow(msg.sender, token, amount);
            
        require(healthFactorBefore >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD, 
            "Not enough collateral for this borrow");

        account.borrowed = newBorrowed;
        reserves[token].totalBorrows += amount;
        
        // Calculate new health factor
        (,, uint256 healthFactorAfter) = _calculateUserGlobalData(msg.sender, address(0), 0);
        
        if (healthFactorBefore != healthFactorAfter) {
            emit HealthFactorChanged(msg.sender, healthFactorBefore, healthFactorAfter);
        }
        
        // Update interest rates
        _updateInterestRatesOnAction(token);

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @notice Repays a loan
     * @param token The address of the token
     * @param amount The amount to repay
     */
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused validToken(token) {
        require(amount > 0, "Amount must be greater than 0");

        _updateUserInterest(token, msg.sender);
        _updateReserveInterest(token);

        UserAccount storage account = userAccounts[token][msg.sender];
        require(account.borrowed > 0, "No outstanding loan");

        uint256 repayAmount = amount;
        if (repayAmount > account.borrowed) {
            repayAmount = account.borrowed;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);

        account.borrowed -= repayAmount;
        reserves[token].totalBorrows -= repayAmount;

        // Update interest rates
        _updateInterestRatesOnAction(token);

        emit Repay(msg.sender, token, repayAmount, msg.sender);
    }
    
    /**
     * @notice Repays a loan on behalf of another user
     * @param token The address of the token
     * @param onBehalfOf The address of the user to repay for
     * @param amount The amount to repay
     */
    function repayBehalf(address token, address onBehalfOf, uint256 amount) external nonReentrant whenNotPaused validToken(token) {
        require(amount > 0, "Amount must be greater than 0");
        require(onBehalfOf != address(0), "Invalid user address");

        _updateUserInterest(token, onBehalfOf);
        _updateReserveInterest(token);

        UserAccount storage account = userAccounts[token][onBehalfOf];
        require(account.borrowed > 0, "No outstanding loan");

        uint256 repayAmount = amount;
        if (repayAmount > account.borrowed) {
            repayAmount = account.borrowed;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), repayAmount);

        account.borrowed -= repayAmount;
        reserves[token].totalBorrows -= repayAmount;

        // Update interest rates
        _updateInterestRatesOnAction(token);

        emit Repay(onBehalfOf, token, repayAmount, msg.sender);
    }
    
    /**
     * @notice Emergency withdraw when the contract is paused or emergency withdrawals are enabled
     * @param token The address of the token
     */
    function emergencyWithdraw(address token) external nonReentrant onlyEmergencyEnabled(token) {
        UserAccount storage account = userAccounts[token][msg.sender];
        require(account.deposited > 0, "No balance to withdraw");
        
        uint256 amount = account.deposited;
        account.deposited = 0;
        reserves[token].totalDeposits -= amount;
        
        IERC20(token).safeTransfer(msg.sender, amount);
        
        emit EmergencyWithdraw(msg.sender, token, amount);
    }
    
    /**
     * @notice Update interest rates after an action (deposit, withdraw, borrow, repay)
     * @param token The address of the token
     */
    function _updateInterestRatesOnAction(address token) internal {
        ReserveData storage reserve = reserves[token];
        
        // Recalculate interest rates
        (uint256 newLiquidityRate, uint256 newBorrowRate) = _calculateInterestRates(token);
        
        if (reserve.liquidityRate != newLiquidityRate || reserve.borrowRate != newBorrowRate) {
            reserve.liquidityRate = newLiquidityRate;
            reserve.borrowRate = newBorrowRate;
            emit InterestRateUpdated(token, newLiquidityRate, newBorrowRate);
        }
    }

    /**
     * @notice Calculates dynamic interest rates based on utilization rate
     * @param token The address of the token
     * @return liquidityRate The new liquidity rate
     * @return borrowRate The new borrow rate
     */
    function _calculateInterestRates(address token) internal view returns (uint256 liquidityRate, uint256 borrowRate) {
        ReserveData storage reserve = reserves[token];
        
        if (reserve.totalDeposits == 0) {
            return (0, BASE_BORROW_RATE);
        }
        
        uint256 utilizationRate = reserve.totalBorrows * 10000 / reserve.totalDeposits;
        
        if (utilizationRate <= OPTIMAL_UTILIZATION_RATE) {
            borrowRate = BASE_BORROW_RATE + utilizationRate * SLOPE_1 / 10000;
        } else {
            uint256 excessUtilization = utilizationRate - OPTIMAL_UTILIZATION_RATE;
            borrowRate = BASE_BORROW_RATE + 
                        OPTIMAL_UTILIZATION_RATE * SLOPE_1 / 10000 + 
                        excessUtilization * SLOPE_2 / 10000;
        }
        
        // Cap borrow rate
        if (borrowRate > MAX_BORROW_RATE) {
            borrowRate = MAX_BORROW_RATE;
        }
        
        // Calculate liquidity rate based on borrow rate, utilization, and reserve factor
        liquidityRate = borrowRate * utilizationRate / 10000 * (10000 - reserve.reserveFactor) / 10000;
        
        return (liquidityRate, borrowRate);
    }
    
    /**
     * @notice Withdraws collected fees to the fee recipient
     * @param token The address of the token
     */
    function withdrawFees(address token) external onlyOwner validToken(token) {
        uint256 feeAmount = collectedFees[token];
        require(feeAmount > 0, "No fees to withdraw");
        
        collectedFees[token] = 0;
        IERC20(token).safeTransfer(feeRecipient, feeAmount);
        
        emit FeeCollected(token, feeAmount);
    }

    /**
     * @notice Tracks which tokens a user has interacted with
     * @param user The address of the user
     * @param token The address of the token
     */
    function _trackUserToken(address user, address token) internal {
        if (!hasInteracted[user][token]) {
            hasInteracted[user][token] = true;
            userTokens[user].push(token);
        }
    }
    
    /**
     * @notice Calculates user's global collateral and borrowing data
     * @param user The address of the user
     * @param excludeToken Optional token to exclude (for withdrawal calculations)
     * @param newExcludedAmount New amount for the excluded token (for withdrawal calculations)
     * @return totalCollateralUSD Total collateral value in USD
     * @return totalBorrowsUSD Total borrowed value in USD
     * @return healthFactor The user's health factor
     */
    function _calculateUserGlobalData(
        address user, 
        address excludeToken, 
        uint256 newExcludedAmount
    ) internal view returns (
        uint256 totalCollateralUSD, 
        uint256 totalBorrowsUSD, 
        uint256 healthFactor
    ) {
        totalCollateralUSD = 0;
        totalBorrowsUSD = 0;
        uint256 totalWeightedCollateralUSD = 0;
        
        // Loop through all user tokens
        address[] memory tokens = userTokens[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            UserAccount memory account = userAccounts[token][user];
            uint256 tokenPrice = IPriceOracleGetter(oracle).getAssetPrice(token);
            
            // Skip if no activity for this token or invalid price
            if ((account.deposited == 0 && account.borrowed == 0) || tokenPrice == 0) continue;
            
            // Calculate deposit value
            uint256 depositAmount = account.deposited;
            if (token == excludeToken) {
                depositAmount = newExcludedAmount;
            }
            
            if (depositAmount > 0 && account.isCollateral) {
                uint256 depositValueUSD = depositAmount * tokenPrice;
                totalCollateralUSD += depositValueUSD;
                
                // Apply liquidation threshold
                uint256 weightedValueUSD = depositValueUSD.percentMul(reserves[token].liquidationThreshold);
                totalWeightedCollateralUSD += weightedValueUSD;
            }
            
            // Calculate borrow value
            if (account.borrowed > 0) {
                uint256 borrowValueUSD = account.borrowed * tokenPrice;
                totalBorrowsUSD += borrowValueUSD;
            }
        }
        
        // Calculate health factor
        if (totalBorrowsUSD == 0) {
            healthFactor = type(uint256).max; // Infinite health factor if no borrows
        } else {
            healthFactor = (totalWeightedCollateralUSD * 1e18) / totalBorrowsUSD;
        }
        
        return (totalCollateralUSD, totalBorrowsUSD, healthFactor);
    }
    
    /**
     * @notice Calculates user's global data with a new borrow
     * @param user The address of the user
     * @param borrowToken The token to borrow
     * @param borrowAmount The amount to borrow
     * @return totalCollateralUSD Total collateral value in USD
     * @return totalBorrowsUSD Total borrowed value in USD including new borrow
     * @return healthFactor The user's health factor after new borrow
     */
    function _calculateUserGlobalDataWithNewBorrow(
        address user, 
        address borrowToken, 
        uint256 borrowAmount
    ) internal view returns (
        uint256 totalCollateralUSD, 
        uint256 totalBorrowsUSD, 
        uint256 healthFactor
    ) {
        // Get current values
        (totalCollateralUSD, totalBorrowsUSD, ) = _calculateUserGlobalData(user, address(0), 0);
        
        // Add new borrow to total
        uint256 borrowTokenPrice = IPriceOracleGetter(oracle).getAssetPrice(borrowToken);
        require(borrowTokenPrice != 0, "Invalid token price");
        
        uint256 newBorrowValueUSD = borrowAmount * borrowTokenPrice / 1e18;
        totalBorrowsUSD += newBorrowValueUSD;
        
        // Calculate weighted collateral (using liquidation thresholds)
        uint256 totalWeightedCollateralUSD = 0;
        address[] memory tokens = userTokens[user];
        
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            UserAccount memory account = userAccounts[token][user];
            
            if (account.deposited > 0 && account.isCollateral) {
                uint256 tokenPrice = IPriceOracleGetter(oracle).getAssetPrice(token);
                if (tokenPrice == 0) continue;
                
                uint256 depositValueUSD = account.deposited * tokenPrice;
                
                // Apply liquidation threshold
                uint256 weightedValueUSD = depositValueUSD.percentMul(reserves[token].liquidationThreshold);
                totalWeightedCollateralUSD += weightedValueUSD;
            }
        }
        
        // Calculate health factor
        if (totalBorrowsUSD == 0) {
            healthFactor = type(uint256).max; // Infinite health factor if no borrows
        } else {
            healthFactor = (totalWeightedCollateralUSD * 1e18) / totalBorrowsUSD;
        }
        
        return (totalCollateralUSD, totalBorrowsUSD, healthFactor);
    }

    /**
     * @notice Updates the interest for a user's account
     * @param token The address of the token
     * @param user The address of the user
     */
    function _updateUserInterest(address token, address user) internal {
        UserAccount storage account = userAccounts[token][user];
        ReserveData storage reserve = reserves[token];
        
        uint256 timeDelta = block.timestamp - account.lastUpdateTimestamp;
        if (timeDelta > 0) {
            // Update deposit interest
            if (account.deposited > 0) {
                uint256 depositInterest = account.deposited * reserve.liquidityRate * timeDelta / (INTEREST_RATE_DIVISOR * 365 days);
                account.deposited += depositInterest;
                reserve.totalDeposits += depositInterest;
            }
            
            // Update borrow interest
            if (account.borrowed > 0) {
                uint256 borrowInterest = account.borrowed * reserve.borrowRate * timeDelta / (INTEREST_RATE_DIVISOR * 365 days);
                
                // Calculate protocol fee
                uint256 protocolFeeAmount = 0;
                if (reserve.reserveFactor > 0) {
                    protocolFeeAmount = borrowInterest.percentMul(reserve.reserveFactor);
                    collectedFees[token] += protocolFeeAmount;
                }
                
                account.borrowed += borrowInterest;
                reserve.totalBorrows += borrowInterest;
            }
            
            account.lastUpdateTimestamp = block.timestamp;
        }
    }

    /**
     * @notice Updates the interest for a reserve
     * @param token The address of the token
     */
    function _updateReserveInterest(address token) internal {
        ReserveData storage reserve = reserves[token];
        reserve.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Gets the list of supported tokens
     * @return The list of supported tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }
    
    /**
     * @notice Gets the list of tokens a user has interacted with
     * @param user The address of the user
     * @return The list of tokens
     */
    function getUserTokens(address user) external view returns (address[] memory) {
        return userTokens[user];
    }

    /**
     * @notice Gets the account data for a user and specific token
     * @param token The address of the token
     * @param user The address of the user
     * @return deposited The deposited amount
     * @return borrowed The borrowed amount
     * @return isCollateral Whether the token is used as collateral
     */
    function getUserTokenData(address token, address user) 
        external 
        view 
        returns (
            uint256 deposited, 
            uint256 borrowed,
            bool isCollateral
        ) 
    {
        UserAccount storage account = userAccounts[token][user];
        return (account.deposited, account.borrowed, account.isCollateral);
    }
    
    /**
     * @notice Gets the global account data for a user across all tokens
     * @param user The address of the user
     * @return totalCollateralUSD The total collateral value in USD
     * @return totalBorrowsUSD The total borrowed value in USD
     * @return healthFactor The health factor of the position
     */
    function getUserAccountData(address user) 
        external 
        view 
        returns (
            uint256 totalCollateralUSD, 
            uint256 totalBorrowsUSD, 
            uint256 healthFactor
        ) 
    {
        return _calculateUserGlobalData(user, address(0), 0);
    }

    /**
     * @notice Liquidates a user's position
     * @param user The address of the user to liquidate
     * @param debtToken The token the user borrowed
     * @param collateralToken The token to receive as collateral
     * @param debtAmount The amount of debt to cover
     */
    function liquidationCall(
        address user,
        address debtToken,
        address collateralToken,
        uint256 debtAmount
    ) external nonReentrant whenNotPaused {
        require(user != address(0), "Invalid user address");
        require(debtToken != address(0) && collateralToken != address(0), "Invalid token addresses");
        require(debtToken != collateralToken, "Same token not allowed");
        require(debtAmount > 0, "Amount must be greater than 0");
        
        // Check health factor
        (,, uint256 healthFactor) = _calculateUserGlobalData(user, address(0), 0);
        require(healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "User position is healthy");
        
        _liquidatePosition(user, debtToken, collateralToken, debtAmount, healthFactor);
    }
    
    /**
     * @notice Internal function to liquidate a user's position
     * @param user The address of the user to liquidate
     * @param debtToken The token the user borrowed
     * @param collateralToken The token to receive as collateral
     * @param debtAmount The amount of debt to cover
     * @param healthFactorBefore The user's health factor before liquidation
     */
    function _liquidatePosition(
        address user,
        address debtToken,
        address collateralToken,
        uint256 debtAmount,
        uint256 healthFactorBefore
    ) internal {
        // Check if user has debt
        uint256 userDebtBalance = userAccounts[debtToken][user].borrowed;
        require(userDebtBalance > 0, "User has no debt in this token");
        
        // Check if user has collateral
        uint256 userCollateralBalance = userAccounts[collateralToken][user].deposited;
        require(userCollateralBalance > 0, "User has no collateral in this token");
        require(userAccounts[collateralToken][user].isCollateral, "Token not used as collateral");
        
        // Calculate max amount that can be liquidated (50% of user's debt)
        uint256 maxDebtAmount = userDebtBalance.percentMul(LIQUIDATION_CLOSE_FACTOR);
        
        // Get the actual debt amount to be covered
        uint256 actualDebtAmount = debtAmount > maxDebtAmount ? maxDebtAmount : debtAmount;
        
        _executeActualLiquidation(
            user,
            debtToken,
            collateralToken,
            actualDebtAmount,
            userCollateralBalance,
            healthFactorBefore
        );
    }
    
    /**
     * @notice Executes the actual liquidation
     * @param user The address of the user to liquidate
     * @param debtToken The token the user borrowed
     * @param collateralToken The token to receive as collateral
     * @param actualDebtAmount The amount of debt to cover
     * @param userCollateralBalance The user's collateral balance
     * @param healthFactorBefore The user's health factor before liquidation
     */
    function _executeActualLiquidation(
        address user,
        address debtToken,
        address collateralToken,
        uint256 actualDebtAmount,
        uint256 userCollateralBalance,
        uint256 healthFactorBefore
    ) internal {
        // Get token prices
        uint256 debtTokenPrice = IPriceOracleGetter(oracle).getAssetPrice(debtToken);
        uint256 collateralTokenPrice = IPriceOracleGetter(oracle).getAssetPrice(collateralToken);
        require(debtTokenPrice != 0 && collateralTokenPrice != 0, "Invalid token prices");
        
        // Calculate collateral to liquidate (debt amount plus bonus)
        uint256 debtAmountInUSD = actualDebtAmount * debtTokenPrice / 1e18;
        uint256 bonusAmount = debtAmountInUSD.percentMul(LIQUIDATION_PENALTY);
        uint256 totalCollateralAmountInUSD = debtAmountInUSD + bonusAmount;
        
        uint256 maxCollateralToLiquidate = totalCollateralAmountInUSD * 1e18 / collateralTokenPrice;
        
        // Calculate actual collateral to liquidate (capped by user's balance)
        uint256 actualCollateralToLiquidate = maxCollateralToLiquidate > userCollateralBalance ? 
            userCollateralBalance : maxCollateralToLiquidate;
            
        _finalizeLiquidation(
            user,
            debtToken,
            collateralToken,
            actualDebtAmount,
            actualCollateralToLiquidate,
            healthFactorBefore
        );
    }
    
    /**
     * @notice Finalizes the liquidation by transferring tokens
     * @param user The address of the user to liquidate
     * @param debtToken The token the user borrowed
     * @param collateralToken The token to receive as collateral
     * @param actualDebtAmount The amount of debt to cover
     * @param actualCollateralToLiquidate The amount of collateral to liquidate
     * @param healthFactorBefore The user's health factor before liquidation
     */
    function _finalizeLiquidation(
        address user,
        address debtToken,
        address collateralToken,
        uint256 actualDebtAmount,
        uint256 actualCollateralToLiquidate,
        uint256 healthFactorBefore
    ) internal {
        // First, get debt token from liquidator
        IERC20(debtToken).safeTransferFrom(msg.sender, address(this), actualDebtAmount);
        
        // Decrease user's debt
        userAccounts[debtToken][user].borrowed -= actualDebtAmount;
        reserves[debtToken].totalBorrows -= actualDebtAmount;
        
        // Update debt token interest rates
        _updateInterestRatesOnAction(debtToken);
        
        // Update user's collateral
        userAccounts[collateralToken][user].deposited -= actualCollateralToLiquidate;
        reserves[collateralToken].totalDeposits -= actualCollateralToLiquidate;
        
        // Update collateral token interest rates
        _updateInterestRatesOnAction(collateralToken);
        
        // Send collateral to liquidator
        IERC20(collateralToken).safeTransfer(msg.sender, actualCollateralToLiquidate);
        
        // Emit liquidation event
        emit LiquidationCall(
            user, 
            collateralToken, 
            actualCollateralToLiquidate, 
            debtToken, 
            actualDebtAmount, 
            msg.sender
        );
        
        // Emit updated health factor event
        (,, uint256 healthFactorAfter) = _calculateUserGlobalData(user, address(0), 0);
        emit HealthFactorChanged(user, healthFactorBefore, healthFactorAfter);
    }

    /**
     * @notice Checks if a user has enough collateral for their borrowed amount
     * @param token The address of the token
     * @param user The address of the user
     * @param depositAmount The deposit amount to check against
     * @param borrowAmount The borrow amount to check against
     * @return True if the user has enough collateral
     */
    function _hasEnoughCollateral(
        address token, 
        address user, 
        uint256 depositAmount, 
        uint256 borrowAmount
    ) internal view returns (bool) {
        if (borrowAmount == 0) return true;
        
        // Calculate collateral value for this specific token
        uint256 tokenPrice = IPriceOracleGetter(oracle).getAssetPrice(token);
        if (tokenPrice == 0) return false;
        
        uint256 depositValue = depositAmount * tokenPrice;
        uint256 borrowValue = borrowAmount * tokenPrice;
        
        // Check against liquidation threshold for this token
        uint256 maxBorrowValue = depositValue.percentMul(reserves[token].liquidationThreshold);
        return borrowValue <= maxBorrowValue;
    }

    /**
     * @notice Gets the current interest rates for a token
     * @param token The address of the token
     * @return currentLiquidityRate The current liquidity rate
     * @return currentBorrowRate The current borrow rate
     * @return newLiquidityRate The new liquidity rate (based on current utilization)
     * @return newBorrowRate The new borrow rate (based on current utilization)
     */
    function getReserveData(address token)
        external
        view
        returns (
            uint256 currentLiquidityRate,
            uint256 currentBorrowRate,
            uint256 newLiquidityRate,
            uint256 newBorrowRate
        )
    {
        ReserveData storage reserve = reserves[token];
        currentLiquidityRate = reserve.liquidityRate;
        currentBorrowRate = reserve.borrowRate;
        
        (newLiquidityRate, newBorrowRate) = _calculateInterestRates(token);
    }
    
    /**
     * @notice Gets detailed user position report across all tokens
     * @param user The address of the user
     * @return tokens List of tokens the user has interacted with
     * @return depositedAmounts Amount deposited for each token
     * @return borrowedAmounts Amount borrowed for each token
     * @return depositedValuesUSD USD value of deposits for each token
     * @return borrowedValuesUSD USD value of borrows for each token
     * @return isCollateralFlags Whether each token is used as collateral
     * @return ltvsPerToken LTV for each token
     * @return thresholdsPerToken Liquidation threshold for each token
     * @return summary Summarized position data
     */
    function getUserPositionReport(address user) 
        external 
        view 
        returns (
            address[] memory tokens,
            uint256[] memory depositedAmounts,
            uint256[] memory borrowedAmounts,
            uint256[] memory depositedValuesUSD,
            uint256[] memory borrowedValuesUSD,
            bool[] memory isCollateralFlags,
            uint256[] memory ltvsPerToken,
            uint256[] memory thresholdsPerToken,
            UserPositionSummary memory summary
        ) 
    {
        tokens = userTokens[user];
        uint256 tokenCount = tokens.length;
        
        // Başlangıçta tüm dizileri oluştur
        UserTokenData memory tokenData = _getUserTokenData(user, tokens, tokenCount);
        depositedAmounts = tokenData.depositedAmounts;
        borrowedAmounts = tokenData.borrowedAmounts;
        depositedValuesUSD = tokenData.depositedValuesUSD;
        borrowedValuesUSD = tokenData.borrowedValuesUSD;
        isCollateralFlags = tokenData.isCollateralFlags;
        ltvsPerToken = tokenData.ltvsPerToken;
        thresholdsPerToken = tokenData.thresholdsPerToken;
        
        // Özet bilgileri hesapla
        summary = _calculateUserSummary(
            tokenData.totalWeightedCollateralUSD,
            tokenData.totalCollateralUSD,
            tokenData.totalBorrowsUSD,
            tokenData.weightedLtvTotalUSD
        );
        
        return (
            tokens,
            depositedAmounts,
            borrowedAmounts,
            depositedValuesUSD,
            borrowedValuesUSD,
            isCollateralFlags,
            ltvsPerToken,
            thresholdsPerToken,
            summary
        );
    }
    
    // User token data to reduce stack depth
    struct UserTokenData {
        uint256[] depositedAmounts;
        uint256[] borrowedAmounts;
        uint256[] depositedValuesUSD;
        uint256[] borrowedValuesUSD;
        bool[] isCollateralFlags;
        uint256[] ltvsPerToken;
        uint256[] thresholdsPerToken;
        uint256 totalWeightedCollateralUSD;
        uint256 totalCollateralUSD;
        uint256 totalBorrowsUSD;
        uint256 weightedLtvTotalUSD;
    }
    
    /**
     * @notice Helper function to process user token data
     * @param user User address
     * @param tokens User's tokens
     * @param tokenCount Number of tokens
     * @return data All token related arrays and aggregated values
     */
    function _getUserTokenData(
        address user,
        address[] memory tokens,
        uint256 tokenCount
    )
        internal
        view
        returns (UserTokenData memory data)
    {
        data.depositedAmounts = new uint256[](tokenCount);
        data.borrowedAmounts = new uint256[](tokenCount);
        data.depositedValuesUSD = new uint256[](tokenCount);
        data.borrowedValuesUSD = new uint256[](tokenCount);
        data.isCollateralFlags = new bool[](tokenCount);
        data.ltvsPerToken = new uint256[](tokenCount);
        data.thresholdsPerToken = new uint256[](tokenCount);
        
        data.totalWeightedCollateralUSD = 0;
        data.totalCollateralUSD = 0;
        data.totalBorrowsUSD = 0;
        data.weightedLtvTotalUSD = 0;
        
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = tokens[i];
            UserAccount memory account = userAccounts[token][user];
            ReserveData memory reserve = reserves[token];
            
            // Get token price from oracle
            uint256 tokenPrice = IPriceOracleGetter(oracle).getAssetPrice(token);
            if (tokenPrice == 0) continue;
            
            // Store basic data
            data.depositedAmounts[i] = account.deposited;
            data.borrowedAmounts[i] = account.borrowed;
            data.isCollateralFlags[i] = account.isCollateral;
            data.ltvsPerToken[i] = reserve.loanToValueRatio;
            data.thresholdsPerToken[i] = reserve.liquidationThreshold;
            
            // Calculate USD values
            data.depositedValuesUSD[i] = account.deposited * tokenPrice / 1e18;
            data.borrowedValuesUSD[i] = account.borrowed * tokenPrice / 1e18;
            
            // Update totals
            if (account.deposited > 0 && account.isCollateral) {
                data.totalCollateralUSD += data.depositedValuesUSD[i];
                
                // Apply liquidation threshold for health factor
                uint256 weightedValueUSD = data.depositedValuesUSD[i].percentMul(reserve.liquidationThreshold);
                data.totalWeightedCollateralUSD += weightedValueUSD;
                
                // Calculate available borrow capacity
                data.weightedLtvTotalUSD += data.depositedValuesUSD[i].percentMul(reserve.loanToValueRatio);
            }
            
            if (account.borrowed > 0) {
                data.totalBorrowsUSD += data.borrowedValuesUSD[i];
            }
        }
        
        return data;
    }
    
    /**
     * @notice Helper function to calculate user summary
     * @param totalWeightedCollateralUSD Total weighted collateral in USD
     * @param totalCollateralUSD Total collateral in USD
     * @param totalBorrowsUSD Total borrows in USD
     * @param weightedLtvTotalUSD Weighted LTV total in USD
     * @return UserPositionSummary struct with calculated values
     */
    function _calculateUserSummary(
        uint256 totalWeightedCollateralUSD,
        uint256 totalCollateralUSD,
        uint256 totalBorrowsUSD,
        uint256 weightedLtvTotalUSD
    )
        internal
        view
        returns (UserPositionSummary memory)
    {
        // Calculate health factor
        uint256 healthFactor;
        if (totalBorrowsUSD == 0) {
            healthFactor = type(uint256).max; // Infinite health factor if no borrows
        } else {
            healthFactor = (totalWeightedCollateralUSD * 1e18) / totalBorrowsUSD;
        }
        
        // Calculate available borrows
        uint256 availableBorrowsUSD = 0;
        if (totalCollateralUSD > 0) {
            if (weightedLtvTotalUSD > totalBorrowsUSD) {
                availableBorrowsUSD = weightedLtvTotalUSD - totalBorrowsUSD;
            }
        }
        
        // Determine risk level using updated function
        uint8 riskLevel = getRiskLevelFromHealthFactor(healthFactor);
        
        // Create summary
        return UserPositionSummary({
            totalCollateralUSD: totalCollateralUSD,
            totalBorrowsUSD: totalBorrowsUSD,
            healthFactor: healthFactor,
            availableBorrowsUSD: availableBorrowsUSD,
            riskLevel: riskLevel
        });
    }

    /**
     * @notice Gets user liquidation risk information and recommended actions
     * @param user The address of the user
     * @return riskLevel 0: safe, 1: medium risk, 2: high risk, 3: liquidation imminent
     * @return healthFactor The current health factor
     * @return recommendedActions String with recommended actions
     * @return tokensAtRisk Array of tokens that could be liquidated first
     */
    function getUserLiquidationRisk(address user) 
        external 
        view 
        returns (
            uint8 riskLevel,
            uint256 healthFactor,
            string memory recommendedActions,
            address[] memory tokensAtRisk
        ) 
    {
        (,,healthFactor) = _calculateUserGlobalData(user, address(0), 0);
        
        // More conservative risk levels
        if (healthFactor == type(uint256).max || healthFactor >= 2 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
            riskLevel = 0; // Safe
            recommendedActions = "Position is safe. No action needed.";
            tokensAtRisk = new address[](0);
        } else if (healthFactor >= (7 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / 5) { // 1.4x (more conservative)
            riskLevel = 1; // Medium risk
            recommendedActions = "Consider adding more collateral or repaying some debt.";
            tokensAtRisk = _getTokensAtRisk(user, 1);
        } else if (healthFactor >= (6 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / 5) { // 1.2x (more conservative)
            riskLevel = 2; // High risk
            recommendedActions = "Warning: Your position is at risk. Add collateral or repay debt soon.";
            tokensAtRisk = _getTokensAtRisk(user, 2);
        } else {
            riskLevel = 3; // Liquidation imminent
            recommendedActions = "URGENT: Liquidation imminent! Add collateral or repay debt immediately.";
            tokensAtRisk = _getTokensAtRisk(user, 3);
        }
        
        return (riskLevel, healthFactor, recommendedActions, tokensAtRisk);
    }
    
    /**
     * @notice Internal function to find tokens most at risk of liquidation
     * @param user The address of the user
     * @param severity The risk severity level
     * @return Tokens most at risk of liquidation
     */
    function _getTokensAtRisk(address user, uint8 severity) internal view returns (address[] memory) {
        address[] memory userTokensList = userTokens[user];
        address[] memory result = new address[](userTokensList.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < userTokensList.length; i++) {
            address token = userTokensList[i];
            UserAccount memory account = userAccounts[token][user];
            
            // If this token is used as collateral and has a significant value
            if (account.isCollateral && account.deposited > 0) {
                // For higher severity, recommend more tokens to manage
                if (severity == 3 || 
                    (severity == 2 && i < 3) || 
                    (severity == 1 && i < 1)) {
                    result[count++] = token;
                }
            }
            
            // Always include tokens with high borrowing
            if (account.borrowed > 0) {
                // Look for tokens with highest borrowed values relative to their deposited value
                uint256 tokenPrice = IPriceOracleGetter(oracle).getAssetPrice(token);
                if (tokenPrice > 0) {
                    uint256 borrowValueUSD = account.borrowed * tokenPrice / 1e18;
                    uint256 depositValueUSD = account.deposited * tokenPrice / 1e18;
                    
                    // If borrowed value is significant or ratio is high
                    if (borrowValueUSD > 0 && 
                        (severity == 3 || 
                         (severity == 2 && borrowValueUSD > depositValueUSD / 2) ||
                         (severity == 1 && borrowValueUSD > depositValueUSD * 3 / 4))) {
                        
                        // Check if already added
                        bool alreadyAdded = false;
                        for (uint256 j = 0; j < count; j++) {
                            if (result[j] == token) {
                                alreadyAdded = true;
                                break;
                            }
                        }
                        
                        if (!alreadyAdded) {
                            result[count++] = token;
                        }
                    }
                }
            }
        }
        
        // Resize array to actual count
        address[] memory finalResult = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            finalResult[i] = result[i];
        }
        
        return finalResult;
    }
    
    /**
     * @notice Internal function to validate token balances
     * @param token The address of the token
     * @param expectedBalance The expected balance of the token in the contract
     * @return success Whether the validation succeeded
     * @return message A message describing the validation result
     */
    function _validateTokenBalance(address token, uint256 expectedBalance) internal view returns (bool success, string memory message) {
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        
        // Allow a small tolerance for rounding errors (0.1%)
        uint256 tolerance = expectedBalance / 1000;
        
        if (actualBalance + tolerance < expectedBalance) {
            return (false, "Contract balance is less than expected");
        }
        
        // Check if balance is significantly higher than expected (could indicate trapped funds)
        if (actualBalance > expectedBalance + tolerance && actualBalance > expectedBalance * 101 / 100) {
            return (true, "Warning: Contract balance is higher than expected");
        }
        
        return (true, "Balance validation successful");
    }
    
    /**
     * @notice Validates the current state of a specific token
     * @param token The token to validate
     * @return isValid Whether the token state is valid
     * @return validationMessage Validation message
     */
    function validateTokenState(address token) external view returns (bool isValid, string memory validationMessage) {
        if (!reserves[token].isActive) {
            return (false, "Token is not active");
        }
        
        // Expected balance = deposits - borrows + collected fees
        uint256 expectedBalance = reserves[token].totalDeposits - reserves[token].totalBorrows + collectedFees[token];
        
        return _validateTokenBalance(token, expectedBalance);
    }
    
    /**
     * @notice Validates the global state of the protocol
     * @return isValid Whether the protocol state is valid
     * @return validationMessages An array of validation messages
     */
    function validateProtocolState() external view returns (bool isValid, string[] memory validationMessages) {
        string[] memory messages = new string[](supportedTokens.length);
        uint256 messageCount = 0;
        bool allValid = true;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            if (!reserves[token].isActive) continue;
            
            // Expected balance = deposits - borrows + collected fees
            uint256 expectedBalance = reserves[token].totalDeposits - reserves[token].totalBorrows + collectedFees[token];
            (bool valid, string memory message) = _validateTokenBalance(token, expectedBalance);
            
            if (!valid) {
                allValid = false;
            }
            
            messages[messageCount++] = string(abi.encodePacked(
                valid ? "OK: " : "ERROR: ",
                "Token ", _addressToString(token), " - ", message
            ));
        }
        
        // Resize the messages array to actual message count
        string[] memory result = new string[](messageCount);
        for (uint256 i = 0; i < messageCount; i++) {
            result[i] = messages[i];
        }
        
        return (allValid, result);
    }
    
    /**
     * @notice Helper function to convert address to hex string
     * @param addr The address to convert
     * @return The hex string representation
     */
    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory buffer = new bytes(42);
        buffer[0] = '0';
        buffer[1] = 'x';
        
        for (uint256 i = 0; i < 20; i++) {
            uint8 value = uint8(uint160(addr) / (2**(8 * (19 - i))));
            buffer[2 + i * 2] = _toHexChar(value / 16);
            buffer[3 + i * 2] = _toHexChar(value % 16);
        }
        
        return string(buffer);
    }
    
    /**
     * @notice Helper function to convert a byte to its hex character
     * @param value The value to convert (0-15)
     * @return The hex character
     */
    function _toHexChar(uint8 value) internal pure returns (bytes1) {
        if (value < 10) {
            return bytes1(uint8(bytes1('0')) + value);
        } else {
            return bytes1(uint8(bytes1('a')) + value - 10);
        }
    }

    /**
     * @notice Determines risk level based on health factor
     * @param healthFactor The user's health factor
     * @return riskLevel 0: safe, 1: medium risk, 2: high risk, 3: liquidation imminent
     */
    function getRiskLevelFromHealthFactor(uint256 healthFactor) 
        public 
        view 
        returns (uint8 riskLevel) 
    {
        if (healthFactor == type(uint256).max || healthFactor >= 2 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) {
            return 0; // Safe
        } else if (healthFactor >= (7 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / 5) { // 1.4x (more conservative)
            return 1; // Medium risk
        } else if (healthFactor >= (6 * HEALTH_FACTOR_LIQUIDATION_THRESHOLD) / 5) { // 1.2x (more conservative)
            return 2; // High risk
        } else {
            return 3; // Liquidation imminent
        }
    }

    /**
     * @notice Simulates the impact of price changes on a user's position
     * @param user The address of the user
     * @param tokenAddress The address of the token to simulate price change for
     * @param priceChangePercent The percentage of price change (can be negative), scaled by 100 (e.g. -1000 = -10%)
     * @return currentHealthFactor The current health factor
     * @return newHealthFactor The simulated new health factor
     * @return currentRiskLevel The current risk level
     * @return newRiskLevel The simulated new risk level
     */
    function simulatePriceImpact(
        address user,
        address tokenAddress,
        int256 priceChangePercent
    ) 
        external 
        view 
        returns (
            uint256 currentHealthFactor,
            uint256 newHealthFactor,
            uint8 currentRiskLevel,
            uint8 newRiskLevel
        ) 
    {
        // Get current price and health factor
        (,, currentHealthFactor) = _calculateUserGlobalData(user, address(0), 0);
        currentRiskLevel = getRiskLevelFromHealthFactor(currentHealthFactor);
        
        // Get token price
        uint256 currentPrice = IPriceOracleGetter(oracle).getAssetPrice(tokenAddress);
        require(currentPrice > 0, "Invalid token price");
        
        // Calculate new price
        uint256 newPrice;
        if (priceChangePercent >= 0) {
            newPrice = currentPrice + (currentPrice * uint256(priceChangePercent) / 10000);
        } else {
            uint256 absoluteChange = uint256(-priceChangePercent);
            require(absoluteChange <= 10000, "Price change too large");
            newPrice = currentPrice - (currentPrice * absoluteChange / 10000);
        }
        
        // Use helper function to calculate new health factor to avoid stack too deep error
        newHealthFactor = _calculateSimulatedHealthFactor(user, tokenAddress, newPrice);
        
        newRiskLevel = getRiskLevelFromHealthFactor(newHealthFactor);
        
        return (currentHealthFactor, newHealthFactor, currentRiskLevel, newRiskLevel);
    }

    /**
     * @notice Helper function to calculate simulated health factor with a new token price
     * @param user The address of the user
     * @param simulatedToken The token to simulate price change for
     * @param newPrice The new price to use for simulation
     * @return healthFactor The simulated health factor
     */
    function _calculateSimulatedHealthFactor(
        address user,
        address simulatedToken,
        uint256 newPrice
    )
        internal
        view
        returns (uint256 healthFactor)
    {
        uint256 totalCollateralUSD = 0;
        uint256 totalBorrowsUSD = 0;
        uint256 totalWeightedCollateralUSD = 0;
        
        address[] memory tokens = userTokens[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            // Skip if no activity for this token
            if (userAccounts[token][user].deposited == 0 && userAccounts[token][user].borrowed == 0) continue;
            
            // Get token price (use simulated price if this is the target token)
            uint256 tokenPrice = token == simulatedToken ? newPrice : IPriceOracleGetter(oracle).getAssetPrice(token);
            if (tokenPrice == 0) continue;
            
            // Calculate deposit value
            if (userAccounts[token][user].deposited > 0 && userAccounts[token][user].isCollateral) {
                uint256 depositValueUSD = userAccounts[token][user].deposited * tokenPrice;
                totalCollateralUSD += depositValueUSD;
                
                // Apply liquidation threshold
                uint256 weightedValueUSD = depositValueUSD.percentMul(reserves[token].liquidationThreshold);
                totalWeightedCollateralUSD += weightedValueUSD;
            }
            
            // Calculate borrow value
            if (userAccounts[token][user].borrowed > 0) {
                uint256 borrowValueUSD = userAccounts[token][user].borrowed * tokenPrice;
                totalBorrowsUSD += borrowValueUSD;
            }
        }
        
        // Calculate simulated health factor
        if (totalBorrowsUSD == 0) {
            return type(uint256).max; // Infinite health factor if no borrows
        } else {
            return (totalWeightedCollateralUSD * 1e18) / totalBorrowsUSD;
        }
    }
} 