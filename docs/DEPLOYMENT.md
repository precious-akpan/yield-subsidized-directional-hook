# Deployment Guide

Production deployment checklist and procedures for the Yield Subsidized Directional Hook.

## Pre-Deployment Checklist

### Code Quality
- [ ] All tests passing (`forge test`)
- [ ] Gas optimization complete
- [ ] Code coverage >95%
- [ ] Static analysis clean (Slither, Mythril)
- [ ] External security audit completed
- [ ] Audit findings remediated and verified

### Dependencies
- [ ] All dependencies pinned to specific versions
- [ ] Dependency licenses reviewed
- [ ] No known vulnerabilities in dependencies
- [ ] Submodules updated to latest stable versions

### Configuration
- [ ] Oracle addresses verified on target network
- [ ] Vault addresses verified and audited
- [ ] Fee parameters reviewed and approved
- [ ] Pause mechanism tested
- [ ] Access control roles documented

### Documentation
- [ ] NatSpec complete for all public functions
- [ ] Integration guide reviewed
- [ ] Architecture documentation updated
- [ ] Deployment scripts tested on testnet

## Testnet Deployment

### 1. Environment Setup

Create `.env` file:

```bash
# Network RPCs
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY

# Private keys (use hardware wallet in production)
DEPLOYER_PRIVATE_KEY=0x...
OWNER_PRIVATE_KEY=0x...

# Contract addresses (testnet)
POOL_MANAGER_ADDRESS=0x...
ORACLE_ADDRESS=0x...
VAULT0_ADDRESS=0x...
VAULT1_ADDRESS=0x...

# Etherscan API keys for verification
ETHERSCAN_API_KEY=...
BASESCAN_API_KEY=...
```

### 2. Deploy Hook

```bash
# Deploy to Sepolia
forge script script/Deploy.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify \
    --slow

# Verify deployment
forge verify-contract \
    $HOOK_ADDRESS \
    src/YieldSubsidizedDirectionalHook.sol:YieldSubsidizedDirectionalHook \
    --chain sepolia \
    --constructor-args $(cast abi-encode "constructor(address)" $POOL_MANAGER_ADDRESS)
```

### 3. Initialize Test Pool

```bash
# Initialize pool with hook
forge script script/InitializePool.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast

# Configure pool parameters
forge script script/Configure.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast
```

### 4. Deploy Automation (Optional)

```bash
# Deploy Reactive Network contracts
forge script script/DeployReactiveAutomation.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify
```

### 5. Testnet Validation

Run integration tests against deployed contracts:

```bash
# Set deployed addresses in test
export HOOK_ADDRESS=0x...
export POOL_ID=0x...

# Run live integration tests
forge test --fork-url $SEPOLIA_RPC_URL --match-contract LiveIntegration -vvv
```

## Mainnet Deployment

### Security Measures

1. **Hardware Wallet**: Use Ledger/Trezor for deployment
2. **Multi-sig**: Transfer ownership to multi-sig immediately after deployment
3. **Timelock**: Consider timelock for critical configuration changes
4. **Emergency Pause**: Test pause mechanism before going live

### Deployment Procedure

#### Step 1: Final Audit Review

- Ensure audit report is finalized
- All critical/high findings must be resolved
- Medium/low findings documented with rationale if not fixed
- Auditor sign-off obtained

#### Step 2: Deploy Infrastructure

```bash
# 1. Deploy hook contract
forge script script/Deploy.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --ledger \
    --sender $DEPLOYER_ADDRESS \
    --broadcast \
    --verify

# 2. Verify on Etherscan
forge verify-contract $HOOK_ADDRESS \
    src/YieldSubsidizedDirectionalHook.sol:YieldSubsidizedDirectionalHook \
    --chain mainnet \
    --constructor-args $(cast abi-encode "constructor(address)" $POOL_MANAGER_ADDRESS)

# 3. Transfer ownership to multi-sig
cast send $HOOK_ADDRESS \
    "transferOwnership(address)" $MULTISIG_ADDRESS \
    --ledger \
    --from $DEPLOYER_ADDRESS
```

#### Step 3: Initialize Pool

```bash
# Initialize pool through PoolManager
cast send $POOL_MANAGER_ADDRESS \
    "initialize((address,address,uint24,int24,address),uint160,bytes)" \
    "($TOKEN0,$TOKEN1,3000,60,$HOOK_ADDRESS)" \
    $SQRT_PRICE_X96 \
    "0x" \
    --ledger \
    --from $DEPLOYER_ADDRESS
```

#### Step 4: Configure Hook (via Multi-sig)

Create Gnosis Safe transaction:

```javascript
// Configure pool
const configTx = {
    to: HOOK_ADDRESS,
    data: hook.interface.encodeFunctionData("configurePool", [
        poolId,
        {
            oracle: ORACLE_ADDRESS,
            vault0: VAULT0_ADDRESS,
            vault1: VAULT1_ADDRESS,
            baseFeeBps: 30,
            maxFeeMultiplier: 30000,
            deviationThresholdBps: 50,
            isPaused: false
        }
    ])
};
```

#### Step 5: Deploy Automation

```bash
# Deploy Reactive Network contracts (if using)
forge script script/DeployReactiveAutomation.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --ledger \
    --sender $DEPLOYER_ADDRESS \
    --broadcast \
    --verify
```

#### Step 6: Monitoring Setup

Deploy monitoring infrastructure:

```bash
# Deploy monitoring subgraph
graph deploy \
    --product hosted-service \
    your-github-username/yield-subsidized-hook

# Set up alerting
# Configure alerts for:
# - Large capital sweeps
# - Oracle price anomalies
# - Vault failures
# - Unusual fee scaling
# - Emergency pause triggers
```

## Post-Deployment

### Immediate Actions

1. **Verify all deployments**
   ```bash
   # Check hook deployment
   cast code $HOOK_ADDRESS | grep -q "0x" && echo "✓ Deployed"
   
   # Verify pool registration
   cast call $HOOK_ADDRESS "isPoolRegistered(bytes32)(bool)" $POOL_ID
   
   # Check configuration
   cast call $HOOK_ADDRESS "getPoolConfig(bytes32)" $POOL_ID
   ```

2. **Test basic operations**
   - Perform small test swap
   - Trigger manual capital sweep with minimal amounts
   - Verify events are emitted correctly

3. **Monitor initial activity**
   - Watch for first hour of operation
   - Monitor gas costs
   - Check oracle price updates
   - Verify vault interactions

### Gradual Rollout

Consider a phased approach:

**Phase 1: Limited Launch (Week 1)**
- Small pool with limited liquidity
- Conservative fee parameters
- Manual keeper monitoring
- Daily reviews

**Phase 2: Expanded Testing (Week 2-4)**
- Increase liquidity caps gradually
- Monitor IL subsidy performance
- Evaluate keeper efficiency
- Adjust parameters if needed

**Phase 3: Full Production (Week 4+)**
- Remove liquidity caps
- Enable automation fully
- Open to general public
- Continue monitoring

## Configuration Management

### Parameter Tuning

Monitor and adjust these parameters based on real data:

```solidity
// Fee scaling parameters
baseFeeBps           // Adjust based on market volatility
maxFeeMultiplier     // Increase if toxic flow persists
deviationThresholdBps // Tune based on oracle accuracy

// Capital sweep parameters (Reactive Network)
sweepThreshold       // Lower for more frequent sweeps
minSweepInterval     // Adjust based on gas costs
```

### Emergency Procedures

#### Pause Hook
```bash
# Emergency pause via multi-sig
cast send $HOOK_ADDRESS "pause(bytes32)" $POOL_ID \
    --ledger --from $MULTISIG_SIGNER
```

#### Withdraw from Vaults
```bash
# Emergency vault withdrawal (owner only)
cast send $HOOK_ADDRESS "emergencyWithdraw(bytes32)" $POOL_ID \
    --ledger --from $MULTISIG_SIGNER
```

## Upgrade Strategy

This hook is immutable by design. For upgrades:

1. **Deploy new version** with improvements
2. **Migrate liquidity** to new hook gradually
3. **Deprecate old hook** after migration complete
4. **Document changes** in migration guide

## Monitoring Dashboard

Key metrics to track:

### Operational Metrics
- Swap volume and count
- Average fee applied (toxic vs benign)
- Capital sweep frequency and amounts
- Vault deposit/withdrawal success rate

### Financial Metrics
- Total yield generated
- Subsidy distributed to LPs
- IL coverage percentage
- Claim token redemption rate

### Security Metrics
- Oracle staleness incidents
- Price deviation alerts
- Vault failure events
- Pause mechanism triggers

### Example Monitoring Query (TheGraph)

```graphql
{
  yieldSubsidizedHook(id: $HOOK_ADDRESS) {
    totalSwaps
    totalVolumeUSD
    totalYieldGenerated
    totalSubsidyDistributed
    activePools {
      id
      token0
      token1
      totalLiquidity
      subsidyPool {
        availableYield0
        availableYield1
      }
    }
  }
}
```

## Rollback Plan

If critical issues are discovered:

1. **Immediate**: Pause affected pools
2. **Within 1 hour**: Assess severity and impact
3. **Within 4 hours**: Deploy fix or rollback plan
4. **Within 24 hours**: Migrate to safe state
5. **Within 1 week**: Post-mortem and lessons learned

## Deployment Costs (Estimated)

| Network | Hook Deployment | Pool Init | Config | Automation | Total |
|---------|----------------|-----------|---------|------------|-------|
| Ethereum Mainnet | ~2-3 ETH | ~0.5 ETH | ~0.2 ETH | ~1 ETH | ~4-5 ETH |
| Base | ~0.002 ETH | ~0.0005 ETH | ~0.0002 ETH | ~0.001 ETH | ~0.004 ETH |
| Arbitrum | ~0.01 ETH | ~0.002 ETH | ~0.001 ETH | ~0.005 ETH | ~0.02 ETH |

*Costs vary with gas prices. Use gas estimation before deployment.*

## Contact

For deployment support:
- **GitHub**: [@precious-akpan](https://github.com/precious-akpan)
- **Security**: security@precious-akpan.dev
- **Emergency**: Use GitHub security advisory for critical issues
