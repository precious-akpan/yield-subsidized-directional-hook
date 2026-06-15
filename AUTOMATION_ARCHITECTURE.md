# Automation Architecture

## Overview

The Yield Subsidized Directional Hook uses a **hybrid on-chain/off-chain architecture** for automated capital sweeps due to LP position data availability limitations in Uniswap v4.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     ORIGIN CHAIN (Ethereum L1)                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐         ┌──────────────────┐             │
│  │  Uniswap v4     │         │  Hook Contract   │             │
│  │  PoolManager    │◄────────│  (YieldSub...)   │             │
│  └────────┬────────┘         └────────┬─────────┘             │
│           │                           │                         │
│           │ ModifyLiquidity           │ IdleCapitalDetected    │
│           │ events                    │ event                  │
│           │                           │                         │
│           ▼                           ▼                         │
│  ┌─────────────────────────────────────────────────┐           │
│  │         Event Logs (Blockchain State)           │           │
│  └─────────────────────────────────────────────────┘           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                           │
                           │ Events indexed
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                    OFF-CHAIN INFRASTRUCTURE                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────┐           │
│  │           The Graph Indexer                     │           │
│  │  - Tracks ModifyLiquidity events                │           │
│  │  - Maintains position registry                  │           │
│  │  - Provides GraphQL API:                        │           │
│  │    * getPoolPositions(poolId)                   │           │
│  │    * getActivePositions(poolId)                 │           │
│  └────────────────────┬────────────────────────────┘           │
│                       │                                         │
│                       │ GraphQL query                           │
│                       │                                         │
│  ┌────────────────────▼────────────────────────────┐           │
│  │           Keeper Service (Node.js/Python)       │           │
│  │  - Monitors IdleCapitalDetected events          │           │
│  │  - Queries indexer for position data            │           │
│  │  - Checks threshold & interval conditions       │           │
│  │  - Calls sweepIdleCapital with positions        │           │
│  └────────────────────┬────────────────────────────┘           │
│                       │                                         │
└───────────────────────┼─────────────────────────────────────────┘
                        │
                        │ sweepIdleCapital(
                        │   poolKey,
                        │   tickLowers,   ◄── From indexer
                        │   tickUppers,   ◄── From indexer
                        │   liquidityAmounts ◄── From indexer
                        │ )
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ORIGIN CHAIN (Ethereum L1)                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────┐           │
│  │           Hook Contract (YieldSub...)           │           │
│  │  1. Validates position data                     │           │
│  │  2. Calculates idle capital                     │           │
│  │  3. Flash accounting (unlock/lock)              │           │
│  │  4. Deposits to external vaults                 │           │
│  │  5. Updates subsidy pool                        │           │
│  └─────────────────────────────────────────────────┘           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### 1. Position Tracking (Continuous)
```
Uniswap v4 Pool
  └─> ModifyLiquidity event
       └─> The Graph Indexer
            └─> Position registry updated
                 ├─> Track tickLower, tickUpper
                 ├─> Track liquidity amounts
                 └─> Index by poolId
```

### 2. Idle Capital Detection (Triggered by LP exit)
```
LP removes liquidity
  └─> Hook.beforeRemoveLiquidity()
       └─> IL subsidy distributed
            └─> IdleCapitalDetected event emitted
                 ├─> poolId (indexed)
                 ├─> idleAmount0
                 ├─> idleAmount1
                 └─> poolKey
```

### 3. Automated Sweep Execution (Event-driven)
```
Keeper Service receives IdleCapitalDetected
  └─> Check threshold: idleAmount >= sweepThreshold?
       ├─> No: Skip sweep
       └─> Yes: Check interval: block.timestamp >= lastSweep + minInterval?
            ├─> No: Skip sweep (too soon)
            └─> Yes: Query indexer for positions
                 └─> Call Hook.sweepIdleCapital(poolKey, positions...)
                      └─> Hook validates and executes sweep
                           ├─> Calculate idle amounts
                           ├─> Flash accounting (unlock)
                           ├─> Take tokens from pool
                           ├─> Deposit to vaults
                           ├─> Update subsidy pool
                           └─> Settle deltas (lock)
```

## Components

### 1. The Graph Subgraph
**Location:** `subgraph/` (to be created in Task 25.1)

**Purpose:** Index and store LP position data off-chain

**Schema:**
```graphql
type Position @entity {
  id: ID!                    # Derived from poolId-owner-tickLower-tickUpper
  poolId: Bytes!             # The pool this position belongs to
  owner: Bytes!              # LP owner address
  tickLower: Int!            # Lower tick boundary
  tickUpper: Int!            # Upper tick boundary
  liquidity: BigInt!         # Liquidity amount (updated on ModifyLiquidity)
  createdAt: BigInt!         # Block timestamp of creation
  updatedAt: BigInt!         # Block timestamp of last update
}

type Pool @entity {
  id: ID!                    # PoolId
  positions: [Position!]!    # All positions in this pool
  totalPositions: Int!       # Count of active positions
}
```

**Key Queries:**
```graphql
# Get all active positions for a pool
query GetPoolPositions($poolId: Bytes!) {
  positions(
    where: { 
      poolId: $poolId, 
      liquidity_gt: 0 
    }
    orderBy: tickLower
  ) {
    tickLower
    tickUpper
    liquidity
    owner
  }
}

# Get positions in specific tick range
query GetPositionsInRange($poolId: Bytes!, $minTick: Int!, $maxTick: Int!) {
  positions(
    where: {
      poolId: $poolId,
      liquidity_gt: 0,
      tickLower_gte: $minTick,
      tickUpper_lte: $maxTick
    }
  ) {
    tickLower
    tickUpper
    liquidity
  }
}
```

### 2. Keeper Service
**Location:** `keeper-service/` (to be created in Task 25.2)

**Purpose:** Automate capital sweeps by monitoring events and calling hook

**Technology:** Node.js with ethers.js or Python with web3.py

**Key Functions:**
```javascript
class IdleCapitalKeeper {
  constructor(config) {
    this.hookContract = new ethers.Contract(config.hookAddress, hookAbi, signer);
    this.graphClient = new GraphQLClient(config.graphEndpoint);
    this.sweepThreshold = config.sweepThreshold;
    this.minInterval = config.minInterval;
  }
  
  // Monitor IdleCapitalDetected events
  async monitorEvents() {
    this.hookContract.on('IdleCapitalDetected', async (poolId, amount0, amount1, poolKey) => {
      await this.handleIdleCapital(poolId, amount0, amount1, poolKey);
    });
  }
  
  // Handle idle capital detection
  async handleIdleCapital(poolId, amount0, amount1, poolKey) {
    // 1. Check threshold
    if (amount0 < this.sweepThreshold && amount1 < this.sweepThreshold) {
      console.log(`Skipping sweep for ${poolId}: below threshold`);
      return;
    }
    
    // 2. Check interval
    const lastSweep = await this.getLastSweepTime(poolId);
    if (Date.now() / 1000 < lastSweep + this.minInterval) {
      console.log(`Skipping sweep for ${poolId}: interval not met`);
      return;
    }
    
    // 3. Query positions from indexer
    const positions = await this.queryPositions(poolId);
    
    // 4. Execute sweep
    try {
      const tx = await this.hookContract.sweepIdleCapital(
        poolKey,
        positions.tickLowers,
        positions.tickUppers,
        positions.liquidityAmounts,
        { gasLimit: 500000 }
      );
      
      await tx.wait();
      console.log(`Successfully swept pool ${poolId}: ${tx.hash}`);
    } catch (error) {
      console.error(`Sweep failed for ${poolId}:`, error);
    }
  }
  
  // Query position data from subgraph
  async queryPositions(poolId) {
    const query = `
      query GetPositions($poolId: Bytes!) {
        positions(where: { poolId: $poolId, liquidity_gt: 0 }) {
          tickLower
          tickUpper
          liquidity
        }
      }
    `;
    
    const data = await this.graphClient.request(query, { poolId });
    
    return {
      tickLowers: data.positions.map(p => p.tickLower),
      tickUppers: data.positions.map(p => p.tickUpper),
      liquidityAmounts: data.positions.map(p => p.liquidity)
    };
  }
}
```

**Configuration:**
```json
{
  "hookAddress": "0x...",
  "graphEndpoint": "https://api.thegraph.com/subgraphs/name/...",
  "rpcUrl": "https://eth-mainnet.g.alchemy.com/v2/...",
  "privateKey": "env:KEEPER_PRIVATE_KEY",
  "sweepThreshold": "1000000000000000000",
  "minInterval": 604800
}
```

### 3. SweeperHelper Contract (Optional)
**Location:** `src/utils/SweeperHelper.sol` (to be created in Task 25.3)

**Purpose:** Simplify manual sweep calls for testing/demos

**Interface:**
```solidity
contract SweeperHelper {
    IYieldSubsidizedDirectionalHook public immutable hook;
    IPoolManager public immutable poolManager;
    
    constructor(address _hook, address _poolManager) {
        hook = IYieldSubsidizedDirectionalHook(_hook);
        poolManager = IPoolManager(_poolManager);
    }
    
    /// @notice Sweep with partial position data (queries liquidity from PoolManager)
    function sweepWithKeys(
        PoolKey calldata key,
        address[] calldata owners,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers
    ) external {
        // Query liquidity amounts for each position
        uint128[] memory liquidityAmounts = new uint128[](owners.length);
        
        for (uint256 i = 0; i < owners.length; i++) {
            Position.State memory pos = poolManager.getPosition(
                key.toId(),
                owners[i],
                tickLowers[i],
                tickUppers[i],
                0 // salt
            );
            liquidityAmounts[i] = pos.liquidity;
        }
        
        // Call hook with complete data
        hook.sweepIdleCapital(key, tickLowers, tickUppers, liquidityAmounts);
    }
    
    /// @notice Preview idle capital without executing sweep
    function previewIdleCapital(
        PoolKey calldata key,
        address[] calldata owners,
        int24[] calldata tickLowers,
        int24[] calldata tickUppers
    ) external view returns (uint256 idleAmount0, uint256 idleAmount1) {
        // Similar to above but calls view function
        uint128[] memory liquidityAmounts = new uint128[](owners.length);
        
        for (uint256 i = 0; i < owners.length; i++) {
            Position.State memory pos = poolManager.getPosition(
                key.toId(),
                owners[i],
                tickLowers[i],
                tickUppers[i],
                0
            );
            liquidityAmounts[i] = pos.liquidity;
        }
        
        return hook.calculateIdleCapital(key, tickLowers, tickUppers, liquidityAmounts);
    }
}
```

## Design Rationale

### Why Hybrid Architecture?

**Problem:** Uniswap v4's PoolManager doesn't expose position enumeration.

**Attempted Solutions:**
1. ❌ **Query PoolManager directly** - No enumeration API available
2. ❌ **Track positions in hook storage** - Too expensive (+40k gas per LP operation)
3. ❌ **Include positions in events** - Still need to get data from somewhere
4. ✅ **Off-chain indexer** - Zero gas overhead, standard DeFi pattern

**Precedents:**
- Aave uses Gelato keepers for liquidations
- Compound uses Chainlink Automation for governance
- Uniswap v3 uses The Graph for position tracking

### Trade-offs

| Aspect | On-Chain Only | Hybrid (This Design) |
|--------|---------------|---------------------|
| **Gas Cost** | +40k per LP op | No overhead |
| **Decentralization** | Fully on-chain | Requires keeper |
| **Latency** | Immediate | Event → Indexer → Keeper (~1-2 blocks) |
| **Complexity** | High (storage mgmt) | Medium (off-chain infra) |
| **Feasibility** | Works but expensive | Standard pattern |

### Why Not Reactive Network?

**Reactive Network** was explored but has limitations:

```
Reactive Network callback can:
✅ Receive events from origin chain
✅ Check threshold/interval conditions
✅ Call origin chain contracts

Reactive Network callback CANNOT:
❌ Query off-chain APIs (like The Graph)
❌ Make arbitrary HTTP requests
❌ Access position data not in event
```

**Solution:** Use Reactive Network as one of multiple trigger sources, but keeper service must query indexer.

## Deployment Guide

### Prerequisites
- Node.js 18+ or Python 3.9+
- The Graph CLI (`npm install -g @graphprotocol/graph-cli`)
- Ethereum node RPC access
- Private key for keeper wallet (funded with ETH for gas)

### Step 1: Deploy Subgraph
```bash
cd subgraph/

# Install dependencies
npm install

# Authenticate with The Graph
graph auth --product hosted-service <ACCESS_TOKEN>

# Generate code from schema
graph codegen

# Build subgraph
graph build

# Deploy to hosted service
graph deploy --product hosted-service <GITHUB_USERNAME>/yield-hook-positions

# Note the endpoint URL
```

### Step 2: Deploy Keeper Service
```bash
cd keeper-service/

# Install dependencies
npm install

# Configure environment
cp .env.example .env
# Edit .env with:
# - HOOK_ADDRESS
# - GRAPH_ENDPOINT
# - RPC_URL
# - KEEPER_PRIVATE_KEY
# - SWEEP_THRESHOLD
# - MIN_INTERVAL

# Start keeper
npm start

# Or run as background service
pm2 start keeper.js --name yield-hook-keeper
```

### Step 3: Monitor and Maintain
```bash
# View keeper logs
pm2 logs yield-hook-keeper

# Check subgraph sync status
curl https://api.thegraph.com/index-node/graphql \
  -d '{ "query": "{ indexingStatuses { synced } }" }'

# Monitor keeper wallet balance
cast balance $KEEPER_ADDRESS --rpc-url $RPC_URL
```

## Future Improvements

### Short-term (3-6 months)
1. **Multiple keepers** - Decentralize via Gelato/Chainlink
2. **Keeper incentives** - Reward keepers for successful sweeps
3. **Fallback keepers** - Backup keeper if primary fails

### Long-term (6-12 months)
1. **Protocol enhancement** - Propose `PoolManager.getPoolPositions()` to Uniswap governance
2. **On-chain fallback** - Implement Solution 3 (position registry) as expensive alternative
3. **Cross-chain expansion** - Support L2s with cheaper position tracking

## Monitoring and Alerts

### Key Metrics
- **Sweep latency**: Time from IdleCapitalDetected to sweep execution
- **Sweep success rate**: Successful sweeps / total sweep attempts
- **Indexer lag**: Subgraph block number vs chain head
- **Keeper balance**: ETH remaining for gas

### Recommended Alerts
```yaml
alerts:
  - name: Keeper Out of Gas
    condition: keeper_balance < 0.1 ETH
    action: Send notification to admin
    
  - name: Indexer Lagging
    condition: indexer_lag > 100 blocks
    action: Restart indexer
    
  - name: Sweep Failed
    condition: sweep_error_count > 3 in 1 hour
    action: Pause keeper, investigate
    
  - name: High Idle Capital
    condition: idle_capital_value > $10k for > 24 hours
    action: Investigate why sweep not triggered
```

## Cost Analysis

### Operating Costs

**Indexer (The Graph Hosted Service):**
- Free tier: Up to 100k queries/day
- Paid tier: ~$200/month for production workloads

**Keeper Service:**
- Server: $5-20/month (DigitalOcean/AWS t2.micro)
- Gas: ~200k gas per sweep × $0.50 = ~$0.10 per sweep
- Estimated: ~4 sweeps/day × 30 days = $12/month in gas

**Total monthly cost: ~$17-232/month**

### Break-even Analysis

**Yield generated per sweep:**
- Average idle capital: 100 ETH
- Vault APY: 5%
- Annual yield: 5 ETH
- Weekly yield: ~0.096 ETH (~$290 at $3000/ETH)

**Sweep cost:**
- Gas: $0.10 per sweep
- Operating: $7/sweep amortized monthly

**Result: Highly profitable** (yield >> costs)

## Security Considerations

### Keeper Security
1. **Private key protection** - Use hardware wallet or KMS
2. **Rate limiting** - Prevent keeper from being drained by malicious events
3. **Gas price limits** - Don't sweep if gas price > threshold
4. **Multi-sig approval** - Require approval for configuration changes

### Indexer Reliability
1. **Multiple indexer endpoints** - Fallback to different Graph node
2. **Cache position data** - Keep recent positions in keeper memory
3. **Verify data** - Compare indexer data with on-chain spot checks

### Smart Contract Safety
1. **Keeper whitelist** - Only allow approved keepers to call sweep (optional)
2. **Emergency pause** - Admin can pause sweeps if keeper compromised
3. **Sweep limits** - Cap max amount per sweep to limit damage

## Conclusion

The hybrid architecture provides a **production-ready automation solution** that:

✅ Works with existing Uniswap v4 architecture  
✅ Minimizes gas costs for LPs  
✅ Uses proven DeFi automation patterns  
✅ Scales efficiently with pool growth  
✅ Can be decentralized further via Gelato/Chainlink

While not fully on-chain, this approach represents the **optimal balance** between decentralization, cost-efficiency, and practicality given current protocol limitations.
