# Reusable Terraform Workflows

## Prerequisites

### 1. GitHub Environments

GitHub environments for Terraform Plan (e.g. 'uks' or 'env_name uks') and Terraform Apply (e.g. 'uks apply' or 'env_name uks apply') created in your repository. Do the same for all the environments your project requires (dev, uat, pprd and prd).

> **Note:** We require two GitHub environments (e.g. 'prd uks' and 'prd uks apply') for each environment (e.g. prod) so we can set approval gates. Running a plan doesn't require any approval but running a apply, which does the actual deployment of resources requires a peer approval and can't be self-approved.

### 2. Federated Login

Federated login created for OIDC authentication:
- Credential for 'dev uks' environment (should match created environment in GH)
- Credential for 'dev uks apply' environment (should match created environment in GH)

### 3. Set Variables

| Name | Required | Type | Example Value | Rationale |
|------|----------|------|---------------|-----------|
| `PLAN_ENV` | Yes | Environment Variable | dev | Name of the GH plan env |
| `APPLY_ENV` | Yes | Environment Variable | dev apply | Name of the GH apply env |
| `TF_BACKEND_ENV` | Yes | Environment Variable | dev | Backend env name or short repo name |
| `TF_BACKEND_SA_RG` | Yes | Environment Variable | rg-tfstate-edp-dev-storage-uks-001 | Name of the resource group your storage container resides in |
| `TF_BACKEND_SA` | Yes | Environment Variable | orgsttfstateedpdevuks001 | Storage account name |
| `TF_BACKEND_SA_REGION` | Yes | Environment Variable | UKSouth | Storage account region name |
| `TF_BACKEND_SA_REGION_SHORT` | Yes | Environment Variable | uks | Storage account region name (short form) |
| `TF_BACKEND_SA_SKU` | Yes | Environment Variable | Standard_ZRS | Storage account SKU |
| `ARM_SUBSCRIPTION_ID` | Optional | Environment Variable | 92acec4d-ba32-839d-dfc8-90be6bc7d807 | If your environments have a dedicated subscription, define it here. If not, define it as a repository variable |
| `ARM_CLIENT_ID` | Optional | Environment Variable | ea7bdd81-9014-8154-ce18-643a567e92190 | If your environments have a dedicated subscription, the client ID will be different for each subscription. If not, define it as a repository variable |
| `RUNNER_CONFIG` | Yes | Repository Variable | `{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}` | The runner or group of runners you want your workflow to use |
| `ARM_TENANT_ID` | Yes | Repository Variable | 4b944cde-5892-6d9e-9c6f-081bc09764dd | Azure Tenant ID |
| `ARM_SUBSCRIPTION_ID` | Yes | Repository Variable | 92acec4d-ba32-839d-dfc8-90be6bc7d807 | If your environments do not have a dedicated subscription for each environment, define it here. If not, define it in each environment as a variable |
| `ARM_CLIENT_ID` | Yes | Repository Variable | ea7bdd81-9014-8154-ce18-643a567e92190 | If your environments do not have a dedicated subscription for each environment, the client ID will be the same. If not, define it in each environment as a variable |
| `ARTIFACTORY_ACCESS_TOKEN` | No | Repository Secret | | Define the Artifactory token here if your project needs this passed to Terraform as a variable. Then set 'use_artifactory_token' to 'true' under terraform config block in the reusable-tf job |

#### RUNNER_CONFIG Examples:
- `{"runner": "ubuntu-latest"}`
- `{"labels": ["self-hosted", "linux", "alz"]}`
- `{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}`

### 5. Copy the Reusable Workflow Caller

Copy the reusable workflow caller from here into your repository's workflows folder.

## Reusable Workflow Caller Structure

The reusable workflow caller comprises of two jobs:

- **workflow config**: here we name the workflow, configure workflow triggers and concurrency
- **variables job**: allows to pass the configured environment repository values to the reusable workflow
- **reusable-tf job**: calls the reusable terraform workflow and allows the user to configure the behaviour of the called workflow

### Initial Workflow Config

````yaml
name: 'dev - terraform apply'

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - terraform/*.tf
      - terraform/config/dev/**
      - terraform/config/global.tfvars
      - .github/workflows/dev-terraform-*.yml

concurrency:
  group: workflow-tf-dev-uks
  cancel-in-progress: false
````

1. **Workflow Name (name:)**: Specifies the name of the workflow. It's what you see in the GitHub UI when the workflow runs.
2. **Trigger Events (on:)**: Defines the events that trigger the workflow. This can include a variety of GitHub event types, like push, pull_request, or workflow_dispatch.
3. **Concurrency (concurrency:)**: Manages the execution behaviour of workflows, such as ensuring only a single instance of a workflow runs at a time or cancelling previous runs that are not completed. The dev plan and apply concurrency group should be the same.

### Passing Repository Environment Vars

````yaml
jobs:
  variables:
    name: 'set-vars'
    environment: 'dev uks'  #replace with your created GH plan environment
````

> **Note:** You can use your plan or apply environment as the variables and their values should be the same.

## Reusable Terraform Workflow Setup

### Calling the Reusable Workflow

The following code block calls the reusable terraform workflow stored in the alz-reusable-workflows repository:

````yaml
reusable-tf:
  needs: variables
  uses: org/alz-reusable-workflows/.github/workflows/terraform-workflow.yml@main
  with:
````

### Configuring the Reusable Workflow

> **Note:** Any arguments in the following format in the 'reusable-tf' job can be passed via repository variables or setting the value in the code as below. Values set via GitHub variables will take precedent over values hardcoded in the workflow.
> 
> `${{ fromJson(vars.TERRAFORM_PLAN || 'true') }}`

## Config Options

The default options are set to what a typical terraform workflow should look like. Change them only if your project has different requirements otherwise stick with the hardcoded default values.

| Config Type | Name | Default Value | Rationale |
|-------------|------|---------------|-----------|
| **TF Backend Checks** | `check_tfstate_storage` | `true` | Enable \| Disable running terraform backend checks. Set it to 'false' if you're not using this script |
| | `tfstate_storage_script` | `${{ vars.TFSTATE_STORAGE_SCRIPT \|\| './scripts/create-tfstate-storage.sh --checks-only' }}` | Location of the backend checks script |
| **TF Config** | `use_artifactory_token` | `false` | If your project needs the Artifactory token available to Terraform and associate to the variable 'artifactory_access_token'. **Note:** you also need to define 'artifactory_access_token' in your variables.tf |
| | `terraform_plan` | `true` | Enable \| Disable running of Terraform Plan |
| | `terraform_apply` | `false` | Enable \| Disable running of Terraform Apply |
| | `terraform_format` | `true` | Enable \| Disable running of Terraform Format |
| | `terraform_validate` | `true` | Enable \| Disable running of Terraform validate |
| | `terraform_working_dir` | terraform | The default behaviour assumes you've got all your .tf files in a folder called 'terraform' under your repo's root directory |
| | `terraform_version` | `${{ vars.TERRAFORM_VERSION \|\| '1.9.7' }}` | Optional variable, defaults to Terraform version 1.9.7. This variable allows you to override the default Terraform version |
| | `terraform_plan_args` | `-var-file=config/${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}.tfvars`<br>`-var-file=config/global.tfvars` | First argument is link to your config.tfvars<br>Second argument is the link to the global.tfvars (delete the global.tfvars line, if you don't have one.) |
| **TF Docs** | `tf_docs_enabled` | `true` | Enable \| Disable the Terraform Docs job |
| | `tf_docs_output_file` | `../README.md` | Location of the readme file you want Terraform Docs to update |
| | `tf_docs_config_file` | .terraform-docs.yml | Location of the terraform docs config file |
| **Terraform Backend Config** | N/A | | No Terraform backend configuration is done in this block. The values are passed to this block via the 'variables' job and the variables job pulls the values you set in each GitHub Environment (e.g. 'dev uks' or 'dev uks apply'). See prerequisites 3. |
| **OIDC Config** | N/A | | No OIDC configuration is done in this block. The values are passed to this block via the 'variables' job and the variables job pulls the values you set in each GitHub Environment. See prerequisites 3. |
| **Misc** | `push_plan_to_pr` | `true` | Push plan output as a comment on pull requests |
| **Misc** | `install_kubelogin` | `false` | Optional variable, defaults to false. This option controls the installation of kubelogin and makes it available for your workflow runs |
| **Misc** | `reusable_workflow_branch` | | Optional variable, defaults to main. This option allows you to control the individual actions branch used within the reusable workflows. It can be used when testing a new action or feature in the alz-reusable-workflows repo |

### Terraform Backend Config Structure

````yaml
#TF Backend Config
terraform_backend_resource_group: ${{ needs.variables.outputs.TERRAFORM_BACKEND_RESOURCE_GROUP }}
terraform_backend_location: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION }}
terraform_backend_storage_account: ${{ needs.variables.outputs.TERRAFORM_BACKEND_STORAGE_ACCOUNT }}
terraform_backend_container: ${{ needs.variables.outputs.TERRAFORM_BACKEND_CONTAINER }}
terraform_backend_sku: ${{ needs.variables.outputs.TERRAFORM_BACKEND_SKU }}
terraform_backend_env: ${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}
terraform_backend_location_short: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}
custom_backend_config: ${{ vars.CUSTOM_BACKEND_CONFIG }}
````

### OIDC Configuration Structure

````yaml
#OIDC Configuration          
arm_client_id: ${{ needs.variables.outputs.ARM_CLIENT_ID }}
arm_tenant_id: ${{ needs.variables.outputs.ARM_TENANT_ID }}
arm_subscription_id: ${{ needs.variables.outputs.ARM_SUBSCRIPTION_ID }}
````

### Reusable Workflow Branch Configuration

````yaml
reusable_workflow_branch: ${{ vars.REUSABLE_WORKFLOW_BRANCH || 'main' }}
````

## Terraform Apply Workflow

We create a separate workflow that does the apply as per this example.

The main difference is setting the following value to 'true' in the TF Config block:

````yaml
terraform_apply: ${{ fromJson(vars.TERRAFORM_APPLY || 'true') }}
````

Other changes you might want to make from your plan to apply workflow are the pipeline name and workflow triggers, example:

````yaml
name: 'dev - terraform apply'

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - terraform/*.tf
      - terraform/config/dev/**
      - terraform/config/global.tfvars
      - .github/workflows/dev-terraform-*.yml
````

## Report Issues

Any code bugs should be raised here.

## Examples

### Reusable Terraform Plan Workflow Caller

> **Note:** Always refer/copy the workflow examples from source.

````yaml
name: 'dev uks - terraform plan'
 
on: 
  workflow_dispatch:
  pull_request:
    branches:
      - main    
    paths:
      - terraform/*.tf
      - terraform/config/dev/**
      - terraform/config/global.tfvars
      - .github/workflows/dev-terraform-*.yml

concurrency:
  group: workflow-tf-dev-uks
  cancel-in-progress: false    

permissions:
  id-token: write
  contents: write
  pull-requests: write
  actions: read
  
jobs:
  variables:
    name: 'set-vars'
    environment: 'dev' 
    runs-on: >- 
      ${{ 
        (contains(vars.RUNNER_CONFIG, '{') && contains(vars.RUNNER_CONFIG, '}'))
        && (fromJSON(vars.RUNNER_CONFIG).runner || fromJSON(vars.RUNNER_CONFIG).labels)
        || vars.RUNNER_CONFIG
      }}
    steps:
      - name: Set and Output Variables
        id: set_vars
        run: |
         declare -A vars=(
            ["ENVIRONMENT_PLAN"]="${{ vars.PLAN_ENV || 'n/a' }}"
            ["ENVIRONMENT_APPLY"]="${{ vars.APPLY_ENV || 'n/a' }}"
            ["TERRAFORM_BACKEND_RESOURCE_GROUP"]="${{ vars.TF_BACKEND_SA_RG }}"
            ["TERRAFORM_BACKEND_STORAGE_ACCOUNT"]="${{ vars.TF_BACKEND_SA }}"
            ["TERRAFORM_BACKEND_LOCATION"]="${{ vars.TF_BACKEND_SA_REGION }}"
            ["TERRAFORM_BACKEND_LOCATION_SHORT"]="${{ vars.TF_BACKEND_SA_REGION_SHORT }}"
            ["TERRAFORM_BACKEND_CONTAINER"]="${{ vars.TF_BACKEND_SA_CONTAINER }}"
            ["TERRAFORM_BACKEND_SKU"]="${{ vars.TF_BACKEND_SA_SKU }}"
            ["TERRAFORM_BACKEND_ENV"]="${{ vars.TF_BACKEND_ENV }}"
            ["ARM_TENANT_ID"]="${{ vars.ARM_TENANT_ID }}"
            ["ARM_SUBSCRIPTION_ID"]="${{ vars.ARM_SUBSCRIPTION_ID }}"
            ["ARM_CLIENT_ID"]="${{ vars.ARM_CLIENT_ID }}"
          )
          ordered_keys=(ARM_TENANT_ID ARM_SUBSCRIPTION_ID ARM_CLIENT_ID ENVIRONMENT_PLAN ENVIRONMENT_APPLY TERRAFORM_BACKEND_RESOURCE_GROUP TERRAFORM_BACKEND_STORAGE_ACCOUNT TERRAFORM_BACKEND_LOCATION TERRAFORM_BACKEND_LOCATION_SHORT TERRAFORM_BACKEND_CONTAINER TERRAFORM_BACKEND_SKU TERRAFORM_BACKEND_ENV)
          {
            echo "| Variable | Value |"
            echo "|----------|-------|"
            for key in "${ordered_keys[@]}"; do
              echo "| $key | ${vars[$key]} |"
              echo "$key=${vars[$key]}" >> $GITHUB_OUTPUT
            done
          } >> $GITHUB_STEP_SUMMARY

    outputs:
      ENVIRONMENT_PLAN: ${{ steps.set_vars.outputs.ENVIRONMENT_PLAN }}
      ENVIRONMENT_APPLY: ${{ steps.set_vars.outputs.ENVIRONMENT_APPLY }}
      TERRAFORM_BACKEND_RESOURCE_GROUP: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_RESOURCE_GROUP }}
      TERRAFORM_BACKEND_STORAGE_ACCOUNT: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_STORAGE_ACCOUNT }}
      TERRAFORM_BACKEND_LOCATION: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_LOCATION }}
      TERRAFORM_BACKEND_LOCATION_SHORT: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}
      TERRAFORM_BACKEND_CONTAINER: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_CONTAINER }}
      TERRAFORM_BACKEND_SKU: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_SKU }}
      TERRAFORM_BACKEND_ENV: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_ENV }}
      ARM_TENANT_ID: ${{ steps.set_vars.outputs.ARM_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ steps.set_vars.outputs.ARM_SUBSCRIPTION_ID }}
      ARM_CLIENT_ID: ${{ steps.set_vars.outputs.ARM_CLIENT_ID }}

  reusable-tf:
    needs: variables
    uses: org/alz-reusable-workflows/.github/workflows/terraform-workflow.yml@main
    with:
      
      #Runner Config
      runs_on: >-
        ${{ vars.RUNNER_CONFIG || 
        '{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}' }}

      #Environment Config
      environment_plan: ${{ needs.variables.outputs.ENVIRONMENT_PLAN }}
      environment_apply: ${{ needs.variables.outputs.ENVIRONMENT_APPLY }}     
            
      #TF Backend Checks    
      check_tfstate_storage: ${{ fromJson(vars.CHECK_TFSTATE_STORAGE || 'true') }}
      tfstate_storage_script: ${{ vars.TFSTATE_STORAGE_SCRIPT || './scripts/create-tfstate-storage.sh --checks-only' }}
           
      #TF Config
      use_artifactory_token: true
      terraform_plan: ${{ fromJson(vars.TERRAFORM_PLAN || 'true') }}
      terraform_apply: ${{ fromJson(vars.TERRAFORM_APPLY || 'false') }}
      terraform_format: ${{ fromJson(vars.TERRAFORM_FORMAT || 'true') }}
      terraform_validate: ${{ fromJson(vars.TERRAFORM_VALIDATE || 'true') }}
      terraform_working_dir: ${{ vars.TERRAFORM_WORKING_DIR || './terraform' }}
      terraform_init_args: ${{ vars.TERRAFORM_INIT_ARGS || '' }}
      terraform_version: ${{ vars.TERRAFORM_VERSION || '1.9.7' }}
      terraform_plan_args: >-
        -var-file=config/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}.tfvars 
        -var-file=config/global.tfvars

      #TF Docs Configuration
      tf_docs_enabled: ${{ fromJson(vars.TF_DOCS_ENABLED || 'true') }}
      tf_docs_output_file: ${{ vars.TF_DOCS_OUTPUT_FILE || '../README.md' }}
      tf_docs_config_file: ${{ vars.TF_DOCS_CONFIG_FILE || '.terraform-docs.yml' }}

      #TF Backend Config
      terraform_backend_resource_group: ${{ needs.variables.outputs.TERRAFORM_BACKEND_RESOURCE_GROUP }}
      terraform_backend_location: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION }}
      terraform_backend_storage_account: ${{ needs.variables.outputs.TERRAFORM_BACKEND_STORAGE_ACCOUNT }}
      terraform_backend_container: ${{ needs.variables.outputs.TERRAFORM_BACKEND_CONTAINER }}
      terraform_backend_sku: ${{ needs.variables.outputs.TERRAFORM_BACKEND_SKU }}
      terraform_backend_env: ${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}
      terraform_backend_location_short: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}
      custom_backend_config: ${{ vars.CUSTOM_BACKEND_CONFIG }}      

      #OIDC Configuration           
      arm_client_id: ${{ needs.variables.outputs.ARM_CLIENT_ID }}
      arm_tenant_id: ${{ needs.variables.outputs.ARM_TENANT_ID }}
      arm_subscription_id: ${{ needs.variables.outputs.ARM_SUBSCRIPTION_ID }}

      #Misc
      push_plan_to_pr: ${{ fromJson(vars.PUSH_PLAN_TO_PR || 'true') }}
      install_kubelogin: false
      reusable_workflow_branch: ${{ vars.REUSABLE_WORKFLOW_BRANCH || 'main' }}
    secrets:
      GH_PAT: ${{ secrets.GH_PAT }}
      ARTIFACTORY_ACCESS_TOKEN: ${{ secrets.ARTIFACTORY_ACCESS_TOKEN }}
````

### Reusable Terraform Apply Workflow Caller

> **Note:** Always refer/copy the workflow examples from source.

````yaml
name: 'dev - terraform apply'

on:
  workflow_dispatch:
  push:
    branches:
      - main
    paths:
      - terraform/*.tf
      - terraform/config/dev/**
      - terraform/config/global.tfvars
      - .github/workflows/dev-terraform-*.yml

concurrency:
  group: workflow-tf-dev-uks
  cancel-in-progress: false    

permissions:
  id-token: write
  contents: write
  pull-requests: write
  actions: read
  
jobs:
  variables:
    name: 'set-vars'
    environment: 'dev' 
    runs-on: >- 
      ${{ 
        (contains(vars.RUNNER_CONFIG, '{') && contains(vars.RUNNER_CONFIG, '}'))
        && (fromJSON(vars.RUNNER_CONFIG).runner || fromJSON(vars.RUNNER_CONFIG).labels)
        || vars.RUNNER_CONFIG
      }}
    steps:
      - name: Set and Output Variables
        id: set_vars
        run: |
         declare -A vars=(
            ["ENVIRONMENT_PLAN"]="${{ vars.PLAN_ENV || 'n/a' }}"
            ["ENVIRONMENT_APPLY"]="${{ vars.APPLY_ENV || 'n/a' }}"
            ["TERRAFORM_BACKEND_RESOURCE_GROUP"]="${{ vars.TF_BACKEND_SA_RG }}"
            ["TERRAFORM_BACKEND_STORAGE_ACCOUNT"]="${{ vars.TF_BACKEND_SA }}"
            ["TERRAFORM_BACKEND_LOCATION"]="${{ vars.TF_BACKEND_SA_REGION }}"
            ["TERRAFORM_BACKEND_LOCATION_SHORT"]="${{ vars.TF_BACKEND_SA_REGION_SHORT }}"
            ["TERRAFORM_BACKEND_CONTAINER"]="${{ vars.TF_BACKEND_SA_CONTAINER }}"
            ["TERRAFORM_BACKEND_SKU"]="${{ vars.TF_BACKEND_SA_SKU }}"
            ["TERRAFORM_BACKEND_ENV"]="${{ vars.TF_BACKEND_ENV }}"
            ["ARM_TENANT_ID"]="${{ vars.ARM_TENANT_ID }}"
            ["ARM_SUBSCRIPTION_ID"]="${{ vars.ARM_SUBSCRIPTION_ID }}"
            ["ARM_CLIENT_ID"]="${{ vars.ARM_CLIENT_ID }}"
          )
          ordered_keys=(ARM_TENANT_ID ARM_SUBSCRIPTION_ID ARM_CLIENT_ID ENVIRONMENT_PLAN ENVIRONMENT_APPLY TERRAFORM_BACKEND_RESOURCE_GROUP TERRAFORM_BACKEND_STORAGE_ACCOUNT TERRAFORM_BACKEND_LOCATION TERRAFORM_BACKEND_LOCATION_SHORT TERRAFORM_BACKEND_CONTAINER TERRAFORM_BACKEND_SKU TERRAFORM_BACKEND_ENV)
          {
            echo "| Variable | Value |"
            echo "|----------|-------|"
            for key in "${ordered_keys[@]}"; do
              echo "| $key | ${vars[$key]} |"
              echo "$key=${vars[$key]}" >> $GITHUB_OUTPUT
            done
          } >> $GITHUB_STEP_SUMMARY

    outputs:
      ENVIRONMENT_PLAN: ${{ steps.set_vars.outputs.ENVIRONMENT_PLAN }}
      ENVIRONMENT_APPLY: ${{ steps.set_vars.outputs.ENVIRONMENT_APPLY }}
      TERRAFORM_BACKEND_RESOURCE_GROUP: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_RESOURCE_GROUP }}
      TERRAFORM_BACKEND_STORAGE_ACCOUNT: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_STORAGE_ACCOUNT }}
      TERRAFORM_BACKEND_LOCATION: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_LOCATION }}
      TERRAFORM_BACKEND_LOCATION_SHORT: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}
      TERRAFORM_BACKEND_CONTAINER: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_CONTAINER }}
      TERRAFORM_BACKEND_SKU: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_SKU }}
      TERRAFORM_BACKEND_ENV: ${{ steps.set_vars.outputs.TERRAFORM_BACKEND_ENV }}
      ARM_TENANT_ID: ${{ steps.set_vars.outputs.ARM_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ steps.set_vars.outputs.ARM_SUBSCRIPTION_ID }}
      ARM_CLIENT_ID: ${{ steps.set_vars.outputs.ARM_CLIENT_ID }}

  reusable-tf:
    needs: variables
    uses: org/alz-reusable-workflows/.github/workflows/terraform-workflow.yml@main
    with:
      
      #Runner Config
      runs_on: >-
        ${{ vars.RUNNER_CONFIG || 
        '{"group": "replacesvcs", "labels": ["self-hosted", "prod", "linuxdefender"]}' }}

      #Environment Config
      environment_plan: ${{ needs.variables.outputs.ENVIRONMENT_PLAN }}
      environment_apply: ${{ needs.variables.outputs.ENVIRONMENT_APPLY }}     
            
      #TF Backend Checks    
      check_tfstate_storage: ${{ fromJson(vars.CHECK_TFSTATE_STORAGE || 'true') }}
      tfstate_storage_script: ${{ vars.TFSTATE_STORAGE_SCRIPT || './scripts/create-tfstate-storage.sh --checks-only' }}
           
      #TF Config
      use_artifactory_token: false
      terraform_plan: ${{ fromJson(vars.TERRAFORM_PLAN || 'true') }}
      terraform_apply: ${{ fromJson(vars.TERRAFORM_APPLY || 'true') }}
      terraform_format: ${{ fromJson(vars.TERRAFORM_FORMAT || 'true') }}
      terraform_validate: ${{ fromJson(vars.TERRAFORM_VALIDATE || 'true') }}
      terraform_working_dir: ${{ vars.TERRAFORM_WORKING_DIR || './terraform' }}
      terraform_init_args: ${{ vars.TERRAFORM_INIT_ARGS || '' }}
      terraform_version: ${{ vars.TERRAFORM_VERSION || '1.9.7' }}
      terraform_plan_args: >-
        -var-file=config/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}/${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}.tfvars 
        -var-file=config/global.tfvars

      #TF Docs Configuration
      tf_docs_enabled: ${{ fromJson(vars.TF_DOCS_ENABLED || 'true') }}
      tf_docs_output_file: ${{ vars.TF_DOCS_OUTPUT_FILE || '../README.md' }}
      tf_docs_config_file: ${{ vars.TF_DOCS_CONFIG_FILE || '.terraform-docs.yml' }}

      #TF Backend Config
      terraform_backend_resource_group: ${{ needs.variables.outputs.TERRAFORM_BACKEND_RESOURCE_GROUP }}
      terraform_backend_location: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION }}
      terraform_backend_storage_account: ${{ needs.variables.outputs.TERRAFORM_BACKEND_STORAGE_ACCOUNT }}
      terraform_backend_container: ${{ needs.variables.outputs.TERRAFORM_BACKEND_CONTAINER }}
      terraform_backend_sku: ${{ needs.variables.outputs.TERRAFORM_BACKEND_SKU }}
      terraform_backend_env: ${{ needs.variables.outputs.TERRAFORM_BACKEND_ENV }}
      terraform_backend_location_short: ${{ needs.variables.outputs.TERRAFORM_BACKEND_LOCATION_SHORT }}
      custom_backend_config: ${{ vars.CUSTOM_BACKEND_CONFIG }}      

      #OIDC Configuration           
      arm_client_id: ${{ needs.variables.outputs.ARM_CLIENT_ID }}
      arm_tenant_id: ${{ needs.variables.outputs.ARM_TENANT_ID }}
      arm_subscription_id: ${{ needs.variables.outputs.ARM_SUBSCRIPTION_ID }}

      #Misc
      push_plan_to_pr: ${{ fromJson(vars.PUSH_PLAN_TO_PR || 'true') }}
      install_kubelogin: false
      reusable_workflow_branch: ${{ vars.REUSABLE_WORKFLOW_BRANCH || 'main' }}	
    secrets:
      GH_PAT: ${{ secrets.GH_PAT }}
      ARTIFACTORY_ACCESS_TOKEN: ${{ secrets.ARTIFACTORY_ACCESS_TOKEN }}
````