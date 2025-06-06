# SimpleLendingPool and LPBasedOracle

This project includes a customized lending protocol and its associated price oracle running on the Avalanche network. SimpleLendingPool allows users to deposit assets, borrow against them, and use cross-collateral functionality, while LPBasedOracle is designed to fetch token prices from liquidity pools.

## Overview

Key features of the SimpleLendingPool and LPBasedOracle project:

- **Flexible Asset Support**: Any token with a liquidity pool can be added to the protocol
- **Cross-Collateral**: Deposit one token and borrow a different token
- **Dynamic Interest Rates**: Interest rates automatically adjusted based on utilization ratio
- **Liquidator Mechanism**: Liquidate positions with health factor below threshold
- **DEX Integration**: Price discovery from various DEXes including TraderJoe, ArenaSwap, Kyber, Paraswap
- **Crisis Management**: Emergency withdrawal and pause functionality

## Contract Addresses and Links

### Main Contracts (Avalanche Mainnet)

- **SimpleLendingPool**: [`0x72B13072be68B3d529DE120cE7C8C1D0050dEEE7`](https://snowtrace.io/address/0x72B13072be68B3d529DE120cE7C8C1D0050dEEE7)
- **LPBasedOracle**: [`0x688951C143b25A1A66E4a2616399a05d9b123AC8`](https://snowtrace.io/address/0x688951C143b25A1A66E4a2616399a05d9b123AC8)
- **Fee Recipient**: [`0xB799CD1f2ED5dB96ea94EdF367fBA2d90dfd9634`](https://snowtrace.io/address/0xB799CD1f2ED5dB96ea94EdF367fBA2d90dfd9634)

### Supported DEX Routers

- **ArenaSwap Router**: [`0xF56D524D651B90E4B84dc2FffD83079698b9066E`](https://snowtrace.io/address/0xF56D524D651B90E4B84dc2FffD83079698b9066E)
- **Kyber Router**: [`0x6131B5fae19EA4f9D964eAc0408E4408b66337b5`](https://snowtrace.io/address/0x6131B5fae19EA4f9D964eAc0408E4408b66337b5)
- **Paraswap Router**: [`0x6A000F20005980200259B80c5102003040001068`](https://snowtrace.io/address/0x6A000F20005980200259B80c5102003040001068)
- **TraderJoe Router**: [`0x45A62B090DF48243F12A21897e7ed91863E2c86b`](https://snowtrace.io/address/0x45A62B090DF48243F12A21897e7ed91863E2c86b)

### Some Supported Tokens

The protocol currently supports 43 tokens. Some important tokens include:

- **ORDER**: [`0x1BEd077195307229FcCBC719C5f2ce6416A58180`](https://snowtrace.io/address/0x1BEd077195307229FcCBC719C5f2ce6416A58180)
- **ID**: [`0x34a528Da3b2EA5c6Ad1796Eba756445D1299a577`](https://snowtrace.io/address/0x34a528Da3b2EA5c6Ad1796Eba756445D1299a577)
- **ARENA**: [`0xB8d7710f7d8349A506b75dD184F05777c82dAd0C`](https://snowtrace.io/address/0xB8d7710f7d8349A506b75dD184F05777c82dAd0C)

A complete list of supported tokens can be found in the `.env` file.

## SimpleLendingPool Protocol

SimpleLendingPool is a lending protocol designed for users to deposit assets, borrow, and provide liquidity. It provides:

### Key Features

1. **Asset Deposit and Borrowing**:
   - Deposit assets as collateral
   - Borrow against collateral value
   - Repay loans

2. **Dynamic Interest Rates**:
   - Interest rates vary based on pool utilization ratio
   - Optimal utilization rate: 80%
   - Base borrowing rate: 1%
   - Maximum borrowing rate: 30%

3. **Risk Parameters**:
   - Token-based LTV (Loan-to-Value) ratios
   - Liquidation thresholds
   - Health factor monitoring

4. **Cross-Collateral Usage**:
   - Deposit one token and borrow a different token
   - Token-specific risk parameters

5. **Liquidator Mechanism**:
   - Liquidate positions with health factor below 1.0
   - 10% liquidator premium (LIQUIDATION_PENALTY)

### Architecture

SimpleLendingPool is based on a simplified version of Aave V3 and consists of the following components:

- **Pool Contract**: Main contract managing all user interactions
- **Oracle**: Provides asset prices (LPBasedOracle)
- **Interest Rate Strategy**: Dynamic interest rate calculations

### Protocol Constants

```solidity
uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // 1.0
uint256 public constant LIQUIDATION_CLOSE_FACTOR = 5000; // 50%
uint256 public constant LIQUIDATION_PENALTY = 1000; // 10%
uint256 public constant INTEREST_RATE_DIVISOR = 10000; // 100% = 10000
uint256 public constant MAX_BORROW_RATE = 3000; // 30% APY max
uint256 public constant MAX_RESERVE_FACTOR = 3000; // 30% max

// Dynamic interest rate constants
uint256 public constant BASE_BORROW_RATE = 100; // 1% base rate
uint256 public constant SLOPE_1 = 400; // 4% increase / 100% utilization up to optimal
uint256 public constant SLOPE_2 = 4000; // 40% increase / 100% utilization above optimal
uint256 public constant OPTIMAL_UTILIZATION_RATE = 8000; // 80% optimal utilization
```

## LPBasedOracle Mechanism

LPBasedOracle is a price oracle that can fetch token prices from liquidity pools (LPs). This allows any token with a liquid LP to be easily added to the protocol, compared to traditional oracles.

### Working Principle

1. **Direct LP Pricing**:
   - Price is calculated based on reserve ratios in a token's LP with WAVAX or other assets
   - If paired with WAVAX, price is calculated directly
   - If paired with another token, that token's price is obtained first

2. **Pricing via DEX Routers**:
   - When a direct LP is not found, prices are obtained through DEX routers
   - Token is routed through WAVAX to calculate price
   - Multiple routers are tried to find the best price

3. **Base Token**:
   - All pricing is based on WAVAX (Wrapped AVAX)
   - WAVAX address: [`0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7`](https://snowtrace.io/address/0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7)

### Oracle Advantages

1. **Flexibility**: Ability to include tokens not supported by traditional price oracles
2. **Quick Integration**: Rapid addition of new tokens to the protocol
3. **Multi-Source Pricing**: Verification of prices across multiple DEXes and LPs

### Oracle Risks

1. **Manipulation Risk**: Price manipulation risk in LPs with low liquidity
2. **DEX Dependency**: System dependency on healthy DEX infrastructure
3. **Price Deviations**: Price differences across different LPs

## Getting Started

### Local Development Environment

To run this project in your local environment:

```bash
# Clone the repository
git clone <repository-url>

# Navigate to the directory
cd xx1

# Install dependencies
npm install

# Configure the .env file (see example)
cp .env.example .env
```

Edit the `.env` file with the necessary settings:

```
# Private key
PRIVATE_KEY=your_private_key_here

# Avalanche Mainnet RPC URL
AVALANCHE_MAINNET_URL=https://api.avax.network/ext/bc/C/rpc
RPC_URL=https://api.avax.network/ext/bc/C/rpc

# API keys for verification (optional)
SNOWTRACE_API_KEY=your_snowtrace_api_key_here

# Gas settings (optional, can be adjusted)
GAS_PRICE=5000000000
GAS_LIMIT=8000000

# Contract addresses (deployed on Avalanche Mainnet)
# DEX router addresses
ARENA_ROUTER=0xF56D524D651B90E4B84dc2FffD83079698b9066E
KYBER_ROUTER=0x6131B5fae19EA4f9D964eAc0408E4408b66337b5
PARASWAP_ROUTER=0x6A000F20005980200259B80c5102003040001068
JOE_ROUTER=0x45A62B090DF48243F12A21897e7ed91863E2c86b

#LPBasedOracle
LP_BASED_ORACLE=0x688951C143b25A1A66E4a2616399a05d9b123AC8
#Base token address
WAVAX=0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7

# Fee recipient address for ATokens
FEE_RECIPIENT=0xB799CD1f2ED5dB96ea94EdF367fBA2d90dfd9634

# Deployment address
LENDING_POOL_ADDRESS=0x72B13072be68B3d529DE120cE7C8C1D0050dEEE7
```

### Test Scripts

You can use the following scripts to test various features of the protocol:

1. **Basic User Test**:
```bash
node scripts/comprehensive-user-test.js
```

2. **Cross-Collateral Test**:
```bash
node scripts/id-token-cross-test.js
```

3. **Liquidator Bot**:
```bash
node scripts/liquidator-bot.js
```

## Documentation

Detailed documentation for the protocol can be found in the `docs` folder:

1. **[SimpleLendingPool_Tutorial.md](docs/SimpleLendingPool_Tutorial.md)**: Comprehensive guide explaining basic protocol usage
2. **[SimpleLendingPool_LiquidatorGuide.md](docs/SimpleLendingPool_LiquidatorGuide.md)**: Special guide for those who want to work as liquidators
3. **[SimpleLendingPool_API.md](docs/SimpleLendingPool_API.md)**: All API functions, function selector IDs, and examples

## JavaScript/Web3 Integration

You can use the following example to connect to the protocol with JavaScript:

```javascript
const { ethers } = require("ethers");

// Minimal ABI
const lendingPoolABI = [
  "function deposit(address token, uint256 amount, bool useAsCollateral) external",
  "function withdraw(address token, uint256 amount) external",
  "function borrow(address token, uint256 amount) external",
  "function repay(address token, uint256 amount) external",
  "function getUserTokenData(address token, address user) view returns (uint256 deposited, uint256 borrowed, bool isCollateral)"
];

async function connectToProtocol() {
  // Provider setup
  const provider = new ethers.JsonRpcProvider("https://api.avax.network/ext/bc/C/rpc");
  
  // Connect with wallet
  const wallet = new ethers.Wallet("YOUR_PRIVATE_KEY", provider);
  
  // Connect to Lending Pool contract
  const lendingPool = new ethers.Contract(
    "0x72B13072be68B3d529DE120cE7C8C1D0050dEEE7",
    lendingPoolABI,
    wallet
  );
  
  return { provider, wallet, lendingPool };
}
```

## Replit UI/UX Integration

Steps for those who want to develop a UI/UX for this project:

1. Create a new project on Replit
2. Integrate the JavaScript functions and ABIs from this repository into your project
3. Follow the UI/UX guide described in the documentation

### UI/UX Components

For an effective interface, you should include the following components:

- **Asset List**: List and details of supported tokens
- **User Position**: Summary of deposited and borrowed assets
- **Health Factor Indicator**: Visual representation of user's position health
- **Transaction Forms**: Forms for deposit, withdrawal, borrowing, and repayment
- **Cross-Collateral Panel**: Selection of collateral and borrowed assets
- **Liquidator Interface**: Panel showing liquidatable positions

## Security Considerations

Security issues to consider when using this protocol:

1. **LP Price Manipulation**: Risk of price manipulation in pools with low liquidity
2. **Collateral Value Fluctuations**: Sudden value losses in tokens with high volatility
3. **Cross-Collateral Risks**: Risks related to correlation between different tokens
4. **DEX Dependency**: Potential issues in DEX operations

## Contract Owner Functions

Administrative functions that can be performed by the contract owner:

1. **Adding Tokens**: Add new tokens with `addSupportedToken()`
2. **Deactivating Tokens**: Deactivate tokens with `deactivateToken()`
3. **Pausing Protocol**: Pause all operations with `setPaused(true)`
4. **Emergency Withdrawal**: Enable emergency withdrawal with `setEmergencyWithdraw(token, true)`
5. **Setting Reserve Factor**: Adjust protocol income ratio with `setReserveFactor()`
6. **Setting Maximum Capacity**: Set token deposit limit with `setMaxCapacity()`

## Listed Tokens and LP Addresses

The list of tokens supported by the protocol on Avalanche Mainnet and their LP addresses can be found in the `.env` file. The protocol currently supports 43 tokens.

## Contributing

To contribute to the project:

1. Fork this repository
2. Create a new branch for your changes
3. Commit your changes
4. Push your branch
5. Create a Pull Request

## License

This project is licensed under the MIT License. See the LICENSE file for more information.
