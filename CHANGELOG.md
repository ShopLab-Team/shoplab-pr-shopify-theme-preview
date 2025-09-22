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

## [1.0.1] - 2025-09-22

### Fixed
- **Critical Fix**: Theme cleanup on retry - when theme creation fails with Liquid errors, the failed theme is now properly deleted before retrying, preventing multiple duplicate themes from being created
- **Critical Fix**: Liquid validation errors no longer trigger retries - the script now detects validation errors (e.g., "can't be greater than", "must be") and stops immediately instead of retrying 3 times
- **Critical Fix**: Themes created with errors are now immediately cleaned up to prevent orphaned themes accumulating in the store
- Failed themes are now always cleaned up after max retries to prevent orphaned themes
- Clear error messaging when cleanup fails to prevent confusion
- **Slack Formatting**: Fixed broken formatting in Slack notifications - removed box drawing characters that don't render properly in Slack
- **Slack Formatting**: Error messages in both Slack and PR comments are now cleaned and formatted properly
- Error messages are now formatted with bullet points for better readability in Slack

## [Unreleased]

### Added
- Automatic theme limit management for Shopify's 20-theme limit
- Auto-deletion of oldest themes when hitting limit (sorted by last update time)
- `preserve-theme` label to protect themes from auto-deletion
- `rebuild-theme` label to recreate deleted themes
- `no-sync` label to skip pulling settings from production/source theme
- Retry logic with automatic cleanup when theme creation fails
- Notification comments when themes are auto-removed
- **Error Reporting**: Shopify errors are now posted as PR comments for visibility
- **Slack Integration**: Optional Slack webhook notifications for initial deployments and errors (not updates)
- **Improved Retry Logic**: When uploads fail, retries use the same theme ID instead of creating duplicates
- **No-Sync Mode**: Skip pulling production settings during initial theme creation (updates always preserve settings)

### Changed
- Simplified action configuration - removed pr-number requirement
- Now uses PR title directly as theme name for better clarity
- Consolidated documentation - merged SETUP.md into README.md
- Reduced example files to single comprehensive example.yml
- Simplified package.json by removing unnecessary scripts
- Streamlined test workflow to focus on essential checks
- Updated scripts to use PR title-based theme identification
- Workflow now responds to 'labeled' events for theme rebuilding

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
- Theme diff visualization
- Support for theme migrations
- Automated testing suite
