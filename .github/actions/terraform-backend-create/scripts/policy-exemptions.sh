#!/bin/bash
# policy-exemptions.sh

# Configuration (using environment variables with defaults)
RUN_POLICY_EXEMPTIONS_CHECK=${RUN_POLICY_EXEMPTIONS_CHECK:-true}
CREATE_POLICY_EXEMPTIONS=${CREATE_POLICY_EXEMPTIONS:-true}

# Logging function if not already available
if ! command -v log &>/dev/null; then
    log() {
        local level=$1
        shift
        echo "[$level] $(date '+%Y-%m-%d %H:%M:%S') - $*"
    }
fi

# Function to group policy assignments by assignment_id
process_policy_assignments() {
    local -A grouped_assignments=()
    local assignments_file="${GITHUB_ACTION_PATH}/policy/policy-assignments.conf"

    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^#.*$ || -z $line ]] && continue
        IFS='|' read -r assignment_id def_ref_id display_name <<< "$line"
        
        if [[ -n "$assignment_id" ]]; then
            if [[ ${grouped_assignments[$assignment_id]+_} ]]; then
                # Add to existing group
                grouped_assignments[$assignment_id]+=",$def_ref_id"
            else
                # Create new group
                grouped_assignments[$assignment_id]="$def_ref_id"
            fi
        fi
    done < "$assignments_file"

    declare -p grouped_assignments
}

# Function to check if exemption is expired
is_exemption_expired() {
    local exemption_name="$1"
    local expiration_date
    
    expiration_date=$(az policy exemption show \
        --name "$exemption_name" \
        --resource-group "$RESOURCE_GROUP" \
        --query "properties.expiresOn" \
        -o tsv 2>/dev/null)

    if [ -n "$expiration_date" ]; then
        local current_date
        current_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        if [[ "$expiration_date" < "$current_date" ]]; then
            return 0  # Expired
        fi
    fi
    return 1  # Not expired or no expiration date
}

# Function to load policy assignments from file
load_policy_assignments() {
    local assignments_file="${GITHUB_ACTION_PATH}/policy/policy-assignments.conf"
    if [ ! -f "$assignments_file" ]; then
        log "ERROR" "Policy assignments file not found: $assignments_file"
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ ^#.*$ || -z $line ]] && continue
        default_policy_assignments+=("$line")
    done < "$assignments_file"
}

# Function to check existing exemptions
check_existing_exemptions() {
    log "INFO" "🔍 Checking existing policy exemptions..."
    
    local exemptions
    exemptions=$(az policy exemption list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(name, 'temp-')].{Name:displayName, RefId:join(', ', policyDefinitionReferenceIds)}" \
        -o json)

    if [ -n "$exemptions" ] && [ "$exemptions" != "[]" ]; then
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "INFO" "Existing Policy Exemptions:"
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        echo "$exemptions" | jq -r '.[] | "  📝 \(.Name)\n    └─ 🔗 Reference: \(.RefId)"'
        
        log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        return 0
    else
        log "INFO" "No existing exemptions found"
        return 1
    fi
}

# Function to create exemptions from passed assignments
create_policy_exemptions() {
    local expiration_date
    expiration_date=$(date -u -d "+1 days" +"%Y-%m-%dT23:59:59Z")
    local success=true
    
    # Get grouped assignments
    local grouped_assignments_str
    grouped_assignments_str=$(process_policy_assignments)
    eval "$grouped_assignments_str"
    
    log "INFO" "🔄 Creating policy exemptions..."
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "INFO" "Required Policy Exemptions:"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Process each grouped assignment
    for assignment_id in "${!grouped_assignments[@]}"; do
        local ref_ids
        IFS=',' read -r -a ref_ids <<< "${grouped_assignments[$assignment_id]}"
        local display_name
        local exemption_name

        if [ ${#ref_ids[@]} -gt 1 ]; then
            # Multiple policies - use grouped name
            display_name="Multiple Policies - $(basename "$assignment_id")"
            exemption_name="temp-multiple-policies-${RANDOM}"
        else
            # Single policy - use original naming
            local display_name_lookup
            display_name_lookup=$(grep "|${ref_ids[0]}|" "${GITHUB_ACTION_PATH}/policy/policy-assignments.conf" | cut -d'|' -f3)
            display_name="${display_name_lookup:-"Policy - ${ref_ids[0]}"}"
            
            local safe_name
            safe_name=$(echo "$display_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--/-/g' | sed 's/-$//')
            exemption_name="temp-${safe_name:0:40}-${RANDOM}"
        fi

        # Check if exemption exists
        local existing_name
        existing_name=$(az policy exemption list \
            --resource-group "$RESOURCE_GROUP" \
            --query "[?displayName=='Temp Exemption - ${display_name}'].name" \
            --output tsv)

        if [ -n "$existing_name" ]; then
            if is_exemption_expired "$existing_name"; then
                log "INFO" "🔄 Existing exemption expired, creating new one: $display_name"
                az policy exemption delete \
                    --name "$existing_name" \
                    --resource-group "$RESOURCE_GROUP" \
                    --output none
            else
                log "INFO" "ℹ️ Valid exemption already exists for: $display_name"
                continue
            fi
        fi

        log "INFO" "▶️ Policy: $display_name"
        log "INFO" "  └─ Assignment ID: $assignment_id"
        log "INFO" "  └─ Definition Reference IDs: ${ref_ids[*]}"
        log "INFO" "  └─ Expires: $expiration_date"

        # Create the policy exemption
        if ! az policy exemption create \
            --name "$exemption_name" \
            --resource-group "$RESOURCE_GROUP" \
            --exemption-category "Waiver" \
            --policy-assignment "$assignment_id" \
            --description "Temporary exemption for storage account configuration (created via IaC)" \
            --display-name "Temp Exemption - $display_name" \
            --expires-on "$expiration_date" \
            --policy-definition-reference-ids "${ref_ids[@]}" \
            2>&1; then
            log "ERROR" "❌ Failed to create exemption for: $display_name"
            success=false
        else
            log "INFO" "✅ Created exemption: $display_name"
        fi
        
        log "INFO" "──────────────────────────────"
    done

    if [ "$success" = true ]; then
        log "INFO" "✅ Successfully created policy exemptions"
        log "INFO" "📅 New exemptions valid until: $expiration_date"
        return 0
    else
        log "ERROR" "❌ Failed to create some policy exemptions"
        return 1
    fi
}

# Function to show exemption summary
show_exemption_summary() {
    log "INFO" "📋 Policy Exemption Summary for $RESOURCE_GROUP"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local summary
    summary=$(az policy exemption list \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?contains(name, 'temp-')].{Name:displayName, RefId:join(', ', policyDefinitionReferenceIds)}" \
        -o json | \
        jq -r '.[] | "  📝 \(.Name)\n    └─ 🔗 Reference: \(.RefId)"')
    
    echo "$summary"
    log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Function to handle the full policy exemption workflow
handle_policy_exemptions() {
    if $RUN_POLICY_EXEMPTIONS_CHECK; then
        # Check existing exemptions but don't exit if found
        if check_existing_exemptions; then
            log "INFO" "Found existing policy exemptions, checking for additional needed exemptions..."
        fi

        if $CREATE_POLICY_EXEMPTIONS; then
            create_policy_exemptions
            show_exemption_summary

            # Add wait time for policies to take effect
            log "INFO" "Waiting for policy exemptions to propagate..."
            local wait_time=120 # Wait time in seconds
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

            return $?
        else
            log "INFO" "Policy exemption creation is disabled (CREATE_POLICY_EXEMPTIONS=false)"
            return 0
        fi
    else
        log "INFO" "Policy exemption checks are disabled (RUN_POLICY_EXEMPTIONS_CHECK=false)"
        return 0
    fi
}