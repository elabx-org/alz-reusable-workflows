# Reusable Module Release and Tagging Workflow

## Pipeline Overview

This pipeline is designed to validate Terraform code, check formatting, generate documentation, and create releases for Terraform modules. It can be triggered manually, by pull requests or pushes to the main branch.

## Pipeline Components

1. **Validate and Release Caller (validate-and-release.yml)**: This is the entry point that calls the reusable workflow.
2. **Reusable Module Validate & Release (mod-validate-and-release.yml)**: This is the main reusable workflow that contains the core logic for validation and release.

## Setup

1. Create a copy of the reusable workflow caller (validate-and-release.yml) in your module repo's workflows folder.

2. The pipeline has default values configured but recommend overriding the values via GitHub environment variables to suit your project needs and to have more control over the pipeline (GitHub environment configured variables take precedence over the default workflow configured values).

3. Store your .tf files in the root folder (as per the default configured value of `TERRAFORM_WORKING_DIR`)

4. **Recommend configuring the following values:**
   1. `RUNNER_CONFIG`
   2. `RUN_CHECK_TF_CHANGES`
   3. `RUN_RELEASE_AND_TAG`
   4. `RUN_TF_DOCS`
   5. `RUN_VALIDATE_MODULE`
   6. `RUN_TF_LINT`
   7. `RUN_TF_SECURITY_SCAN`
   8. `RUN_TEST_MODULE`
   9. `TEST_ENVIRONMENT`

5. **Add the following jobs in your branch protection status checks** (note you need to run the pipeline once before the following jobs are visible as status checks)
   1. `release-module / Validate Module`
   2. `release-module / Lint Module`
   3. `release-module / Test Module`
   4. `release-module / Security Scan Module`
   5. `release-module / Create Release and Tag`
   6. `release-module / Generate Terraform Docs`

## Configuration Options

The pipeline can be configured using GitHub repository variables or workflow inputs:

| Variable Name | Description | Default Value | Possible Values |
|---------------|-------------|---------------|-----------------|
| `RUNNER_CONFIG` | JSON string for runner configuration | `'{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}'` | JSON object |
| `DEFAULT_INCREMENT` | Default version increment type | `patch` | `'patch'`, `'minor'`, `'major'` |
| `INSTALL_GH_CLI` | Whether to install GitHub CLI | `true` | `true`, `false` |
| `TERRAFORM_WORKING_DIR` | Terraform working directory | `.` | Any valid directory path |
| `RUN_CHECK_TF_CHANGES` | Enable/disable Terraform change check | `true` | `true`, `false` |
| `RUN_VALIDATE_MODULE` | Enable/disable Terraform validation | `true` | `true`, `false` |
| `RUN_TEST_MODULE` | Enable/disable Terraform Testing | `false` | `true`, `false` |
| `TEST_ENVIRONMENT` | The name of the GitHub environment to use for testing. Used to retrieve Azure login credentials. | `sandbox uks test` | Free text, any valid GitHub environment name |
| `RUN_TF_LINT` | Enable/disable Terraform Linting | `false` | `true`, `false` |
| `RUN_TF_SECURITY_SCAN` | Enable/disable Terraform Security Scanning | `false` | `true`, `false` |
| `RUN_TF_DOCS` | Enable/disable Terraform docs generation | `true` | `true`, `false` |
| `RUN_RELEASE_AND_TAG` | Enable/disable release and tag creation | `true` | `true`, `false` |
| `TF_DOCS_OUTPUT_FILE` | Output file for Terraform docs | `'.terraform-docs.yml'` | Any valid filename |
| `TF_DOCS_CONFIG_FILE` | Config file for Terraform docs | `false` | `true`, `false` |
| `TF_DOCS_CLEAR_WORKSPACE` | Clear workspace before generating docs. Initially added to solve issues with temporary runners | `false` | `true`, `false` |

## Trigger Events

- Pull Requests to the main branch
- Pushes to the main branch  
- Manual triggers (workflow_dispatch)

## Jobs and Their Functions

### 1. Output Configuration
- Displays the current configuration settings for the workflow
- Runs on every execution to provide visibility into the workflow setup

### 2. Check for Terraform Changes
- Checks for changes in .tf files since the last release or in the current PR
- Determines if a new release is needed based on detected changes
- **Outputs:**
  - Whether Terraform files have changed
  - Whether a force release is requested
  - List of changed files

### 3. Validate Module
- Runs Terraform initialisation, format checking, and validation
- Ensures the Terraform code is correctly formatted and syntactically valid
- Can be skipped if no changes are detected and force release is not enabled

### 4. Terraform Lint Module
- Executes tflint against the repository to check for standardised errors
- Fails the workflow if tflint comes back with an error finding

### 5. Terraform Test Module
- Runs Terraform Tests against the repository
- Runs both Unit tests and Integrations tests, for connecting through to Azure
  - Unit tests are stored in the `./tests/` folder
  - Integration tests are stored in the `./tests/integration/` folder
- Fails the workflow if Terraform Tests are enabled and the tests either fail, or no tests are found

### 6. Security Scan Module
- Runs Checkov's Terraform security scanning against the repository
- If any security findings are found, the workflow execution fails

### 7. Generate Terraform Docs
- Generates or updates documentation for the Terraform module
- Uses terraform-docs to create standardised documentation
- Can update the README or a specified output file

### 8. Create Release and Tag
- Determines the version increment type (patch, minor, major) based on commit messages or manual input
- Creates a new git tag and GitHub release if conditions are met
- Comments on PRs with expected version increments
- A release and a tag are only created when the pipeline is run against the main branch

### 9. Workflow Summary
- Provides an overview of all job executions in the workflow
- Summarises the status and key details of each job

## Version Increment Logic

| Keyword in Commit Message | Version Increment | Example | Description |
|---------------------------|-------------------|---------|-------------|
| `BREAKING CHANGE` or `MAJOR` | Major | v1.0.0 → v2.0.0 | Used for breaking or incompatible changes with the previous version. This will increment the first number in the version. |
| `Minor` | Minor | v1.0.0 → v1.1.0 | Used for adding new features with backwards compatibility. This will increment the second number in the version. |
| Any other message | Patch | v1.0.0 → v1.0.1 | Used for backwards-compatible bug fixes. This will increment the third number in the version. |

**Important Notes:**
1. The pipeline scans all commit messages in a pull request to determine the highest level of change
2. Keywords are case-insensitive
3. For pushes to main, only the latest commit message is considered
4. The PR title and body are also included in the scan for keywords
5. If multiple increment types are detected, the highest takes precedence (Major > Minor > Patch)
6. Manual triggers allow overriding the increment type, regardless of commit messages

## Manual Triggers

| Input Parameter | Description | Options | Effect |
|----------------|-------------|---------|--------|
| Version Increment | Determines how the version number should be incremented | `patch` (default)<br>`minor`<br>`major` | patch: v1.0.0 → v1.0.1<br>minor: v1.0.0 → v1.1.0<br>major: v1.0.0 → v2.0.0 |
| Force Release | Forces a release creation even if no code changes are detected | `true`<br>`false` (default) | true: Creates a release regardless of changes<br>false: Only creates a release if changes are detected |

Manual triggers allow for greater control over the release process. Here are some key points about using manual triggers:

1. **Flexibility**: Manual triggers allow for creating releases outside the normal push-driven process, providing more control over release timing.
2. **Version Increment Override**: When manually triggering the workflow, you can specify the version increment type (patch, minor, major). This option overrides the increment type that would be determined from commit messages.
3. **Force Release**: The Force Release option can be used to create a new release even when no .tf file changes are detected. This is useful for creating releases based on non-code changes (e.g., documentation updates).
4. **Validation Steps**: Even when manually triggered, the pipeline still runs all validation steps before creating a release, ensuring code quality. [needs RUN_VALIDATE_MODULE var set to true]
5. **No Changes Scenario**: If Force Release is set to false and no changes are detected, the pipeline will run but skip release creation. This prevents unnecessary releases.
6. **Release Management**: Manual triggers provide flexibility for release management, allowing for specific version control and release timing as needed.

## Example Caller Workflow Code

````yaml
name: Test, Release and Tag

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
  workflow_dispatch:
    inputs:
      increment:
        description: |
          Version increment type:
          ┌─────────────────────────────────────────┐
          │ patch: 1.0.0 -------→ 1.0.1 [bug fixes] │
          ├─────────────────────────────────────────┤
          │ minor: 1.0.0 ----→ 1.1.0 [new features] │
          ├─────────────────────────────────────────┤
          │ major: 1.0.0 → 2.0.0 [breaking changes] │
          └─────────────────────────────────────────┘
          (default: patch)
        required: true
        default: 'patch'
        type: choice
        options:
          - patch
          - minor
          - major
      force_release:
        description: 'Force release creation (no code changes)'
        required: true
        default: false
        type: boolean

jobs:
  release-module:
    uses: org/alz-reusable-workflows/.github/workflows/mod-validate-and-release.yml@main
    with:
      runs_on: >-
        ${{ vars.RUNNER_CONFIG || 
        '{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}' }}                            
      increment: ${{ github.event.inputs.increment || vars.DEFAULT_INCREMENT || 'patch' }}
      force_release: ${{ fromJSON(github.event.inputs.force_release || 'false') }}
      install_gh_cli: ${{ fromJSON(vars.INSTALL_GH_CLI != null && vars.INSTALL_GH_CLI || 'true') }}
      terraform_working_dir: ${{ vars.TERRAFORM_WORKING_DIR || '.' }}
      
      # Job execution controls
      run_check_tf_changes: ${{ fromJSON(vars.RUN_CHECK_TF_CHANGES != null && vars.RUN_CHECK_TF_CHANGES || 'true') }}                                          
      run_validate_module: ${{ fromJSON(vars.RUN_VALIDATE_MODULE != null && vars.RUN_VALIDATE_MODULE || 'true') }}                                         
      run_tf_docs: ${{ fromJSON(vars.RUN_TF_DOCS != null && vars.RUN_TF_DOCS || 'true') }}                                                      
      run_release_and_tag: ${{ fromJSON(vars.RUN_RELEASE_AND_TAG != null && vars.RUN_RELEASE_AND_TAG || 'true') }}                     

      # Terraform Testing
      # The following options must be enabled, as by standard they are not set to run to avoid breaking other modules using the workflow without testing
      run_test_module: ${{ fromJSON(vars.RUN_TEST_MODULE != null && vars.RUN_TEST_MODULE || 'false') }}
      test_environment: ${{ fromJSON(vars.TEST_ENVIRONMENT != null && vars.TEST_ENVIRONMENT || 'sandbox uks test') }}
      run_lint_module: ${{ fromJSON(vars.RUN_TF_LINT != null && vars.RUN_TF_LINT || 'false') }}
      run_security_scan_module: ${{ fromJSON(vars.RUN_TF_SECURITY_SCAN != null && vars.RUN_TF_SECURITY_SCAN || 'false') }}

      # Terraform docs settings
      tf_docs_output_file: ${{ vars.TF_DOCS_OUTPUT_FILE || 'README.md' }}                
      tf_docs_config_file: ${{ vars.TF_DOCS_CONFIG_FILE || '.terraform-docs.yml' }}          
      tf_docs_clear_workspace: ${{ fromJSON(vars.TF_DOCS_CLEAR_WORKSPACE != null && vars.TF_DOCS_CLEAR_WORKSPACE || 'true') }}    



# =====================================================================
# INFO
# =====================================================================
#
# Runner Configuration:
# - To use GitHub-hosted runner: {"runner": "ubuntu-latest"}
# - To use self-hosted runner: {"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}
#
# GitHub Repository Variables:
# - Set these in your repo: Settings > Secrets and variables > Actions > Variables
# - Available variables, their purpose, and default values:
#   - RUNNER_CONFIG: JSON string for runner configuration
#     Default: '{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}'
#   - DEFAULT_INCREMENT: Default version increment type
#     Default: 'patch'
#   - FORCE_RELEASE: Whether to force a release creation
#     Default: false, not configurable via repository variables
#   - INSTALL_GH_CLI: Whether to install GitHub CLI
#     Default: true
#   - TERRAFORM_WORKING_DIR: Set the Terraform working directory
#     Default: '.' (current directory)
#   - RUN_CHECK_TF_CHANGES: Whether to run Terraform change check
#     Default: false
#   - RUN_VALIDATE_MODULE: Whether to run Terraform validation
#     Default: false
#   - RUN_TF_DOCS: Whether to generate Terraform docs
#     Default: true
#   - RUN_RELEASE_AND_TAG: Whether to create release and tag
#     Default: true
#   - TF_DOCS_OUTPUT_FILE: Set the output file for Terraform docs
#     Default: 'README.md'
#   - TF_DOCS_CONFIG_FILE: Set the config file for Terraform docs
#     Default: '.terraform-docs.yml'
#   - TF_DOCS_CLEAR_WORKSPACE: Whether to clear workspace before generating docs
#     Default: true
#
# Workflow Dispatch Inputs:
# - increment: Choose version increment type (patch, minor, major)
#   Default: 'patch'
# - force_release: Force release creation even without changes
#   Default: false
#
# Note: Repository variables take precedence over default values in the workflow.
#       Use these to customize behavior without changing the workflow file.
#
#
# =====================================================================
````

### Configuration Notes

#### Runner Configuration:
- To use GitHub-hosted runner: `{"runner": "ubuntu-latest"}`
- To use self-hosted runner: `{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}`

#### GitHub Repository Variables:
Set these in your repo: Settings > Secrets and variables > Actions > Variables

**Available variables, their purpose, and default values:**
- `RUNNER_CONFIG`: JSON string for runner configuration (Default: `'{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}'`)
- `DEFAULT_INCREMENT`: Default version increment type (Default: `'patch'`)
- `FORCE_RELEASE`: Whether to force a release creation (Default: `false`, not configurable via repository variables)
- `INSTALL_GH_CLI`: Whether to install GitHub CLI (Default: `true`)
- `TERRAFORM_WORKING_DIR`: Set the Terraform working directory (Default: `'.'` - current directory)
- `RUN_CHECK_TF_CHANGES`: Whether to run Terraform change check (Default: `false`)
- `RUN_VALIDATE_MODULE`: Whether to run Terraform validation (Default: `false`)
- `RUN_TF_DOCS`: Whether to generate Terraform docs (Default: `true`)
- `RUN_RELEASE_AND_TAG`: Whether to create release and tag (Default: `true`)
- `TF_DOCS_OUTPUT_FILE`: Set the output file for Terraform docs (Default: `'README.md'`)
- `TF_DOCS_CONFIG_FILE`: Set the config file for Terraform docs (Default: `'.terraform-docs.yml'`)
- `TF_DOCS_CLEAR_WORKSPACE`: Whether to clear workspace before generating docs (Default: `true`)

#### Workflow Dispatch Inputs:
- `increment`: Choose version increment type (patch, minor, major) - Default: `'patch'`
- `force_release`: Force release creation even without changes - Default: `false`

> **Note**: Repository variables take precedence over default values in the workflow. Use these to customize behavior without changing the workflow file.