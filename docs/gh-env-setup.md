# GitHub Environment Setup Tutorial

## Tutorials

### Setting Up Your First GitHub Environment

This tutorial will guide you through creating your first GitHub environment for a development project named "demo" in UK South region. By the end, you'll have a working environment ready for your Azure deployments.

#### Before You Begin

You need:
- A GitHub repository for your project with relevant access
- Your Azure subscription ID
- Your Azure client ID (spn client id that will be used for OIDC auth)
- Azure tenant ID

#### Step 1: Create Your First Configuration

1. Open your repository in GitHub
2. Click "Add file" → "Create new file"
3. Name it setup-env-config.yml
4. Copy the example configuration and replace placeholder values for (subscription_ids, client_Ids)
5. Commit changes

````yaml
project_name: demo
region: uks
environments: dev
subscription_ids: 00000000-0000-0000-0000-000000000000
client_ids: 11111111-1111-1111-1111-111111111111
tenant_id: <replace-with-your-tenant-id>
storage_suffix: "001"
````

> **Note:** Do not include any comments in `setup-env-config.yml`

#### Step 2: Run the Setup

1. Click "Actions" in your repository
2. Click "setup gh env"
3. Click "Run workflow"
4. Select setup-env-config.yml from the dropdown for 'Select configuration file'
5. Click "Run workflow" again

#### Step 3: Verify Success

1. Go to repository Settings → Environments
2. You should see two new environments:
   - `uks dev plan`
   - `uks dev apply`
3. Click each environment to view the configured variables

**Well done!** You've created your first GitHub environment setup.

## How-To Guides

### How to Implement the Workflow in Your Repository

1. Create a workflow file at create-env.yml
2. Create a configuration file at setup-env-config.yml if using config file approach (recommended)
3. Ensure you have set up the `GH_PAT` secret in your repository settings if not already inherited as an organisation secret.

````yaml
name: setup gh env

on:
  workflow_dispatch:
    inputs:
      config_file:
        description: 'Select configuration file (If selected, other input values will be ignored)'
        required: false
        type: choice
        options:
          - 'none'
          - '.github/configs/setup-env-config.yml'
        default: 'none'  
      project_name:
        description: 'Project name (e.g. 3-4 letters project short name)'
        required: false
      region:
        description: 'Azure region code (e.g. uks,ukw | comma-separated for multiple env)'
        required: false
        type: string
        default: 'uks'
      environments:
        description: 'Environments to create (comma-separated, e.g. dev,pprd,prd)'
        required: false
      subscription_ids:
        description: 'Subscription IDs (comma-separated, same order as environments)'
        required: false
      client_ids:
        description: 'Client IDs (comma-separated, same order as environments)'
        required: false
      tenant_id:
        description: 'Azure Tenant ID'
        required: true
        default: '<replace-with-your-tenant-id>'
      storage_suffix:
        description: 'Storage account suffix'
        required: false
        default: '001'

jobs:
  call-reusable-workflow:
    uses: org-redacted/alz-reusable-workflows/.github/workflows/gh-env-setup.yml@main
    with:
      config_file: ${{ inputs.config_file }}
      project_name: ${{ inputs.project_name }}
      region: ${{ inputs.region }}
      environments: ${{ inputs.environments }}
      subscription_ids: ${{ inputs.subscription_ids }}
      client_ids: ${{ inputs.client_ids }}
      tenant_id: ${{ inputs.tenant_id }}
      storage_suffix: ${{ inputs.storage_suffix }}
    secrets:
      GH_PAT: ${{ secrets.GH_PAT }}

# Docs: 
````

### How to Create Environments without using a config file

**Steps:**

1. Go to Actions → setup gh env
2. Click "Run workflow"
3. Select "none" for config_file
4. Enter:
   - Project name: `myproj`
   - Region: `uks`
   - Environments: `dev`
   - Subscription IDs: `your-sub-id`
   - Client IDs: `your-client-id`
   - Tenant ID: `your-tenant-id`
   - Storage suffix: `001`
5. Click "Run workflow"

### How to Set Up Multi Region Environments

**Steps:**

1. Create your configuration file with the following content and store it in this location: setup-env-config.yml

````yaml
project_name: proj
region: uks,ukw
environments: dev,prd
subscription_ids: sub-dev-id,sub-prd-id
client_ids: client-dev-id,client-prd-id
tenant_id: <replace-with-your-tenant-id>
storage_suffix: "001"
````

2. Run the workflow:
   - Go to Action → setup gh env
   - Select config file from the drop down
   - Run workflow

This creates:
- `uks dev plan/apply`
- `uks prd plan/apply`
- `ukw dev plan/apply`
- `ukw prd plan/apply`

### How to Resolve Common Validation Errors

#### Count Mismatch

If you see: "Error: Number of subscription IDs does not match number of environments"

- Check your environment count matches subscription ID count
- Check your client ID count matches environment count

**Example:**

✅ **Correct:**
- `environments: dev,prd`
- `subscription_ids: sub1,sub2`
- `client_ids: client1,client2`

❌ **Incorrect:**
- `environments: dev,prd`
- `subscription_ids: sub1`
- `client_ids: client1,client2`

#### Storage Account Name Length

If you see: "Error: Storage account name exceeds 24 characters"

- The format is: `orgsttfstate[project][region][suffix]`
- Count the total characters
- Adjust your project_name to reduce length

**Example:**

✅ **Correct:**
- `project_name: abc` # Results in: `orgsttfstateabcuks001` (21 chars)

❌ **Incorrect:**
- `project_name: toolong` # Results in: `orgsttfstatetoolonguks001` (26 chars)

## Reference

### Validation Rules

The workflow implements several validation checks to ensure correct configuration:

#### Input Count Validation

Ensures that the number of environments matches the associated Azure resources and vice versa:

```yaml
environments: dev,pprd,prd         # 3 environments
subscription_ids: sub1,sub2,sub3   # 3 subscription IDs
client_ids: cl1,cl2,cl3            # 3 client IDs
```

Validation will fail if counts don't match.

#### Storage Account Name Length

Validates that the generated storage account name doesn't exceed Azure's 24-character limit:

- Format: `orgsttfstate[project][region][suffix]`
- Example: `orgsttfstateabcuks001`
- Project name length affects total length
- Validated for each region specified

Error messages you might see:
- "Error: Number of subscription IDs does not match number of environments"
- "Error: Number of client IDs does not match number of environments"
- "Error: Storage account name 'orgsttfstatetoolonguks001' exceeds 24 characters"

### Configuration File Structure

#### Required Fields

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `project_name` | string | 3-4 letter identifier | "proj" |
| `environments` | string | Comma-separated env names | "dev,prd" |
| `subscription_ids` | string | Comma-separated Azure sub IDs | "id1,id2" |
| `client_ids` | string | Comma-separated Azure client IDs | "cid1,cid2" |
| `tenant_id` | string | Azure tenant ID | "<replace-with-your-tenant-id>" |
| `region` | string | Comma-separated Azure region codes | "uks" or "uks,ukw" |
| `storage_suffix` | string | Storage account suffix | "001" |

### Environment Variables Created

#### Per Environment:

| Variable | Format | Example |
|----------|--------|---------|
| `APPLY_ENV` | `[region] [environment] apply` | "uks dev apply" |
| `PLAN_ENV` | `[region] [environment] plan` | "uks dev plan" |
| `TF_BACKEND_ENV` | `[environment]` | "dev" |
| `TF_BACKEND_SA` | `orgsttf[project][environment][region][suffix]` | "orgsttfprjdevuks001" |
| `TF_BACKEND_SA_REGION` | `[Full region name]` | "UKSouth" |
| `TF_BACKEND_SA_REGION_SHORT` | `[Short region code]` | "uks" |
| `TF_BACKEND_SA_RG` | `rg-tfstate-[project]-storage-[region]` | "rg-tfstate-proj-storage-uks-001" |
| `TF_BACKEND_SA_SKU` | `[Storage SKU]` | "Standard_ZRS" |
| `ARM_CLIENT_ID` | `[Client ID]` | "client1" |
| `ARM_SUBSCRIPTION_ID` | `[Subscription ID]` | "sub1" |
| `TF_BACKEND_SA_CONTAINER` | `platform-[project]-[environment]` | "platform-proj-dev" |

#### Repository Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `RUNNER_CONFIG` | JSON configuration for self-hosted runners | `{"group":"replacesvcs","labels":["self-hosted","prod","linuxdefender"]}` |
| `ARM_TENANT_ID` | Azure tenant ID | `<replace-with-your-tenant-id>` |

### Region Configurations

#### UK South (uks)
- Full name: UKSouth
- Storage SKU: Standard_ZRS
- Backend container: platform-[project]-[environment]

#### UK West (ukw)
- Full name: UKWest
- Storage SKU: Standard_LRS
- Backend container: platform-[project]-[environment]

## Explanation

### Why Input Validations Matter

The workflow includes several validation checks that help prevent common deployment issues:

#### Input Count Matching

The requirement for matching counts between environments, subscription IDs, and client IDs serves multiple purposes:

- Ensures each environment has its dedicated Azure resources
- Prevents misconfigurations where environments might share credentials
- Makes the relationship between environments and their Azure resources explicit

When the workflow validates these counts:
- It helps catch configuration errors early
- Prevents partial or incomplete environment setups
- Ensures consistent state across all environments

#### Storage Account Name Validation

The 24-character limit validation for storage account names is crucial because:

- Azure storage accounts have a strict 24-character limit
- Failed deployments can occur if names are too long
- Changing storage account names after deployment is disruptive
- Early validation prevents deployment failures

This validation approach follows the principle of "fail fast" - catching configuration issues before any resources are created or modified.

### Why Separate Plan and Apply Environments

The separation of plan and apply environments is designed specifically for Terraform workflow security:

**Plan Environments:**
- Used for `terraform plan` operations
- No approval requirements

**Apply Environments:**
- Used for `terraform apply` operations
- Used for enabling GitHub environment protection rules
- Required to set up approvals to do applies
- Controls who can make actual infrastructure modifications
- You still need to configure branch protections rules and approval gates

### Architecture Decisions

The dual configuration approach (file vs manual) serves different use cases:

**Configuration File:**
- Version controlled
- Team standardisation
- Audit trail
- Suitable for permanent environments

**Manual Inputs:**
- Quick testing/deployment
- One-off environments
- Emergency fixes
- Prototype development