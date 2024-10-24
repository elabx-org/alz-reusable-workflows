#!/bin/bash
# version = 6.1

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
RUN_RESOURCE_PROVIDER_CHECK=${RUN_RESOURCE_PROVIDER_CHECK:-true}
RUN_RESOURCE_GROUP_CHECK=${RUN_RESOURCE_GROUP_CHECK:-true}
RUN_STORAGE_ACCOUNT_CHECK=${RUN_STORAGE_ACCOUNT_CHECK:-true}
RUN_NETWORK_RULES_CHECK=${RUN_NETWORK_RULES_CHECK:-true}
RUN_BLOB_PROPERTIES_CHECK=${RUN_BLOB_PROPERTIES_CHECK:-true}
RUN_CONTAINER_PROPERTIES_CHECK=${RUN_CONTAINER_PROPERTIES_CHECK:-true}
RUN_BACKUP_CHECKS=${RUN_BACKUP_CHECKS:-true}

CREATE_RESOURCE_GROUP=${CREATE_RESOURCE_GROUP:-true}
CREATE_STORAGE_ACCOUNT=${CREATE_STORAGE_ACCOUNT:-true}
UPDATE_NETWORK_RULES=${UPDATE_NETWORK_RULES:-false}
CREATE_CONTAINER=${CREATE_CONTAINER:-true}
UPDATE_BLOB_POLICIES=${UPDATE_BLOB_POLICIES:-true}
UPDATE_CONTAINER_POLICIES=${UPDATE_CONTAINER_POLICIES:-true}
SETUP_AZURE_BACKUP=${SETUP_AZURE_BACKUP:-true}

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

# Backup Vault variables
BACKUP_USE="tfstate"
POLICY_FILE="backup-policy.json"
BACKUP_VAULT_NAME="bvault-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
BACKUP_POLICY_NAME="bkpol-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
BACKUP_INSTANCE_NAME="bki-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"

## Determine storage setting based on location
if [[ "$LOCATION" == "UKWest" || "$LOCATION_SHORT" == "ukw" ]]; then
    STORAGE_SETTING="[{'type':'LocallyRedundant','datastore-type':'VaultStore'}]"
elif [[ "$LOCATION" == "UKSouth" || "$LOCATION_SHORT" == "uks" ]]; then
    STORAGE_SETTING="[{'type':'ZoneRedundant','datastore-type':'VaultStore'}]"
else
    echo "[ERROR]: Unsupported location $LOCATION"
    exit 1
fi

# Read backup-instance-template.json & substitute the variables
# sed -e "s/\${SUBSCRIPTION_ID}/${SUBSCRIPTION_ID}/g" \
#     -e "s/\${RESOURCE_GROUP}/${RESOURCE_GROUP}/g" \
#     -e "s/\${LOCATION}/${LOCATION}/g" \
#     -e "s/\${STORAGE_ACCOUNT}/${STORAGE_ACCOUNT}/g" \
#     -e "s/\${BACKUP_VAULT_NAME}/${BACKUP_VAULT_NAME}/g" \
#     -e "s/\${BACKUP_POLICY_NAME}/${BACKUP_POLICY_NAME}/g" \
#     -e "s/\${BACKUP_INSTANCE_NAME}/${BACKUP_INSTANCE_NAME}/g" \
#     backup-instance-template.json > backup-instance.json

# Logging function
log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Function to retrieve and set tags
get_and_set_tags() {
    log "INFO" "Retrieving subscription tags..."
    local subscription_tags=$(az tag list --resource-id /subscriptions/$SUBSCRIPTION_ID)

    org_service_name=$(echo $subscription_tags | jq -r '.properties.tags.org_service_name // "placeholder_service_name"')
    org_budget_code=$(echo $subscription_tags | jq -r '.properties.tags.org_budget_code // "placeholder_budget_code"')
    org_environment=$(echo $subscription_tags | jq -r '.properties.tags.org_environment // "placeholder_env"')
    org_service_tier=$(echo $subscription_tags | jq -r '.properties.tags.org_service_tier // "placeholder_tier"')

    ENV_SHORT=${org_environment:0:4}
    SVC_NAME=${org_service_name:0:4}

    TAGS="org_service_name=$org_service_name org_budget_code=$org_budget_code org_environment=$org_environment org_service_tier=$org_service_tier"
}

# Function to check if container exists
check_container_exists() {
    log "INFO" "Checking if container $CONTAINER_NAME exists..."
    az storage container show --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT --auth-mode login &>/dev/null
}

# Function to check resource provider registration
check_resource_provider() {
    local provider=$1
    log "INFO" "Checking $provider Resource Provider registration status..."
    local state=$(az provider show --namespace $provider --query "registrationState" -o tsv)
    if [ "$state" != "Registered" ]; then
        log "ERROR" "$provider resource provider is not registered."
        return 1
    fi
    return 0
}

# Function to check resource group existence
check_resource_group() {
    log "INFO" "Checking if Resource Group $RESOURCE_GROUP exists..."
    az group show --name $RESOURCE_GROUP &>/dev/null
}

# Function to check storage account existence and configuration
check_storage_account() {
    log "INFO" "Checking if Storage Account $STORAGE_ACCOUNT exists and is properly configured..."
    local account_info=$(az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP -o json)
    if [ -z "$account_info" ]; then
        log "ERROR" "Storage Account $STORAGE_ACCOUNT does not exist."
        return 1
    fi

    local tls_version=$(echo $account_info | jq -r '.minimumTlsVersion')
    if [ "$tls_version" != "TLS1_2" ]; then
        log "ERROR" "Storage Account $STORAGE_ACCOUNT does not use TLS 1.2."
        return 1
    fi

    return 0
}

# Function to check network rules
check_network_rules() {
    log "INFO" "Checking Storage Account network rules..."
    local all_rules_exist=true
    
    for subnet_id in "${subnet_ids[@]}"; do
        if ! az storage account network-rule list --account-name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "virtualNetworkRules[?virtualNetworkResourceId=='$subnet_id']" -o tsv &>/dev/null; then
            log "ERROR" "Network rule for subnet $subnet_id does not exist."
            all_rules_exist=false
        fi
    done

    local default_action=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" --query "networkRuleSet.defaultAction" -o tsv)
    if [ "$default_action" != "Deny" ]; then
        log "ERROR" "Default network rule is not set to Deny."
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
    log "INFO" "Checking blob service properties..."
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
    log "INFO" "Checking container service properties..."
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
    local all_checks_passed=true

    if check_container_exists; then
        log "INFO" "Container $CONTAINER_NAME exists. Skipping basic existence checks."
    else
        log "INFO" "Container $CONTAINER_NAME does not exist. Performing all checks."
        if $RUN_RESOURCE_PROVIDER_CHECK; then
            check_resource_provider "Microsoft.Storage" || all_checks_passed=false
        fi
        if $RUN_RESOURCE_GROUP_CHECK; then
            check_resource_group || all_checks_passed=false
        fi
        if $RUN_STORAGE_ACCOUNT_CHECK; then
            check_storage_account || all_checks_passed=false
        fi
    fi

    if $RUN_NETWORK_RULES_CHECK; then
        check_network_rules || all_checks_passed=false
    fi
    if $RUN_BLOB_PROPERTIES_CHECK; then
        check_blob_service_properties || all_checks_passed=false
    fi
    if $RUN_CONTAINER_PROPERTIES_CHECK; then
        check_container_service_properties || all_checks_passed=false
    fi

    if $all_checks_passed; then
        log "INFO" "All checks passed successfully."
        return 0
    else
        log "ERROR" "One or more checks failed."
        return 1
    fi
}

# Function to perform backup checks
perform_checks_backup() {
  if $RUN_BACKUP_CHECKS; then
      log "INFO" "Performing backup checks..."
      local all_checks_passed=true

      # Install the dataprotection extension
      ensure_dataprotection_extension

      # Check if the backup vault exists
      log "INFO" "Checking if Backup Vault $BACKUP_VAULT_NAME exists..."
      if az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP &>/dev/null; then
          log "INFO" "Backup Vault '$BACKUP_VAULT_NAME' exists"
      else
          log "ERROR" "Backup Vault '$BACKUP_VAULT_NAME' does not exist"
          all_checks_passed=false
          if [[ "$1" == "--checks-only" ]]; then return 1; fi
      fi

      # Check if the backup policy exists
      log "INFO" "Checking if Backup Policy $BACKUP_POLICY_NAME exists..."
      if az dataprotection backup-policy show --resource-group $RESOURCE_GROUP --vault-name $BACKUP_VAULT_NAME --name $BACKUP_POLICY_NAME &>/dev/null; then
          log "INFO" "Backup Policy '$BACKUP_POLICY_NAME' exists"
      else
          log "ERROR" "Backup Policy '$BACKUP_POLICY_NAME' does not exist"
          all_checks_passed=false
          if [[ "$1" == "--checks-only" ]]; then return 1; fi
      fi

      # Check if Storage Account Backup Contributor role is assigned
      log "INFO" "Checking Storage Account Backup Contributor role assignment..."
      local vault_object_id=$(az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP --query identity.principalId --output tsv)
      if az role assignment list --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" --query "[?principalId=='${vault_object_id}' && roleDefinitionName=='Storage Account Backup Contributor']" -o tsv | grep -q "Storage Account Backup Contributor"; then
          log "INFO" "Storage Account Backup Contributor role is properly assigned"
      else
          log "ERROR" "Storage Account Backup Contributor role is not assigned"
          all_checks_passed=false
          if [[ "$1" == "--checks-only" ]]; then return 1; fi
      fi

      # Check if Azure Backup for Blobs is enabled
      log "INFO" "Checking Azure Backup status for storage account $STORAGE_ACCOUNT..."
      local backup_instance=$(az dataprotection backup-instance list \
          --resource-group "$RESOURCE_GROUP" \
          --vault-name "$BACKUP_VAULT_NAME" \
          --query "[?name=='$BACKUP_INSTANCE_NAME' && properties.dataSourceInfo.resourceName=='$STORAGE_ACCOUNT' && properties.currentProtectionState=='ProtectionConfigured']" \
          --output tsv)

      if [ -n "$backup_instance" ]; then
          log "INFO" "Azure Backup is properly configured for storage account $STORAGE_ACCOUNT"
      else
          log "ERROR" "Azure Backup is not configured for storage account $STORAGE_ACCOUNT"
          all_checks_passed=false
          if [[ "$1" == "--checks-only" ]]; then return 1; fi
      fi

      if $all_checks_passed; then
          log "INFO" "All backup checks passed successfully"
          return 0
      else
          log "ERROR" "One or more backup checks failed"
          return 1
      fi
    else
        log "INFO" "Skipping backup checks"
    fi
}

# Function to register resource provider
register_resource_provider() {
    local provider=$1
    log "INFO" "Registering $provider resource provider..."
    az provider register --namespace $provider
    
    while [ "$(az provider show --namespace $provider --query "registrationState" -o tsv)" != "Registered" ]; do
        log "INFO" "Waiting for $provider resource provider to be registered..."
        sleep 10
    done
}

# Function to create resource group
create_resource_group() {
    if ! check_resource_group; then
        log "INFO" "Creating Resource Group $RESOURCE_GROUP..."
        az group create --location $LOCATION --name $RESOURCE_GROUP --tags $TAGS --output none
    else
        log "INFO" "Resource Group $RESOURCE_GROUP already exists."
    fi
}

# Function to create storage account
create_storage_account() {
    if ! check_storage_account; then
        log "INFO" "Creating Storage Account $STORAGE_ACCOUNT..."
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
    else
        log "INFO" "Storage Account $STORAGE_ACCOUNT already exists."
    fi
}

# Function to update storage account network rules
update_storage_network_rules() {
    log "INFO" "Updating storage account network rules..."
    az storage account update \
        --name $STORAGE_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --default-action Deny \
        --bypass AzureServices \
        --output none

    for subnet_id in "${subnet_ids[@]}"; do
        az storage account network-rule add \
            --account-name $STORAGE_ACCOUNT \
            --resource-group $RESOURCE_GROUP \
            --subnet $subnet_id \
            --output none
    done

    # Implement retry mechanism here
}

# Function to create container
create_container() {
    if ! check_container_exists; then
        log "INFO" "Creating container $CONTAINER_NAME..."
        az storage container create \
            --name $CONTAINER_NAME \
            --account-name $STORAGE_ACCOUNT \
            --auth-mode login \
            --output none
    else
        log "INFO" "Container $CONTAINER_NAME already exists."
    fi
}

# Function to update blob policies
update_blob_policies() {
    # Retrieve storage account key
    STORAGE_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP --account-name $STORAGE_ACCOUNT --query '[0].value' --output tsv)
    if ! check_blob_service_properties; then
        log "INFO" "Updating blob policies..."
        az storage blob service-properties delete-policy update \
            --account-name $STORAGE_ACCOUNT \
            --account-key $STORAGE_KEY \
            --enable true \
            --days-retained 90 \
            --output none
    else
        log "INFO" "Blob policies are already configured correctly."
    fi
}

# Function to update container policies
update_container_policies() {
    if ! check_container_service_properties; then
        log "INFO" "Updating container policies..."
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
    else
        log "INFO" "Container policies are already configured correctly."
    fi
}

# Function to set up Azure Backup for Blobs
setup_azure_backup() {
    log "INFO" "Setting up Azure Backup for Blobs..."
    
    # Install the dataprotection extension
    ensure_dataprotection_extension

    # Perform backup-specific checks
    perform_checks_backup

    if [ "$VAULT_EXISTS" = false ]; then
        log "INFO" "Creating Backup Vault $BACKUP_VAULT_NAME..."
        if ! az dataprotection backup-vault create \
            --vault-name $BACKUP_VAULT_NAME \
            --resource-group $RESOURCE_GROUP \
            --location $LOCATION \
            --type "systemAssigned" \
            --storage-setting "$STORAGE_SETTING" \
            --immutability-state "unlocked" \
            --tags $TAGS; then
            log "ERROR" "Failed to create Backup Vault"
            return 1
        fi
    fi

    if [ "$POLICY_EXISTS" = false ]; then
        log "INFO" "Creating backup policy $BACKUP_POLICY_NAME..."
        if ! az dataprotection backup-policy create \
            --resource-group $RESOURCE_GROUP \
            --vault-name $BACKUP_VAULT_NAME \
            --name $BACKUP_POLICY_NAME \
            --policy @$POLICY_FILE; then
            log "ERROR" "Failed to create backup policy"
            return 1
        fi
    fi

    if [ "$ROLE_ASSIGNED" = false ]; then
        log "INFO" "Assigning Storage Account Backup Contributor role..."
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
            log "ERROR" "Failed to assign Storage Account Backup Contributor role"
            return 1
        fi
    fi

    if [ "$BACKUP_PROTECTION_ENABLED" = false ]; then
        log "INFO" "Enabling backup protection for storage account $STORAGE_ACCOUNT..."
        local backup_result=$(az dataprotection backup-instance create \
            --resource-group $RESOURCE_GROUP \
            --vault-name $BACKUP_VAULT_NAME \
            --backup-instance @backup-instance.json 2>&1)
        
        if [ $? -eq 0 ]; then
            log "INFO" "Successfully enabled Azure Backup for storage account $STORAGE_ACCOUNT"
        elif echo "$backup_result" | grep -q "Datasource is already protected"; then
            log "INFO" "Datasource is already protected - no action needed"
        else
            log "ERROR" "Failed to enable backup protection: $backup_result"
            return 1
        fi
    else
        log "INFO" "Backup protection is already enabled for storage account $STORAGE_ACCOUNT"
    fi

    log "INFO" "Azure Backup setup completed successfully"
    return 0
}

# Main function to orchestrate the script
main() {
    get_and_set_tags

    if [[ "$1" == "--checks-only" ]]; then
        log "INFO" "Running in checks-only mode."
        perform_checks
        perform_checks_backup
    else
        log "INFO" "Running in create/update mode."
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
    fi
}

# Run the main function
main "$@"