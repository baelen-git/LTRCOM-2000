#!/bin/bash

# --- Configuration & Validation ---
if [ -z "$1" ]; then
  echo "Error: No org was provided."
  echo "Usage: $0 <org name>"
  exit 1
fi

ORG_NAME="$1"
DELETE=true

# Get the Org MOID
ORG_MOID=$(isctl get organization organization --filter "Name eq '${ORG_NAME}'" -o jsonpath="[*].Moid")

if [ -z "$ORG_MOID" ]; then
    echo "Error: Organization '${ORG_NAME}' not found."
    exit 1
fi

# --- Helper Functions ---

# Function to format a list of names into a filter string: ('Name1','Name2')
format_filter_array() {
    local input_list="$1"
    if [ -z "$input_list" ]; then
        echo ""
        return
    fi
    
    # Use awk to format the list into ('item1','item2')
    echo "$input_list" | awk 'BEGIN { ORS=""; print "(" } { printf "'\''%s'\''%s", $0, (NR==ENVIRON["TOTAL_LINES"]?"":",") } END { print ")" }'
}

# Function to wait for workflows associated with a list of profiles
wait_for_workflows() {
    local profile_list="$1"
    
    if [ -z "$profile_list" ]; then
        return
    fi

    # Calculate total lines for the awk script in format_filter_array
    export TOTAL_LINES=$(echo "$profile_list" | wc -l)
    local filter_array=$(format_filter_array "$profile_list")

    echo ""
    echo -n "Wait for running workflows..."

    while true; do
        # Check for InProgress workflows initiated by names in the list
        count=$(isctl get workflow workflowinfo --filter "WorkflowCtx.InitiatorCtx.InitiatorName in ${filter_array} AND WorkflowStatus eq 'InProgress'" --count 2>/dev/null)

        # Validate output is a number
        if [[ -z "$count" ]] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
             echo "Warning: isctl returned unexpected output: '$count'. Retrying..."
             sleep 5
             continue
        fi
        
        if (( count == 0 )); then
            echo " Done."
            break
        else
            echo -n "."
            sleep 3
        fi
    done
}

# Function to process standard profiles (Server and Chassis)
# Usage: process_profiles "Resource Name" "isctl_command_type" "Filter_Field"
process_profiles() {
    local resource_type="$1"   # e.g., "server profile"
    local isctl_type="$2"      # e.g., "server profile" (usually same as above)
    local filter_field="$3"    # e.g., "Organization.Moid"

    echo "--- Processing ${resource_type}s ---"

    # 1. Get List
    local list=$(isctl get ${isctl_type} --filter "${filter_field} eq '${ORG_MOID}'" -o jsonpath="[*].Name")

    if [ -z "$list" ]; then
        echo "No ${resource_type}s found."
        return
    fi

    # 2. Unassign
    while read -r ITEM; do
        [ -z "$ITEM" ] && continue
        echo -n "Attempting to unassign ${resource_type} '${ITEM}'... "
        isctl update ${isctl_type} name "$ITEM" --Action Unassign > /dev/null
        if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
    done <<< "$list"

    # 3. Wait for Workflows
    wait_for_workflows "$list"

    # 4. Delete
    if [ "$DELETE" = true ]; then
        while read -r ITEM; do
            [ -z "$ITEM" ] && continue
            echo -n "Attempting to delete ${resource_type} '${ITEM}'... "
            isctl delete ${isctl_type} name "$ITEM" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        done <<< "$list"
    fi
}

# Function specifically for Domain Profiles (Switch Cluster Profiles)
# Requires special handling because unassign happens on the Switch Profile (Node A/B), but delete happens on the Cluster Profile
process_domain_profiles() {
    echo "--- Processing Domain Profiles ---"

    # 1. Get List of Cluster Profiles
    local list=$(isctl get fabric switchclusterprofile --filter "Organization.Moid eq '${ORG_MOID}'" -o jsonpath="[*].Name")

    if [ -z "$list" ]; then
        echo "No Domain Profiles found."
        return
    fi

    # 2. Unassign Nodes A and B
    while read -r DP; do
        [ -z "$DP" ] && continue
        
        for SUFFIX in "-A" "-B"; do
            echo -n "Attempting to unassign domain profile node ${DP}${SUFFIX}... "
            isctl update fabric switchprofile name "${DP}${SUFFIX}" --Action Unassign > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        done
    done <<< "$list"

    # 3. Wait for Workflows
    # Note: Workflows are usually tied to the Cluster Profile name or the Node names depending on Intersight version.
    # Assuming InitiatorName matches the Cluster Profile name based on your original script logic.
    wait_for_workflows "$list"

    # 4. Delete Cluster Profile
    while read -r DP; do
        [ -z "$DP" ] && continue
        echo -n "Attempting to delete domain profile '${DP}'... "
        
        if [ "$DELETE" = true ]; then
            isctl delete fabric switchclusterprofile name "$DP" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else 
            echo "(Dry Run) isctl delete fabric switchclusterprofile name '$DP'"
        fi
    done <<< "$list"
}

# --- Main Execution ---

# 1. Process Server Profiles
process_profiles "Server Profile" "server profile" "Organization.Moid"

echo ""

# 2. Process Chassis Profiles
process_profiles "Chassis Profile" "chassis profile" "Organization.Moid"

echo ""

# 3. Process Domain Profiles
process_domain_profiles

echo ""
echo "All operations completed."