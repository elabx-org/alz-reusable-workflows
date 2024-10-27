#!/bin/bash
# version = 7.0

set -e

# Environment Variables
RESOURCE_GROUP=${TERRAFORM_BACKEND_RESOURCE_GROUP}
STORAGE_ACCOUNT=${TERRAFORM_BACKEND_STORAGE_ACCOUNT}
CONTAINER_NAME=${TERRAFORM_BACKEND_CONTAINER}
LOCATION=${TERRAFORM_BACKEND_LOCATION}
LOCATION_SHORT=${TERRAFORM_BACKEND_LOCATION_SHORT}
SKU=${TERRAFORM_BACKEND_SKU}
ENVIRONMENT=${TERRAFORM_BACKEND_ENV}
SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}

# Configuration (using environment variables with defaults)
RUN_INFRA_CHECKS=${RUN_INFRA_CHECKS:-true}
RUN_BACKUP_CHECKS=${RUN_BACKUP_CHECKS:-true}
RUN_RESOURCE_PROVIDER_CHECK=${RUN_RESOURCE_PROVIDER_CHECK:-true}
RUN_RESOURCE_GROUP_CHECK=${RUN_RESOURCE_GROUP_CHECK:-true}
RUN_STORAGE_ACCOUNT_CHECK=${RUN_STORAGE_ACCOUNT_CHECK:-true}
RUN_NETWORK_RULES_CHECK=${RUN_NETWORK_RULES_CHECK:-true}
RUN_BLOB_PROPERTIES_CHECK=${RUN_BLOB_PROPERTIES_CHECK:-true}
RUN_CONTAINER_PROPERTIES_CHECK=${RUN_CONTAINER_PROPERTIES_CHECK:-true}

CREATE_RESOURCE_GROUP=${CREATE_RESOURCE_GROUP:-true}
CREATE_STORAGE_ACCOUNT=${CREATE_STORAGE_ACCOUNT:-true}
UPDATE_NETWORK_RULES=${UPDATE_NETWORK_RULES:-false}
CREATE_CONTAINER=${CREATE_CONTAINER:-true}
UPDATE_BLOB_POLICIES=${UPDATE_BLOB_POLICIES:-true}
UPDATE_CONTAINER_POLICIES=${UPDATE_CONTAINER_POLICIES:-true}
SETUP_AZURE_BACKUP=${SETUP_AZURE_BACKUP:-true}

# Initialize the consolidated_message at the start of script
consolidated_message="Azure Backup Configuration Status:%0A"

# Default subnet IDs
default_subnet_ids=(
    "/subscriptions/redacted_sub_id/resourceGroups/rg-vnet_spoke_shared_services_defender-yrbj/providers/Microsoft.Network/virtualNetworks/vnet-shared_services_network_1_defender-jthq/subnets/snet-aks_defender_nodepool_system-isxr" # new bank runners
    "/subscriptions/redacted_sub_id/resourceGroups/rg-vnet_spoke_shared_services_defender-yrbj/providers/Microsoft.Network/virtualNetworks/vnet-shared_services_network_1_defender-jthq/subnets/snet-aks_defender_nodepool_user1-yegu" # new bank runners
)

# Use custom subnet IDs if provided, otherwise use default
if [ -n "$SUBNET_IDS" ]; then
    IFS=',' read -ra subnet_ids <<< "$SUBNET_IDS"
else
    subnet_ids=("${default_subnet_ids[@]}")
fi

## Determine storage setting based on location
if [[ "$LOCATION" == "UKWest" || "$LOCATION_SHORT" == "ukw" ]]; then
    STORAGE_SETTING="[{'type':'LocallyRedundant','datastore-type':'VaultStore'}]"
elif [[ "$LOCATION" == "UKSouth" || "$LOCATION_SHORT" == "uks" ]]; then
    STORAGE_SETTING="[{'type':'ZoneRedundant','datastore-type':'VaultStore'}]"
else
    echo "[ERROR]: Unsupported location $LOCATION"
    exit 1
fi

# Logging function
log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Function to create backup instance JSON from template
create_backup_instance_json() {
    local template_file="$GITHUB_ACTION_PATH/policy/backup-instance-template.json"
    local output_file="$GITHUB_ACTION_PATH/policy/backup-instance.json"

    if [ ! -f "$template_file" ]; then
        log "ERROR" "❌ Backup instance template file not found: $template_file"
        return 1
    fi

    log "INFO" "📝 Creating backup instance configuration from template..."
    
    sed -e "s/\${SUBSCRIPTION_ID}/${SUBSCRIPTION_ID}/g" \
        -e "s/\${RESOURCE_GROUP}/${RESOURCE_GROUP}/g" \
        -e "s/\${LOCATION}/${LOCATION}/g" \
        -e "s/\${STORAGE_ACCOUNT}/${STORAGE_ACCOUNT}/g" \
        -e "s/\${BACKUP_VAULT_NAME}/${BACKUP_VAULT_NAME}/g" \
        -e "s/\${BACKUP_POLICY_NAME}/${BACKUP_POLICY_NAME}/g" \
        -e "s/\${BACKUP_INSTANCE_NAME}/${BACKUP_INSTANCE_NAME}/g" \
        "$template_file" > "$output_file"

    if [ $? -eq 0 ]; then
        log "INFO" "✅ Successfully created backup instance configuration"
        return 0
    else
        log "ERROR" "❌ Failed to create backup instance configuration"
        return 1
    fi
}

# Function to ensure Azure CLI dataprotection extension is installed
install_dataprotection_extension() {
    log "INFO" "🔍 Checking if dataprotection extension is installed..."
    if ! az extension show --name dataprotection &>/dev/null; then
        log "INFO" "🔄 Installing dataprotection extension..."
        az extension add --name dataprotection --only-show-errors
        if [ $? -eq 0 ]; then
            log "INFO" "✅ Successfully installed dataprotection extension"
        else
            log "ERROR" "❌ Failed to install dataprotection extension"
            return 1
        fi
    else
        log "INFO" "ℹ️ Dataprotection extension is already installed"
    fi
    return 0
}

# Function to retrieve and set tags
get_and_set_tags() {
    log "INFO" "🔍 Retrieving subscription tags..."
    local subscription_tags=$(az tag list --resource-id /subscriptions/$SUBSCRIPTION_ID)

    # Extract specific tag values with default values if tags are not found
    boe_service_name=$(echo $subscription_tags | jq -r '.properties.tags.boe_service_name // "placeholder_service_name"')
    boe_budget_code=$(echo $subscription_tags | jq -r '.properties.tags.boe_budget_code // "placeholder_budget_code"')
    boe_environment=$(echo $subscription_tags | jq -r '.properties.tags.boe_environment // "placeholder_env"')
    boe_service_tier=$(echo $subscription_tags | jq -r '.properties.tags.boe_service_tier // "placeholder_tier"')

    # Extract max first 4 letters of the boe_environment value used for naming resources
    ENV_SHORT=${boe_environment:0:4}
    SVC_NAME=${boe_service_name:0:4}

    # Prepare TAGS variable
    TAGS="boe_service_name=$boe_service_name boe_budget_code=$boe_budget_code boe_environment=$boe_environment boe_service_tier=$boe_service_tier"

    log "INFO" "✅ Successfully retrieved and set tags"
}

# Function to set up backup variables
setup_backup_variables() {
    if [ -z "$ENV_SHORT" ] || [ -z "$SVC_NAME" ]; then
        log "ERROR" "❌ ENV_SHORT and SVC_NAME must be set before calling setup_backup_variables"
        return 1
    fi

    BACKUP_USE="tfstate"
    POLICY_FILE="$GITHUB_ACTION_PATH/policy/backup-policy.json"
    BACKUP_VAULT_NAME="bvault-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
    BACKUP_POLICY_NAME="bkpol-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
    BACKUP_INSTANCE_NAME="bki-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"

    log "INFO" "✅ Successfully set up backup variables"
}

# Function to check if container exists
check_container_exists() {
    log "INFO" "🔍 Checking if container $CONTAINER_NAME exists..."
    az storage container show --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT --auth-mode login &>/dev/null
}

# Function to check resource provider registration
check_resource_provider() {
    local provider=$1
    log "INFO" "🔍 Checking $provider Resource Provider registration status..."
    local state=$(az provider show --namespace $provider --query "registrationState" -o tsv)
    if [ "$state" != "Registered" ]; then
        log "ERROR" "❌ $provider resource provider is not registered."
        return 1
    fi
    return 0
}

# Function to check resource group existence
check_resource_group() {
    log "INFO" "🔍 Checking if Resource Group $RESOURCE_GROUP exists..."
    az group show --name $RESOURCE_GROUP &>/dev/null
}

# Function to check storage account existence and configuration
check_storage_account() {
    log "INFO" "🔍 Checking if Storage Account $STORAGE_ACCOUNT exists and is properly configured..."
    local account_info=$(az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP -o json)
    if [ -z "$account_info" ]; then
        log "ERROR" "❌ Storage Account $STORAGE_ACCOUNT does not exist."
        return 1
    fi

    local tls_version=$(echo $account_info | jq -r '.minimumTlsVersion')
    if [ "$tls_version" != "TLS1_2" ]; then
        log "ERROR" "❌ Storage Account $STORAGE_ACCOUNT does not use TLS 1.2."
        return 1
    fi

    return 0
}

# Function to check network rules
check_network_rules() {
    log "INFO" "🔍 Checking Storage Account network rules..."
    local all_rules_exist=true
    
    for subnet_id in "${subnet_ids[@]}"; do
        if ! az storage account network-rule list --account-name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "virtualNetworkRules[?virtualNetworkResourceId=='$subnet_id']" -o tsv &>/dev/null; then
            log "ERROR" "❌ Network rule for subnet $subnet_id does not exist."
            all_rules_exist=false
        fi
    done

    local default_action=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "networkRuleSet.defaultAction" -o tsv)
    if [ "$default_action" != "Deny" ]; then
        log "ERROR" "❌ Default network rule is not set to Deny."
        all_rules_exist=false
    fi

    if $all_rules_exist; then
        return 0
    else
        return 1
    fi
}

# Function to check blob service properties
check_blob_service_properties() {
    log "INFO" "🔍 Checking blob service properties..."
    local properties=$(az storage blob service-properties show --account-name $STORAGE_ACCOUNT --auth-mode login -o json)
    local delete_retention_enabled=$(echo $properties | jq -r '.deleteRetentionPolicy.enabled')
    local delete_retention_days=$(echo $properties | jq -r '.deleteRetentionPolicy.days')

    if [[ "$delete_retention_enabled" == "true" && "$delete_retention_days" == "90" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check container service properties
check_container_service_properties() {
    log "INFO" "🔍 Checking container service properties..."
    local properties=$(az storage account blob-service-properties show --account-name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP -o json)
    local container_delete_retention_enabled=$(echo $properties | jq -r '.containerDeleteRetentionPolicy.enabled')
    local container_delete_retention_days=$(echo $properties | jq -r '.containerDeleteRetentionPolicy.days')
    local change_feed_enabled=$(echo $properties | jq -r '.changeFeed.enabled')
    local change_feed_retention_days=$(echo $properties | jq -r '.changeFeed.retentionInDays')
    local versioning_enabled=$(echo $properties | jq -r '.isVersioningEnabled')
    local restore_policy_enabled=$(echo $properties | jq -r '.restorePolicy.enabled')
    local restore_days=$(echo $properties | jq -r '.restorePolicy.days')

    if [[ "$container_delete_retention_enabled" == "true" && 
          "$container_delete_retention_days" == "90" &&
          "$change_feed_enabled" == "true" &&
          "$change_feed_retention_days" == "90" &&
          "$versioning_enabled" == "true" &&
          "$restore_policy_enabled" == "true" &&
          "$restore_days" == "89" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to perform all checks
perform_checks() {
    local backup_warnings=${1:-false}  # Pass backup warnings status, default to false
    local all_checks_passed=true
    local check_results=()
    local failed_checks=()

    log "INFO" "🔍 Starting infrastructure checks..."

    # Container existence check
    if check_container_exists; then
        log "INFO" "📦 ⏭️ Container $CONTAINER_NAME exists. Skipping full checks."
        check_results+=("✅ Container: exists")
    else
        log "INFO" "📦 ❌ Container $CONTAINER_NAME does not exist. Performing all checks."
        check_results+=("❌ Container: does not exist")
        
        # Resource Provider check
        if $RUN_RESOURCE_PROVIDER_CHECK; then
            if check_resource_provider "Microsoft.Storage"; then
                check_results+=("✅ Resource Provider: registered")
            else
                check_results+=("❌ Resource Provider: not registered")
                failed_checks+=("Microsoft.Storage resource provider is not registered")
                all_checks_passed=false
            fi
        fi

        # Resource Group check
        if $RUN_RESOURCE_GROUP_CHECK; then
            if check_resource_group; then
                check_results+=("✅ Resource Group: exists")
            else
                check_results+=("❌ Resource Group: does not exist")
                failed_checks+=("Resource Group does not exist")
                all_checks_passed=false
            fi
        fi

        # Storage Account check
        if $RUN_STORAGE_ACCOUNT_CHECK; then
            if check_storage_account; then
                check_results+=("✅ Storage Account: properly configured")
            else
                check_results+=("❌ Storage Account: misconfigured or does not exist")
                failed_checks+=("Storage Account is misconfigured or does not exist")
                all_checks_passed=false
            fi
        fi
    fi

    # Network Rules check
    if $RUN_NETWORK_RULES_CHECK; then
        if check_network_rules; then
            check_results+=("✅ Network Rules: properly configured")
        else
            check_results+=("❌ Network Rules: misconfigured")
            failed_checks+=("Network rules are not properly configured")
            all_checks_passed=false
        fi
    fi

    # Blob Properties check
    if $RUN_BLOB_PROPERTIES_CHECK; then
        if check_blob_service_properties; then
            check_results+=("✅ Blob Properties: properly configured")
        else
check_results+=("❌ Blob Properties: misconfigured")
            failed_checks+=("Blob properties are not properly configured")
            all_checks_passed=false
        fi
    fi

    # Container Properties check
    if $RUN_CONTAINER_PROPERTIES_CHECK; then
        if check_container_service_properties; then
            check_results+=("✅ Container Properties: properly configured")
        else
            check_results+=("❌ Container Properties: misconfigured")
            failed_checks+=("Container properties are not properly configured")
            all_checks_passed=false
        fi
    fi

    # Display summary of all checks
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "Infrastructure Checks Summary:"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for result in "${check_results[@]}"; do
        log "INFO" "$result"
    done
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # If any checks failed, create an error annotation
    if ! $all_checks_passed; then
        echo "::error::Infrastructure Checks Failed"
        for failed in "${failed_checks[@]}"; do
            echo "::error::- ${failed}"
        done
        log "ERROR" "❌ One or more infrastructure checks failed"
        return 1
    else
        if [[ $consolidated_message != "Azure Backup Configuration Status:%0A" ]]; then
            echo "::notice::Infrastructure checks passed with backup configuration warnings"
            log "INFO" "✅ Infrastructure checks passed (with backup configuration warnings)"
        else
            echo "::notice::All infrastructure checks passed successfully"
            log "INFO" "✅ All infrastructure checks passed"
        fi
        return 0
    fi
}

# Function to check backup status without failing
check_backup_status() {
    log "INFO" "🔍 Checking backup status..."
    VAULT_EXISTS=false
    POLICY_EXISTS=false
    ROLE_ASSIGNED=false
    BACKUP_PROTECTION_ENABLED=false

    # Install the dataprotection extension
    install_dataprotection_extension

    # Check if the backup vault exists
    log "INFO" "🔍 Checking if Backup Vault exists..."
    if az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
        log "INFO" "Backup Vault '$BACKUP_VAULT_NAME' exists"
        VAULT_EXISTS=true
        check_results+=("✅ Backup Vault: exists")
    else
        log "INFO" "Backup Vault '$BACKUP_VAULT_NAME' does not exist"    
        check_results+=("❌ Backup Vault: does not exist")
    fi

    # Check if the backup policy exists
    if [ "$VAULT_EXISTS" = true ]; then
        log "INFO" "🔍 Checking if Backup Policy exists..."
        if az dataprotection backup-policy show --resource-group $RESOURCE_GROUP --vault-name $BACKUP_VAULT_NAME --name $BACKUP_POLICY_NAME &>/dev/null; then
            log "INFO" "Backup Policy '$BACKUP_POLICY_NAME' exists"
            POLICY_EXISTS=true
            check_results+=("✅ Backup Policy: exists")
        else
            log "INFO" "Backup Policy '$BACKUP_POLICY_NAME' does not exist"    
            check_results+=("❌ Backup Policy: does not exist")
        fi

        # Check if Storage Account Backup Contributor role is assigned
        log "INFO" "🔍 Checking Storage Account Backup Contributor role assignment..."
        VAULT_OBJECT_ID=$(az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP --query identity.principalId --output tsv)
        if az role assignment list --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" --query "[?principalId=='${VAULT_OBJECT_ID}' && roleDefinitionName=='Storage Account Backup Contributor']" -o tsv | grep -q "Storage Account Backup Contributor"; then
            log "INFO" "Storage Account Backup Contributor role is properly assigned"
            ROLE_ASSIGNED=true
            check_results+=("✅ Backup Contributor Role: assigned")
        else
            log "INFO" "Storage Account Backup Contributor role is not assigned"    
            check_results+=("❌ Backup Contributor Role: not assigned")
        fi

        # Check if Azure Backup is enabled
        log "INFO" "🔍 Checking Azure Backup status..."
        backup_instance=$(az dataprotection backup-instance list \
            --resource-group "$RESOURCE_GROUP" \
            --vault-name "$BACKUP_VAULT_NAME" \
            --query "[?name=='$BACKUP_INSTANCE_NAME' && properties.dataSourceInfo.resourceName=='$STORAGE_ACCOUNT' && properties.currentProtectionState=='ProtectionConfigured']" \
            --output tsv)

        if [ -n "$backup_instance" ]; then
            log "INFO" "Azure Backup is properly configured for storage account $STORAGE_ACCOUNT"
            BACKUP_PROTECTION_ENABLED=true
            check_results+=("✅ Backup Protection: enabled")
        else
            log "INFO" "Azure Backup is not configured for storage account $STORAGE_ACCOUNT"
            check_results+=("❌ Backup Protection: not configured")
        fi
    else
        check_results+=("⚠️ Backup Policy: check skipped (vault missing)")
        check_results+=("⚠️ Backup Contributor Role: check skipped (vault missing)")
        check_results+=("⚠️ Backup Protection: check skipped (vault missing)")
    fi

    # Display summary of all backup checks
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "Backup Status Check Summary:"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for result in "${check_results[@]}"; do
        log "INFO" "$result"
    done
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to perform backup checks
perform_checks_backup() {
    if $RUN_BACKUP_CHECKS; then
        log "INFO" "🔍 Performing backup checks..."
        local check_results=()
        consolidated_message="Azure Backup Configuration Status:%0A"

        # Run checks
        log "INFO" "🔍 Checking backup status..."
        install_dataprotection_extension

        # Check if the backup vault exists
        log "INFO" "🔍 Checking if Backup Vault exists..."
        VAULT_EXISTS=false
        POLICY_EXISTS=false
        ROLE_ASSIGNED=false
        BACKUP_PROTECTION_ENABLED=false

        if az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
            log "INFO" "Backup Vault '$BACKUP_VAULT_NAME' exists"
            VAULT_EXISTS=true
            check_results+=("✅ Backup Vault: exists")
        else
            log "INFO" "Backup Vault '$BACKUP_VAULT_NAME' does not exist"    
            check_results+=("❌ Backup Vault: does not exist")
            consolidated_message+="- Backup Vault does not exist%0A"
        fi

        # Only check other components if vault exists
        if [ "$VAULT_EXISTS" = false ]; then
            check_results+=("⚠️ Backup Policy: check skipped (vault missing)")
            check_results+=("⚠️ Backup Contributor Role: check skipped (vault missing)")
            check_results+=("⚠️ Backup Protection: check skipped (vault missing)")
            consolidated_message+="- Backup Policy does not exist%0A"
            consolidated_message+="- Storage Account Backup Contributor role is not assigned%0A"
            consolidated_message+="- Azure Backup is not configured for storage account%0A"
        else
            # Check backup policy
            if az dataprotection backup-policy show --resource-group $RESOURCE_GROUP --vault-name $BACKUP_VAULT_NAME --name $BACKUP_POLICY_NAME &>/dev/null; then
                POLICY_EXISTS=true
                check_results+=("✅ Backup Policy: exists")
            else
                check_results+=("❌ Backup Policy: does not exist")
                consolidated_message+="- Backup Policy does not exist%0A"
            fi

            # Check role assignment
            VAULT_OBJECT_ID=$(az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP --query identity.principalId --output tsv)
            if az role assignment list --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" --query "[?principalId=='${VAULT_OBJECT_ID}' && roleDefinitionName=='Storage Account Backup Contributor']" -o tsv | grep -q "Storage Account Backup Contributor"; then
                ROLE_ASSIGNED=true
                check_results+=("✅ Backup Contributor Role: assigned")
            else
                check_results+=("❌ Backup Contributor Role: not assigned")
                consolidated_message+="- Storage Account Backup Contributor role is not assigned%0A"
            fi

            # Check backup protection
            backup_instance=$(az dataprotection backup-instance list \
                --resource-group "$RESOURCE_GROUP" \
                --vault-name "$BACKUP_VAULT_NAME" \
                --query "[?name=='$BACKUP_INSTANCE_NAME' && properties.dataSourceInfo.resourceName=='$STORAGE_ACCOUNT' && properties.currentProtectionState=='ProtectionConfigured']" \
                --output tsv)

            if [ -n "$backup_instance" ]; then
                BACKUP_PROTECTION_ENABLED=true
                check_results+=("✅ Backup Protection: enabled")
            else
                check_results+=("❌ Backup Protection: not configured")
                consolidated_message+="- Azure Backup is not configured for storage account%0A"
            fi
        fi

        # Display single summary
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "INFO" "Azure Backup Checks Summary:"
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for result in "${check_results[@]}"; do
            log "INFO" "$result"
        done
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Create warning if needed
        if [[ $consolidated_message != "Azure Backup Configuration Status:%0A" ]]; then
            echo "::warning::${consolidated_message}"
            log "WARN" "⚠️ One or more backup checks had warnings"
        fi
    else
        log "INFO" "ℹ️ Skipping backup checks"
    fi
}


# Function to register resource provider
register_resource_provider() {
    local provider=$1
    log "INFO" "🔄 Registering $provider resource provider..."
    az provider register --namespace $provider
    
    while [ "$(az provider show --namespace $provider --query "registrationState" -o tsv)" != "Registered" ]; do
        log "INFO" "⏳ Waiting for $provider resource provider to be registered..."
        sleep 10
    done
    log "INFO" "✅ Successfully registered $provider resource provider"
}

# Function to create resource group
create_resource_group() {
    if ! check_resource_group; then
        log "INFO" "🏗️ Creating Resource Group $RESOURCE_GROUP..."
        az group create --location $LOCATION --name $RESOURCE_GROUP --tags $TAGS --output none
        log "INFO" "✅ Successfully created Resource Group $RESOURCE_GROUP"
    else
        log "INFO" "ℹ️ Resource Group $RESOURCE_GROUP already exists"
    fi
}

# Function to create storage account
create_storage_account() {
    if ! check_storage_account; then
        log "INFO" "🏗️ Creating Storage Account $STORAGE_ACCOUNT..."
        az storage account create \
            --name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --sku $SKU \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access false \
            --public-network-access Enabled \
            --default-action Allow \
            --tags $TAGS \
            --output none
        log "INFO" "✅ Successfully created Storage Account $STORAGE_ACCOUNT"
    else
        log "INFO" "ℹ️ Storage Account $STORAGE_ACCOUNT already exists"
    fi
}

# Function to update storage account network rules
update_storage_network_rules() {
    log "INFO" "🔒 Updating storage account network rules..."
    az storage account update \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --default-action Deny \
        --bypass AzureServices \
        --output none

    for subnet_id in "${subnet_ids[@]}"; do
        log "INFO" "🔗 Adding network rule for subnet: $(basename $subnet_id)"
        az storage account network-rule add \
            --account-name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --subnet $subnet_id \
            --output none
    done
    log "INFO" "✅ Successfully updated network rules"
}

# Function to create container
create_container() {
    if ! check_container_exists; then
        log "INFO" "📦 Creating container $CONTAINER_NAME..."
        az storage container create \
            --name $CONTAINER_NAME \
            --account-name $STORAGE_ACCOUNT \
            --auth-mode login \
            --output none
        log "INFO" "✅ Successfully created container $CONTAINER_NAME"
    else
        log "INFO" "ℹ️ Container $CONTAINER_NAME already exists"
    fi
}

# Function to update blob policies
update_blob_policies() {
    # Retrieve storage account key
    STORAGE_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT --query '[0].value' --output tsv)
    if ! check_blob_service_properties; then
        log "INFO" "🔄 Updating blob policies..."
        az storage blob service-properties delete-policy update \
            --account-name $STORAGE_ACCOUNT \
            --account-key $STORAGE_KEY \
            --enable true \
            --days-retained 90 \
            --output none
        log "INFO" "✅ Successfully updated blob policies"
    else
        log "INFO" "ℹ️ Blob policies are already configured correctly"
    fi
}

# Function to update container policies
update_container_policies() {
    if ! check_container_service_properties; then
        log "INFO" "🔄 Updating container policies..."
        az storage account blob-service-properties update \
            --account-name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --enable-container-delete-retention true \
            --container-delete-retention-days 90 \
            --enable-change-feed true \
            --change-feed-retention-days 90 \
            --enable-versioning true \
            --enable-restore-policy true \
            --restore-days 89 \
            --output none
        log "INFO" "✅ Successfully updated container policies"
    else
        log "INFO" "ℹ️ Container policies are already configured correctly"
    fi
}

# Function to set up Azure Backup for Blobs
setup_azure_backup() {
    log "INFO" "🔄 Setting up Azure Backup for Blobs..."
    
    # Get current status without failing
    check_backup_status

    if [ "$VAULT_EXISTS" = false ]; then
        log "INFO" "🏗️ Creating Backup Vault $BACKUP_VAULT_NAME..."
        if ! az dataprotection backup-vault create \
            --vault-name $BACKUP_VAULT_NAME \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --type "systemAssigned" \
            --storage-setting "$STORAGE_SETTING" \
            --immutability-state "unlocked" \
            --tags $TAGS; then
            log "ERROR" "❌ Failed to create Backup Vault"
            return 1
        fi
        log "INFO" "✅ Successfully created Backup Vault"
    fi

    if [ "$POLICY_EXISTS" = false ]; then
        log "INFO" "📝 Creating backup policy $BACKUP_POLICY_NAME..."
        if ! az dataprotection backup-policy create \
            --resource-group $RESOURCE_GROUP \
            --vault-name $BACKUP_VAULT_NAME \
            --name $BACKUP_POLICY_NAME \
            --policy @$POLICY_FILE; then
            log "ERROR" "❌ Failed to create backup policy"
            return 1
        fi
        log "INFO" "✅ Successfully created backup policy"
    fi

    if [ "$ROLE_ASSIGNED" = false ]; then
        log "INFO" "🔑 Assigning Storage Account Backup Contributor role..."
        local vault_object_id=$(az dataprotection backup-vault show \
            --vault-name $BACKUP_VAULT_NAME \
            --resource-group $RESOURCE_GROUP \
            --query identity.principalId \
            --output tsv)
            
        if ! az role assignment create \
            --assignee-object-id $vault_object_id \
            --assignee-principal-type ServicePrincipal \
            --role "Storage Account Backup Contributor" \
            --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"; then
            log "ERROR" "❌ Failed to assign Storage Account Backup Contributor role"
            return 1
        fi
        log "INFO" "✅ Successfully assigned Backup Contributor role"
    fi

    if [ "$BACKUP_PROTECTION_ENABLED" = false ]; then
        log "INFO" "🔒 Enabling backup protection for storage account $STORAGE_ACCOUNT..."
        local backup_result=$(az dataprotection backup-instance create \
            --resource-group $RESOURCE_GROUP \
            --vault-name $BACKUP_VAULT_NAME \
            --backup-instance @backup-instance.json 2>&1)
        
        if [ $? -eq 0 ]; then
            log "INFO" "✅ Successfully enabled Azure Backup for storage account $STORAGE_ACCOUNT"
        elif echo "$backup_result" | grep -q "Datasource is already protected"; then
            log "INFO" "ℹ️ Datasource is already protected - no action needed"
        else
            log "ERROR" "❌ Failed to enable backup protection: $backup_result"
            return 1
        fi
    else
        log "INFO" "ℹ️ Backup protection is already enabled for storage account $STORAGE_ACCOUNT"
    fi

    log "INFO" "✅ Azure Backup setup completed successfully"
    return 0
}

# Main function
main() {
    get_and_set_tags
    setup_backup_variables

    case "$1" in
        "checks-only")
            log "INFO" "🔍 Running in checks-only mode."
            perform_checks
            perform_checks_backup
            ;;
        "backup-only")
            log "INFO" "🔍 Running backup checks only."
            perform_checks_backup
            ;;
        "infra-only")
            log "INFO" "🔍 Running infrastructure checks only."
            perform_checks
            ;;
        "create"|"")  # Default to create if no argument provided
            log "INFO" "🏗️ Running in create/update mode."
            if $CREATE_RESOURCE_GROUP; then
                register_resource_provider "Microsoft.Storage"
                create_resource_group
            fi
            if $CREATE_STORAGE_ACCOUNT; then
                create_storage_account
            fi
            if $UPDATE_NETWORK_RULES; then
                update_storage_network_rules
            fi
            if $CREATE_CONTAINER; then
                create_container
            fi
            if $UPDATE_BLOB_POLICIES; then
                update_blob_policies
            fi
            if $UPDATE_CONTAINER_POLICIES; then
                update_container_policies
            fi
            if $SETUP_AZURE_BACKUP; then
                register_resource_provider "Microsoft.DataProtection"
                setup_azure_backup
            fi
            ;;
        *)
            log "ERROR" "❌ Invalid mode: $1"
            log "ERROR" "Valid modes are: checks-only, backup-only, infra-only, create"
            exit 1
            ;;
    esac
}

# Run the main function
main "$@"