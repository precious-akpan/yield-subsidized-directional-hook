# Architecture Overview

## System Design

The Yield Subsidized Directional Hook is built on a modular architecture with clear separation of concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                   Uniswap v4 PoolManager                     │
└────────────────────────┬────────────────────────────────────┘
                         │
                         │ Hook Callbacks
                         │
┌────────────────────────▼────────────────────────────────────┐
│         YieldSubsidizedDirectionalHook (Main Contract)       │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Hook Callback Layer                         │   │
│  │  • beforeInitialize() - Pool registration           │   │
│  │  • beforeSwap() - Directional fee application       │   │
│  │  • beforeRemoveLiquidity() - IL subsidy distribution│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Oracle Integration Layer                    │   │
│  │  • Price fetching with staleness validation         │   │
│  │  • Price comparison (oracle vs pool)                │   │
│  │  • Toxic flow classification                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Fee Scaling Engine                          │   │
│  │  • Flow direction detection                          │   │
│  │  • Linear scaling calculation                        │   │
│  │  • Dynamic fee application                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Capital Management Layer                    │   │
│  │  • Idle capital detection                            │   │
│  │  • Flash accounting (unlock/lock pattern)           │   │
│  │  • Vault deposit/withdrawal                          │   │
│  │  • Yield tracking                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          IL Compensation System                      │   │
│  │  • Position tracking                                 │   │
│  │  • IL calculation (compare hold vs position value)  │   │
│  │  • Subsidy distribution from yield pool             │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          Claim Token System (ERC-1155)               │   │
│  │  • Token ID generation per pool-vault-token          │   │
│  │  • Minting during vault illiquidity                  │   │
│  │  • Redemption when vault recovers                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
└───────────────────────┬───────────────────┬──────────────────┘
                        │                   │
          ┌─────────────▼─────┐   ┌────────▼─────────────┐
          │  External Oracle   │   │  ERC-4626 Vaults     │
          │  (IOracle)         │   │  (IExternalVault)    │
          └────────────────────┘   └──────────────────────┘
```

## Component Interactions

### 1. Swap Flow (Directional Fee Scaling)

```
User Swap Request
    ├─> beforeSwap() callback triggered
    ├─> Fetch oracle price (IOracle.getPrice)
    ├─> Validate price staleness
    ├─> Compare oracle price vs pool price
    ├─> Classify flow direction (toxic/benign)
    ├─> Calculate scaled fee (linear curve)
    └─> Return dynamic fee to PoolManager
```

### 2. Capital Sweep Flow

```
Keeper Trigger (Manual or Reactive Network)
    ├─> sweepIdleCapital(poolKey)
    ├─> Calculate idle out-of-range liquidity
    ├─> PoolManager.unlock() for flash accounting
    │   ├─> lockAcquired() callback
    │   ├─> take(token0, idle0)
    │   ├─> take(token1, idle1)
    │   ├─> vault0.deposit(idle0)
    │   ├─> vault1.deposit(idle1)
    │   ├─> Track vault shares and principal
    │   └─> settle() deltas to zero
    └─> Emit CapitalSwept event
```

### 3. Liquidity Removal Flow (IL Subsidy)

```
LP Removes Liquidity
    ├─> beforeRemoveLiquidity() callback
    ├─> Retrieve LP's initial position data
    ├─> Calculate current position value
    ├─> Calculate hold value (initial amounts at current price)
    ├─> Compute IL = hold_value - position_value
    ├─> Query available yield from subsidy pool
    ├─> Attempt vault withdrawal for subsidy
    │   ├─> Success: Transfer subsidy to LP
    │   └─> Failure: Mint claim token (ERC-1155)
    └─> Update subsidy pool accounting
```

## Data Structures

### PoolConfig
```solidity
struct PoolConfig {
    IOracle oracle;              // External price oracle
    IExternalVault vault0;       // Vault for token0
    IExternalVault vault1;       // Vault for token1
    uint24 baseFeeBps;           // Baseline fee (e.g., 30 = 0.30%)
    uint24 maxFeeMultiplier;     // Max multiplier (e.g., 30000 = 3.0x)
    uint24 deviationThresholdBps;// Deviation threshold (e.g., 50 = 0.50%)
    bool isPaused;               // Emergency pause flag
}
```

### SubsidyPool
```solidity
struct SubsidyPool {
    uint256 totalYield0;         // Accumulated yield in token0
    uint256 totalYield1;         // Accumulated yield in token1
    uint256 totalPrincipal0;     // Principal deposited to vault0
    uint256 totalPrincipal1;     // Principal deposited to vault1
    uint256 vaultShares0;        // Vault shares held for token0
    uint256 vaultShares1;        // Vault shares held for token1
}
```

### LPPosition
```solidity
struct LPPosition {
    uint256 initialAmount0;      // LP's initial token0 amount
    uint256 initialAmount1;      // LP's initial token1 amount
    uint256 initialPrice;        // Price at position creation
    uint256 timestamp;           // Position creation timestamp
}
```

## Security Model

### Access Control
- **Pool Registration**: Only occurs during `beforeInitialize`
- **Callback Validation**: All callbacks verify `msg.sender == address(poolManager)`
- **Pool Existence Check**: Functions check pool is registered before executing
- **Owner Privileges**: Configuration changes restricted to contract owner

### Reentrancy Protection
- All external functions use OpenZeppelin's `nonReentrant` modifier
- Flash accounting prevents recursive calls during unlock
- Vault interactions wrapped in try-catch blocks

### Failure Handling
- **Oracle Failures**: Revert to baseline fee if oracle unavailable
- **Vault Failures**: Mint claim tokens instead of blocking LP withdrawals
- **Price Staleness**: Reject oracle data older than threshold
- **Gas Limits**: External calls have reasonable gas limits

## Gas Optimization Strategies

1. **Storage Access**
   - Batch read related storage variables
   - Cache frequently accessed values in memory
   - Use packed structs where possible

2. **Computation**
   - Pre-compute constants at compile time
   - Use bitwise operations for simple math
   - Avoid redundant calculations

3. **External Calls**
   - Minimize oracle calls (single call per swap)
   - Batch vault operations when possible
   - Use staticcall for view functions

## Integration Points

### With Uniswap v4
- Implements `IHooks` interface
- Registers hook permissions in `getHookPermissions()`
- Uses flash accounting via `unlock()` pattern
- Integrates with `PoolManager` for all operations

### With External Systems
- **Oracles**: Must implement `IOracle` (single `getPrice` function)
- **Vaults**: Must implement `IExternalVault` (ERC-4626 compatible)
- **Keepers**: Permissionless access to `sweepIdleCapital()`

### With Reactive Network
- **ReactiveSubscriber**: Monitors pool events on origin chain
- **ReactiveKeeperCallback**: Evaluates sweep conditions and triggers automation
- **Event-driven**: No polling, pure event-based triggering

## Scalability Considerations

### Multi-Pool Support
- Each pool has independent configuration
- Separate subsidy pools per pool
- No cross-pool dependencies

### State Growth
- Position tracking: O(1) per LP per pool
- Claim tokens: Fungible per pool-vault-token combination
- Subsidy pools: Fixed size per pool

### Throughput
- Swap path adds ~40-50k gas overhead
- Capital sweeps are permissionless and parallel
- No bottlenecks or single points of failure

## Future Enhancements

1. **Advanced Fee Curves**: Exponential, sigmoid, or custom curves
2. **Multi-Oracle Support**: Aggregate prices from multiple sources
3. **Dynamic Thresholds**: Adjust parameters based on market conditions
4. **Cross-Pool Yield**: Share yield across multiple pools
5. **LP NFT Integration**: Support Uniswap v4 position NFTs
