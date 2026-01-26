# Shopify PR Theme Preview Action

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Shopify%20PR%20Theme%20Preview-blue?logo=github)](https://github.com/marketplace/actions/shoplab-pr-shopify-theme-preview)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Automatically deploy and manage Shopify preview themes for pull requests. This GitHub Action creates isolated theme environments for each PR, making it easy to review changes before merging.

## ✨ Features

- 🚀 **Automatic Deployment** - Creates a Shopify theme for each PR using the PR title as theme name
- 🔄 **Smart Updates** - Updates existing themes on new commits without losing settings
- 💾 **Settings Preservation** - Pulls settings from your live theme (or custom source)
- 🔗 **Preview Links** - Adds preview URLs directly to PR comments
- 🧹 **Auto Cleanup** - Deletes themes when PRs are closed or merged
- 🔒 **Secure** - Built with security best practices
- 🎯 **Theme Limit Handling** - Automatically manages Shopify's 20-theme limit
- ⚠️ **Error Reporting** - Posts Shopify errors as PR comments for easy debugging
- 💬 **Slack Notifications** - Optional Slack webhook integration for deployment status
- 📢 **MS Teams Notifications** - Optional Microsoft Teams webhook integration for deployment status
- 🔄 **No-Sync Mode** - Option to use repository JSON files without production sync

## 🎯 Automatic Theme Limit Management

Shopify stores have a limit of 20 development themes. This action automatically handles this limit:

### How it works:
1. **Detects theme limit errors** - When creating a new theme hits the 20-theme limit
2. **Finds the oldest theme** - Identifies themes from open PRs (sorted by last update time)
3. **Respects protected themes** - Skips themes with the `preserve-theme` label
4. **Auto-removes oldest theme** - Deletes it and notifies the PR author
5. **Retries theme creation** - Automatically creates your new theme

### Label Features:
- **`preserve-theme`** - Add this label to protect a PR's theme from auto-deletion
- **`rebuild-theme`** - Add this label to recreate a deleted theme
- **`no-sync`** - Add this label to skip pulling settings from production/source theme

### Auto-Removal Notification:
When a theme is auto-removed, the PR receives this comment:
```
⚠️ Theme Auto-Removed Due to Store Limit

Your preview theme was automatically deleted to make room for newer PRs 
(Shopify limit: 20 themes).

To recreate your preview theme:
- Add the label `rebuild-theme` to this PR
- Or push a new commit

The theme will be automatically recreated.
```

## 🚀 Quick Setup

### 1. Get Your Shopify CLI Access Token

Install Shopify CLI and generate a theme access token:

```bash
npm install -g @shopify/cli@latest
shopify theme token --store=your-store.myshopify.com
```

**Save this token securely** - you'll need it in the next step.

### 2. Add GitHub Secrets

Go to your repository **Settings** → **Secrets and variables** → **Actions** and add:

- `SHOPIFY_STORE_URL` - Your store URL (e.g., `your-store.myshopify.com`)
- `SHOPIFY_CLI_THEME_TOKEN` - The token from step 1

### 3. Create Workflow File

Create `.github/workflows/pr-theme.yml`:

```yaml
name: PR Theme Management

on:
  pull_request:
    types: [opened, synchronize, reopened, closed, labeled]

# Cancel in-progress runs for the same PR
concurrency:
  group: pr-theme-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  manage-theme:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    
    # Security: Only run for PRs from the same repository (not forks)
    if: github.event.pull_request.head.repo.full_name == github.repository
    
    permissions:
      pull-requests: write
      issues: write
      contents: read
      
    steps:
      - name: Checkout code
        if: github.event.action != 'closed' && (github.event.action != 'labeled' || github.event.label.name == 'rebuild-theme')
        uses: actions/checkout@v5
        with:
          ref: ${{ github.event.pull_request.head.sha }}

      - name: Deploy/Update PR Theme
        if: github.event.action != 'closed' && (github.event.action != 'labeled' || github.event.label.name == 'rebuild-theme')
        uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
          shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
          action-type: 'deploy'

      - name: Cleanup PR Theme
        if: github.event.action == 'closed'
        uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
          shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
          action-type: 'cleanup'
```

### 4. Test It

1. Create a new branch and make changes
2. Open a pull request
3. Watch the Actions tab - a theme will be created using your PR title
4. Check the PR comments for the preview link

## 📋 Configuration

### Required Inputs

| Input | Description |
|-------|-------------|
| `github-token` | GitHub token for PR operations (use `${{ secrets.GITHUB_TOKEN }}`) |
| `shopify-store-url` | Your Shopify store URL |
| `shopify-cli-theme-token` | Shopify CLI theme access token |
| `action-type` | Either `deploy` or `cleanup` |

### Optional Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `source-theme-id` | Theme ID to pull settings from | Uses live theme |
| `build-command` | Command to build assets before deployment | None |
| `node-version` | Node.js version to use | `20` |
| `slack-webhook-url` | Slack webhook URL for notifications | None |
| `ms-teams-webhook-url` | Microsoft Teams webhook URL for notifications | None |
| `theme-root` | Directory containing the theme files (useful for compiled themes) | `.` (repository root) |

## 🎯 Advanced Usage

### With Build Step

If your theme requires compilation:

```yaml
- name: Setup Node.js
  if: github.event.action != 'closed'
  uses: actions/setup-node@v5
  with:
    node-version: '20'

- name: Install dependencies
  if: github.event.action != 'closed'
  run: npm ci

- name: Deploy/Update PR Theme
  if: github.event.action != 'closed'
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    build-command: 'npm run build'  # Your build command
    action-type: 'deploy'
```

### With Compiled Theme Directory

If your build process outputs to a different directory (e.g., `dist`), use `theme-root`:

```yaml
- name: Setup Node.js
  if: github.event.action != 'closed'
  uses: actions/setup-node@v5
  with:
    node-version: '20'

- name: Install dependencies
  if: github.event.action != 'closed'
  run: yarn install --frozen-lockfile

- name: Deploy/Update PR Theme
  if: github.event.action != 'closed'
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    build-command: 'yarn webpack:build'  # Build to dist folder
    theme-root: 'dist'  # Deploy from dist folder
    action-type: 'deploy'
```

**Note:** The `theme-root` parameter specifies where the compiled/built theme files are located. The build command runs in the repository root, and then the action deploys from the specified `theme-root` directory.

### With Custom Source Theme

To pull settings from a staging theme instead of live:

```yaml
- name: Deploy/Update PR Theme
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    source-theme-id: '123456789'  # Your staging theme ID
    action-type: 'deploy'
```

### For Monorepos

If your theme is in a subdirectory, use `theme-root`:

```yaml
- name: Checkout code
  uses: actions/checkout@v5
  with:
    ref: ${{ github.event.pull_request.head.sha }}

- name: Deploy Theme
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    theme-root: 'themes/my-theme'  # Path to theme directory
    action-type: 'deploy'
```

**Note:** Use `theme-root` to specify where your theme files are located. This is preferred over `working-directory` as it's handled internally by the action.

### With Slack Notifications

To receive deployment notifications in Slack:

1. [Create a Slack Webhook URL](https://api.slack.com/messaging/webhooks)
2. Add it as a GitHub secret: `SLACK_WEBHOOK_URL`
3. Include it in your workflow:

```yaml
- name: Deploy/Update PR Theme
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
    action-type: 'deploy'
```

You'll receive notifications for:
- ✅ Initial theme creation with preview links
- ⚠️ Themes created with warnings  
- ❌ Failed deployments with error details
- 🧹 Theme cleanup events

**Note:** Theme updates do not trigger notifications to avoid spam

### With Microsoft Teams Notifications

To receive deployment notifications in Microsoft Teams:

1. [Create an Incoming Webhook in MS Teams](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook)
2. Add it as a GitHub secret: `MS_TEAMS_WEBHOOK_URL`
3. Include it in your workflow:

```yaml
- name: Deploy/Update PR Theme
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    ms-teams-webhook-url: ${{ secrets.MS_TEAMS_WEBHOOK_URL }}
    action-type: 'deploy'
```

You'll receive notifications for:
- ✅ Initial theme creation with preview links
- ⚠️ Themes created with warnings  
- ❌ Failed deployments with error details
- 🧹 Theme cleanup events

**Note:** Theme updates do not trigger notifications to avoid spam

### Using Both Slack and MS Teams

You can enable both notification channels simultaneously:

```yaml
- name: Deploy/Update PR Theme
  uses: ShopLab-Team/shoplab-pr-shopify-theme-preview@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    shopify-store-url: ${{ secrets.SHOPIFY_STORE_URL }}
    shopify-cli-theme-token: ${{ secrets.SHOPIFY_CLI_THEME_TOKEN }}
    slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
    ms-teams-webhook-url: ${{ secrets.MS_TEAMS_WEBHOOK_URL }}
    action-type: 'deploy'
```

### Using Repository JSON Files (no-sync)

By default, the action pulls JSON configuration files from your live/source theme during initial theme creation to preserve production settings.

The `no-sync` label **only affects initial theme creation**:
- **WITH `no-sync`**: Skip pulling settings from production/source theme, use repo's JSON files
- **WITHOUT `no-sync`**: Pull settings from production/source theme before creating

**Important:** The `no-sync` label does NOT affect theme updates. When updating existing themes, JSON files are ALWAYS excluded to preserve the theme's current settings, regardless of the label.

**When to use `no-sync` label:**
- Creating a theme with completely new settings structure
- Testing theme settings that differ from production
- When your repo's JSON files should be the initial configuration
- Deploying a theme without production settings inheritance

**Behavior Summary:**

| Scenario | no-sync Label | Action |
|----------|--------------|--------|
| Initial theme creation | No | Pull JSON from production → Push all files including JSON |
| Initial theme creation | Yes | Don't pull from production → Push all files including JSON from repo |
| Theme update (exists) | No | Push only non-JSON files (preserve settings) |
| Theme update (exists) | Yes | Push only non-JSON files (preserve settings) |

**Note:** Locale default files (like `en.default.json`) are always updated even during theme updates to ensure translation changes are applied.

## 🔧 How It Works

1. **PR Opened**: Creates a new theme using your PR title as the theme name
2. **New Commits**: Updates the existing theme (preserves settings)
3. **PR Closed/Merged**: Deletes the theme automatically

### Files Preserved During Updates

When updating existing themes, the following JSON files are **always preserved** (not updated):
- `templates/*.json` - Template settings
- `sections/*.json` - Section settings
- `config/settings_data.json` - Theme settings  
- `snippets/*.json` - Snippet configurations

**Files that ARE updated:**
- All `.liquid` files (templates, sections, snippets, layout)
- All asset files (CSS, JS, images, fonts)
- Locale default files (`locales/*.default.json`) - to apply translation updates

**Note:** The `no-sync` label does NOT change this behavior for updates. It only affects whether settings are pulled from production during initial theme creation.

## 🎨 PR Comment Preview

### Successful Deployment

When deployed, you'll see a comment like:

> ## 🚀 Shopify Theme Preview
> 
> **Preview your changes:** https://your-store.myshopify.com?preview_theme_id=123456789
> 
> **Theme:** Add new header feature  
> **Theme ID:** `123456789`
> 
> This preview theme will be automatically deleted when the PR is closed or merged.

### Deployment with Errors

If Shopify encounters errors but still creates the theme:

> ## ⚠️ Shopify Theme Preview Created with Errors
> 
> The theme was created but encountered some issues:
> 
> ```
> templates/page.contact.json: Section type 'contact-us-form' does not refer to an existing section file
> ```
> 
> **Preview URL (may have issues):** https://your-store.myshopify.com?preview_theme_id=123456789  
> **Theme ID:** `123456789`
> 
> Please fix the errors and push a new commit to update the theme.

### Failed Deployment

If theme creation fails completely:

> ## ❌ Shopify Theme Preview Failed
> 
> Failed to create the preview theme due to the following error:
> 
> ```
> Theme limit exceeded (maximum 20 themes)
> ```
> 
> Please fix the errors and push a new commit to retry.

## 🐛 Troubleshooting

### Theme Not Creating

- Verify your `SHOPIFY_CLI_THEME_TOKEN` has proper permissions
- Check the store URL is correct
- Review GitHub Actions logs for detailed errors

### Settings Not Pulling

- Ensure the source theme exists
- Verify `source-theme-id` is valid (if provided)
- Check that JSON files exist in the source theme

### Build Failing

- Test your build command locally first
- Ensure all dependencies are installed
- Verify Node.js version compatibility

### Theme Not Deleting

- Check if the PR comment contains the theme ID
- Verify the token has delete permissions
- The theme may have been manually deleted

## 📚 Full Example

See [examples/example.yml](examples/example.yml) for a complete workflow with all optional parameters documented.

## 📄 License

MIT © [shoplab](https://github.com/ShopLab-Team)

## 🆘 Support

- [Report a bug](https://github.com/ShopLab-Team/shoplab-pr-shopify-theme-preview/issues)
- [Request a feature](https://github.com/ShopLab-Team/shoplab-pr-shopify-theme-preview/issues)
- [Shopify CLI Documentation](https://shopify.dev/docs/themes/tools/cli)
- [GitHub Actions Documentation](https://docs.github.com/actions)