# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-01-01

### Added
- Initial release of Shopify PR Theme Preview Action
- Automatic theme deployment for pull requests
- Smart theme updates that preserve settings
- Settings pulling from live or custom source theme
- Preview URL generation and PR comments
- Automatic cleanup on PR close/merge
- Support for custom build commands
- Concurrency control to prevent overlapping deployments
- Security features including PR title sanitization
- Comprehensive examples for different use cases
- Support for monorepos and subdirectories
- Node.js version configuration
- Detailed documentation and troubleshooting guide

### Security
- Sanitized PR titles to prevent command injection
- Minimal permission scope requirements
- Protected against malicious inputs
- Support for fork protection in workflows

## [Unreleased]

### Changed
- Simplified action configuration - removed pr-number requirement
- Now uses PR title directly as theme name for better clarity
- Consolidated documentation - merged SETUP.md into README.md
- Reduced example files to single comprehensive example.yml
- Simplified package.json by removing unnecessary scripts
- Streamlined test workflow to focus on essential checks
- Updated scripts to use PR title-based theme identification

### Removed
- Removed separate SETUP.md file (content merged into README.md)
- Removed CONTRIBUTING.md for simplicity
- Removed multiple example files (basic.yml, advanced.yml, with-build.yml)
- Removed unnecessary linting scripts from package.json

### Planned
- Support for multiple theme deployments per PR
- Theme performance metrics in PR comments
- Automatic theme check integration
- Support for theme preview passwords
- Webhook notifications for deployment status
- Theme diff visualization
- Support for theme migrations
- Automated testing suite
