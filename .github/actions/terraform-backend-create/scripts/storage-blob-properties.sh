#!/bin/bash

# Initialize blob service properties configuration
init_blob_service_properties() {
    log "INFO" "🔄 Initializing blob service properties configuration..."

    # Blob Service Properties Configuration
    BLOB_DELETE_RETENTION_ENABLED=${BLOB_DELETE_RETENTION_ENABLED:-true}
    BLOB_DELETE_RETENTION_DAYS=${BLOB_DELETE_RETENTION_DAYS:-90}
    BLOB_CONTAINER_DELETE_ENABLED=${BLOB_CONTAINER_DELETE_ENABLED:-true}
    BLOB_CONTAINER_DELETE_DAYS=${BLOB_CONTAINER_DELETE_DAYS:-90}
    BLOB_CHANGE_FEED_ENABLED=${BLOB_CHANGE_FEED_ENABLED:-true}
    BLOB_CHANGE_FEED_DAYS=${BLOB_CHANGE_FEED_DAYS:-90}
    BLOB_VERSIONING_ENABLED=${BLOB_VERSIONING_ENABLED:-true}
    BLOB_RESTORE_POLICY_ENABLED=${BLOB_RESTORE_POLICY_ENABLED:-true}
    BLOB_RESTORE_POLICY_DAYS=${BLOB_RESTORE_POLICY_DAYS:-89}

    log "INFO" "✅ Blob service properties configuration initialized"
}

# Generate blob service properties JSON configuration
generate_blob_properties_json() {
    cat << EOF
{
    "properties": {
        "deleteRetentionPolicy": {
            "enabled": ${BLOB_DELETE_RETENTION_ENABLED},
            "days": ${BLOB_DELETE_RETENTION_DAYS}
        },
        "containerDeleteRetentionPolicy": {
            "enabled": ${BLOB_CONTAINER_DELETE_ENABLED},
            "days": ${BLOB_CONTAINER_DELETE_DAYS}
        },
        "changeFeed": {
            "enabled": ${BLOB_CHANGE_FEED_ENABLED},
            "retentionInDays": ${BLOB_CHANGE_FEED_DAYS}
        },
        "isVersioningEnabled": ${BLOB_VERSIONING_ENABLED},
        "restorePolicy": {
            "enabled": ${BLOB_RESTORE_POLICY_ENABLED},
            "days": ${BLOB_RESTORE_POLICY_DAYS}
        }
    }
}
EOF
}

# Function to check blob service properties
check_blob_service_properties() {
    # Initialize variables when function is called
    init_blob_service_properties

    log "INFO" "🔍 Checking blob service properties..."

    local api_version="2023-01-01"
    local storage_url="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT/blobServices/default"

    # Get current properties
    local properties
    properties=$(az rest --method GET \
        --uri "https://management.azure.com$storage_url?api-version=$api_version" \
        --query "properties" 2>/dev/null)

    if [ -z "$properties" ]; then
        log "ERROR" "❌ Failed to get blob service properties"
        return 1
    fi

    # Extract all property values - separated declarations and assignments
    local delete_retention_enabled
    local delete_retention_days
    local container_delete_retention_enabled
    local container_delete_retention_days
    local change_feed_enabled
    local change_feed_retention_days
    local versioning_enabled
    local restore_policy_enabled
    local restore_days

    delete_retention_enabled=$(echo "$properties" | jq -r '.deleteRetentionPolicy.enabled')
    delete_retention_days=$(echo "$properties" | jq -r '.deleteRetentionPolicy.days')
    container_delete_retention_enabled=$(echo "$properties" | jq -r '.containerDeleteRetentionPolicy.enabled')
    container_delete_retention_days=$(echo "$properties" | jq -r '.containerDeleteRetentionPolicy.days')
    change_feed_enabled=$(echo "$properties" | jq -r '.changeFeed.enabled')
    change_feed_retention_days=$(echo "$properties" | jq -r '.changeFeed.retentionInDays')
    versioning_enabled=$(echo "$properties" | jq -r '.isVersioningEnabled')
    restore_policy_enabled=$(echo "$properties" | jq -r '.restorePolicy.enabled')
    restore_days=$(echo "$properties" | jq -r '.restorePolicy.days')

    # Check if all properties match expected values
    if [[ "$delete_retention_enabled" == "$BLOB_DELETE_RETENTION_ENABLED" && 
          "$delete_retention_days" == "$BLOB_DELETE_RETENTION_DAYS" &&
          "$container_delete_retention_enabled" == "$BLOB_CONTAINER_DELETE_ENABLED" &&
          "$container_delete_retention_days" == "$BLOB_CONTAINER_DELETE_DAYS" &&
          "$change_feed_enabled" == "$BLOB_CHANGE_FEED_ENABLED" &&
          "$change_feed_retention_days" == "$BLOB_CHANGE_FEED_DAYS" &&
          "$versioning_enabled" == "$BLOB_VERSIONING_ENABLED" &&
          "$restore_policy_enabled" == "$BLOB_RESTORE_POLICY_ENABLED" &&
          "$restore_days" == "$BLOB_RESTORE_POLICY_DAYS" ]]; then
        log "INFO" "✅ All blob service properties are correctly configured"
        return 0
    else
        log "INFO" "⚠️ One or more blob service properties need updating"
        # Add detailed comparison logging
        log "INFO" "Current vs Expected values:"
        log "INFO" "Delete Retention: $delete_retention_enabled vs $BLOB_DELETE_RETENTION_ENABLED"
        log "INFO" "Delete Days: $delete_retention_days vs $BLOB_DELETE_RETENTION_DAYS"
        log "INFO" "Container Delete: $container_delete_retention_enabled vs $BLOB_CONTAINER_DELETE_ENABLED"
        log "INFO" "Container Days: $container_delete_retention_days vs $BLOB_CONTAINER_DELETE_DAYS"
        log "INFO" "Change Feed: $change_feed_enabled vs $BLOB_CHANGE_FEED_ENABLED"
        log "INFO" "Change Feed Days: $change_feed_retention_days vs $BLOB_CHANGE_FEED_DAYS"
        log "INFO" "Versioning: $versioning_enabled vs $BLOB_VERSIONING_ENABLED"
        log "INFO" "Restore Policy: $restore_policy_enabled vs $BLOB_RESTORE_POLICY_ENABLED"
        log "INFO" "Restore Days: $restore_days vs $BLOB_RESTORE_POLICY_DAYS"
        return 1
    fi
}

# Function to update blob service properties
update_blob_service_properties() {
    # Initialize variables when function is called
    init_blob_service_properties
    
    log "INFO" "🔄 Checking if blob service properties need updating..."
    
    if ! check_blob_service_properties; then
        log "INFO" "🔄 Updating blob service properties..."

        local api_version="2023-01-01"
        local storage_url="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT/blobServices/default"

        # Generate the request body using the centralized configuration
        local request_body
        request_body=$(generate_blob_properties_json)

        # Log the request body for debugging
        log "INFO" "Request body:"
        echo "$request_body" | jq '.'

        # Update all properties in a single call
        if az rest --method PUT \
            --uri "https://management.azure.com$storage_url?api-version=$api_version" \
            --body "$request_body" --output none; then
            log "INFO" "✅ Successfully updated blob service properties"
            
            # Add delay before verification
            sleep 5  # Give Azure some time to process the change
            
            # Verify the changes
            if check_blob_service_properties; then
                log "INFO" "✅ Verified all blob service properties are correctly configured"
                return 0
            else
                log "ERROR" "❌ Verification failed after update"
                return 1
            fi
        else
            log "ERROR" "❌ Failed to update blob service properties"
            return 1
        fi
    else
        log "INFO" "ℹ️ All blob service properties are already configured correctly"
        return 0
    fi
}