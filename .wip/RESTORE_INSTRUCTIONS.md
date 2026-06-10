# Restore Instructions for Reactive Network Automation

## Quick Start (When Implementing Tasks 21-24)

```bash
# Move automation contracts back to src/
mv .wip/automation src/

# Verify structure
ls -la src/automation/
# Should show:
# - ReactiveKeeperCallback.sol
# - ReactiveSubscriber.sol
```

## What to Fix

### 1. Update AbstractReactive Interface Usage

**Old signature (current code):**
```solidity
function react(
    uint256[] calldata _topics,
    bytes calldata _data,
    uint256 _origin,
    address _sender
) external override
```

**New signature (Reactive Network SDK):**
```solidity
function react(LogRecord calldata log) external;
```

### 2. Update Constructor

**Old:**
```solidity
constructor(ISystemContract _service) AbstractReactive(_service) {
```

**New:** Check AbstractReactive base class for current constructor signature.

### 3. Fix Type Conversions

- Change `msg.sender != service` comparisons
- Handle `ISystemContract` to address conversions
- Update `IReactive` interface calls

## Testing After Restore

```bash
# Should compile without errors
forge build

# Run automation tests
forge test --match-contract "Reactive"
```

## Checklist Before Merging

- [ ] All automation contracts compile successfully
- [ ] Unit tests for ReactiveKeeperCallback pass (task 21.5)
- [ ] Unit tests for ReactiveSubscriber pass (task 21.5)
- [ ] Integration tests for automated sweeps pass (tasks 24.1-24.4)
- [ ] Deployment script works (task 23.1)

## Reference

- Spec tasks: 21.1 - 24.4
- Reactive Network docs: Check latest SDK documentation
- Current status: Tasks 1-7 complete, automation deferred
