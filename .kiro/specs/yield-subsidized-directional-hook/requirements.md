# Requirements Document

## Introduction

The Yield Subsidized Directional Hook is a production-ready Uniswap v4 Hook that protects liquidity providers (LPs) from Impermanent Loss (IL) through three integrated mechanisms: taxing toxic order flow via directional fee scaling, generating external yield on out-of-range capital, and distributing accumulated yield to LPs as IL subsidies upon liquidity removal.

This hook addresses the fundamental challenge of LP profitability in automated market makers by identifying and penalizing informed arbitrage trades that cause IL, while simultaneously generating alternative revenue streams from idle capital to compensate LPs for unavoidable price divergence losses.

## Glossary

- **Hook**: A Uniswap v4 smart contract that implements lifecycle callbacks to customize pool behavior
- **PoolManager**: The Uniswap v4 core contract that manages all pools and enforces hook permissions
- **Impermanent_Loss**: The opportunity cost LPs incur when token prices diverge from initial deposit ratios
- **Toxic_Flow**: Informed order flow (typically arbitrage) that exploits stale pool prices and causes LP losses
- **Directional_Fee_Scaling**: Dynamic fee adjustment based on whether a swap pushes the pool price toward or away from the oracle price
- **Flash_Accounting**: Uniswap v4's singleton architecture where internal balances are tracked via deltas and settled atomically via unlock/lock
- **Idle_Capital**: LP positions that are out-of-range and not actively providing liquidity at the current price tick
- **IL_Subsidy_Pool**: On-chain accounting structure that accumulates external yield and tracks LP entitlements
- **Oracle_Price**: External reference price from a trusted price feed used to identify toxic flow direction
- **Keeper**: Automated bot or external actor that triggers permissionless capital sweep operations
- **Claim_Token**: ERC-1155 token representing a deferred claim on principal locked in external yield vaults
- **Yield_Vault**: External ERC-4626 compatible contract that accepts deposits and generates yield


## Requirements

### Requirement 1: Hook Registration and Initialization

**User Story:** As a pool deployer, I want to register the hook with correct permissions, so that the PoolManager allows the hook to execute its callbacks.

#### Acceptance Criteria

1. WHEN getHookPermissions is called, THE Hook SHALL return a Hooks.Permissions bitmap with beforeInitialize, beforeSwap, and beforeRemoveLiquidity flags set to true
2. WHEN getHookPermissions is called, THE Hook SHALL return a Hooks.Permissions bitmap with afterInitialize, afterSwap, afterAddLiquidity, afterRemoveLiquidity, afterDonate, beforeAddLiquidity, and beforeDonate flags set to false
3. WHEN beforeInitialize is called, THE Hook SHALL verify that msg.sender equals the stored PoolManager address
4. IF msg.sender does not equal the PoolManager address in beforeInitialize, THEN THE Hook SHALL revert with an unauthorized caller error
5. WHEN beforeInitialize is called with a PoolKey that is already registered, THE Hook SHALL revert with a duplicate pool error
6. WHEN beforeInitialize is called with a valid unregistered PoolKey, THE Hook SHALL store the PoolKey hash in its registry mapping
7. WHEN beforeInitialize completes successfully, THE Hook SHALL return the IHooks.beforeInitialize.selector

### Requirement 2: Access Control for Core Callbacks

**User Story:** As a security auditor, I want all v4 callbacks to enforce strict access control, so that malicious actors cannot spoof callbacks with fake pool data.

#### Acceptance Criteria

1. THE Hook SHALL store the PoolManager address during deployment or initialization
2. WHEN beforeInitialize callback is invoked, THE Hook SHALL verify that msg.sender equals the stored PoolManager address before executing callback logic
3. WHEN beforeSwap callback is invoked, THE Hook SHALL verify that msg.sender equals the stored PoolManager address before executing callback logic
4. WHEN beforeRemoveLiquidity callback is invoked, THE Hook SHALL verify that msg.sender equals the stored PoolManager address before executing callback logic
5. IF msg.sender is not the PoolManager address in any callback, THEN THE Hook SHALL revert with a custom error indicating unauthorized caller
6. WHEN beforeSwap callback is invoked, THE Hook SHALL verify the provided PoolKey corresponds to a pool registered during beforeInitialize
7. WHEN beforeRemoveLiquidity callback is invoked, THE Hook SHALL verify the provided PoolKey corresponds to a pool registered during beforeInitialize
8. IF a PoolKey that was not registered during beforeInitialize is provided to beforeSwap or beforeRemoveLiquidity, THEN THE Hook SHALL revert with a custom error indicating invalid pool


### Requirement 3: Oracle Price Integration

**User Story:** As a hook developer, I want to query external oracle prices during swaps, so that I can determine swap flow direction relative to fair market value.

#### Acceptance Criteria

1. THE Hook SHALL define an IOracle interface with a getPrice function that returns a price value and timestamp
2. WHEN the hook is deployed, THE Hook SHALL accept and store an oracle contract address implementing IOracle
3. WHEN beforeSwap is executed, THE Hook SHALL query the oracle price for the relevant token pair
4. IF the oracle call reverts or returns stale data, THEN THE Hook SHALL apply the baseline pool fee without directional scaling
5. THE Hook SHALL cache oracle prices within a single transaction to avoid redundant external calls

### Requirement 4: Current Pool Price Retrieval

**User Story:** As a hook developer, I want to read the current pool price from Slot0, so that I can compare it against the oracle price.

#### Acceptance Criteria

1. WHEN beforeSwap is executed, THE Hook SHALL read the current sqrtPriceX96 from the pool's Slot0
2. THE Hook SHALL convert sqrtPriceX96 to a comparable price format matching the oracle price format
3. THE Hook SHALL handle both token0-to-token1 and token1-to-token0 price conversions correctly
4. THE Hook SHALL maintain precision during price format conversions to avoid rounding errors that misclassify flow direction


### Requirement 5: Swap Direction Classification

**User Story:** As an LP protection mechanism, I want to classify each swap as toxic or benign based on price movement direction, so that I can apply appropriate fee scaling.

#### Acceptance Criteria

1. WHEN a swap would move the pool price away from the oracle price by more than a configured threshold, THE Hook SHALL classify the swap as Toxic_Flow
2. WHEN a swap would move the pool price toward the oracle price, THE Hook SHALL classify the swap as benign rebalancing flow
3. THE Hook SHALL determine price movement direction by comparing the pre-swap pool price, post-swap expected pool price, and oracle price
4. THE Hook SHALL account for both zeroForOne and oneForZero swap directions when classifying flow toxicity
5. THE Hook SHALL use a configurable price deviation threshold measured in basis points or percentage

### Requirement 6: Dynamic Fee Scaling

**User Story:** As an LP, I want toxic swaps to pay higher fees proportional to price deviation, so that informed arbitrageurs compensate me for the IL they cause.

#### Acceptance Criteria

1. WHEN a swap is classified as Toxic_Flow, THE Hook SHALL calculate a fee multiplier based on the magnitude of price deviation from the oracle
2. WHEN a swap is classified as benign flow, THE Hook SHALL apply the baseline pool swap fee without scaling
3. THE Hook SHALL define a fee scaling curve that maps price deviation percentage to fee multiplier values
4. THE Hook SHALL cap the maximum fee multiplier to prevent excessive fees that break pool competitiveness
5. WHEN beforeSwap returns, THE Hook SHALL return BeforeSwapDelta with the overridden dynamic fee via the appropriate return value encoding


### Requirement 7: Gas-Efficient beforeSwap Execution

**User Story:** As a trader, I want swap transactions to complete efficiently without gas exhaustion, so that I can execute trades reliably.

#### Acceptance Criteria

1. THE Hook SHALL implement beforeSwap with O(1) computational complexity using only constant-time state lookups
2. THE Hook SHALL NOT perform loops or unbounded iterations inside beforeSwap
3. THE Hook SHALL NOT make external calls to volatile or untrusted contracts inside beforeSwap
4. THE Hook SHALL complete all beforeSwap logic within a gas budget that allows normal swap transactions to succeed
5. IF the oracle price lookup exceeds a gas threshold, THEN THE Hook SHALL skip directional fee scaling and apply baseline fees

### Requirement 8: Idle Capital Detection

**User Story:** As a keeper, I want to identify out-of-range LP positions programmatically, so that I can trigger capital sweeps to maximize yield generation.

#### Acceptance Criteria

1. THE Hook SHALL provide a public view function that returns the total amount of idle capital in a given pool
2. WHEN calculating idle capital, THE Hook SHALL compare initialized LP tick ranges against the current active tick
3. THE Hook SHALL classify liquidity positions as idle if their tick range does not include the current active tick
4. THE Hook SHALL return idle capital amounts denominated in both token0 and token1
5. THE Hook SHALL account for multiple LP positions at different tick ranges when computing total idle capital


### Requirement 9: Permissionless Capital Sweep Function

**User Story:** As a keeper, I want to sweep idle capital to external yield vaults without requiring special permissions, so that yield generation is automated and decentralized.

#### Acceptance Criteria

1. THE Hook SHALL provide a public sweepIdleCapital function that accepts a PoolKey parameter
2. THE sweepIdleCapital function SHALL be callable by any external address without access control restrictions
3. WHEN sweepIdleCapital is called, THE Hook SHALL validate that the provided PoolKey corresponds to a registered pool
4. WHEN sweepIdleCapital is called, THE Hook SHALL calculate the current amount of idle out-of-range capital
5. IF no idle capital exists, THEN THE Hook SHALL revert with an informative error or return early without state changes

### Requirement 10: Flash Accounting for Capital Withdrawal

**User Story:** As a hook developer, I want to withdraw idle capital using Uniswap v4's unlock mechanism, so that I can move funds to external vaults atomically.

#### Acceptance Criteria

1. WHEN sweepIdleCapital executes, THE Hook SHALL call poolManager.unlock with an encoded callback payload
2. WHEN the unlock callback (lockAcquired) is invoked, THE Hook SHALL withdraw idle token amounts from the PoolManager using take operations
3. THE Hook SHALL settle the withdrawn tokens to the hook's address before depositing to external vaults
4. THE Hook SHALL ensure that all delta accounting balances to zero before the unlock call completes
5. IF delta accounting does not balance, THEN THE Hook SHALL revert the entire sweep transaction


### Requirement 11: External Yield Vault Interface

**User Story:** As a hook developer, I want to deposit idle capital into ERC-4626 compatible yield vaults, so that out-of-range liquidity generates returns.

#### Acceptance Criteria

1. THE Hook SHALL define an IExternalVault interface following ERC-4626 standards with deposit, withdraw, and totalAssets functions
2. WHEN the hook is deployed or configured, THE Hook SHALL accept and store vault contract addresses for token0 and token1
3. WHEN idle capital is swept, THE Hook SHALL deposit withdrawn token amounts into the corresponding vault contracts
4. THE Hook SHALL track the total amount of capital deposited into each vault per pool
5. THE Hook SHALL receive vault share tokens representing the deposited principal and accrued yield

### Requirement 12: Yield Accumulation Tracking

**User Story:** As an LP, I want the hook to track accumulated yield separately from principal, so that I can verify my IL subsidy eligibility.

#### Acceptance Criteria

1. THE Hook SHALL maintain an IL_Subsidy_Pool accounting structure per pool that tracks total yield accumulated
2. WHEN yield is harvested from external vaults, THE Hook SHALL credit the difference between current vault value and initial principal to the subsidy pool
3. THE Hook SHALL track individual LP contributions to the subsidy pool based on their proportional share of swept capital
4. THE Hook SHALL provide a view function that returns the current subsidy pool balance for a given pool
5. THE Hook SHALL provide a view function that returns an individual LP's claimable subsidy amount


### Requirement 13: Impermanent Loss Calculation

**User Story:** As an LP, I want my IL to be calculated accurately when I remove liquidity, so that I receive fair compensation from the subsidy pool.

#### Acceptance Criteria

1. WHEN beforeRemoveLiquidity is invoked, THE Hook SHALL calculate the LP's realized Impermanent_Loss based on initial deposit ratio and current pool price
2. THE Hook SHALL compare the LP's current token amounts to the hold-value (initial tokens held without providing liquidity)
3. THE Hook SHALL express IL as a percentage or absolute value representing the opportunity cost
4. THE Hook SHALL handle edge cases where the LP is in profit (negative IL) by treating IL as zero for subsidy purposes
5. THE Hook SHALL use the pool's Slot0 price at the time of liquidity removal for IL calculation

### Requirement 14: IL Subsidy Distribution

**User Story:** As an LP, I want to receive yield subsidies proportional to my IL when I remove liquidity, so that I am compensated for losses caused by price divergence.

#### Acceptance Criteria

1. WHEN beforeRemoveLiquidity is invoked and IL is greater than zero, THE Hook SHALL calculate the LP's pro-rata share of the subsidy pool
2. THE Hook SHALL cap the subsidy amount at the lesser of calculated IL or available subsidy pool balance
3. WHEN subsidy funds are available, THE Hook SHALL add the subsidy amount to the LP's withdrawal by adjusting the BalanceDelta return value
4. WHEN subsidy is distributed, THE Hook SHALL deduct the distributed amount from the IL_Subsidy_Pool total
5. IF insufficient subsidy funds exist to fully cover IL, THEN THE Hook SHALL distribute available funds proportionally and emit an event indicating partial coverage


### Requirement 15: Vault Withdrawal for Subsidy Funding

**User Story:** As a hook mechanism, I want to withdraw yield from external vaults when distributing subsidies, so that accumulated returns are converted to liquidity for LP compensation.

#### Acceptance Criteria

1. WHEN IL subsidy is being distributed and vault funds are needed, THE Hook SHALL call the vault's withdraw function to retrieve tokens
2. THE Hook SHALL withdraw only the amount needed for the current subsidy distribution plus a gas buffer
3. IF the vault withdrawal reverts due to insufficient liquidity, THEN THE Hook SHALL handle the error gracefully without reverting the LP's removeLiquidity transaction
4. THE Hook SHALL track the amount of yield withdrawn from vaults and update the subsidy pool accounting accordingly
5. THE Hook SHALL prioritize withdrawing generated yield over principal when calling vault withdraw functions

### Requirement 16: Locked Capital Claim Tokens

**User Story:** As an LP, I want to receive claim tokens when my principal is locked in external vaults, so that I can redeem my capital later without blocking my liquidity removal.

#### Acceptance Criteria

1. WHERE the external vault cannot immediately return withdrawn capital due to utilization limits, THE Hook SHALL mint an ERC-1155 Claim_Token to the LP
2. THE Claim_Token SHALL represent the LP's proportional claim on locked principal in the external vault
3. THE Hook SHALL assign a unique token ID to each vault and pool combination for proper claim tracking
4. WHEN minting a Claim_Token, THE Hook SHALL record the amount of locked capital and the vault address in metadata
5. THE Hook SHALL emit an event containing the LP address, token ID, locked amount, and vault address when minting claim tokens


### Requirement 17: Claim Token Redemption

**User Story:** As an LP holding claim tokens, I want to redeem them for my locked capital when vault liquidity becomes available, so that I can recover my full principal.

#### Acceptance Criteria

1. THE Hook SHALL provide a public redeemLockedCapital function that accepts a token ID and amount parameter
2. WHEN redeemLockedCapital is called, THE Hook SHALL verify the caller owns sufficient Claim_Token balance for the specified token ID
3. WHEN redeeming, THE Hook SHALL attempt to withdraw the corresponding capital amount from the external vault
4. IF the vault withdrawal succeeds, THEN THE Hook SHALL burn the redeemed Claim_Tokens and transfer the withdrawn capital to the LP
5. IF the vault withdrawal fails due to continued illiquidity, THEN THE Hook SHALL revert with an informative error indicating vault is still locked

### Requirement 18: Graceful Vault Failure Handling

**User Story:** As an LP, I want my liquidity removal to succeed even if external vaults fail, so that my funds are not permanently locked due to third-party failures.

#### Acceptance Criteria

1. WHEN beforeRemoveLiquidity attempts to withdraw from external vaults and the call reverts, THE Hook SHALL NOT revert the parent removeLiquidity transaction
2. IF vault withdrawal fails, THEN THE Hook SHALL mint Claim_Tokens to the LP representing their locked principal
3. THE Hook SHALL emit an event when vault withdrawal fails indicating the failure reason and claim token issuance
4. THE Hook SHALL allow the removeLiquidity transaction to complete with whatever capital is immediately available
5. THE Hook SHALL maintain accurate accounting of locked capital versus liquid capital in subsidy pool tracking


### Requirement 19: Fee Scaling Configuration

**User Story:** As a pool administrator, I want to configure fee scaling parameters for each pool, so that I can optimize the toxicity tax for different market conditions.

#### Acceptance Criteria

1. THE Hook SHALL store configurable fee scaling parameters including base multiplier, maximum multiplier, and deviation threshold per pool
2. THE Hook SHALL provide an administrative function to update fee scaling parameters for registered pools
3. WHEN fee scaling parameters are updated, THE Hook SHALL validate that maximum multiplier is greater than or equal to base multiplier
4. WHEN fee scaling parameters are updated, THE Hook SHALL validate that deviation threshold is within reasonable bounds to prevent misclassification
5. THE Hook SHALL emit an event when fee scaling parameters are modified including the pool identifier and new parameter values

### Requirement 20: Oracle Configuration and Updates

**User Story:** As a pool administrator, I want to update oracle addresses for pools, so that I can switch to better price feeds or recover from oracle failures.

#### Acceptance Criteria

1. THE Hook SHALL store oracle contract addresses per pool or per token pair
2. THE Hook SHALL provide an administrative function to update the oracle address for a given pool
3. WHEN an oracle address is updated, THE Hook SHALL validate that the new oracle implements the IOracle interface
4. WHEN an oracle address is updated, THE Hook SHALL emit an event containing the pool identifier, old oracle address, and new oracle address
5. THE Hook SHALL allow setting an oracle address to zero to disable directional fee scaling for a specific pool


### Requirement 21: Vault Configuration

**User Story:** As a pool administrator, I want to configure external vault addresses for yield generation, so that I can select secure and high-performing yield sources.

#### Acceptance Criteria

1. THE Hook SHALL store vault addresses for token0 and token1 per pool
2. THE Hook SHALL provide an administrative function to set or update vault addresses for a pool
3. WHEN a vault address is set, THE Hook SHALL validate that the vault implements the IExternalVault interface
4. WHEN a vault address is set, THE Hook SHALL validate that the vault's underlying asset matches the corresponding pool token
5. THE Hook SHALL emit an event when vault addresses are configured including pool identifier, token address, and vault address

### Requirement 22: Administrative Access Control

**User Story:** As a security-conscious deployer, I want administrative functions to be restricted to authorized addresses, so that malicious actors cannot misconfigure the hook.

#### Acceptance Criteria

1. THE Hook SHALL maintain an owner or admin address with exclusive access to configuration functions
2. WHEN an administrative function is called, THE Hook SHALL verify the caller is the authorized admin address
3. IF an unauthorized address calls an administrative function, THEN THE Hook SHALL revert with an access denied error
4. THE Hook SHALL provide a function to transfer administrative control to a new address
5. WHEN administrative control is transferred, THE Hook SHALL emit an event with the old and new admin addresses


### Requirement 23: Event Emission for Directional Fee Application

**User Story:** As an analytics platform, I want events emitted when directional fees are applied, so that I can track toxic flow patterns and fee revenue.

#### Acceptance Criteria

1. WHEN a swap triggers directional fee scaling, THE Hook SHALL emit an event containing pool identifier, swap direction, price deviation, and applied fee multiplier
2. THE event SHALL include both the oracle price and pool price at the time of the swap
3. THE event SHALL indicate whether the swap was classified as Toxic_Flow or benign flow
4. THE event SHALL include the calculated fee amount collected from the directional scaling
5. THE Hook SHALL emit events efficiently to avoid excessive gas consumption in the swap path

### Requirement 24: Event Emission for Capital Sweeps

**User Story:** As a keeper, I want events emitted when capital is swept to external vaults, so that I can monitor sweep success and optimize timing.

#### Acceptance Criteria

1. WHEN sweepIdleCapital successfully deposits capital to external vaults, THE Hook SHALL emit an event containing pool identifier, token addresses, amounts deposited, and vault addresses
2. THE event SHALL include the vault share tokens received in exchange for the deposited capital
3. THE event SHALL include the caller address that triggered the sweep
4. THE event SHALL include a timestamp for tracking sweep frequency and patterns
5. IF a sweep operation fails, THEN THE Hook SHALL emit a separate event indicating the failure reason


### Requirement 25: Event Emission for IL Subsidy Distribution

**User Story:** As an LP, I want events emitted when I receive IL subsidies, so that I can verify the compensation amount and subsidy pool state.

#### Acceptance Criteria

1. WHEN IL subsidy is distributed during liquidity removal, THE Hook SHALL emit an event containing LP address, pool identifier, IL amount, and subsidy amount distributed
2. THE event SHALL include the remaining subsidy pool balance after distribution
3. THE event SHALL indicate whether the subsidy fully covered the IL or was a partial payment
4. THE event SHALL include both token0 and token1 amounts for the subsidy distribution
5. IF no subsidy is available despite positive IL, THEN THE Hook SHALL emit an event indicating zero distribution with the IL amount that went uncompensated

### Requirement 26: Reentrancy Protection

**User Story:** As a security auditor, I want critical state-changing functions protected against reentrancy, so that the hook cannot be exploited via callback attacks.

#### Acceptance Criteria

1. THE Hook SHALL implement reentrancy guards on sweepIdleCapital, redeemLockedCapital, and administrative functions
2. WHEN a guarded function is entered, THE Hook SHALL set a lock flag preventing reentrant calls
3. IF a reentrant call is detected, THEN THE Hook SHALL revert with a reentrancy error
4. WHEN a guarded function completes or reverts, THE Hook SHALL clear the lock flag
5. THE Hook SHALL use OpenZeppelin's ReentrancyGuard or equivalent battle-tested implementation


### Requirement 27: Integer Overflow Protection

**User Story:** As a security auditor, I want all arithmetic operations to be protected against overflow and underflow, so that accounting remains accurate under extreme conditions.

#### Acceptance Criteria

1. THE Hook SHALL use Solidity 0.8.26 or higher to leverage built-in overflow/underflow protection
2. THE Hook SHALL explicitly handle cases where multiplication or division could exceed type bounds before performing operations
3. WHEN calculating fee multipliers and price deviations, THE Hook SHALL validate intermediate results fit within uint256 bounds
4. WHEN tracking subsidy pool balances, THE Hook SHALL validate that additions and subtractions do not cause accounting errors
5. THE Hook SHALL use SafeMath equivalents or checked arithmetic for all financial calculations

### Requirement 28: Price Manipulation Resistance

**User Story:** As an LP, I want the hook to be resistant to price manipulation attacks, so that malicious actors cannot drain subsidy pools or exploit fee scaling.

#### Acceptance Criteria

1. THE Hook SHALL use time-weighted average prices or manipulation-resistant oracles for directional fee calculations
2. THE Hook SHALL implement minimum delay requirements between oracle price updates to prevent flash loan price manipulation
3. WHEN calculating IL, THE Hook SHALL use sufficiently long time windows to prevent single-block manipulation
4. THE Hook SHALL validate that oracle prices are within reasonable bounds compared to recent historical prices
5. IF oracle price deviates by more than a configured threshold from recent averages, THEN THE Hook SHALL treat the oracle as compromised and disable directional scaling


### Requirement 29: Gas Limit Safety for External Calls

**User Story:** As a trader, I want external oracle and vault calls to have gas limits, so that malicious or buggy external contracts cannot cause transaction failures.

#### Acceptance Criteria

1. WHEN calling external oracle contracts, THE Hook SHALL limit the gas forwarded to prevent griefing attacks
2. WHEN calling external vault contracts, THE Hook SHALL limit the gas forwarded to prevent denial-of-service attacks
3. IF an external call consumes all allocated gas and reverts, THEN THE Hook SHALL handle the failure gracefully with fallback behavior
4. THE Hook SHALL configure gas limits as adjustable parameters per external contract type
5. THE Hook SHALL emit events when external calls fail due to gas limits for monitoring and debugging

### Requirement 30: Subsidy Pool Initialization

**User Story:** As a pool deployer, I want subsidy pools to be initialized automatically when pools are created, so that yield accumulation can begin immediately.

#### Acceptance Criteria

1. WHEN beforeInitialize is invoked for a new pool, THE Hook SHALL create an IL_Subsidy_Pool accounting structure for that pool
2. THE subsidy pool SHALL be initialized with zero balance for both token0 and token1
3. THE Hook SHALL initialize tracking structures for individual LP contributions to the subsidy pool
4. THE Hook SHALL initialize vault deposit tracking with zero deposited amounts
5. THE Hook SHALL emit an event when a subsidy pool is initialized containing the pool identifier


### Requirement 31: LP Position Tracking

**User Story:** As the hook mechanism, I want to track LP deposit ratios and timestamps, so that I can accurately calculate IL for each position.

#### Acceptance Criteria

1. WHEN an LP adds liquidity to a pool with this hook, THE Hook SHALL record the initial token0 and token1 amounts deposited
2. THE Hook SHALL record the pool price (sqrtPriceX96) at the time of liquidity addition
3. THE Hook SHALL record the tick range for each LP position
4. THE Hook SHALL maintain a mapping of LP addresses to their position data per pool
5. THE Hook SHALL update position data when LPs modify their liquidity (add or remove)

### Requirement 32: Multi-Pool Support

**User Story:** As a protocol integrator, I want a single hook contract to support multiple pools, so that I can minimize deployment overhead and simplify management.

#### Acceptance Criteria

1. THE Hook SHALL support registration of multiple pool instances with unique PoolKey identifiers
2. THE Hook SHALL maintain separate configuration, subsidy pools, and accounting for each registered pool
3. WHEN processing callbacks, THE Hook SHALL correctly identify which pool is calling based on PoolKey or PoolId parameters
4. THE Hook SHALL prevent configuration updates from one pool affecting other pools
5. THE Hook SHALL provide view functions that return all registered pools


### Requirement 33: Emergency Pause Mechanism

**User Story:** As a risk manager, I want to pause hook operations in case of detected vulnerabilities or external failures, so that I can protect user funds during incidents.

#### Acceptance Criteria

1. THE Hook SHALL implement a pause mechanism that disables non-critical operations while allowing liquidity removal
2. WHEN paused, THE Hook SHALL disable sweepIdleCapital and redeemLockedCapital functions
3. WHEN paused, THE Hook SHALL continue to allow beforeSwap with directional fee scaling disabled (baseline fees only)
4. WHEN paused, THE Hook SHALL continue to allow beforeRemoveLiquidity with IL subsidy distribution disabled
5. THE Hook SHALL provide administrative functions to pause and unpause operations with appropriate access control

### Requirement 34: Vault Share Token Accounting

**User Story:** As the hook mechanism, I want to track vault share tokens separately from principal, so that I can accurately calculate accrued yield.

#### Acceptance Criteria

1. WHEN depositing to external vaults, THE Hook SHALL record the number of vault share tokens received
2. THE Hook SHALL maintain a mapping of vault addresses to share token balances per pool
3. WHEN calculating available yield, THE Hook SHALL query the vault's conversion rate from shares to underlying assets
4. THE Hook SHALL calculate yield as the difference between current share value and initial deposited principal
5. THE Hook SHALL account for vault share token appreciation when determining subsidy pool balances


### Requirement 35: Minimum Sweep Threshold

**User Story:** As a gas optimizer, I want capital sweeps to only occur when idle amounts exceed a threshold, so that small sweeps don't waste gas relative to yield generated.

#### Acceptance Criteria

1. THE Hook SHALL define a minimum idle capital threshold per token below which sweeps are not economical
2. WHEN sweepIdleCapital is called, THE Hook SHALL check if idle capital exceeds the minimum threshold
3. IF idle capital is below the threshold, THEN THE Hook SHALL revert with an informative error or return without executing the sweep
4. THE Hook SHALL allow configuration of minimum sweep thresholds per pool or globally
5. THE Hook SHALL account for gas costs and expected yield rates when determining economical sweep thresholds

### Requirement 36: Claim Token Metadata

**User Story:** As an LP holding claim tokens, I want to query claim token metadata, so that I understand what vaults and amounts my tokens represent.

#### Acceptance Criteria

1. THE Hook SHALL implement ERC-1155 metadata functions that return claim token details
2. WHEN querying a claim token ID, THE Hook SHALL return the associated vault address, pool identifier, and token type
3. THE Hook SHALL provide a function to query the total locked amount for a specific claim token ID
4. THE Hook SHALL provide a function to check if a claim token is redeemable based on current vault liquidity
5. THE Hook SHALL emit standard ERC-1155 URI events when claim tokens are minted


### Requirement 37: Compatibility with Solidity 0.8.26

**User Story:** As a developer, I want the hook to compile with Solidity 0.8.26, so that it uses the specified compiler version with latest security features.

#### Acceptance Criteria

1. THE Hook SHALL declare `pragma solidity ^0.8.26` at the top of all Solidity source files
2. THE Hook SHALL use language features compatible with Solidity 0.8.26
3. THE Hook SHALL compile without errors using the Solidity 0.8.26 compiler
4. THE Hook SHALL use custom errors (introduced in 0.8.4) instead of revert strings for gas efficiency
5. THE Hook SHALL leverage built-in overflow checking available in 0.8.x versions

### Requirement 38: Integration with Uniswap v4 Core

**User Story:** As a Uniswap v4 user, I want the hook to correctly integrate with v4 core contracts, so that pool operations function as expected.

#### Acceptance Criteria

1. THE Hook SHALL inherit from BaseHook provided by @uniswap/v4-periphery
2. THE Hook SHALL correctly implement the IHooks interface callback signatures
3. THE Hook SHALL use PoolKey, BalanceDelta, and BeforeSwapDelta types from @uniswap/v4-core
4. THE Hook SHALL interact with PoolManager using the correct function signatures for take, settle, and unlock operations
5. THE Hook SHALL return proper selector values from all implemented callbacks to satisfy v4 validation


### Requirement 39: NatSpec Documentation

**User Story:** As a developer reading the code, I want comprehensive NatSpec comments, so that I understand the mathematical accounting and flash accounting mechanisms.

#### Acceptance Criteria

1. THE Hook SHALL include NatSpec `@notice` comments for all public and external functions describing their purpose
2. THE Hook SHALL include NatSpec `@param` comments for all function parameters explaining their meaning
3. THE Hook SHALL include NatSpec `@return` comments for functions with return values
4. THE Hook SHALL include detailed comments explaining mathematical formulas for IL calculation, fee scaling curves, and yield accounting
5. THE Hook SHALL include comments explaining the flash accounting unlock/lock flow in capital sweep operations

### Requirement 40: View Functions for Off-Chain Queries

**User Story:** As a frontend developer, I want view functions to query hook state, so that I can display relevant information to users without transactions.

#### Acceptance Criteria

1. THE Hook SHALL provide a view function to query the current fee multiplier that would apply to a hypothetical swap
2. THE Hook SHALL provide a view function to query an LP's current claimable IL subsidy amount
3. THE Hook SHALL provide a view function to query the total subsidy pool balance for a pool
4. THE Hook SHALL provide a view function to query total idle capital available for sweeping in a pool
5. THE Hook SHALL provide a view function to query an LP's position data including initial deposit amounts and tick range
