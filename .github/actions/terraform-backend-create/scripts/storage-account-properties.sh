#!/bin/bash

# Global variable to track actual state
STORAGE_PROPERTIES_STATUS=true

# Initialize storage account properties configuration
init_storage_account_properties() {
    log "INFO" "🔄 Initializing Storage Account properties configuration..."

    # Storage Account Properties Configuration
    ALLOW_BLOB_ANONYMOUS_ACCESS=${ALLOW_BLOB_ANONYMOUS_ACCESS:-false}
    ALLOW_CROSS_TENANT_REPLICATION=${ALLOW_CROSS_TENANT_REPLICATION:-false}
    REQUIRE_INFRASTRUCTURE_ENCRYPTION=${REQUIRE_INFRASTRUCTURE_ENCRYPTION:-true}

    log "INFO" "✅ Storage Account properties configuration initialized"
}

generate_storage_account_properties_json() {
    cat << EOF
{
    "location": "${LOCATION,,}",
    "properties": {
        "allowBlobPublicAccess": ${ALLOW_BLOB_ANONYMOUS_ACCESS},
        "minimumTlsVersion": "TLS1_2",
        "allowCrossTenantReplication": ${ALLOW_CROSS_TENANT_REPLICATION},
        "encryption": {
            "keySource": "Microsoft.Storage",
            "requireInfrastructureEncryption": ${REQUIRE_INFRASTRUCTURE_ENCRYPTION},
            "services": {
                "blob": {
                    "enabled": true,
                    "keyType": "Account"
                },
                "file": {
                    "enabled": true,
                    "keyType": "Account"
                }
            }
        }
    }
}
EOF
}

# Function to check Storage Account properties
check_storage_account_properties() {

    # Initialize variables when function is called
    init_storage_account_properties
    local check_status=true

    log "INFO" "🔍 Checking Storage Account properties..."

    local api_version="2023-01-01"
    local storage_url="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

    # Get current properties
    local properties
    properties=$(az rest --method GET \
        --uri "https://management.azure.com$storage_url?api-version=$api_version" \
        --query "properties" 2>/dev/null)

    if [ -z "$properties" ]; then
        log "ERROR" "❌ Failed to get Storage Account properties"
        STORAGE_PROPERTIES_STATUS=false
        check_status=false
    else
        # Extract all property values - separated declarations and assignments
        local allow_blob_anonymous_access
        allow_blob_anonymous_access=$(echo "$properties" | jq -r '.allowBlobPublicAccess')

        # Check if all properties match expected values
        if [[ "$allow_blob_anonymous_access" == "$ALLOW_BLOB_ANONYMOUS_ACCESS" ]]; then
            log "INFO" "✅ All Storage Account properties are correctly configured"
            STORAGE_PROPERTIES_STATUS=true
        else
            log "INFO" "⚠️ One or more Storage Account properties need updating"
            # Add detailed comparison logging
            log "INFO" "Current vs Expected values:"
            log "INFO" "Allow Blob Anonymous Access: $allow_blob_anonymous_access vs $ALLOW_BLOB_ANONYMOUS_ACCESS"
            STORAGE_PROPERTIES_STATUS=false
            check_status=false
        fi
    fi

    [ "$check_status" = true ] && return 0 || return 1
}

# Function to update Storage Account properties
update_storage_account_properties() {
    # Initialize variables when function is called
    init_storage_account_properties

    log "INFO" "🔄 Checking if Storage Account properties need updating..."

    local operation_success=true

    if ! check_storage_account_properties; then
        log "INFO" "🔄 Updating Storage Account properties..."

        local api_version="2023-01-01"
        local storage_url="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

        # Generate the request body using the centralised configuration
        local request_body
        request_body=$(generate_storage_account_properties_json)

        # Log the request body for debugging
        log "INFO" "Request body:"
        echo "$request_body" | jq '.'

        # Update all properties in a single call
        if az rest --method PUT \
            --uri "https://management.azure.com$storage_url?api-version=$api_version" \
            --body "$request_body" --output none; then
            log "INFO" "✅ Successfully updated Storage Account properties"

            # Add delay before verification
            sleep 5 # Give Azure some time to process the change

	        # Verify the changes
            if check_storage_account_properties; then
                log "INFO" "✅ Verified all Storage Account properties are correctly configured"
                operation_success=true
            else
                log "ERROR" "❌ Verification failed after update"
                operation_success=false
            fi
        else
            log "ERROR" "❌ Failed to update Storage Account properties"
            operation_success=false
        fi
    else
        log "INFO" "ℹ️ All Storage Account properties are already configured correctly"
    fi

    [ "$operation_success" = true ] && return 0 || return 1
}

# Main function to handle execution
main() {
    local mode="$1"
    log "INFO" "Starting Storage Account properties setup..."
    
    case "$mode" in
        "create")
            if ! update_storage_account_properties; then
                log "WARN" "⚠️ Storage Account properties setup encountered issues but continuing execution"
            fi
            ;;
        *)
            check_storage_account_properties
            ;;
    esac
    
    [ "$STORAGE_PROPERTIES_STATUS" = true ] && return 0 || return 1
}

# Run main function if script is executed directly
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    main "${mode:-checks-only}"  # Use mode from parent script, default to checks-only
fi