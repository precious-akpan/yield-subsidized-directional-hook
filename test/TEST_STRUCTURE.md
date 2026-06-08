# Test Structure Documentation

## Overview

This document outlines the comprehensive test structure for the Yield Subsidized Directional Hook project. The test suite is organized into unit tests, integration tests, and security tests, providing thorough coverage of all functionality and requirements.

## Test Architecture

```
test/
├── BaseTest.sol                     # Base test contract with common utilities
├── mocks/                           # Mock contracts for testing
│   ├── MockOracle.sol              # Mock price oracle
│   ├── MockERC4626Vault.sol        # Mock ERC-4626 yield vault
│   └── MockERC20.sol               # Mock ERC20 tokens
├── unit/                           # Unit tests (one component at a time)
│   ├── AccessControl.t.sol         # Access control and permissions
│   ├── PoolRegistration.t.sol      # Pool initialization and registry
│   ├── OracleIntegration.t.sol     # Oracle price fetching
│   ├── DirectionalFeeScaling.t.sol # Fee classification and scaling
│   ├── CapitalSweep.t.sol          # Idle capital detection and sweeps
│   ├── ILCalculation.t.sol         # Impermanent loss calculation
│   ├── SubsidyDistribution.t.sol   # IL subsidy distribution
│   ├── ClaimTokens.t.sol           # ERC-1155 claim token system
│   └── Configuration.t.sol         # Administrative functions
├── integration/                    # Integration tests (end-to-end flows)
│   ├── SwapFlow.t.sol             # Complete swap + fee scaling flow
│   ├── SweepFlow.t.sol            # Complete capital sweep flow
│   ├── SubsidyFlow.t.sol          # Complete IL compensation flow
│   ├── ClaimFlow.t.sol            # Complete claim token lifecycle
│   └── MultiPool.t.sol            # Multi-pool scenarios
└── security/                       # Security and edge case tests
    ├── Reentrancy.t.sol           # Reentrancy attack tests
    ├── AccessControl.t.sol        # Security access control tests
    ├── PriceManipulation.t.sol    # Oracle manipulation tests
    ├── GasLimits.t.sol            # Gas limit safety tests
    └── EdgeCases.t.sol            # Boundary conditions

```

## Test Categories

### 1. Unit Tests

Unit tests focus on individual components in isolation using mocks where necessary.

#### AccessControl.t.sol
- **Purpose**: Verify access control modifiers and ownership
- **Requirements**: 2.1-2.8, 22.1-22.8
- **Key Tests**:
  - Callback authorization (onlyPoolManager)
  - Pool registration validation
  - Administrative function access (onlyOwner)
  - Ownership transfer

#### PoolRegistration.t.sol
- **Purpose**: Test pool initialization and registration
- **Requirements**: 1.1-1.7, 30.1-30.5
- **Key Tests**:
  - Hook permissions bitmap
  - Pool registration process
  - Duplicate registration prevention
  - Subsidy pool initialization

#### OracleIntegration.t.sol
- **Purpose**: Test oracle price fetching and validation
- **Requirements**: 3.1-3.6, 4.1-4.6, 28.1-28.5
- **Key Tests**:
  - Price fetch with validation
  - Staleness detection
  - Price caching
  - Failure handling
  - Price conversion utilities

#### DirectionalFeeScaling.t.sol
- **Purpose**: Test swap direction classification and fee calculation
- **Requirements**: 5.1-5.7, 6.1-6.9, 7.1-7.5, 23.1-23.5
- **Key Tests**:
  - Toxic flow classification
  - Benign flow classification
  - Fee multiplier calculation
  - Fee scaling curve
  - Gas efficiency
  - Event emission

#### CapitalSweep.t.sol
- **Purpose**: Test idle capital detection and sweep mechanism
- **Requirements**: 8.1-8.8, 9.1-9.12, 10.1-10.8, 11.1-11.9
- **Key Tests**:
  - Idle capital detection
  - Flash accounting flow
  - Vault deposits
  - Delta settlement
  - Accounting updates
  - Permissionless execution

#### ILCalculation.t.sol
- **Purpose**: Test impermanent loss calculation
- **Requirements**: 13.1-13.10, 31.1-31.5
- **Key Tests**:
  - IL formula accuracy
  - Hold value vs position value
  - Price movement scenarios
  - Zero IL when profitable
  - Position tracking

#### SubsidyDistribution.t.sol
- **Purpose**: Test IL subsidy distribution mechanism
- **Requirements**: 14.1-14.8, 15.1-15.7, 18.1-18.5
- **Key Tests**:
  - Subsidy calculation
  - Vault withdrawals
  - Partial subsidy handling
  - Claim token minting on vault failure
  - Event emission

#### ClaimTokens.t.sol
- **Purpose**: Test ERC-1155 claim token system
- **Requirements**: 16.1-16.8, 17.1-17.13, 36.1-36.5
- **Key Tests**:
  - Token ID generation
  - Minting on vault failure
  - Redemption when liquidity restored
  - Token transfers
  - Metadata tracking

#### Configuration.t.sol
- **Purpose**: Test administrative configuration functions
- **Requirements**: 19.1-19.6, 20.1-20.5, 21.1-21.5, 33.1-33.5
- **Key Tests**:
  - Pool configuration
  - Oracle updates
  - Vault configuration
  - Parameter validation
  - Pause/unpause

### 2. Integration Tests

Integration tests verify complete user workflows end-to-end.

#### SwapFlow.t.sol
- **Purpose**: Complete swap execution with dynamic fee scaling
- **Workflow**:
  1. Deploy hook with oracle and vaults
  2. Initialize pool
  3. Execute toxic swap
  4. Verify dynamic fee applied
  5. Execute benign swap
  6. Verify baseline fee applied

#### SweepFlow.t.sol
- **Purpose**: Complete capital sweep from detection to vault deposit
- **Workflow**:
  1. Create out-of-range LP positions
  2. Keeper detects idle capital
  3. Execute sweep via flash accounting
  4. Verify capital in vaults
  5. Verify accounting updated

#### SubsidyFlow.t.sol
- **Purpose**: Complete IL subsidy flow from yield generation to distribution
- **Workflow**:
  1. LP adds liquidity
  2. Price moves causing IL
  3. Capital swept and yields generated
  4. LP removes liquidity
  5. IL calculated and subsidy distributed
  6. Verify LP compensated

#### ClaimFlow.t.sol
- **Purpose**: Complete claim token lifecycle
- **Workflow**:
  1. LP removes liquidity
  2. Vault is illiquid
  3. Claim token minted
  4. Vault liquidity restored
  5. LP redeems claim token
  6. Verify capital recovered

#### MultiPool.t.sol
- **Purpose**: Multi-pool scenarios with isolated accounting
- **Tests**:
  - Multiple pools with different configurations
  - Isolated subsidy pools
  - Cross-pool operations don't interfere
  - Separate oracle and vault per pool

### 3. Security Tests

Security tests focus on attack vectors and edge cases.

#### Reentrancy.t.sol
- **Purpose**: Test reentrancy protection
- **Requirements**: 26.1-26.5
- **Attack Scenarios**:
  - Reentrancy via vault callbacks
  - Reentrancy via oracle callbacks
  - Reentrancy on sweepIdleCapital
  - Reentrancy on redeemLockedCapital

#### AccessControl.t.sol (Security)
- **Purpose**: Advanced access control attack scenarios
- **Attack Scenarios**:
  - Callback spoofing attempts
  - Fake pool callbacks
  - Unauthorized admin calls
  - Ownership takeover attempts

#### PriceManipulation.t.sol
- **Purpose**: Test oracle manipulation resistance
- **Requirements**: 28.1-28.5
- **Attack Scenarios**:
  - Flash loan price manipulation
  - Stale oracle exploitation
  - Extreme price deviation
  - Oracle failure exploitation

#### GasLimits.t.sol
- **Purpose**: Test gas limit safety
- **Requirements**: 29.1-29.5
- **Attack Scenarios**:
  - Malicious oracle gas consumption
  - Malicious vault gas consumption
  - Out-of-gas scenarios
  - Graceful degradation

#### EdgeCases.t.sol
- **Purpose**: Boundary conditions and edge cases
- **Test Scenarios**:
  - Zero amounts
  - Maximum uint256 values
  - Extreme price ratios
  - Empty pools
  - Precision loss scenarios

## Mock Contracts

### MockOracle.sol
Simulates price oracle behavior with configurable:
- Price values and timestamps
- Staleness (old timestamps)
- Revert behavior
- Gas consumption

### MockERC4626Vault.sol
Simulates ERC-4626 yield vault with:
- Deposit/withdraw operations
- Yield generation simulation
- Illiquidity simulation
- Revert configuration

### MockERC20.sol
Simple ERC20 implementation for token testing.

## Test Utilities (BaseTest.sol)

### Common Setup
- Test addresses (ALICE, BOB, KEEPER, ADMIN)
- Standard price values (SQRT_PRICE_1_1, etc.)
- Address labeling for better traces

### Helper Functions
- `createPoolKey()` - Create test PoolKey structs
- `dealTokens()` - Deal tokens to addresses
- `approveTokens()` - Approve token spending
- `warpTime()` - Fast-forward time
- `calculateDeviationBps()` - Calculate price deviation
- `sqrtPriceX96ToPrice()` - Price conversion
- `expectCustomError()` - Expect specific errors
- `expectEventWithIndexed()` - Event assertion

## Running Tests

### All Tests
```bash
forge test
```

### Specific Test File
```bash
forge test --match-path test/unit/DirectionalFeeScaling.t.sol
```

### Specific Test Function
```bash
forge test --match-test test_ClassifyToxicFlow_MovingAway
```

### With Verbosity
```bash
forge test -vvv
```

### With Gas Reporting
```bash
forge test --gas-report
```

### With Coverage
```bash
forge coverage
```

### Unit Tests Only
```bash
forge test --match-path "test/unit/*"
```

### Integration Tests Only
```bash
forge test --match-path "test/integration/*"
```

### Security Tests Only
```bash
forge test --match-path "test/security/*"
```

## Test Coverage Goals

| Category | Target Coverage |
|----------|----------------|
| Unit Tests | >95% |
| Integration Tests | All critical user flows |
| Security Tests | All known attack vectors |
| Line Coverage | >90% |
| Branch Coverage | >85% |

## Test Development Workflow

1. **Write Test First**: Follow TDD principles
2. **Implement Minimal Code**: Make test pass
3. **Refactor**: Improve code quality
4. **Verify Coverage**: Ensure adequate coverage
5. **Review**: Peer review tests and implementation

## Continuous Integration

Tests should be run automatically on:
- Every commit (via pre-commit hook)
- Every pull request (via CI/CD)
- Before deployment (manual verification)

## Test Maintenance

- Update tests when requirements change
- Add regression tests for discovered bugs
- Keep mocks synchronized with interfaces
- Document complex test scenarios
- Review and update coverage goals periodically

---

**Last Updated**: June 8, 2026
**Maintainer**: Development Team
