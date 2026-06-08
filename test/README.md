# Test Suite Quick Reference

## 🚀 Quick Start

```bash
# Run all tests
forge test

# Run with gas reporting
forge test --gas-report

# Run with detailed output
forge test -vvv

# Run with coverage
forge coverage
```

## 📁 Test Structure

```
test/
├── BaseTest.sol              # Base test utilities
├── mocks/                    # Mock contracts
├── unit/                     # Component tests
├── integration/              # End-to-end flows
└── security/                 # Attack scenarios
```

## 🧪 Test Files Overview

### Unit Tests
| File | Purpose | Requirements |
|------|---------|--------------|
| `AccessControl.t.sol` | Permission & ownership | 2.1-2.8, 22.1-22.8 |
| `PoolRegistration.t.sol` | Pool initialization | 1.1-1.7, 30.1-30.5 |
| `OracleIntegration.t.sol` | Oracle price fetch | 3.1-3.6, 4.1-4.6 |
| `DirectionalFeeScaling.t.sol` | Fee calculation | 5.1-5.7, 6.1-6.9 |
| `CapitalSweep.t.sol` | Capital management | 8.1-8.8, 9.1-9.12 |
| `ILCalculation.t.sol` | IL measurement | 13.1-13.10 |
| `SubsidyDistribution.t.sol` | Yield distribution | 14.1-14.8, 15.1-15.7 |
| `ClaimTokens.t.sol` | ERC-1155 claims | 16.1-16.8, 17.1-17.13 |
| `Configuration.t.sol` | Admin functions | 19.1-19.6, 20.1-20.5 |

### Integration Tests
- `SwapFlow.t.sol` - Complete swap with dynamic fees
- `SweepFlow.t.sol` - Capital sweep lifecycle
- `SubsidyFlow.t.sol` - IL compensation flow
- `ClaimFlow.t.sol` - Claim token lifecycle
- `MultiPool.t.sol` - Multi-pool scenarios

### Security Tests
- `Reentrancy.t.sol` - Reentrancy protection
- `PriceManipulation.t.sol` - Oracle manipulation
- `GasLimits.t.sol` - Gas griefing attacks
- `EdgeCases.t.sol` - Boundary conditions

## 🎯 Running Specific Tests

### By Category
```bash
# Unit tests only
forge test --match-path "test/unit/*"

# Integration tests only
forge test --match-path "test/integration/*"

# Security tests only
forge test --match-path "test/security/*"
```

### By File
```bash
# Specific test file
forge test --match-path test/unit/DirectionalFeeScaling.t.sol

# With verbosity
forge test --match-path test/unit/DirectionalFeeScaling.t.sol -vvv
```

### By Function
```bash
# Specific test function
forge test --match-test test_ClassifyToxicFlow_MovingAway

# Multiple functions (regex)
forge test --match-test "test_Revert.*"
```

### By Requirement
```bash
# Tests for specific requirement
forge test --match-test ".*Req_2_1.*"  # Access control req 2.1
```

## 📊 Coverage Reports

```bash
# Generate coverage report
forge coverage

# Coverage with detailed output
forge coverage --report debug

# Coverage for specific file
forge coverage --match-path test/unit/DirectionalFeeScaling.t.sol
```

## 🐛 Debugging Tests

### Verbose Output Levels
```bash
# -v: Errors only
forge test -v

# -vv: Errors + test names
forge test -vv

# -vvv: Errors + test names + stack traces
forge test -vvv

# -vvvv: Errors + test names + stack traces + console.log
forge test -vvvv

# -vvvvv: Maximum verbosity (includes storage changes)
forge test -vvvvv
```

### Debugging Specific Tests
```bash
# Run single test with max verbosity
forge test --match-test test_SuccessfulCapitalSweep -vvvvv

# With gas reporting
forge test --match-test test_SuccessfulCapitalSweep --gas-report -vvv
```

### Using console.log
```solidity
import "forge-std/console.sol";

function testExample() public {
    console.log("Value:", someValue);
    console.log("Address:", someAddress);
}
```

## ⚡ Performance Testing

### Gas Benchmarks
```bash
# Gas report for all tests
forge test --gas-report

# Gas report for specific file
forge test --match-path test/unit/DirectionalFeeScaling.t.sol --gas-report

# Save gas report to file
forge test --gas-report > gas-report.txt
```

### Gas Snapshots
```bash
# Create gas snapshot
forge snapshot

# Compare with previous snapshot
forge snapshot --diff

# Update snapshot
forge snapshot --check
```

## 🔍 Test Utilities (BaseTest.sol)

### Common Test Addresses
```solidity
address constant ALICE = 0x0000000000000000000000000000000000000001;
address constant BOB = 0x0000000000000000000000000000000000000002;
address constant KEEPER = 0x0000000000000000000000000000000000000003;
address constant ADMIN = 0x0000000000000000000000000000000000000004;
```

### Helper Functions
```solidity
// Create pool key
PoolKey memory key = createPoolKey(token0, token1, 3000, 60, hookAddress);

// Deal tokens
dealTokens(tokenAddress, ALICE, 1000e18);

// Approve tokens
approveTokens(tokenAddress, ALICE, spenderAddress, 1000e18);

// Fast-forward time
warpTime(3600); // 1 hour

// Calculate deviation
uint256 deviationBps = calculateDeviationBps(price1, price2);

// Convert sqrtPriceX96
uint256 price = sqrtPriceX96ToPrice(sqrtPriceX96);
```

## 🎭 Mock Contracts

### MockOracle
```solidity
MockOracle oracle = new MockOracle();

// Set price
oracle.setPrice(token0, token1, 2000e18);

// Set stale price
oracle.setStalePrice(token0, token1, 2000e18, 600); // 10 min old

// Configure to revert
oracle.setShouldRevert(true);

// Simulate gas consumption
oracle.setGasConsumption(100000);
```

### MockERC4626Vault
```solidity
MockERC4626Vault vault = new MockERC4626Vault(tokenAddress);

// Simulate yield
vault.simulateYield(100e18);

// Set yield rate (basis points per second)
vault.setYieldRate(10); // 0.1% per second

// Configure illiquidity
vault.setIsIlliquid(true);

// Configure to revert
vault.setShouldRevertOnWithdraw(true);
```

## ✅ Test Coverage Goals

| Metric | Target |
|--------|--------|
| Line Coverage | >90% |
| Branch Coverage | >85% |
| Function Coverage | >95% |
| Unit Tests | >95% |

## 🔧 Troubleshooting

### Common Issues

**Test fails with "EvmError: Revert"**
```bash
# Run with -vvvv to see full stack trace
forge test --match-test failing_test -vvvv
```

**Gas limit exceeded**
```bash
# Increase gas limit
forge test --gas-limit 30000000
```

**Fork tests failing**
```bash
# Ensure RPC URL is set
export RPC_URL="https://eth-mainnet.alchemyapi.io/v2/YOUR_KEY"
forge test --fork-url $RPC_URL
```

**Coverage report incomplete**
```bash
# Clean and rebuild
forge clean
forge build
forge coverage
```

## 📝 Writing New Tests

### Test Template
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";

contract MyTest is BaseTest {
    // State variables
    
    function setUp() public override {
        super.setUp();
        // Setup code
    }
    
    /// @notice Test description (Req X.Y)
    function test_FeatureName() public {
        // Arrange
        
        // Act
        
        // Assert
    }
    
    /// @notice Test revert scenario (Req X.Y)
    function test_RevertWhen_Condition() public {
        // Setup
        
        // Expect revert
        vm.expectRevert(CustomError.selector);
        
        // Act
        targetContract.functionThatReverts();
    }
}
```

### Best Practices
1. ✅ Use descriptive test names
2. ✅ Reference requirement numbers
3. ✅ Follow Arrange-Act-Assert pattern
4. ✅ Test one thing per test
5. ✅ Use appropriate assertions
6. ✅ Clean up after tests
7. ✅ Document complex scenarios

## 🚨 CI/CD Integration

Tests run automatically on:
- ✅ Every commit (pre-commit hook)
- ✅ Every pull request (GitHub Actions)
- ✅ Before deployment (manual gate)

## 📚 Additional Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Forge Testing Guide](https://book.getfoundry.sh/forge/tests)
- [Cheatcodes Reference](https://book.getfoundry.sh/cheatcodes/)
- [Test Structure Documentation](./TEST_STRUCTURE.md)

---

**Need Help?** Check the [full test structure documentation](./TEST_STRUCTURE.md) or ask the team!
