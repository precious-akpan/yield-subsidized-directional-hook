# Work-in-Progress Automation Contracts

This directory contains Reactive Network automation contracts (tasks 21-24) that are temporarily excluded from compilation.

## Why These Are Here

The Reactive Network integration has compilation errors that need to be addressed when implementing tasks 21-24:
- `ReactiveKeeperCallback.sol` - Automated capital sweep triggering
- `ReactiveSubscriber.sol` - Event monitoring and forwarding

## Issues to Fix (Tasks 21-24)

1. **Interface Mismatch**: `AbstractReactive` interface has changed
   - Current code uses old signature with multiple parameters
   - Need to update to match `react(LogRecord calldata log)` signature

2. **Constructor Parameters**: `AbstractReactive` constructor signature changed
   - Currently passing `_service` parameter
   - Need to update to match new base class

3. **Type Conversions**: Service contract type handling
   - `ISystemContract` comparison issues
   - Address vs contract type conversions

## When to Re-Enable

Move these files back to `src/automation/` when starting:
- Task 21.1: Create IYieldSubsidizedDirectionalHook interface
- Task 21.2: Implement ReactiveKeeperCallback contract
- Task 21.3: Implement ReactiveSubscriber contract

## Current Status

Tasks 1-7 (swap fee mechanism) are complete and all tests passing.
Next up: Task 8 (idle capital detection).

Reactive Network automation will be implemented in tasks 21-24.
