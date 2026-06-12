# Contributing to Yield-Subsidized Directional Hook

Thank you for your interest in contributing! We welcome contributions from the community.

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (latest version)
- Node.js v18+ (for tooling)
- Git

### Setup

```bash
# Clone the repository
git clone https://github.com/precious-akpan/yield-subsidized-directional-hook.git
cd yield-subsidized-directional-hook

# Install dependencies
forge install

# Build contracts
forge build

# Run tests
forge test
```

## 🔍 Development Workflow

### Before You Start

1. **Check existing issues** to avoid duplicate work
2. **Open an issue** to discuss major changes before implementing
3. **Fork the repository** and create a feature branch

### Branch Naming Convention

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation updates
- `test/description` - Test improvements
- `refactor/description` - Code refactoring

### Making Changes

1. **Create a branch** from `main`
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Write clean, well-documented code**
   - Follow Solidity style guide
   - Add NatSpec comments for all public functions
   - Keep functions focused and testable

3. **Add tests** for new functionality
   - Unit tests for individual functions
   - Integration tests for feature flows
   - Aim for >95% coverage

4. **Run tests locally**
   ```bash
   forge test
   forge test --gas-report
   ```

5. **Format your code**
   ```bash
   forge fmt
   ```

## 📝 Code Style

### Solidity Guidelines

- **Solidity Version**: 0.8.26+
- **Naming**:
  - Contracts: `PascalCase`
  - Functions: `camelCase`
  - Constants: `SCREAMING_SNAKE_CASE`
  - Private/Internal: prefix with `_`


- **Documentation**:
  - All public functions must have NatSpec
  - Include `@notice`, `@param`, `@return` tags
  - Document error conditions with `@dev`

- **Gas Optimization**:
  - Use `calldata` for read-only array parameters
  - Cache storage variables in memory
  - Use packed structs where possible

### Example

```solidity
/// @notice Calculates available yield from vault
/// @dev Returns 0 if vault has no shares or experienced loss
/// @param poolId The unique identifier of the pool
/// @param isToken0 True for token0, false for token1
/// @return availableYield The amount of yield available for distribution
function calculateAvailableYield(
    PoolId poolId,
    bool isToken0
) external view returns (uint256 availableYield) {
    // Implementation
}
```

## ✅ Testing Requirements

### Test Coverage

- **Unit Tests**: Test individual functions in isolation
- **Integration Tests**: Test complete workflows
- **Security Tests**: Test access control and attack vectors
- **Gas Tests**: Benchmark gas usage for critical operations

### Running Tests

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/unit/CapitalSweep.t.sol

# Run with verbosity
forge test -vvv

# Run with gas reporting
forge test --gas-report

# Run with coverage
forge coverage
```


### Test Organization

```
test/
├── unit/           # Individual function tests
├── integration/    # End-to-end workflow tests
├── security/       # Access control and attack tests
├── mocks/          # Mock contracts for testing
└── helpers/        # Test utility functions
```

## 🔒 Security

### Reporting Vulnerabilities

**DO NOT** open public issues for security vulnerabilities.

Instead, email: **security@precious-akpan.dev**

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will respond within 48 hours and keep you updated on the fix timeline.

### Security Best Practices

- All external calls must use try-catch
- All state-changing functions must have reentrancy protection
- Oracle prices must be validated for staleness
- Gas limits must be set on external calls
- Access control must be enforced on admin functions

## 📬 Pull Request Process

### Before Submitting

- [ ] Code builds without errors (`forge build`)
- [ ] All tests pass (`forge test`)
- [ ] Code is formatted (`forge fmt`)
- [ ] New tests added for new functionality
- [ ] Documentation updated (README, inline comments)
- [ ] No merge conflicts with `main`

### PR Description Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] All tests passing

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] No new warnings generated
```


### Review Process

1. **Automated checks** run on every PR (CI/CD)
2. **Code review** by maintainers (1-2 business days)
3. **Revisions** if requested
4. **Merge** once approved

## 🎯 Areas for Contribution

### High Priority

- Gas optimization improvements
- Additional test coverage
- Documentation improvements
- Security hardening
- Integration examples

### Feature Ideas

- Multi-oracle support (aggregate multiple price sources)
- Advanced fee curves (exponential, sigmoid)
- LP position NFT integration
- Cross-pool yield sharing
- Governance system

### Good First Issues

Look for issues labeled `good-first-issue` in the issue tracker.

## 💬 Communication

- **GitHub Issues**: Bug reports, feature requests
- **GitHub Discussions**: Questions, ideas, feedback
- **Pull Requests**: Code contributions

## 📜 Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors.

### Our Standards

**Positive behavior includes**:
- Using welcoming and inclusive language
- Being respectful of differing viewpoints
- Gracefully accepting constructive criticism
- Focusing on what's best for the community

**Unacceptable behavior includes**:
- Trolling, insulting/derogatory comments
- Public or private harassment
- Publishing others' private information
- Other conduct which could reasonably be considered inappropriate

### Enforcement

Instances of unacceptable behavior may be reported to security@precious-akpan.dev.
All complaints will be reviewed and investigated promptly and fairly.


## 🏆 Recognition

Contributors will be:
- Listed in README.md acknowledgments
- Credited in release notes
- Considered for future roles/opportunities

## 📚 Resources

- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4)
- [Foundry Book](https://book.getfoundry.sh/)
- [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- [Reactive Network Docs](https://docs.reactive.network)

## 📄 License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to making Uniswap V4 LP-protective! 🚀
