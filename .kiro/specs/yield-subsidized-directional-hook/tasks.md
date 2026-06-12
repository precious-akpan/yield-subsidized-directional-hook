# Implementation Plan: Yield Subsidized Directional Hook

## Overview

This implementation plan breaks down the YieldSubsidizedDirectionalHook into discrete, testable coding tasks. The hook implements three integrated mechanisms: directional fee scaling to tax toxic arbitrage flow, external yield generation from idle capital, and IL subsidy distribution to compensate LPs.

The implementation follows a dependency-ordered approach, starting with foundational interfaces and data structures, then building core functionality, and finally integrating testing and optimization.

## Tasks

- [x] 1. Set up core interfaces and type definitions
  - [x] 1.1 Create IOracle interface
    - Define `getPrice(address token0, address token1)` function returning price and timestamp
    - Add interface documentation explaining manipulation resistance requirements
    - _Requirements: 3.1, 3.2_
  
  - [x] 1.2 Create IExternalVault interface
    - Define ERC-4626 compatible interface with `asset()`, `deposit()`, `withdraw()`, `convertToAssets()`, and `totalAssets()` functions
    - Include comprehensive function documentation for vault integration patterns
    - _Requirements: 11.1, 11.2_
  
  - [x] 1.3 Define core data structures
    - Create `PoolConfig` struct with oracle, vault addresses, fee parameters, and pause flag
    - Create `SubsidyPool` struct for yield and principal accounting
    - Create `LPPosition` struct for IL calculation tracking
    - Create `ClaimTokenMetadata` struct for locked capital claims
    - Define custom errors: `UnauthorizedCaller`, `PoolNotRegistered`, `PoolAlreadyRegistered`, `PoolPaused`, `InvalidConfiguration`, etc.
    - _Requirements: 1.1-1.7, 19.1, 21.1, 30.1_

- [x] 2. Implement base contract structure and access control
  - [x] 2.1 Create YieldSubsidizedDirectionalHook contract skeleton
    - Inherit from BaseHook, ERC1155, and ReentrancyGuard
    - Define storage mappings: `registeredPools`, `poolConfigs`, `subsidyPools`, `lpPositions`, `claimTokenMetadata`
    - Implement constructor accepting IPoolManager parameter
    - Store immutable poolManager reference
    - Initialize owner address
    - _Requirements: 1.1-1.7, 2.1, 22.1_
  
  - [x] 2.2 Implement access control modifiers and ownership
    - Create `onlyPoolManager()` modifier checking msg.sender equals poolManager
    - Create `onlyOwner()` modifier for administrative functions
    - Implement `transferOwnership(address newOwner)` function
    - Emit `OwnershipTransferred` event on ownership transfer
    - _Requirements: 2.1-2.5, 22.1-22.5_
  
  - [x] 2.3 Write unit tests for access control
    - Test that callbacks revert when called by non-PoolManager addresses
    - Test that administrative functions revert when called by non-owner addresses
    - Test ownership transfer functionality
    - _Requirements: 2.1-2.5, 22.1-22.5_

- [x] 3. Implement hook permissions and pool registration
  - [x] 3.1 Implement getHookPermissions function
    - Return Hooks.Permissions struct with beforeInitialize, beforeSwap, and beforeRemoveLiquidity set to true
    - Set all other hook flags to false
    - _Requirements: 1.1, 1.2_
  
  - [x] 3.2 Implement beforeInitialize callback
    - Add `onlyPoolManager` modifier
    - Validate PoolKey is not already registered
    - Store PoolKey hash in `registeredPools` mapping
    - Initialize empty SubsidyPool for the pool
    - Emit `PoolRegistered` event
    - Return `IHooks.beforeInitialize.selector`
    - _Requirements: 1.3-1.7, 2.2-2.4, 30.1-30.5_
  
  - [x]* 3.3 Write unit tests for pool registration
    - Test successful pool registration via beforeInitialize
    - Test revert on duplicate pool registration
    - Test revert on unauthorized caller
    - Verify SubsidyPool initialization
    - _Requirements: 1.1-1.7, 30.1-30.5_

- [x] 4. Checkpoint - Verify base infrastructure
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Implement oracle integration and price utilities
  - [x] 5.1 Implement oracle price fetching with validation
    - Create `getOraclePriceWithValidation(PoolKey)` internal function
    - Query oracle using try-catch with gas limit
    - Validate timestamp for staleness (5 minute threshold)
    - Validate price deviation from pool price (50% max)
    - Return price and validity flag
    - Cache oracle price within transaction using block.number
    - _Requirements: 3.1-3.5, 28.1-28.5, 29.1-29.5_
  
  - [x] 5.2 Implement price conversion utilities
    - Create `sqrtPriceX96ToPrice(uint160 sqrtPriceX96)` function
    - Create `calculateDeviation(uint256 price1, uint256 price2)` function returning deviation in basis points
    - Ensure proper handling of fixed-point arithmetic and precision
    - _Requirements: 4.1-4.4_
  
  - [x] 5.3 Write unit tests for oracle integration
    - Test oracle price fetching with mock oracle
    - Test staleness detection
    - Test price sanity bounds checking
    - Test graceful handling of oracle failures
    - Test price conversion functions
    - _Requirements: 3.1-3.5, 4.1-4.4, 28.1-28.5_

- [x] 6. Implement swap direction classification and fee scaling
  - [x] 6.1 Implement flow classification logic
    - Create `classifyFlow(PoolKey, bool zeroForOne, int256 amountSpecified)` internal function
    - Fetch oracle price with validation
    - Read current sqrtPriceX96 from pool's Slot0
    - Estimate post-swap price using amount and direction
    - Determine if swap moves price away from oracle price
    - Calculate price deviation magnitude
    - Return toxicity flag and fee multiplier
    - _Requirements: 5.1-5.5, 6.1-6.5_
  
  - [x] 6.2 Implement fee scaling curve
    - Create `calculateFeeMultiplier(uint256 deviationBps, PoolConfig)` internal function
    - Implement linear scaling: base + (deviation / threshold) * (max - base)
    - Cap at maximum multiplier from config
    - Ensure all arithmetic operations are safe from overflow
    - _Requirements: 6.1-6.5, 27.1-27.5_
  
  - [x] 6.3 Implement beforeSwap callback
    - Add `onlyPoolManager` modifier
    - Validate pool is registered
    - Check if pool is paused (return baseline fee if paused)
    - Call `classifyFlow` to determine toxicity and fee
    - Emit `DirectionalFeeApplied` event with pool, direction, toxicity, and fee details
    - Return `beforeSwap.selector`, ZERO_DELTA, and fee override
    - _Requirements: 2.2-2.4, 2.6-2.8, 5.1-5.5, 6.1-6.5, 7.1-7.5, 23.1-23.5, 33.3_
  
  - [ ]* 6.4 Write unit tests for directional fee scaling
    - Test toxic flow classification (swaps moving away from oracle)
    - Test benign flow classification (swaps moving toward oracle)
    - Test fee multiplier calculation for various deviations
    - Test baseline fee when oracle is stale or unavailable
    - Test paused pool behavior
    - _Requirements: 5.1-5.5, 6.1-6.5, 7.1-7.5_

- [x] 7. Checkpoint - Verify swap fee mechanism
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Implement idle capital detection
  - [x] 8.1 Create idle capital calculation function
    - Implement `calculateIdleCapital(PoolKey)` public view function
    - Query current active tick from pool's Slot0
    - Iterate through LP positions to identify out-of-range liquidity
    - Calculate token0 and token1 amounts for idle positions
    - Return total idle amounts for both tokens
    - _Requirements: 8.1-8.5_
  
  - [ ]* 8.2 Write unit tests for idle capital detection
    - Test calculation with in-range positions (should return zero)
    - Test calculation with out-of-range positions
    - Test calculation with mixed range positions
    - _Requirements: 8.1-8.5_

- [x] 9. Implement flash accounting for capital sweeps
  - [x] 9.1 Implement sweepIdleCapital function
    - Add public visibility and `nonReentrant` modifier
    - Validate pool is registered and not paused
    - Calculate idle capital amounts using `calculateIdleCapital`
    - Validate amounts exceed minimum sweep threshold
    - Encode sweep parameters (poolId, key, amounts)
    - Call `poolManager.unlock(data)` to trigger flash accounting
    - _Requirements: 9.1-9.5, 10.1, 26.1-26.5, 33.2_
  
  - [x] 9.2 Implement unlockCallback for capital sweep
    - Validate caller is poolManager
    - Decode sweep parameters from callback data
    - Use `poolManager.take()` to withdraw idle token amounts
    - Approve vault contracts for token transfers
    - Call vault `deposit()` functions with gas limits
    - Update SubsidyPool accounting (principal and vault shares)
    - Settle deltas using `poolManager.settle()`
    - Emit `CapitalSwept` event with amounts and vault shares
    - _Requirements: 10.1-10.5, 11.1-11.5, 12.1-12.5, 24.1-24.5, 29.1-29.5_
  
  - [ ]* 9.3 Write unit tests for capital sweeps
    - Test successful sweep with mock vaults
    - Test revert when pool not registered
    - Test revert when paused
    - Test revert when below minimum threshold
    - Test vault deposit success and share tracking
    - Test delta balancing
    - _Requirements: 9.1-9.5, 10.1-10.5, 11.1-11.5, 24.1-24.5_

- [x] 10. Implement IL calculation engine
  - [x] 10.1 Create IL calculation function
    - Implement `calculateImpermanentLoss(LPPosition, uint160 currentSqrtPriceX96)` internal function
    - Convert initial and current prices to comparable format
    - Calculate current token amounts from liquidity and tick range
    - Calculate hold value (initial tokens held without LP)
    - Calculate position value at current price
    - Compute IL as difference between hold value and position value
    - Return zero if position is profitable (negative IL)
    - Return IL amounts denominated in both token0 and token1
    - _Requirements: 13.1-13.5_
  
  - [x] 10.2 Create position tracking helper
    - Implement `trackLPPosition(address lp, PoolId poolId, LPPosition)` internal function
    - Store position data in `lpPositions` mapping
    - Update position count
    - Handle position updates on liquidity modifications
    - _Requirements: 31.1-31.5_
  
  - [ ]* 10.3 Write unit tests for IL calculation
    - Test IL calculation when price increases
    - Test IL calculation when price decreases
    - Test zero IL when position is profitable
    - Test IL distribution between token0 and token1
    - _Requirements: 13.1-13.5, 31.1-31.5_

- [x] 11. Checkpoint - Verify capital sweep and IL calculation
  - Ensure all tests pass, ask the user if questions arise.

- [x] 12. Implement subsidy distribution system
  - [x] 12.1 Create available yield calculation
    - Implement `calculateAvailableYield(PoolId, bool isToken0)` internal view function
    - Query vault for current asset value using `convertToAssets()`
    - Subtract principal from current value to get yield
    - Return available yield amount
    - _Requirements: 12.1-12.5, 34.1-34.5_
  
  - [x] 12.2 Implement vault withdrawal with claim token fallback
    - Create `withdrawFromVault(PoolKey, PoolId, bool isToken0, uint256 amount)` internal function
    - Attempt vault withdrawal with try-catch and gas limit
    - On success: update principal tracking, transfer tokens
    - On failure: mint ERC-1155 claim token to LP
    - Initialize ClaimTokenMetadata if first occurrence
    - Update `lpLockedAmounts` tracking
    - Emit `ClaimTokenMinted` event on failure
    - _Requirements: 15.1-15.5, 16.1-16.5, 18.1-18.5_
  
  - [x] 12.3 Implement beforeRemoveLiquidity callback
    - Add `onlyPoolManager` modifier
    - Validate pool is registered
    - Retrieve LP address (from tx.origin or hook data)
    - Fetch LP position data
    - Call `calculateImpermanentLoss` with current price
    - Skip if IL is zero
    - Calculate available subsidy from yield pools
    - Cap subsidy at lesser of IL or available yield
    - Call `withdrawFromVault` for needed subsidy amounts
    - Update SubsidyPool yield balances
    - Emit `ILSubsidyDistributed` event with IL and subsidy amounts
    - Return `beforeRemoveLiquidity.selector`
    - _Requirements: 2.2-2.4, 2.6-2.8, 13.1-13.5, 14.1-14.5, 15.1-15.5, 25.1-25.5, 33.4_
  
  - [x] 12.4 Write unit tests for subsidy distribution
    - Test IL subsidy distribution when yield is available
    - Test partial subsidy when yield insufficient
    - Test zero subsidy when no IL
    - Test claim token minting when vault withdrawal fails
    - Test subsidy pool balance updates
    - _Requirements: 13.1-13.5, 14.1-14.5, 15.1-15.5, 18.1-18.5, 25.1-25.5_

- [x] 13. Implement claim token system (ERC-1155)
  - [x] 13.1 Implement claim token ID generation
    - Create `generateClaimTokenId(PoolId, Currency)` internal pure function
    - Encode poolId and token index into unique uint256 ID
    - Use keccak256 hashing for collision resistance
    - _Requirements: 16.1-16.5_
  
  - [x] 13.2 Implement claim token redemption
    - Create `redeemLockedCapital(uint256 claimTokenId, uint256 amount)` external function
    - Add `nonReentrant` modifier
    - Validate caller owns sufficient claim token balance
    - Validate claim token metadata exists
    - Attempt vault withdrawal with specified amount
    - Burn claim tokens on successful withdrawal
    - Update ClaimTokenMetadata and lpLockedAmounts
    - Transfer withdrawn assets to caller
    - Emit `ClaimTokenRedeemed` event
    - Revert with informative error if vault still illiquid
    - _Requirements: 17.1-17.5, 26.1-26.5_
  
  - [x] 13.3 Override ERC-1155 _beforeTokenTransfer hook
    - Update `lpLockedAmounts` tracking when claim tokens are transferred
    - Deduct from sender's locked amount mapping
    - Add to receiver's locked amount mapping
    - _Requirements: 16.1-16.5_
  
  - [ ]* 13.4 Write unit tests for claim token system
    - Test claim token minting when vault withdrawal fails
    - Test claim token redemption when vault liquidity restored
    - Test revert on redemption when vault still illiquid
    - Test claim token transfers between addresses
    - Test lpLockedAmounts tracking accuracy
    - _Requirements: 16.1-16.5, 17.1-17.5_

- [x] 14. Checkpoint - Verify subsidy and claim token systems
  - Ensure all tests pass, ask the user if questions arise.
    - Test partial subsidy scenario
    - _Requirements: 13.1-13.5, 14.1-14.5, 25.1-25.5, 31.1-31.5_
    
- [x] 15. Implement administrative functions
  - [x] 15.1 Implement pool configuration function
    - Create `configurePool(PoolId, PoolConfig)` external function
    - Add `onlyOwner` and `nonReentrant` modifiers
    - Validate pool is registered
    - Validate oracle implements IOracle interface
    - Validate vault implements IExternalVault and asset matches pool token
    - Validate fee parameters (max >= base, reasonable thresholds)
    - Store configuration in `poolConfigs` mapping
    - Emit `PoolConfigured` event
    - _Requirements: 19.1-19.5, 20.1-20.5, 21.1-21.5, 22.1-22.5_
  
  - [x] 15.2 Implement pause/unpause functions
    - Create `pausePool(PoolId)` external function with `onlyOwner` modifier
    - Create `unpausePool(PoolId)` external function with `onlyOwner` modifier
    - Update `isPaused` flag in pool configs
    - Emit `PoolPaused` or `PoolUnpaused` events
    - _Requirements: 22.1-22.5, 33.1-33.5_
  
  - [x]* 15.3 Write unit tests for administrative functions
    - Test pool configuration with valid parameters
    - Test configuration validation (invalid oracle, mismatched vault assets)
    - Test pause/unpause functionality
    - Test access control (revert on non-owner calls)
    - _Requirements: 19.1-19.5, 20.1-20.5, 21.1-21.5, 22.1-22.5, 33.1-33.5_

- [x] 16. Implement utility and view functions
  - [x] 16.1 Create view functions for external queries
    - Implement `getSubsidyPoolBalance(PoolId)` returning yield and principal amounts
    - Implement `getLPClaimableSubsidy(address lp, PoolId)` calculating LP's share
    - Implement `getRegisteredPools()` returning array of registered pool IDs
    - Implement `isPoolRegistered(PoolId)` returning boolean
    - ✅ COMPLETED - All view functions implemented in YieldSubsidizedDirectionalHook.sol
    - _Requirements: 12.4, 12.5, 32.5_
  
  - [x]* 16.2 Write unit tests for view functions
    - Test subsidy pool balance queries
    - Test LP claimable subsidy calculations
    - Test registered pools enumeration
    - _Requirements: 12.4, 12.5, 32.1-32.5_

- [x] 17. Implement gas optimization passes
  - [x] 17.1 Optimize storage access patterns
    - Cache PoolConfig structs in memory during callbacks
    - Use storage pointers for SubsidyPool updates
    - Pack related fields into single storage slots where possible
    - _Requirements: 7.1-7.5, 27.1-27.5_
  
  - [x] 17.2 Optimize arithmetic operations
    - Use unchecked blocks for operations guaranteed not to overflow
    - Minimize redundant calculations by caching intermediate results
    - Use bit shifting for power-of-2 multiplications/divisions where applicable
    - _Requirements: 7.1-7.5, 27.1-27.5_

- [x] 18. Checkpoint - Final verification
  - Ensure all tests pass, ask the user if questions arise.

- [x] 19. Create integration tests
  - [ ] 19.1 Write end-to-end swap flow test
    - Deploy hook with mock oracle and vaults
    - Initialize pool through PoolManager
    - Execute toxic swap and verify dynamic fee applied
    - Execute benign swap and verify baseline fee applied
    - Verify DirectionalFeeApplied events
    - _Requirements: 1.1-1.7, 2.1-2.8, 5.1-5.5, 6.1-6.5, 23.1-23.5_
  
  - [ ] 19.2 Write end-to-end capital sweep flow test
    - Set up pool with out-of-range LP positions
    - Call sweepIdleCapital as keeper
    - Verify capital transferred to vaults
    - Verify vault shares tracked in SubsidyPool
    - Verify CapitalSwept event emission
    - _Requirements: 8.1-8.5, 9.1-9.5, 10.1-10.5, 11.1-11.5, 24.1-24.5_
  
  - [ ] 19.3 Write end-to-end IL subsidy flow test
    - Add liquidity to pool, track position
    - Simulate price movement causing IL
    - Sweep capital to generate yield
    - Remove liquidity and verify subsidy distribution
    - Verify ILSubsidyDistributed event

  
  - [x]* 19.4 Write end-to-end claim token flow test
    - Remove liquidity when vault is illiquid
    - Verify claim token minting
    - Restore vault liquidity
    - Redeem claim tokens
    - Verify ClaimTokenMinted and ClaimTokenRedeemed events
    - _Requirements: 16.1-16.5, 17.1-17.5, 18.1-18.5_
  
  - [x]* 19.5 Write multi-pool integration test
    - Register multiple pools with different configurations
    - Verify isolated accounting and configuration per pool
    - Test cross-pool operations don't interfere
    - _Requirements: 32.1-32.5_

- [x] 20. Create security and edge case tests
  - [x]* 20.1 Write reentrancy attack tests
    - Test reentrancy protection on sweepIdleCapital
    - Test reentrancy protection on redeemLockedCapital
    - Test reentrancy protection on administrative functions
    - _Requirements: 26.1-26.5_
  
  - [x]* 20.2 Write price manipulation tests
    - Test oracle staleness rejection
    - Test oracle price sanity bounds
    - Test graceful fallback when oracle compromised
    - _Requirements: 28.1-28.5_
  
  - [x]* 20.3 Write overflow/underflow tests
    - Test extreme values in fee calculations
    - Test subsidy pool balance edge cases
    - Verify all arithmetic is checked or explicitly unchecked
    - _Requirements: 27.1-27.5_
  
  - [x]* 20.4 Write gas limit safety tests
    - Test oracle calls with malicious gas-consuming contracts
    - Test vault calls with malicious gas-consuming contracts
    - Verify graceful handling of out-of-gas scenarios
    - _Requirements: 29.1-29.5_
  
  - [x]* 20.5 Write pause mechanism tests
    - Test paused pool behavior for swaps (baseline fees only)
    - Test paused pool blocks capital sweeps
    - Test paused pool allows liquidity removal without subsidies
    - _Requirements: 33.1-33.5_

- [x] 21. Implement Reactive Network automation contracts
  - [x] 21.1 Create IYieldSubsidizedDirectionalHook interface
    - Define interface for automation compatibility
    - Include `sweepIdleCapital`, `getIdleCapital`, `getPoolConfig`, `getSubsidyPool`, `isPoolRegistered` functions
    - Define events: `IdleCapitalDetected`, `CapitalSwept`, `ILSubsidyDistributed`, `ClaimTokenMinted`
    - Add comprehensive NatSpec documentation
    - _Requirements: 41.1-41.5, 49.1-49.5_
  
  - [x] 21.2 Implement ReactiveKeeperCallback contract
    - Inherit from AbstractReactive (Reactive Network SDK)
    - Store immutable hook address and Reactive Network service address
    - Implement storage for sweep threshold and minimum sweep interval
    - Maintain mapping of last sweep timestamps per pool
    - Create `react(uint256[] topics, bytes data, uint256 origin, address sender)` function
    - Validate caller is Reactive Network service
    - Decode pool ID and idle amounts from event data
    - Check sweep interval (block.timestamp >= lastSweepTime + minInterval)
    - Check sweep threshold (idle amount >= threshold)
    - Call hook.sweepIdleCapital(poolKey) if conditions met
    - Update lastSweepTime mapping
    - Emit SweepTriggered event
    - ✅ COMPLETED - ReactiveKeeperCallback.sol fully implemented in src/automation/
    - ✅ Uses modern IReactive.LogRecord pattern (more advanced than AbstractReactive)
    - ✅ Includes admin functions: setSweepThreshold, setMinSweepInterval, transferAdmin
    - ✅ Includes view functions: canSweep, getLastSweepTime, getSweepConfig
    - ✅ Comprehensive test coverage in test/unit/ReactiveAutomation.t.sol
    - _Requirements: 42.1-42.5, 43.1-43.5, 44.1-44.5, 47.1-47.5, 50.1-50.5_
  
- [x] 21.3 Implement ReactiveSubscriber contract
    - Inherit from AbstractReactive (Reactive Network SDK)
    - Store immutable hook address, callback address, and Reactive Network service address
    - Define event topic constants for LiquidityModified and IdleCapitalDetected
    - Subscribe to hook events in constructor via Reactive Network service
    - Implement `react(uint256[] topics, bytes data, uint256 origin, address sender)` function
    - Validate caller is Reactive Network service
    - Validate event sender is monitored hook address
    - Forward event to callback contract via IReactive interface
    - ✅ COMPLETED - ReactiveSubscriber.sol implemented
    - _Requirements: 45.1-45.5, 47.1-47.5_
  
  - [x] 21.4 Add automation configuration functions
    - Implement `setSweepThreshold(uint256)` with onlyAdmin modifier in callback
    - Implement `setMinSweepInterval(uint256)` with onlyAdmin modifier in callback
    - Implement `transferAdmin(address)` in both contracts
    - Emit ThresholdUpdated, IntervalUpdated, AdminTransferred events
    - Add `canSweep(bytes32 poolId)` view function to check readiness
    - _Requirements: 43.1-43.5, 44.1-44.5, 46.1-46.5, 48.1-48.5_
  
  - [ ]* 21.5 Write unit tests for Reactive Network automation
    - Test ReactiveKeeperCallback threshold validation
    - Test ReactiveKeeperCallback interval enforcement
    - Test ReactiveSubscriber event forwarding
    - Test access control on configuration functions
    - Test automated sweep triggering with mock hook
    - Mock Reactive Network service for testing
    - _Requirements: 42.1-42.5, 43.1-43.5, 44.1-44.5, 45.1-45.5, 46.1-46.5_

- [x] 22. Add IdleCapitalDetected event emission to hook
  - [x] 22.1 Define IdleCapitalDetected event in hook contract
    - Add event with parameters: poolId, idleAmount0, idleAmount1, poolKey
    - Include comprehensive NatSpec documentation
    - ✅ COMPLETED - Event defined with indexed poolId for efficient filtering
    - _Requirements: 41.1-41.5_
  
  - [x] 22.2 Implement idle capital detection trigger
    - Create `_emitIdleCapitalIfNeeded(PoolKey)` internal function
    - Call calculateIdleCapital to get current idle amounts
    - Compare against minimum detection threshold (e.g., 0.1 ETH)
    - Emit IdleCapitalDetected if threshold exceeded
    - Call from beforeRemoveLiquidity after LP exits
    - Call from afterSwap if price moves significantly (optional)
    - ✅ COMPLETED - Integrated into beforeRemoveLiquidity callback
    - ✅ Event emitted as trigger signal for Reactive Network automation
    - _Requirements: 41.1-41.5_
  
  - [ ]* 22.3 Write unit tests for idle capital event emission
    - Test event emission when idle capital exceeds threshold
    - Test no event when idle capital below threshold
    - Test event includes correct pool and amounts
    - Verify event can be monitored by ReactiveSubscriber
    - _Requirements: 41.1-41.5_

- [x] 23. Create deployment script for Reactive Network automation
  - [ ] 23.1 Create DeployReactiveAutomation.s.sol script
    - Read environment variables: REACTIVE_SERVICE_ADDRESS, HOOK_ADDRESS, SWEEP_THRESHOLD, SWEEP_INTERVAL
    - Deploy ReactiveKeeperCallback on Reactive Network
    - Deploy ReactiveSubscriber on origin chain
    - Log deployment addresses and configuration
    - Provide verification instructions
    - _Requirements: 42.1-42.5, 45.1-45.5_
  
  - [ ]* 23.2 Test deployment script
    - Verify script runs successfully on local testnet
    - Verify environment variable loading
    - Verify contracts deploy with correct parameters
    - Test deployment on public testnet (optional)
    - _Requirements: All Reactive Network requirements_

- [ ] 24. Create integration tests for automated sweeps
  - [ ]* 24.1 Write end-to-end automated sweep test
    - Deploy hook, ReactiveSubscriber, and ReactiveKeeperCallback
    - Create out-of-range LP positions
    - Emit IdleCapitalDetected event
    - Simulate Reactive Network triggering callback.react()
    - Verify sweepIdleCapital executed successfully
    - Verify capital transferred to vaults
    - Verify lastSweepTime updated
    - _Requirements: 41.1-41.5, 42.1-42.5, 43.1-43.5, 44.1-44.5, 50.1-50.5_
  
  - [ ]* 24.2 Write threshold filtering test
    - Emit IdleCapitalDetected with amount below threshold
    - Verify sweep NOT triggered
    - Emit IdleCapitalDetected with amount above threshold
    - Verify sweep IS triggered
    - _Requirements: 43.1-43.5_
  
  - [ ]* 24.3 Write interval enforcement test
    - Trigger first automated sweep successfully
    - Immediately trigger second sweep attempt
    - Verify SweepTooSoon revert
    - Fast-forward time beyond interval
    - Verify second sweep succeeds
    - _Requirements: 44.1-44.5_
  
  - [ ]* 24.4 Write multi-pool automation test
    - Set up two pools with different configurations
    - Trigger sweeps for both pools
    - Verify independent interval tracking
    - Verify independent threshold checking
    - Verify isolated lastSweepTime per pool
    - _Requirements: 50.1-50.5_

- [ ] 25. Final checkpoint - Complete verification with automation
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional test tasks and can be skipped for faster MVP delivery
- Each task references specific requirements from the requirements document for traceability
- The implementation uses Solidity 0.8.26+ for built-in overflow protection and Foundry for testing
- The hook integrates with Uniswap v4's BaseHook, PoolManager, and flash accounting patterns
- All external calls (oracle, vault) use gas limits and try-catch for safety
- The claim token system uses ERC-1155 for efficient multi-token management
- Property-based testing is not included as the design focuses on integration patterns rather than universal mathematical properties
- Checkpoints ensure incremental validation and provide natural pause points for review

## Task Dependency Graph

```json
{
  "waves": [
    {
      "id": 0,
      "tasks": ["1.1", "1.2", "1.3"]
    },
    {
      "id": 1,
      "tasks": ["2.1"]
    },
    {
      "id": 2,
      "tasks": ["2.2", "2.3", "3.1"]
    },
    {
      "id": 3,
      "tasks": ["3.2", "3.3"]
    },
    {
      "id": 4,
      "tasks": ["5.1", "5.2"]
    },
    {
      "id": 5,
      "tasks": ["5.3", "6.1", "6.2"]
    },
    {
      "id": 6,
      "tasks": ["6.3", "6.4"]
    },
    {
      "id": 7,
      "tasks": ["8.1", "8.2"]
    },
    {
      "id": 8,
      "tasks": ["9.1"]
    },
    {
      "id": 9,
      "tasks": ["9.2", "9.3"]
    },
    {
      "id": 10,
      "tasks": ["10.1", "10.2"]
    },
    {
      "id": 11,
      "tasks": ["10.3", "12.1"]
    },
    {
      "id": 12,
      "tasks": ["12.2"]
    },
    {
      "id": 13,
      "tasks": ["12.3", "12.4", "13.1"]
    },
    {
      "id": 14,
      "tasks": ["13.2", "13.3"]
    },
    {
      "id": 15,
      "tasks": ["13.4", "15.1", "15.2"]
    },
    {
      "id": 16,
      "tasks": ["15.3", "16.1"]
    },
    {
      "id": 17,
      "tasks": ["16.2", "17.1", "17.2"]
    },
    {
      "id": 18,
      "tasks": ["19.1", "19.2", "19.3", "19.4", "19.5"]
    },
    {
      "id": 19,
      "tasks": ["20.1", "20.2", "20.3", "20.4", "20.5"]
    },
    {
      "id": 20,
      "tasks": ["21.1", "21.2", "21.3"]
    },
    {
      "id": 21,
      "tasks": ["21.4", "21.5"]
    },
    {
      "id": 22,
      "tasks": ["22.1", "22.2"]
    },
    {
      "id": 23,
      "tasks": ["22.3", "23.1"]
    },
    {
      "id": 24,
      "tasks": ["23.2", "24.1", "24.2", "24.3", "24.4"]
    }
  ]
}
```
