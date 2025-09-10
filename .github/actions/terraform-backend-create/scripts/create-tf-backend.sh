#!/bin/bash
# shellcheck disable=SC2086
# version = 7.0

set -e

# Environment Variables
RESOURCE_GROUP=${TERRAFORM_BACKEND_RESOURCE_GROUP}
STORAGE_ACCOUNT=${TERRAFORM_BACKEND_STORAGE_ACCOUNT}
CONTAINER_NAME=${TERRAFORM_BACKEND_CONTAINER}
LOCATION=${TERRAFORM_BACKEND_LOCATION}
SKU=${TERRAFORM_BACKEND_SKU}
SUBSCRIPTION_ID=${ARM_SUBSCRIPTION_ID}

# Exports for sourced scripts
export LOCATION_SHORT=${TERRAFORM_BACKEND_LOCATION_SHORT}
export ALLOW_BLOB_ANONYMOUS_ACCESS=${ALLOW_BLOB_ANONYMOUS_ACCESS:-false}
export ALLOW_CROSS_TENANT_REPLICATION=${ALLOW_CROSS_TENANT_REPLICATION:-false}
export REQUIRE_INFRASTRUCTURE_ENCRYPTION=${REQUIRE_INFRASTRUCTURE_ENCRYPTION:-true}


# Configuration (using environment variables with defaults)
RUN_INFRA_CHECKS=${RUN_INFRA_CHECKS:-true}
RUN_BACKUP_CHECKS=${RUN_BACKUP_CHECKS:-true}
RUN_RESOURCE_PROVIDER_CHECK=${RUN_RESOURCE_PROVIDER_CHECK:-true}
RUN_RESOURCE_GROUP_CHECK=${RUN_RESOURCE_GROUP_CHECK:-true}
RUN_STORAGE_ACCOUNT_CHECK=${RUN_STORAGE_ACCOUNT_CHECK:-true}
RUN_NETWORK_RULES_CHECK=${RUN_NETWORK_RULES_CHECK:-true}
RUN_BLOB_SERVICE_PROPERTIES_CHECK=${RUN_BLOB_SERVICE_PROPERTIES_CHECK:-true}
RUN_STORAGE_ACCOUNT_PROPERTIES_CHECK=${RUN_STORAGE_ACCOUNT_PROPERTIES_CHECK:-true}
RUN_POLICY_EXEMPTIONS_CHECK=${RUN_POLICY_EXEMPTIONS_CHECK:-true}

CREATE_RESOURCE_GROUP=${CREATE_RESOURCE_GROUP:-true}
CREATE_STORAGE_ACCOUNT=${CREATE_STORAGE_ACCOUNT:-true}
UPDATE_NETWORK_RULES=${UPDATE_NETWORK_RULES:-true}
CREATE_CONTAINER=${CREATE_CONTAINER:-true}
UPDATE_BLOB_SERVICE_PROPERTIES=${UPDATE_BLOB_SERVICE_PROPERTIES:-true}
UPDATE_STORAGE_ACCOUNT_PROPERTIES=${UPDATE_STORAGE_ACCOUNT_PROPERTIES:-true}
CREATE_POLICY_EXEMPTIONS=${CREATE_POLICY_EXEMPTIONS:-true}
SETUP_AZURE_BACKUP=${SETUP_AZURE_BACKUP:-true}

# Initialize the consolidated_message at the start of script
consolidated_message="Azure Backup Configuration Status:%0A"

# Default subnet IDs
default_subnet_ids=(
    "/subscriptions/b501e2c6-08b6-4f20-8e44-2dc427c57a17/resourceGroups/rg-plat-man-ghrtmp-001/providers/Microsoft.Network/virtualNetworks/vnet-plat-man-uks-004/subnets/snet-plat-mon-ghrtmp-uks-001" # alz temp runners
    "/subscriptions/b501e2c6-08b6-4f20-8e44-2dc427c57a17/resourceGroups/rg-plat-man-ghrtmp-001/providers/Microsoft.Network/virtualNetworks/vnet-plat-man-uks-004/subnets/snet-plat-mon-ghrtmp-uks-002" # alz temp runners
    "/subscriptions/4782e379-ae5a-4ad7-b1e3-551602206711/resourceGroups/rg-vnet_spoke_shared_services_defender-yrbj/providers/Microsoft.Network/virtualNetworks/vnet-shared_services_network_1_defender-jthq/subnets/snet-aks_defender_nodepool_system-isxr"
    "/subscriptions/4782e379-ae5a-4ad7-b1e3-551602206711/resourceGroups/rg-vnet_spoke_shared_services_defender-yrbj/providers/Microsoft.Network/virtualNetworks/vnet-shared_services_network_1_defender-jthq/subnets/snet-aks_defender_nodepool_user1-yegu"
)

# Source companion scripts
if [[ -f "$GITHUB_ACTION_PATH/scripts/storage-blob-properties.sh" ]]; then
    # shellcheck source=/dev/null
    source "$GITHUB_ACTION_PATH/scripts/storage-blob-properties.sh"
else
    log "ERROR" "❌ Missing storage-blob-properties.sh"
    exit 1
fi

if [[ -f "$GITHUB_ACTION_PATH/scripts/policy-exemptions.sh" ]]; then
    # shellcheck source=/dev/null
    source "$GITHUB_ACTION_PATH/scripts/policy-exemptions.sh"
else
    log "ERROR" "❌ Missing policy-exemptions.sh"
    exit 1
fi

if [[ -f "$GITHUB_ACTION_PATH/scripts/az-backup-blobs.sh" ]]; then
    # shellcheck source=/dev/null
    source "$GITHUB_ACTION_PATH/scripts/az-backup-blobs.sh"
else
    log "ERROR" "❌ Missing az-backup-blobs.sh"
    exit 1
fi

if [[ -f "$GITHUB_ACTION_PATH/scripts/storage-account-properties.sh" ]]; then
    # shellcheck source=/dev/null
    source "$GITHUB_ACTION_PATH/scripts/storage-account-properties.sh"
else
    log "ERROR" "❌ Missing storage-account-properties.sh"
    exit 1
fi

# Use custom subnet IDs if provided, otherwise use default
if [ -n "$SUBNET_IDS" ]; then
    IFS=',' read -ra subnet_ids <<< "$SUBNET_IDS"
else
    subnet_ids=("${default_subnet_ids[@]}")
fi

# Logging function
log() {
    local level=$1
    shift
    echo "[${level}] $(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Function to retrieve and set tags
get_and_set_tags() {
    log "INFO" "🔍 Retrieving subscription tags..."
    # shellcheck disable=SC2155
    local subscription_tags=$(az tag list --resource-id /subscriptions/"$SUBSCRIPTION_ID")

    # Extract specific tag values with default values if tags are not found
    org_service_name=$(echo "$subscription_tags" | jq -r '.properties.tags.org_service_name // "placeholder_service_name"')
    org_budget_code=$(echo "$subscription_tags" | jq -r '.properties.tags.org_budget_code // "placeholder_budget_code"')
    org_environment=$(echo "$subscription_tags" | jq -r '.properties.tags.org_environment // "placeholder_env"')
    org_service_tier=$(echo "$subscription_tags" | jq -r '.properties.tags.org_service_tier // "placeholder_tier"')

    # Extract max first 4 letters of the org_environment value used for naming resources
    export ENV_SHORT=${org_environment:0:4}
    export SVC_NAME=${org_service_name:0:4}

    # Prepare TAGS variable
    TAGS="org_service_name=$org_service_name org_budget_code=$org_budget_code org_environment=$org_environment org_service_tier=$org_service_tier"

    log "INFO" "✅ Successfully retrieved and set tags"
}

# Function to check container existence
check_container_exists() {
    log "INFO" "🔍 Checking if container $CONTAINER_NAME [$RESOURCE_GROUP/$STORAGE_ACCOUNT] exists..."
    az storage container show --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login &>/dev/null
}

# Function to check resource provider registration
check_resource_provider() {
    local provider=$1
    log "INFO" "🔍 Checking $provider Resource Provider registration status..."
    local state
    state=$(az provider show --namespace "$provider" --query "registrationState" -o tsv)
    if [ "$state" != "Registered" ]; then
        log "ERROR" "❌ $provider resource provider is not registered."
        return 1
    fi
    return 0
}

# Function to check resource group existence
check_resource_group() {
    log "INFO" "🔍 Checking if Resource Group $RESOURCE_GROUP exists..."
    az group show --name "$RESOURCE_GROUP" &>/dev/null
}

# Function to check storage account existence and configuration
check_storage_account() {
    log "INFO" "🔍 Checking if Storage Account $STORAGE_ACCOUNT exists and is properly configured..."
    local account_info
    account_info=$(az storage account show --name "$STORAGE_ACCOUNT" --resource-group "$RESOURCE_GROUP" -o json)
    
    if [ -z "$account_info" ]; then
        log "INFO" "❌ Storage Account $STORAGE_ACCOUNT does not exist."
        return 1
    fi

    local tls_version
    tls_version=$(echo "$account_info" | jq -r '.minimumTlsVersion')
    if [ "$tls_version" != "TLS1_2" ]; then
        log "ERROR" "❌ Storage Account $STORAGE_ACCOUNT does not use TLS 1.2."
        return 1
    fi

    local blob_encryption_enabled
    local infrastructure_encryption
    
    blob_encryption_enabled=$(echo "$account_info" | jq -r '.encryption.services.blob.enabled')
    infrastructure_encryption=$(echo "$account_info" | jq -r '.encryption.requireInfrastructureEncryption')
    
    if [[ "$blob_encryption_enabled" != "true" || "$infrastructure_encryption" != "true" ]]; then
        log "ERROR" "❌ Storage Account $STORAGE_ACCOUNT encryption is not properly configured."
        return 1
    fi    

    return 0
}

# Function to check network rules
check_network_rules() {
    log "INFO" "🔍 Checking Storage Account network rules..."
    local all_rules_exist=true
    
    for subnet_id in "${subnet_ids[@]}"; do
        if ! az storage account network-rule list \
            --account-name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --query "virtualNetworkRules[?virtualNetworkResourceId=='$subnet_id']" \
            -o tsv &>/dev/null; then
            log "ERROR" "❌ Network rule for subnet $subnet_id does not exist."
            all_rules_exist=false
        fi
    done

    local default_action
    default_action=$(az storage account show \
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --query "networkRuleSet.defaultAction" \
        -o tsv)

    if [ "$default_action" != "Deny" ]; then
        log "ERROR" "❌ Default network rule is not set to Deny."
        all_rules_exist=false
    fi

    if $all_rules_exist; then
        log "INFO" "✅ All network rules are correctly configured."
        return 0
    else
        log "ERROR" "❌ Not all network rules are correctly configured."
        return 1
    fi
}

# Function to perform all checks
perform_checks() {
    local all_checks_passed=true
    local check_results=()
    local failed_checks=()
    local warning_checks=()

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
    if $RUN_BLOB_SERVICE_PROPERTIES_CHECK; then
        if check_blob_service_properties; then
            check_results+=("✅ Blob Service Properties: properly configured")
        else
            check_results+=("❌ Blob Service Properties: misconfigured")
            failed_checks+=("Blob properties are not properly configured")
            all_checks_passed=false
        fi
    fi

    # Storage Account Properties check
    if $RUN_STORAGE_ACCOUNT_PROPERTIES_CHECK; then
        if check_storage_account_properties; then
            check_results+=("✅ Storage Account Properties: properly configured")
        else
            check_results+=("⚠️ Storage Account Properties: misconfigured")
            warning_checks+=("Storage Account properties are not properly configured")
        fi
    fi

# Display summary of all checks
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
        # Handle both backup and storage account warnings
        if [ ${#warning_checks[@]} -gt 0 ] || [[ "$consolidated_message" != "Azure Backup Configuration Status:%0A" ]]; then
            echo "::notice::Infrastructure checks passed with warnings"
            # Show storage account warnings
            for warning in "${warning_checks[@]}"; do
                echo "::warning::- ${warning}"
            done
            # Show backup warnings if any
            if [[ "$consolidated_message" != "Azure Backup Configuration Status:%0A" ]]; then
                echo "$consolidated_message"
            fi
            log "INFO" "✅ Infrastructure checks passed (with warnings)"
        else
            echo "::notice::All infrastructure checks passed successfully"
            log "INFO" "✅ All infrastructure checks passed"
        fi
        return 0
    fi
}

# Function to register resource provider
register_resource_provider() {
    local provider=$1
    log "INFO" "🔄 Registering $provider resource provider..."
    az provider register --namespace "$provider"
    
    while [ "$(az provider show --namespace "$provider" --query "registrationState" -o tsv)" != "Registered" ]; do
        log "INFO" "⏳ Waiting for $provider resource provider to be registered..."
        sleep 10
    done
    log "INFO" "✅ Successfully registered $provider resource provider"
}

# Function to create resource group
create_resource_group() {
    if ! check_resource_group 2>/dev/null; then
        log "INFO" "🏗️ Creating Resource Group $RESOURCE_GROUP..."
        # shellcheck disable=SC2086
        az group create --location "$LOCATION" --name "$RESOURCE_GROUP" --tags $TAGS --output none
        log "INFO" "✅ Successfully created Resource Group $RESOURCE_GROUP"
    else
        log "INFO" "ℹ️ Resource Group $RESOURCE_GROUP already exists"
    fi
}

# Function to create storage account
create_storage_account() {
    if ! check_storage_account 2>/dev/null; then
        log "INFO" "🏗️ Creating Storage Account $STORAGE_ACCOUNT..."
        az storage account create \
            --name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --sku "$SKU" \
            --min-tls-version TLS1_2 \
            --allow-blob-public-access true \
            --public-network-access Enabled \
            --default-action Allow \
            --encryption-services blob \
            --require-infrastructure-encryption "$REQUIRE_INFRASTRUCTURE_ENCRYPTION" \
            --allow-cross-tenant-replication "$ALLOW_CROSS_TENANT_REPLICATION" \
            --allow-shared-key-access true \
            --tags "$TAGS" \
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
        --name "$STORAGE_ACCOUNT" \
        --resource-group "$RESOURCE_GROUP" \
        --default-action Deny \
        --bypass AzureServices \
        --output none

    for subnet_id in "${subnet_ids[@]}"; do
        log "INFO" "🔗 Adding network rule for subnet: $(basename "$subnet_id")"
        az storage account network-rule add \
            --account-name "$STORAGE_ACCOUNT" \
            --resource-group "$RESOURCE_GROUP" \
            --subnet "$subnet_id" \
            --output none
    done
    log "INFO" "✅ Successfully updated network rules"
    
    # Add wait period with countdown for network rules to propagate
    log "INFO" "⏳ Waiting for network rules to propagate..."
    local wait_time=30  # Wait time in seconds
    local count=0
    while [ $count -lt $wait_time ]; do
        printf "."
        sleep 1
        count=$((count + 1))
        # Print newline every 10 dots
        if [ $((count % 10)) -eq 0 ]; then
            echo " $count seconds"
        fi
    done
    echo ""
    log "INFO" "Wait complete. Proceeding with operations..."
}

# Function to create container
create_container() {
    if ! check_container_exists 2>/dev/null; then
        log "INFO" "📦 Creating container $CONTAINER_NAME..."
        
        # Add retry logic
        local max_attempts=3
        local attempt=1
        local wait_time=30
        
        while [ $attempt -le $max_attempts ]; do
            if az storage container create \
                --name "$CONTAINER_NAME" \
                --account-name "$STORAGE_ACCOUNT" \
                --auth-mode login \
                --output none; then
                
                log "INFO" "✅ Successfully created container $CONTAINER_NAME"
                return 0
            else
                if [ $attempt -lt $max_attempts ]; then
                    log "WARN" "⚠️ Attempt $attempt failed. Waiting $wait_time seconds before retry..."
                    local count=0
                    while [ $count -lt $wait_time ]; do
                        printf "."
                        sleep 1
                        count=$((count + 1))
                        # Print newline every 10 dots
                        if [ $((count % 10)) -eq 0 ]; then
                            echo " $count seconds"
                        fi
                    done
                    echo ""
                    log "INFO" "Retrying container creation (Attempt $((attempt + 1)) of $max_attempts)..."
                fi
                ((attempt++))
            fi
        done
        
        log "ERROR" "❌ Failed to create container after $max_attempts attempts"
        return 1
    else
        log "INFO" "ℹ️ Container $CONTAINER_NAME already exists"
    fi
}

# Main function
main() {
    get_and_set_tags

    case "$1" in
        "checks-only")
            log "INFO" "🔍 Running in checks-only mode."
            if ! perform_checks true; then
                return 1
            fi
            setup_backup_variables || exit 1 
            perform_checks_backup
            ;;
        "backup-only")
            log "INFO" "🔍 Running backup checks only."
            setup_backup_variables || exit 1 
            perform_checks_backup
            ;;
        "infra-only")
            log "INFO" "🔍 Running infrastructure checks only."
            perform_checks true
            ;;
        "create"|"")
            log "INFO" "🏗️ Running in create/update mode."
            if $CREATE_RESOURCE_GROUP; then
                register_resource_provider "Microsoft.Storage"
                create_resource_group
            fi

            if $CREATE_POLICY_EXEMPTIONS; then
                handle_policy_exemptions
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

            if $UPDATE_BLOB_SERVICE_PROPERTIES; then
                update_blob_service_properties
            fi
            
            if $UPDATE_STORAGE_ACCOUNT_PROPERTIES; then
                update_storage_account_properties
            fi

            if $SETUP_AZURE_BACKUP; then
                setup_backup_variables || exit 1 
                register_resource_provider "Microsoft.DataProtection"
                setup_azure_backup
            fi
            ;;
        "configure-backup-only")
            log "INFO" "🏗️ Running in configure-backup-only mode." 
            if $SETUP_AZURE_BACKUP; then
                setup_backup_variables || exit 1 
                register_resource_provider "Microsoft.DataProtection"
                setup_azure_backup
            fi
            ;;                       
        *)
            log "ERROR" "❌ Invalid mode: $1"
            log "ERROR" "Valid modes are: checks-only, backup-only, infra-only, configure-backup-only, create"
            exit 1
            ;;
    esac
}

# Run the main function with all arguments
main "$@"