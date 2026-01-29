#!/bin/bash

# --- Configuration & Validation ---
usage() {
  echo "Usage: $0 <org name> [--server] [--chassis] [--domain] [--unassign] [--delete] [--clear-user-labels]"
  echo ""
  echo "If no profile flags are provided, all profile types are cleaned."
  echo "If --unassign and --delete are both omitted, no changes are made (dry run)."
}

ORG_NAME=""
DELETE=false
UNASSIGN=false
CLEAR_USER_LABELS=false

CLEAN_SERVER=false
CLEAN_CHASSIS=false
CLEAN_DOMAIN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --server)  CLEAN_SERVER=true ;;
    --chassis) CLEAN_CHASSIS=true ;;
    --domain)  CLEAN_DOMAIN=true ;;
    --unassign) UNASSIGN=true ;;
    --delete)   DELETE=true ;;
    --clear-user-labels|--clear-user-label) CLEAR_USER_LABELS=true ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Error: Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [ -z "$ORG_NAME" ]; then
        ORG_NAME="$1"
      else
        echo "Error: Unexpected argument: $1"
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

if [ -z "$ORG_NAME" ]; then
  echo "Error: No org was provided."
  usage
  exit 1
fi

# If no specific profile flags were set, do nothing by default (dry run)
if ! $CLEAN_SERVER && ! $CLEAN_CHASSIS && ! $CLEAN_DOMAIN; then
  echo "No profile flags provided; no profile operations will run."
fi

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
# Usage: process_profiles "Resource Name" "isctl_command_type"
process_profiles() {
    local resource_type="$1"   # e.g., "server profile"
    local isctl_type="$2"      # e.g., "server profile" (usually same as above)

    echo "--- Processing ${resource_type}s ---"

    # 1. Get List
    local list=$(isctl get ${isctl_type} --filter "Organization.Moid eq '${ORG_MOID}'" -o jsonpath="[*].Name")

    if [ -z "$list" ]; then
        echo "No ${resource_type}s found."
        return
    fi

    # 2. Unassign
    while read -r ITEM; do
        [ -z "$ITEM" ] && continue
        if [ "$UNASSIGN" = true ]; then
            echo -n "Attempting to unassign ${resource_type} '${ITEM}'... "
            isctl update ${isctl_type} name "$ITEM" --Action Unassign > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl update ${isctl_type} name '${ITEM}' --Action Unassign"
        fi
    done <<< "$list"

    # 3. Wait for Workflows
    if [ "$UNASSIGN" = true ]; then
        wait_for_workflows "$list"
    fi

    # 4. Delete
    if [ "$DELETE" = true ]; then
        while read -r ITEM; do
            [ -z "$ITEM" ] && continue
            echo -n "Attempting to delete ${resource_type} '${ITEM}'... "
            isctl delete ${isctl_type} name "$ITEM" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        done <<< "$list"
    else
        while read -r ITEM; do
            [ -z "$ITEM" ] && continue
            echo "(Dry Run) isctl delete ${isctl_type} name '${ITEM}'"
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
            if [ "$UNASSIGN" = true ]; then
                echo -n "Attempting to unassign domain profile node ${DP}${SUFFIX}... "
                isctl update fabric switchprofile name "${DP}${SUFFIX}" --Action Unassign > /dev/null
                if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
            else
                echo "(Dry Run) isctl update fabric switchprofile name '${DP}${SUFFIX}' --Action Unassign"
            fi
        done
    done <<< "$list"

    # 3. Wait for Workflows
    # Note: Workflows are usually tied to the Cluster Profile name or the Node names depending on Intersight version.
    # Assuming InitiatorName matches the Cluster Profile name based on your original script logic.
    if [ "$UNASSIGN" = true ]; then
        wait_for_workflows "$list"
    fi

    # 4. Delete Cluster Profile
    while read -r DP; do
        [ -z "$DP" ] && continue
        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete domain profile '${DP}'... "
            isctl delete fabric switchclusterprofile name "$DP" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else 
            echo "(Dry Run) isctl delete fabric switchclusterprofile name '${DP}'"
        fi
    done <<< "$list"
}

# Function to clear user labels for all servers in the org
clear_user_labels() {
    echo "--- Clearing Server User Labels ---"

    # Use jq to extract Moid + SourceObjectType
    local server_list
    server_list=$(isctl get compute physicalsummary --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '.[]? | select(.Moid != null) | "\(.Moid) \(.SourceObjectType // "")"')

    if [ -z "$server_list" ]; then
        echo "No servers found."
        return
    fi

    while read -r MOID SOURCEOBJECTTYPE; do
        [ -z "$MOID" ] && continue
        if [ "$SOURCEOBJECTTYPE" = "compute.Blade" ]; then
            echo -n "Clearing user label for blade server '${MOID}'... "
            isctl update compute serversetting moid "$MOID" --ServerConfig '{"UserLabel": ""}' > /dev/null
        else
            echo -n "Clearing user label for server '${MOID}'... ${CLASSID} "
            isctl update compute serversetting moid "$MOID" --ServerConfig '{"UserLabel": ""}' > /dev/null
        fi
        if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
    done <<< "$server_list"
}

# --- Main Execution ---

# 1. Process Server Profiles
if $CLEAN_SERVER; then
  process_profiles "Server Profile" "server profile"
  echo ""
fi

# 2. Process Chassis Profiles
if $CLEAN_CHASSIS; then
  process_profiles "Chassis Profile" "chassis profile"
  echo ""
fi

# 3. Process Domain Profiles
if $CLEAN_DOMAIN; then
  process_domain_profiles
  echo ""
fi

# 4. Clear User Labels
if $CLEAR_USER_LABELS; then
  clear_user_labels
  echo ""
fi

echo "All requested operations completed."

#Way to remove all user profiles
# 
