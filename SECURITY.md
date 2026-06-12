# Security Policy

## 🔒 Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security issue, please follow responsible disclosure practices.

### **DO NOT** open a public GitHub issue for security vulnerabilities.

Instead, please email: **security@precious-akpan.dev**

### What to Include

Your report should include:

1. **Description** of the vulnerability
2. **Steps to reproduce** the issue
3. **Potential impact** assessment
4. **Affected versions** (if applicable)
5. **Suggested fix** (optional but appreciated)
6. **Your contact information** for follow-up

### Response Timeline

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity (24 hours to 30 days)

## 🛡️ Security Measures

### Current Protections

- ✅ OpenZeppelin ReentrancyGuard on all external functions
- ✅ Access control validation (onlyPoolManager for callbacks)
- ✅ Oracle staleness checks and price validation
- ✅ Try-catch blocks on all external vault calls
- ✅ Gas limits on external calls (150k gas)
- ✅ Solidity 0.8.26+ with checked arithmetic
- ✅ Comprehensive test coverage (171 tests)

### Known Limitations

1. **Oracle Dependency**: Hook behavior relies on external oracle availability
2. **Vault Risk**: External ERC-4626 vault failures can temporarily lock capital
3. **LP Tracking**: Simplified single-position-per-LP model

## 🔍 Audit Status

**Status**: Pre-audit

This contract has not yet undergone a formal security audit. Use in production at your own risk.

**Planned**: Q3 2026 - External audit with reputable security firm

## 🏆 Bug Bounty

Bug bounty program details coming soon after mainnet deployment.

## 📋 Security Checklist

When reviewing this codebase for security:

- [ ] Reentrancy protection on state-changing functions
- [ ] Access control enforcement
- [ ] Oracle manipulation resistance
- [ ] Vault failure handling (claim token fallback)
- [ ] Integer overflow/underflow protection
- [ ] Gas griefing mitigation
- [ ] Front-running considerations
- [ ] Emergency pause functionality

## 🔗 Security Resources

- [OpenZeppelin Security Audits](https://blog.openzeppelin.com/security-audits)
- [Smart Contract Security Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [Uniswap V4 Security Considerations](https://docs.uniswap.org/contracts/v4/overview)

## 📞 Contact

For security concerns: security@precious-akpan.dev

For general questions: GitHub Issues or Discussions

---

**Last Updated**: June 12, 2026
