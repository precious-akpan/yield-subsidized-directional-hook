# Tasks Update Summary

## Date
June 14, 2026

## Changes Made

Updated `tasks.md` to add new implementation tasks addressing the automation design limitation discovered in Task 24.

## New Tasks Added

### Task 25: Implement off-chain position indexer (Solution 4) - RECOMMENDED
The recommended production solution for automated capital sweeps.

**Subtasks:**
- **25.1** - Create The Graph subgraph for position tracking
  - Track LP positions via ModifyLiquidity events
  - Provide queries for active positions per pool
  
- **25.2** - Create keeper service for automated sweeps
  - Monitor IdleCapitalDetected events
  - Query subgraph for position data
  - Call sweepIdleCapital with complete position arrays
  
- **25.3** - Create SweeperHelper utility contract
  - Reduce caller burden by querying liquidity amounts
  - Provide preview functions for idle capital
  
- **25.4** - Document automation architecture
  - Explain hybrid on-chain/off-chain design
  - Document setup and configuration
  - Note future improvements

### Task 26: Optional alternative automation solutions
Exploration of alternative approaches for future consideration.

**Subtasks:**
- **26.1*** - Implement hook position registry (Solution 3)
  - Track positions in hook storage
  - Measure gas cost impact
  
- **26.2*** - Create Uniswap v4 enhancement proposal (Solution 1)
  - Draft governance proposal for PoolManager.getPoolPositions()
  - Document benefits and reference implementation

### Task 27: Final checkpoint
Updated final checkpoint to include automation verification.

## Rationale

### The Problem
Task 24 integration tests revealed a design limitation:

```solidity
// Current signature - requires position arrays
function sweepIdleCapital(
    PoolKey calldata key,
    int24[] calldata tickLowers,      // ❌ Not available to automation
    int24[] calldata tickUppers,      // ❌ Not available to automation
    uint128[] calldata liquidityAmounts // ❌ Not available to automation
) external
```

The `IdleCapitalDetected` event doesn't include position data, and Uniswap v4's PoolManager doesn't expose position enumeration.

### The Solution
**Task 25** implements the recommended hybrid approach:
- **Off-chain**: The Graph subgraph indexes LP positions
- **On-chain**: Keeper service calls sweep with position data
- **Standard pattern**: Used by Aave, Compound, and other major DeFi protocols

### Why This Approach?
1. **Zero gas overhead** - No storage costs for LPs
2. **Works today** - No protocol changes needed
3. **Scalable** - Indexer handles data off-chain
4. **Proven** - Industry-standard automation pattern

### Future Improvements
**Task 26** explores long-term alternatives:
- **Solution 3**: Hook tracks positions (expensive but fully on-chain)
- **Solution 1**: Protocol enhancement (ideal but requires v4 changes)

## Task Dependencies

New tasks added to dependency graph:
- **Wave 25**: Tasks 25.1, 25.2, 25.3 (parallel execution)
- **Wave 26**: Tasks 25.4, 26.1, 26.2 (parallel execution)

Wave 25 depends on Wave 24 (integration tests completion).

## Documentation Added

### New Files
1. `AUTOMATION_DESIGN_SOLUTIONS.md` - Detailed analysis of 4 solutions
2. `TASKS_UPDATE_SUMMARY.md` - This summary

### Updated Files
1. `tasks.md` - Added Tasks 25-27 and updated notes

## Implementation Priority

### High Priority (MVP)
- ✅ Task 25.1 - The Graph subgraph
- ✅ Task 25.2 - Keeper service
- ✅ Task 25.4 - Documentation

### Medium Priority (Production)
- ⚠️ Task 25.3 - SweeperHelper utility

### Low Priority (Research)
- 🔬 Task 26.1 - Hook position registry exploration
- 🔬 Task 26.2 - v4 enhancement proposal

## Next Steps

1. **Review** the automation design solutions document
2. **Decide** which tasks to implement for the hackathon
3. **Execute** Task 25 subtasks for MVP automation
4. **Document** the hybrid architecture decision

## References

- `AUTOMATION_DESIGN_SOLUTIONS.md` - Full solution analysis
- `TASK_24_COMPLETION.md` - Integration test completion report
- `test/integration/AutomatedSweeps.t.sol` - Integration tests with mock
- `.kiro/specs/yield-subsidized-directional-hook/tasks.md` - Updated task list

## Questions to Consider

1. **For hackathon**: Do we implement the full indexer + keeper (Task 25)?
2. **For demo**: Is the mock automation in tests sufficient to show the mechanism?
3. **For production**: Should we also build SweeperHelper (Task 25.3) for manual sweeps?
4. **For future**: Should we contribute Task 26.2 proposal to Uniswap governance?

## Impact Assessment

### Gas Costs
- **Current approach**: No additional gas for LPs ✅
- **Solution 3 (Task 26.1)**: +40k gas per LP operation ❌
- **Solution 1 (Task 26.2)**: No additional gas (ideal) ✅

### Decentralization
- **Current approach**: Requires keeper infrastructure ⚠️
- **Future enhancement**: Fully on-chain with v4 changes ✅

### Feasibility
- **Task 25 (indexer)**: Implementable today ✅
- **Task 26.1 (registry)**: Implementable but expensive ⚠️
- **Task 26.2 (protocol)**: Requires governance approval ⏳

## Conclusion

The task list has been updated to reflect a **pragmatic path forward**:

1. **Short-term**: Implement off-chain indexer + keeper (Task 25)
2. **Long-term**: Advocate for protocol enhancement (Task 26.2)
3. **Alternative**: Document position registry approach (Task 26.1)

This ensures the hook can be automated in production while acknowledging the design trade-offs and future improvement opportunities.
