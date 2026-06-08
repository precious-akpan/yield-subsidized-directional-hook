# Integration Guide

This guide explains how to integrate the Yield Subsidized Directional Hook into your Uniswap v4 pools.

## Prerequisites

- Uniswap v4 deployment (PoolManager, Position Manager)
- External price oracle implementing `IOracle`
- ERC-4626 compatible yield vaults for both pool tokens
- Foundry development environment

## Step 1: Deploy the Hook

### Deploy Hook Contract

```solidity
import {YieldSubsidizedDirectionalHook} from "src/YieldSubsidizedDirectionalHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Deploy hook
IPoolManager poolManager = IPoolManager(POOL_MANAGER_ADDRESS);
YieldSubsidizedDirectionalHook hook = new YieldSubsidizedDirectionalHook(poolManager);

console.log("Hook deployed at:", address(hook));
```

### Verify Hook Address

The hook address must have the correct permissions encoded in its address. Use Uniswap's create2 deployment or mine for a valid address:

```bash
# Mine for hook address with required permissions
forge script script/MineHookAddress.s.sol
```

## Step 2: Initialize Pool with Hook

### Create Pool Key

```solidity
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

PoolKey memory key = PoolKey({
    currency0: Currency.wrap(TOKEN0_ADDRESS),
    currency1: Currency.wrap(TOKEN1_ADDRESS),
    fee: 3000,                              // 0.30% base fee
    tickSpacing: 60,                        // Standard tick spacing
    hooks: IHooks(address(hook))
});
```

### Initialize Pool

```solidity
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Calculate initial sqrt price (1:1 ratio example)
uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);

// Initialize pool
poolManager.initialize(key, sqrtPriceX96, "");
```

## Step 3: Configure Hook for Pool

### Set Pool Configuration

```solidity
import {IOracle} from "src/interfaces/IOracle.sol";
import {IExternalVault} from "src/interfaces/IExternalVault.sol";

// Prepare pool configuration
YieldSubsidizedDirectionalHook.PoolConfig memory config = YieldSubsidizedDirectionalHook.PoolConfig({
    oracle: IOracle(ORACLE_ADDRESS),
    vault0: IExternalVault(VAULT_TOKEN0_ADDRESS),
    vault1: IExternalVault(VAULT_TOKEN1_ADDRESS),
    baseFeeBps: 30,                     // 0.30% baseline fee
    maxFeeMultiplier: 30000,            // 3.0x max (0.90% max fee)
    deviationThresholdBps: 50,          // 0.50% deviation threshold
    isPaused: false
});

// Configure pool
hook.configurePool(poolId, config);
```

### Configuration Parameters Explained

- **oracle**: Must return manipulation-resistant prices (TWAP recommended)
- **vault0/vault1**: Must implement ERC-4626 standard
- **baseFeeBps**: Normal fee when flow is benign (30 = 0.30%)
- **maxFeeMultiplier**: Maximum fee multiplier (30000 = 3.0x of base)
- **deviationThresholdBps**: Price deviation before fee scaling kicks in (50 = 0.50%)

## Step 4: Deploy Automation (Optional)

### Reactive Network Automation

For automated capital sweeps without centralized infrastructure:

```bash
# Deploy Reactive Network contracts
forge script script/DeployReactiveAutomation.s.sol \
    --rpc-url $ORIGIN_RPC \
    --broadcast

# Configure sweep parameters
cast send $CALLBACK_ADDRESS \
    "setSweepThreshold(uint256)" 1000000000000000000 \  # 1 token minimum
    --private-key $PRIVATE_KEY

cast send $CALLBACK_ADDRESS \
    "setMinSweepInterval(uint256)" 3600 \              # 1 hour minimum
    --private-key $PRIVATE_KEY
```

See [REACTIVE_NETWORK_INTEGRATION.md](./REACTIVE_NETWORK_INTEGRATION.md) for detailed setup.

### Manual Keeper Integration

For custom keeper bots:

```solidity
// Monitor for idle capital
(uint256 idle0, uint256 idle1) = hook.calculateIdleCapital(poolKey);

// Trigger sweep when threshold met
if (idle0 > SWEEP_THRESHOLD || idle1 > SWEEP_THRESHOLD) {
    hook.sweepIdleCapital(poolKey);
}
```

## Step 5: Integrate with Frontend

### Query Pool State

```typescript
// Get pool configuration
const config = await hook.getPoolConfig(poolId);

// Get subsidy pool balance (available yield)
const [yield0, yield1] = await hook.getSubsidyPoolBalance(poolId);

// Get LP's claimable subsidy
const claimable = await hook.getLPClaimableSubsidy(lpAddress, poolId);

// Check if pool is paused
const isPaused = config.isPaused;
```

### Monitor Events

```typescript
// Listen for capital sweeps
hook.on("CapitalSwept", (poolId, amount0, amount1, event) => {
    console.log(`Swept ${amount0} token0 and ${amount1} token1`);
});

// Listen for subsidy distributions
hook.on("SubsidyDistributed", (lpAddress, poolId, subsidy0, subsidy1, event) => {
    console.log(`LP ${lpAddress} received subsidy`);
});

// Listen for claim token minting
hook.on("ClaimTokenMinted", (lpAddress, tokenId, amount, event) => {
    console.log(`Claim token ${tokenId} minted for ${lpAddress}`);
});
```

### Handle Claim Tokens

```typescript
// Check LP's claim token balance
const claimTokenId = await hook.generateClaimTokenId(poolId, token0Address);
const balance = await hook.balanceOf(lpAddress, claimTokenId);

if (balance > 0) {
    // Attempt redemption
    await hook.redeemLockedCapital(claimTokenId, balance);
}
```

## Oracle Integration

### Implementing IOracle

Your oracle must implement this interface:

```solidity
interface IOracle {
    function getPrice(address token0, address token1) 
        external 
        view 
        returns (uint256 price, uint256 timestamp);
}
```

### Example: Chainlink Oracle Wrapper

```solidity
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

contract ChainlinkOracleWrapper is IOracle {
    AggregatorV3Interface public immutable priceFeed;
    
    constructor(address _priceFeed) {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
    
    function getPrice(address, address) 
        external 
        view 
        returns (uint256 price, uint256 timestamp) 
    {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = priceFeed.latestRoundData();
        
        require(answer > 0, "Invalid price");
        
        // Convert Chainlink price (8 decimals) to 18 decimals
        price = uint256(answer) * 1e10;
        timestamp = updatedAt;
    }
}
```

### Example: Uniswap V3 TWAP Oracle

```solidity
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IOracle} from "src/interfaces/IOracle.sol";

contract UniswapV3TWAPOracle is IOracle {
    IUniswapV3Pool public immutable pool;
    uint32 public immutable twapInterval;
    
    constructor(address _pool, uint32 _twapInterval) {
        pool = IUniswapV3Pool(_pool);
        twapInterval = _twapInterval;
    }
    
    function getPrice(address, address) 
        external 
        view 
        returns (uint256 price, uint256 timestamp) 
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapInterval;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));
        
        price = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            uint128(1e18),
            pool.token0(),
            pool.token1()
        );
        
        timestamp = block.timestamp;
    }
}
```

## Vault Integration

### Requirements for ERC-4626 Vaults

Vaults must implement these functions:

```solidity
interface IExternalVault {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
```

### Compatible Vault Protocols

- **Yearn Finance**: yVaults (v2/v3)
- **Compound**: cTokens (via wrapper)
- **Aave**: aTokens (via wrapper)
- **Beefy Finance**: Beefy vaults
- **Any ERC-4626 compliant vault**

### Vault Approval

Hook must be approved to spend vault shares:

```solidity
// Vault needs approval from hook address
vault0.approve(address(hook), type(uint256).max);
vault1.approve(address(hook), type(uint256).max);
```

## Security Checklist

Before going live, verify:

- [ ] Hook address has correct permissions
- [ ] Oracle returns manipulation-resistant prices
- [ ] Oracle price staleness threshold is appropriate
- [ ] Vaults are audited and battle-tested
- [ ] Vault.asset() returns correct token addresses
- [ ] Base fee and multiplier are reasonable
- [ ] Deviation threshold prevents excessive fees
- [ ] Emergency pause mechanism is tested
- [ ] Access controls are properly configured
- [ ] All contracts are verified on block explorer

## Testing Integration

### Unit Test Example

```solidity
import {Test} from "forge-std/Test.sol";

contract IntegrationTest is Test {
    YieldSubsidizedDirectionalHook hook;
    IPoolManager poolManager;
    
    function setUp() public {
        // Deploy mock pool manager
        poolManager = new MockPoolManager();
        
        // Deploy hook
        hook = new YieldSubsidizedDirectionalHook(poolManager);
        
        // Initialize pool and configure
        // ...
    }
    
    function testSwapWithFeeScaling() public {
        // Perform swap and verify fee is scaled correctly
    }
    
    function testCapitalSweep() public {
        // Trigger capital sweep and verify vault deposits
    }
    
    function testILSubsidy() public {
        // Remove liquidity and verify subsidy is distributed
    }
}
```

## Troubleshooting

### Common Issues

**Issue**: `PoolNotRegistered` error
- **Solution**: Call `beforeInitialize` during pool initialization

**Issue**: `OraclePriceStale` error
- **Solution**: Check oracle is returning recent timestamps

**Issue**: Vault deposit reverts
- **Solution**: Verify `vault.asset()` matches pool token address

**Issue**: No subsidy distributed
- **Solution**: Check subsidy pool has available yield via `getSubsidyPoolBalance`

**Issue**: Claim tokens not redeemable
- **Solution**: Vault may still be illiquid, wait and retry

## Support

For integration support:
- **GitHub Issues**: [Report issues](https://github.com/precious-akpan/yield-subsidized-directional-hook/issues)
- **Discussions**: [Ask questions](https://github.com/precious-akpan/yield-subsidized-directional-hook/discussions)
- **Security**: security@precious-akpan.dev
