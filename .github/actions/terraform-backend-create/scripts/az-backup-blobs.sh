#!/bin/bash
# shellcheck disable=SC2086

# Function to set up backup variables
setup_backup_variables() {
    if [ -z "$ENV_SHORT" ] || [ -z "$SVC_NAME" ]; then
        log "ERROR" "❌ ENV_SHORT and SVC_NAME must be set before calling setup_backup_variables"
        return 1
    fi

    # Replacing underscores with hyphens in SVC_NAME for Backup related names
    SVC_NAME=${SVC_NAME//_/-}

    BACKUP_USE="tfstate"
    POLICY_FILE="$GITHUB_ACTION_PATH/policy/backup-policy.json"
    BACKUP_VAULT_NAME="bvault-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
    BACKUP_POLICY_NAME="bkpol-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"
    BACKUP_INSTANCE_NAME="bki-${SVC_NAME}-${ENV_SHORT}-${BACKUP_USE}-${LOCATION_SHORT}-001"

    # Determine storage setting based on location
    if [[ "$LOCATION" == "UKWest" || "$LOCATION_SHORT" == "ukw" ]]; then
        STORAGE_SETTING="[{'type':'LocallyRedundant','datastore-type':'VaultStore'}]"
    elif [[ "$LOCATION" == "UKSouth" || "$LOCATION_SHORT" == "uks" ]]; then
        STORAGE_SETTING="[{'type':'ZoneRedundant','datastore-type':'VaultStore'}]"
    else
        log "ERROR" "❌ Unsupported location $LOCATION"
        return 1
    fi

    log "INFO" "✅ Successfully set up backup variables"
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
    
    if sed -e "s/\${SUBSCRIPTION_ID}/${SUBSCRIPTION_ID}/g" \
        -e "s/\${RESOURCE_GROUP}/${RESOURCE_GROUP}/g" \
        -e "s/\${LOCATION}/${LOCATION}/g" \
        -e "s/\${STORAGE_ACCOUNT}/${STORAGE_ACCOUNT}/g" \
        -e "s/\${BACKUP_VAULT_NAME}/${BACKUP_VAULT_NAME}/g" \
        -e "s/\${BACKUP_POLICY_NAME}/${BACKUP_POLICY_NAME}/g" \
        -e "s/\${BACKUP_INSTANCE_NAME}/${BACKUP_INSTANCE_NAME}/g" \
        "$template_file" > "$output_file"; then
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
        if az extension add --name dataprotection --only-show-errors; then
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

# Function to check backup status with optional warning reporting
check_backup_status() {
    local report_warnings=${1:-false}  # Parameter to determine if warnings should be reported
    local check_results=()
    
    log "INFO" "🔍 Checking backup status..."
    VAULT_EXISTS=false
    POLICY_EXISTS=false
    ROLE_ASSIGNED=false
    BACKUP_PROTECTION_ENABLED=false

    # Initialize consolidated message only if reporting warnings
    if [ "$report_warnings" = true ]; then
        consolidated_message="Azure Backup Configuration Status:%0A"
    fi

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
        if [ "$report_warnings" = true ]; then
            consolidated_message+="- Backup Vault does not exist%0A"
        fi
    fi

    # Only check other components if vault exists
    if [ "$VAULT_EXISTS" = false ]; then
        check_results+=("⚠️ Backup Policy: check skipped (vault missing)")
        check_results+=("⚠️ Backup Contributor Role: check skipped (vault missing)")
        check_results+=("⚠️ Backup Protection: check skipped (vault missing)")
        if [ "$report_warnings" = true ]; then
            consolidated_message+="- Backup Policy does not exist%0A"
            consolidated_message+="- Storage Account Backup Contributor role is not assigned%0A"
            consolidated_message+="- Azure Backup is not configured for storage account%0A"
        fi
    else
        # Check backup policy
        if az dataprotection backup-policy show --resource-group $RESOURCE_GROUP --vault-name $BACKUP_VAULT_NAME --name $BACKUP_POLICY_NAME &>/dev/null; then
            POLICY_EXISTS=true
            check_results+=("✅ Backup Policy: exists")
        else
            check_results+=("❌ Backup Policy: does not exist")
            if [ "$report_warnings" = true ]; then
                consolidated_message+="- Backup Policy does not exist%0A"
            fi
        fi

        # Check role assignment
        VAULT_OBJECT_ID=$(az dataprotection backup-vault show --vault-name $BACKUP_VAULT_NAME --resource-group $RESOURCE_GROUP --query identity.principalId --output tsv)
        if az role assignment list --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" --query "[?principalId=='${VAULT_OBJECT_ID}' && roleDefinitionName=='Storage Account Backup Contributor']" -o tsv | grep -q "Storage Account Backup Contributor"; then
            ROLE_ASSIGNED=true
            check_results+=("✅ Backup Contributor Role: assigned")
        else
            check_results+=("❌ Backup Contributor Role: not assigned")
            if [ "$report_warnings" = true ]; then
                consolidated_message+="- Storage Account Backup Contributor role is not assigned%0A"
            fi
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
            if [ "$report_warnings" = true ]; then
                consolidated_message+="- Azure Backup is not configured for storage account%0A"
            fi
        fi
    fi

    # Display summary
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "Azure Backup Checks Summary:"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for result in "${check_results[@]}"; do
        log "INFO" "$result"
    done
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Create warning if needed and if we're reporting warnings
    if [ "$report_warnings" = true ] && [[ $consolidated_message != "Azure Backup Configuration Status:%0A" ]]; then
        echo "::warning::${consolidated_message}"
        log "WARN" "⚠️ One or more backup checks had warnings"
    fi
}

# Wrapper function for backward compatibility
perform_checks_backup() {
    if $RUN_BACKUP_CHECKS; then
        log "INFO" "🔍 Performing backup checks..."
        check_backup_status true
    else
        log "INFO" "ℹ️ Skipping backup checks"
    fi
}

# Function to set up Azure Backup for Blobs
setup_azure_backup() {
    log "INFO" "🔄 Setting up Azure Backup for Blobs..."

    # Validate required variables are set
    if [ -z "$BACKUP_VAULT_NAME" ] || [ -z "$BACKUP_POLICY_NAME" ]; then
        log "ERROR" "Required backup variables not set"
        return 1
    fi    
    
    # Create backup instance JSON configuration
    if ! create_backup_instance_json; then
        log "ERROR" "❌ Failed to create backup instance configuration"
        return 1
    fi

    # Get current backup status
    check_backup_status
    local setup_success=true

    # Setup Backup Vault if it doesn't exist
    if [ "$VAULT_EXISTS" = false ]; then
        log "INFO" "🏗️ Creating Backup Vault $BACKUP_VAULT_NAME..."
        if ! az dataprotection backup-vault create \
            --vault-name "$BACKUP_VAULT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --type "systemAssigned" \
            --storage-setting "$STORAGE_SETTING" \
            --immutability-state "unlocked" \
            --tags "$TAGS" \
            --output none; then
            log "ERROR" "❌ Failed to create Backup Vault"
            setup_success=false
        else
            log "INFO" "✅ Successfully created Backup Vault"
        fi
    # else
    #     log "INFO" "ℹ️ Backup Vault already exists"
    fi

    # Create backup policy if it doesn't exist
    if [ "$POLICY_EXISTS" = false ]; then
        log "INFO" "📜 Creating backup policy $BACKUP_POLICY_NAME..."
        if ! az dataprotection backup-policy create \
            --resource-group "$RESOURCE_GROUP" \
            --vault-name "$BACKUP_VAULT_NAME" \
            --name "$BACKUP_POLICY_NAME" \
            --policy "@$POLICY_FILE" \
            --output none; then
            log "ERROR" "❌ Failed to create backup policy"
            setup_success=false
        else
            log "INFO" "✅ Successfully created backup policy"
        fi
    # else
    #     log "INFO" "ℹ️ Backup policy already exists"
    fi

    # Assign Storage Account Backup Contributor role if not assigned
    if [ "$ROLE_ASSIGNED" = false ]; then
        log "INFO" "🔑 Assigning Storage Account Backup Contributor role..."
        
        local VAULT_OBJECT_ID
        VAULT_OBJECT_ID=$(az dataprotection backup-vault show \
            --vault-name "$BACKUP_VAULT_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --query identity.principalId \
            --output tsv)

        if ! az role assignment create \
            --assignee-object-id "$VAULT_OBJECT_ID" \
            --assignee-principal-type ServicePrincipal \
            --role "Storage Account Backup Contributor" \
            --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}" \
            --output none; then
            log "ERROR" "❌ Failed to assign Storage Account Backup Contributor role"
            setup_success=false
        else
            log "INFO" "✅ Successfully assigned Storage Account Backup Contributor role"
        fi
    else
        log "INFO" "ℹ️ Role assignment already exists"
    fi

    # Enable backup protection if not enabled
    if [ "$BACKUP_PROTECTION_ENABLED" = false ]; then
        log "INFO" "🔒 Enabling backup protection for storage account $STORAGE_ACCOUNT..."
        
        # Verify backup instance JSON exists
        local output_file="$GITHUB_ACTION_PATH/policy/backup-instance.json"
        if [ ! -f "$output_file" ]; then
            log "ERROR" "❌ Backup instance JSON file not found at: $output_file"
            setup_success=false
        else
            # Enable backup protection
            local backup_result
            if backup_result=$(az dataprotection backup-instance create \
                --resource-group "$RESOURCE_GROUP" \
                --vault-name "$BACKUP_VAULT_NAME" \
                --backup-instance "@$output_file" 2>&1); then
                log "INFO" "✅ Successfully enabled Azure Backup for storage account $STORAGE_ACCOUNT"
            elif echo "$backup_result" | grep -q "Datasource is already protected"; then
                log "INFO" "ℹ️ Datasource is already protected"
            else
                log "ERROR" "❌ Failed to enable backup protection: $backup_result"
                setup_success=false
            fi
        fi
    # else
    #     log "INFO" "ℹ️ Backup protection is already enabled"
    fi

    # Final status check
    if [ "$setup_success" = true ]; then
        log "INFO" "✅ Azure Backup setup completed successfully"
        return 0
    else
        log "ERROR" "❌ Azure Backup setup encountered errors"
        return 1
    fi
}