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

## [1.1.3] - 2025-09-22

### Fixed
- **CRITICAL**: Completely removed ALL retry logic from upload_theme function
- Fixed multiple "local: can only be used in a function" errors in deploy.sh
- Fixed theme ID contamination where debug messages were included in the ID
- Theme uploads now fail immediately on error with NO RETRIES as requested

## [1.1.2] - 2025-09-22

### Fixed
- Removed JavaScript/Node.js from Slack notification payload generation
- Replaced complex Node.js eval with simple bash JSON string concatenation
- Fixed theme detection function output (debug to stderr, result to stdout)
- Added theme name listing in debug output for better troubleshooting
- Fixed "status is not defined" JavaScript error in Slack notifications

## [1.1.0] - 2025-09-22

### Changed
- **MAJOR REFACTORING**: Modularized deploy.sh into smaller, focused components
- Split 1300-line monolithic script into:
  - Main deploy.sh: 361 lines (core orchestration logic)
  - lib/common.sh: 154 lines (utilities and JSON parsing)
  - lib/github.sh: 117 lines (GitHub API functions)
  - lib/slack.sh: 100 lines (Slack notifications)
  - lib/theme.sh: 445 lines (theme management)
- Improved maintainability and code organization
- Functions are now properly exported for reusability
- Easier to test individual components
- Fixed remaining syntax errors from previous versions

## [1.0.9] - 2025-09-22

### Fixed
- **CRITICAL**: Fixed extract_json_value function to properly read from stdin
- **CRITICAL**: Fixed theme name sanitization - brackets are no longer stripped
- **CRITICAL**: Removed retry logic that was creating duplicate themes
- Added manual theme ID extraction as fallback when JSON parsing fails
- Ensured immediate cleanup of themes created with errors
- Only retry for rate limit errors (with 30s delay), not validation errors

### Changed
- create_theme_with_retry now only retries for rate limits, not validation errors
- Theme names preserve brackets and special characters (only whitespace is trimmed)

## [1.0.8] - 2025-09-22

### Fixed
- **CRITICAL**: Fixed bash syntax error - removed 'local' keyword outside function
- Script was failing immediately on line 922

## [1.0.7] - 2025-09-22

### Security & Performance Improvements
- **Security**: Fixed potential code injection vulnerability in JSON parsing
- **Security**: Added proper shell escaping for all variables used in JavaScript
- **Performance**: Added parallel API calls to reduce execution time
- **Performance**: Added caching for theme list to avoid duplicate API calls

### Fixed
- **Fixed**: Added timeout handling for all API calls (GitHub and Slack)
- **Fixed**: Improved error handling with retry logic and exponential backoff
- **Fixed**: Better handling of empty or special character PR titles
- **Fixed**: Added rate limit detection and automatic retry for GitHub API

### Changed
- Refactored JSON parsing to use safe, predefined extraction patterns
- Added `extract_json_value` function for common JSON operations
- Improved theme name sanitization with multiple fallback strategies
- All curl commands now have proper timeout settings

## [1.0.6] - 2025-09-22

### Fixed
- **CRITICAL**: Removed all `jq` dependencies - now uses native Node.js for JSON parsing
- **Fixed**: Handles both array and object JSON responses from Shopify CLI
- **Fixed**: No longer fails when `jq` is not installed on the server

### Changed
- All JSON parsing now uses Node.js which is guaranteed to be available
- More robust JSON handling for different Shopify API response formats
- Removed external dependency on `jq` command-line tool

## [1.0.5] - 2025-09-22

### Fixed
- **Critical**: Fixed theme marker extraction to always use most recently CREATED theme
- **Fixed**: Multiple theme IDs in comments now handled correctly
- **Fixed**: Uses `created_at` timestamp instead of `updated_at` to avoid picking old themes from edited comments
- **Added**: Debug logging to show how many theme markers were found and which was selected

### Changed
- Theme marker extraction now collects all markers and sorts by creation time
- Always selects the most recently created theme, not the most recently edited comment
- Better logging to track which theme ID is being selected from multiple markers

## [1.0.4] - 2025-09-22

### Fixed
- **Critical**: Added theme existence verification before attempting updates
- **Critical**: Handle case where theme is manually deleted from store
- **Fixed**: Properly handle `rebuild-theme` label to pull fresh settings
- **Fixed**: Add detailed error logging for theme update failures
- **Fixed**: Create new theme when referenced theme no longer exists

### Changed
- Theme updates now verify the theme exists before attempting to update
- When theme doesn't exist, automatically fall back to creating new one
- `rebuild-theme` label now properly pulls fresh settings for existing themes
- Added comprehensive error detection for missing themes (404 errors)

## [1.0.3] - 2025-09-22

### Fixed
- **Cleanup**: Removed non-working `extract_theme_cli_json` function, now using direct JSON extraction
- **Fixed**: Slack notification newline formatting now works properly
- **Simplified**: JSON extraction is now more reliable and straightforward

### Changed
- JSON extraction from Shopify CLI output is now done directly with grep
- Removed unnecessary complexity in JSON parsing

## [1.0.2] - 2025-09-22

### Fixed
- **CRITICAL FIX**: Properly parse Shopify CLI JSON output when using --json flag
- **CRITICAL FIX**: JSON extraction now works even when mixed with box-drawing error output
- **CRITICAL FIX**: ALL validation errors now stop execution immediately - no retries ever
- **CRITICAL FIX**: Themes created with errors are immediately deleted, preventing accumulation
- Added comprehensive logging to track theme creation flow
- Handle edge cases where JSON extraction might fail
- Improved error detection and reporting

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
