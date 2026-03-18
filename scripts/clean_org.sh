#!/bin/bash

# --- Configuration & Validation ---
usage() {
  echo "Usage: $0 <org name> [--server] [--chassis] [--domain] [--unused-policies] [--pools] [--software-repo] [--workflows] [--recommission] [--unassign] [--delete] [--dry-run] [--clear-user-labels] [--filter <pattern>]"
  echo ""
  echo "If no cleanup/recommission flags are provided, no operations run."
  echo "When --server is used, server profile templates and vNIC templates are also included in delete operations."
  echo "When --unused-policies is used, policies with no direct profiles and no indirect vNIC references are processed (iteratively in delete mode)."
  echo "When --pools is used, pool objects are processed. Use --filter to target specific pools."
  echo "When --software-repo is used, software repository files are processed (firmware, OS images, SCU links, OS config files)."
  echo "When --workflows is used, non-system-defined workflows in the org are processed."
  echo "When --recommission is used, FI-attached decommissioned servers are listed and can be recommissioned."
  echo "Use --filter with wildcards (*, ?) to match names. If no wildcard is given, contains-style matching is used."
  echo "If --delete is omitted (or --dry-run is used), actions are dry-run only."
}

ORG_NAME=""
DELETE=false
UNASSIGN=false
CLEAR_USER_LABELS=false

CLEAN_SERVER=false
CLEAN_CHASSIS=false
CLEAN_DOMAIN=false
CLEAN_UNUSED_POLICIES=false
CLEAN_POOLS=false
CLEAN_SOFTWARE_REPO=false
CLEAN_WORKFLOWS=false
RECOMMISSION_DECOMMISSIONED=false
NAME_FILTER=""
NAME_MATCH_PATTERN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --server)  CLEAN_SERVER=true ;;
    --chassis) CLEAN_CHASSIS=true ;;
    --domain)  CLEAN_DOMAIN=true ;;
    --unused-policies) CLEAN_UNUSED_POLICIES=true ;;
    --pools|--pool) CLEAN_POOLS=true ;;
    --software-repo|--software-repository) CLEAN_SOFTWARE_REPO=true ;;
    --workflows|--workflow) CLEAN_WORKFLOWS=true ;;
    --recommission|--recommission-decommissioned) RECOMMISSION_DECOMMISSIONED=true ;;
    --unassign) UNASSIGN=true ;;
    --delete)   DELETE=true ;;
    --dry-run|--dryrun) DELETE=false ;;
    --clear-user-labels|--clear-user-label) CLEAR_USER_LABELS=true ;;
    --filter)
      shift
      if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
        echo "Error: --filter requires a value."
        usage
        exit 1
      fi
      NAME_FILTER="$1"
      ;;
    --filter=*)
      NAME_FILTER="${1#*=}"
      if [ -z "$NAME_FILTER" ]; then
        echo "Error: --filter requires a non-empty value."
        usage
        exit 1
      fi
      ;;
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

if [ -n "$NAME_FILTER" ]; then
  if [[ "$NAME_FILTER" == *"*"* || "$NAME_FILTER" == *"?"* || "$NAME_FILTER" == *"["* ]]; then
    NAME_MATCH_PATTERN="$NAME_FILTER"
  else
    NAME_MATCH_PATTERN="*${NAME_FILTER}*"
  fi
  echo "Name filter enabled: '${NAME_MATCH_PATTERN}'"
fi

if $CLEAN_POOLS && [ -z "$NAME_FILTER" ]; then
  echo "Error: --pools requires --filter <pattern> to avoid deleting all pools."
  usage
  exit 1
fi

if $CLEAN_SOFTWARE_REPO && [ -z "$NAME_FILTER" ]; then
  echo "Error: --software-repo requires --filter <pattern> to avoid deleting all software repository files."
  usage
  exit 1
fi

if $CLEAN_WORKFLOWS && [ -z "$NAME_FILTER" ]; then
  echo "Error: --workflows requires --filter <pattern> to avoid deleting all non-system workflows."
  usage
  exit 1
fi

# If no specific cleanup flags were set, do nothing by default (dry run for other selected actions)
if ! $CLEAN_SERVER && ! $CLEAN_CHASSIS && ! $CLEAN_DOMAIN && ! $CLEAN_UNUSED_POLICIES && ! $CLEAN_POOLS && ! $CLEAN_SOFTWARE_REPO && ! $CLEAN_WORKFLOWS && ! $RECOMMISSION_DECOMMISSIONED; then
  echo "No cleanup/recommission flags provided; no operations will run."
fi

# Get the Org MOID
ORG_MOID=$(isctl get organization organization --filter "Name eq '${ORG_NAME}'" -o jsonpath="[*].Moid")

if [ -z "$ORG_MOID" ]; then
    echo "Error: Organization '${ORG_NAME}' not found."
    exit 1
fi

# --- Helper Functions ---

# Apply a shell wildcard filter on newline-delimited names.
filter_name_list() {
    local input_list="$1"

    if [ -z "$input_list" ]; then
        return
    fi

    if [ -z "$NAME_MATCH_PATTERN" ]; then
        printf "%s\n" "$input_list"
        return
    fi

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [[ "$name" == $NAME_MATCH_PATTERN ]]; then
            printf "%s\n" "$name"
        fi
    done <<< "$input_list"
}

name_matches_filter() {
    local input_name="$1"

    if [ -z "$NAME_MATCH_PATTERN" ]; then
        return 0
    fi

    [[ "$input_name" == $NAME_MATCH_PATTERN ]]
}

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
    list=$(filter_name_list "$list")

    if [ -z "$list" ]; then
        if [ -n "$NAME_FILTER" ]; then
            echo "No ${resource_type}s found matching filter '${NAME_FILTER}'."
        else
            echo "No ${resource_type}s found."
        fi
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
    list=$(filter_name_list "$list")

    if [ -z "$list" ]; then
        if [ -n "$NAME_FILTER" ]; then
            echo "No Domain Profiles found matching filter '${NAME_FILTER}'."
        else
            echo "No Domain Profiles found."
        fi
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

# Function to process server profile templates
process_server_templates() {
    echo "--- Processing Server Profile Templates ---"

    local list=$(isctl get server profiletemplate --filter "Organization.Moid eq '${ORG_MOID}'" -o jsonpath="[*].Name")
    list=$(filter_name_list "$list")

    if [ -z "$list" ]; then
        if [ -n "$NAME_FILTER" ]; then
            echo "No Server Profile Templates found matching filter '${NAME_FILTER}'."
        else
            echo "No Server Profile Templates found."
        fi
        return
    fi

    while read -r TEMPLATE_NAME; do
        [ -z "$TEMPLATE_NAME" ] && continue
        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete server profile template '${TEMPLATE_NAME}'... "
            isctl delete server profiletemplate name "$TEMPLATE_NAME" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl delete server profiletemplate name '${TEMPLATE_NAME}'"
        fi
    done <<< "$list"
}

# Function to process vNIC templates and their dependent vNICs.
# vNIC templates cannot be deleted while vNICs still reference them.
process_vnic_templates() {
    echo "--- Processing vNIC Templates ---"

    local template_rows
    template_rows=$(isctl get vnic vnictemplate --filter "Organization.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null and .Name != null)
            | "\(.Moid)|\(.Name)"
        ')

    if [ -z "$template_rows" ]; then
        if [ -n "$NAME_FILTER" ]; then
            echo "No vNIC Templates found matching filter '${NAME_FILTER}'."
        else
            echo "No vNIC Templates found."
        fi
        return
    fi

    local filtered_rows=""
    while IFS='|' read -r TEMPLATE_MOID TEMPLATE_NAME; do
        [ -z "$TEMPLATE_MOID" ] && continue
        [ -z "$TEMPLATE_NAME" ] && continue

        if name_matches_filter "$TEMPLATE_NAME"; then
            filtered_rows+="${TEMPLATE_MOID}|${TEMPLATE_NAME}"$'\n'
        fi
    done <<< "$template_rows"

    if [ -z "$filtered_rows" ]; then
        echo "No vNIC Templates found matching filter '${NAME_FILTER}'."
        return
    fi

    while IFS='|' read -r TEMPLATE_MOID TEMPLATE_NAME; do
        [ -z "$TEMPLATE_MOID" ] && continue
        [ -z "$TEMPLATE_NAME" ] && continue

        local derived_vnic_moids
        derived_vnic_moids=$(isctl get vnic ethif --filter "PermissionResources.Moid eq '${ORG_MOID}' AND SrcTemplate.Moid eq '${TEMPLATE_MOID}'" -o jsonpath="[*].Moid")

        if [ -n "$derived_vnic_moids" ]; then
            while read -r VNIC_MOID; do
                [ -z "$VNIC_MOID" ] && continue
                if [ "$DELETE" = true ]; then
                    echo -n "Attempting to delete vNIC '${VNIC_MOID}' derived from template '${TEMPLATE_NAME}'... "
                    isctl delete vnic ethif moid "$VNIC_MOID" > /dev/null
                    if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
                else
                    echo "(Dry Run) isctl delete vnic ethif moid '${VNIC_MOID}' # derived from template '${TEMPLATE_NAME}'"
                fi
            done <<< "$derived_vnic_moids"
        fi

        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete vNIC template '${TEMPLATE_NAME}'... "
            isctl delete vnic vnictemplate name "$TEMPLATE_NAME" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl delete vnic vnictemplate name '${TEMPLATE_NAME}'"
        fi
    done <<< "$filtered_rows"
}

# Collect policy MOIDs that are indirectly referenced by other objects.
# These must be treated as "in use" even when policy.Profiles is null/empty.
collect_indirectly_used_policy_moids() {
    local ethif_refs
    local fcif_refs
    local qualpolicy_refs
    local pool_qualpolicy_refs

    ethif_refs=$(isctl get vnic ethif --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | [
                .EthQosPolicy.Moid?,
                .EthAdapterPolicy.Moid?,
                .EthNetworkPolicy.Moid?,
                .FabricEthNetworkControlPolicy.Moid?,
                .IscsiBootPolicy.Moid?,
                (.FabricEthNetworkGroupPolicy // [] | if type == "array" then .[] | .Moid? else empty end)
              ]
            | .[]
            | select(. != null and . != "")
        ')

    fcif_refs=$(isctl get vnic fcif --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | [
                .FcQosPolicy.Moid?,
                .FcAdapterPolicy.Moid?,
                .FcNetworkPolicy.Moid?
              ]
            | .[]
            | select(. != null and . != "")
        ')

    # Qualification policies can be in use via resource pools even when Profiles is empty.
    qualpolicy_refs=$(isctl get resourcepool qualificationpolicy --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | select((.ResourcePools // []) | length > 0)
            | .Moid
        ')

    # Also collect qualification policy references from pool objects.
    # This handles API payload variations where pool-side refs are present.
    pool_qualpolicy_refs=$(isctl get resourcepool pool --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | .. | objects
            | select(.ObjectType? == "resourcepool.QualificationPolicy")
            | .Moid?
            | select(. != null and . != "")
        ')

    printf "%s\n%s\n%s\n%s\n" "$ethif_refs" "$fcif_refs" "$qualpolicy_refs" "$pool_qualpolicy_refs" | sed '/^$/d' | sort -u
}

# Function to process unused policies.
# A policy is considered unused when Profiles is empty/null and no vNIC object references it.
# In delete mode, this runs iteratively so newly-unused policies are also cleaned up.
process_unused_policies() {
    echo "--- Processing Unused Policies ---"

    local pass=1
    local total_deleted=0

    while true; do
        local indirect_used_moids
        local indirect_used_moids_json
        indirect_used_moids=$(collect_indirectly_used_policy_moids)
        indirect_used_moids_json=$(printf "%s\n" "$indirect_used_moids" | jq -Rsc 'split("\n") | map(select(length > 0))')

        local policy_rows
        policy_rows=$(isctl get search searchitem \
            --auto-paginate --auto-paginate-batch-size 1000 \
            --filter "PermissionResources.Moid eq '${ORG_MOID}' AND endswith(ObjectType,'Policy')" \
            -o json 2>/dev/null | \
            jq -r --argjson indirect "$indirect_used_moids_json" '
                def rows:
                    if type == "array" then .[] | rows
                    elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                    elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                    else .
                    end;
                rows
                | select(type == "object")
                | select(.Moid != null and .ObjectType != null and .Name != null)
                | select((.Profiles // []) | length == 0)
                | . as $policy
                | select(($indirect | index($policy.Moid)) | not)
                | "\(.Moid)\t\(.Name)\t\(.ObjectType)"')

        if [ -z "$policy_rows" ]; then
            if [ "$pass" -eq 1 ]; then
                if [ -n "$NAME_FILTER" ]; then
                    echo "No unused policies found matching filter '${NAME_FILTER}'."
                else
                    echo "No unused policies found."
                fi
            else
                echo "No additional unused policies found."
            fi
            break
        fi

        local filtered_rows=""
        while IFS=$'\t' read -r POLICY_MOID POLICY_NAME POLICY_OBJECT_TYPE; do
            [ -z "$POLICY_MOID" ] && continue
            [ -z "$POLICY_NAME" ] && continue
            [ -z "$POLICY_OBJECT_TYPE" ] && continue

            if name_matches_filter "$POLICY_NAME"; then
                filtered_rows+="${POLICY_MOID}"$'\t'"${POLICY_NAME}"$'\t'"${POLICY_OBJECT_TYPE}"$'\n'
            fi
        done <<< "$policy_rows"

        if [ -z "$filtered_rows" ]; then
            if [ "$pass" -eq 1 ]; then
                echo "No unused policies found matching filter '${NAME_FILTER}'."
            else
                echo "No additional unused policies found matching filter '${NAME_FILTER}'."
            fi
            break
        fi

        local deleted_in_pass=0
        while IFS=$'\t' read -r POLICY_MOID POLICY_NAME POLICY_OBJECT_TYPE; do
            [ -z "$POLICY_MOID" ] && continue
            [ -z "$POLICY_NAME" ] && continue
            [ -z "$POLICY_OBJECT_TYPE" ] && continue

            local module="${POLICY_OBJECT_TYPE%%.*}"
            local class_name="${POLICY_OBJECT_TYPE#*.}"
            local resource_name
            resource_name=$(echo "$class_name" | tr '[:upper:]' '[:lower:]')

            if [ "$DELETE" = true ]; then
                echo -n "Attempting to delete unused policy '${POLICY_NAME}' (${POLICY_OBJECT_TYPE})... "
                isctl delete "$module" "$resource_name" moid "$POLICY_MOID" > /dev/null
                if [ $? -eq 0 ]; then
                    echo "Success."
                    deleted_in_pass=$((deleted_in_pass + 1))
                    total_deleted=$((total_deleted + 1))
                else
                    echo "Error." >&2
                fi
            else
                echo "(Dry Run) isctl delete ${module} ${resource_name} moid '${POLICY_MOID}' # ${POLICY_NAME} (${POLICY_OBJECT_TYPE})"
            fi
        done <<< "$filtered_rows"

        if [ "$DELETE" != true ]; then
            break
        fi

        if [ "$deleted_in_pass" -eq 0 ]; then
            echo "No policies were deleted in pass ${pass}; stopping iterative cleanup."
            break
        fi

        echo "Pass ${pass} completed: deleted ${deleted_in_pass} policy(ies)."
        pass=$((pass + 1))
    done

    if [ "$DELETE" = true ]; then
        echo "Unused policy cleanup completed. Total deleted: ${total_deleted}."
    fi
}

# Function to process pool objects.
# Pool cleanup is name-filtered and dry-run by default unless --delete is set.
process_pools() {
    echo "--- Processing Pools ---"

    local pool_rows
    pool_rows=$(isctl get search searchitem \
        --auto-paginate --auto-paginate-batch-size 1000 \
        --filter "PermissionResources.Moid eq '${ORG_MOID}' AND endswith(ObjectType,'Pool')" \
        -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null and .Name != null and .ObjectType != null)
            | "\(.Moid)\t\(.Name)\t\(.ObjectType)"')

    if [ -z "$pool_rows" ]; then
        echo "No pools found."
        return
    fi

    local filtered_rows=""
    while IFS=$'\t' read -r POOL_MOID POOL_NAME POOL_OBJECT_TYPE; do
        [ -z "$POOL_MOID" ] && continue
        [ -z "$POOL_NAME" ] && continue
        [ -z "$POOL_OBJECT_TYPE" ] && continue

        if name_matches_filter "$POOL_NAME"; then
            filtered_rows+="${POOL_MOID}"$'\t'"${POOL_NAME}"$'\t'"${POOL_OBJECT_TYPE}"$'\n'
        fi
    done <<< "$pool_rows"

    if [ -z "$filtered_rows" ]; then
        echo "No pools found matching filter '${NAME_FILTER}'."
        return
    fi

    while IFS=$'\t' read -r POOL_MOID POOL_NAME POOL_OBJECT_TYPE; do
        [ -z "$POOL_MOID" ] && continue
        [ -z "$POOL_NAME" ] && continue
        [ -z "$POOL_OBJECT_TYPE" ] && continue

        local module="${POOL_OBJECT_TYPE%%.*}"
        local class_name="${POOL_OBJECT_TYPE#*.}"
        local resource_name
        resource_name=$(echo "$class_name" | tr '[:upper:]' '[:lower:]')

        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete pool '${POOL_NAME}' (${POOL_OBJECT_TYPE})... "
            isctl delete "$module" "$resource_name" moid "$POOL_MOID" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl delete ${module} ${resource_name} moid '${POOL_MOID}' # ${POOL_NAME} (${POOL_OBJECT_TYPE})"
        fi
    done <<< "$filtered_rows"
}

# Function to process software repository files.
# Targets firmware files, OS images, SCU links, and OS configuration files.
process_software_repository() {
    echo "--- Processing Software Repository Files ---"

    local os_config_rows
    local os_image_rows
    local scu_rows
    local firmware_rows
    local combined_rows

    # os.ConfigurationFile
    os_config_rows=$(isctl get os configurationfile --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | "\(.Moid)\t\(.Name // .Moid)\tos\tconfigurationfile\tOS Configuration File\t\(.ObjectType // "os.ConfigurationFile")"
        ')

    # softwarerepository.OperatingSystemFile
    os_image_rows=$(isctl get softwarerepository operatingsystemfile --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | "\(.Moid)\t\(.Name // .Moid)\tsoftwarerepository\toperatingsystemfile\tOS Image\t\(.ObjectType // "softwarerepository.OperatingSystemFile")"
        ')

    # firmware.ServerConfigurationUtilityDistributable
    scu_rows=$(isctl get firmware serverconfigurationutilitydistributable --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | "\(.Moid)\t\(.Name // .Moid)\tfirmware\tserverconfigurationutilitydistributable\tSCU Link\t\(.ObjectType // "firmware.ServerConfigurationUtilityDistributable")"
        ')

    # firmware.Distributable
    firmware_rows=$(isctl get firmware distributable --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | "\(.Moid)\t\(.Name // .Moid)\tfirmware\tdistributable\tFirmware\t\(.ObjectType // "firmware.Distributable")"
        ')

    combined_rows=$(printf "%s\n%s\n%s\n%s\n" "$os_config_rows" "$os_image_rows" "$scu_rows" "$firmware_rows" | sed '/^$/d')

    if [ -z "$combined_rows" ]; then
        echo "No software repository files found."
        return
    fi

    local filtered_rows=""
    while IFS=$'\t' read -r ITEM_MOID ITEM_NAME ITEM_MODULE ITEM_RESOURCE ITEM_KIND ITEM_OBJECT_TYPE; do
        [ -z "$ITEM_MOID" ] && continue
        [ -z "$ITEM_NAME" ] && continue
        [ -z "$ITEM_MODULE" ] && continue
        [ -z "$ITEM_RESOURCE" ] && continue

        if name_matches_filter "$ITEM_NAME"; then
            filtered_rows+="${ITEM_MOID}"$'\t'"${ITEM_NAME}"$'\t'"${ITEM_MODULE}"$'\t'"${ITEM_RESOURCE}"$'\t'"${ITEM_KIND}"$'\t'"${ITEM_OBJECT_TYPE}"$'\n'
        fi
    done <<< "$combined_rows"

    if [ -z "$filtered_rows" ]; then
        echo "No software repository files found matching filter '${NAME_FILTER}'."
        return
    fi

    while IFS=$'\t' read -r ITEM_MOID ITEM_NAME ITEM_MODULE ITEM_RESOURCE ITEM_KIND ITEM_OBJECT_TYPE; do
        [ -z "$ITEM_MOID" ] && continue
        [ -z "$ITEM_NAME" ] && continue
        [ -z "$ITEM_MODULE" ] && continue
        [ -z "$ITEM_RESOURCE" ] && continue

        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete ${ITEM_KIND} '${ITEM_NAME}' (${ITEM_OBJECT_TYPE})... "
            isctl delete "$ITEM_MODULE" "$ITEM_RESOURCE" moid "$ITEM_MOID" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl delete ${ITEM_MODULE} ${ITEM_RESOURCE} moid '${ITEM_MOID}' # ${ITEM_NAME} (${ITEM_KIND})"
        fi
    done <<< "$filtered_rows"
}

# Function to process workflow definition objects.
# System-defined definitions are excluded via SharedScope eq ''.
process_workflows() {
    echo "--- Processing Workflows ---"

    local workflow_rows
    workflow_rows=$(isctl get workflow workflowdefinition \
        --auto-paginate --auto-paginate-batch-size 1000 \
        --filter "PermissionResources.Moid eq '${ORG_MOID}' AND SharedScope eq ''" \
        -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null)
            | "\(.Moid)\t\(.Name // .Moid)\t\(.ModTime // "")"
        ')

    if [ -z "$workflow_rows" ]; then
        echo "No workflow definitions found."
        return
    fi

    local filtered_rows=""
    while IFS=$'\t' read -r WF_MOID WF_NAME WF_MOD_TIME; do
        [ -z "$WF_MOID" ] && continue
        [ -z "$WF_NAME" ] && continue

        if name_matches_filter "$WF_NAME"; then
            filtered_rows+="${WF_MOID}"$'\t'"${WF_NAME}"$'\t'"${WF_MOD_TIME}"$'\n'
        fi
    done <<< "$workflow_rows"

    if [ -z "$filtered_rows" ]; then
        echo "No non-system workflow definitions found matching filter '${NAME_FILTER}'."
        return
    fi

    while IFS=$'\t' read -r WF_MOID WF_NAME WF_MOD_TIME; do
        [ -z "$WF_MOID" ] && continue
        [ -z "$WF_NAME" ] && continue
        if [ "$DELETE" = true ]; then
            echo -n "Attempting to delete workflow definition '${WF_NAME}' (LastModified=${WF_MOD_TIME})... "
            isctl delete workflow workflowdefinition moid "$WF_MOID" > /dev/null
            if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
        else
            echo "(Dry Run) isctl delete workflow workflowdefinition moid '${WF_MOID}' # ${WF_NAME} (LastModified=${WF_MOD_TIME})"
        fi
    done <<< "$filtered_rows"
}

# Function to find decommissioned FI-attached servers and optionally recommission them.
# Uses Search Item API with identity-specific filtering criteria.
process_decommissioned_servers() {
    echo "--- Processing Decommissioned FI-Attached Servers ---"

    local search_filter
    local identity_rows
    local filtered_rows

    search_filter="PermissionResources.Moid eq '${ORG_MOID}' AND Lifecycle eq 'Decommissioned' AND IndexMotypes eq 'equipment.Identity' AND (ObjectType eq 'compute.BladeIdentity' OR ObjectType eq 'compute.RackUnitIdentity') AND Model ne 'UCSX-580P'"

    identity_rows=$(isctl get search searchitem \
        --auto-paginate --auto-paginate-batch-size 1000 \
        --filter "$search_filter" \
        -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Moid != null and .ObjectType != null)
            | "\(.Moid)\t\(.Name // .Moid)\t\(.ObjectType)\t\(.Model // "Unknown")"
        ')

    if [ -z "$identity_rows" ]; then
        if [ -n "$NAME_FILTER" ]; then
            echo "No decommissioned FI-attached server identities found matching filter '${NAME_FILTER}'."
        else
            echo "No decommissioned FI-attached server identities found."
        fi
        return
    fi

    filtered_rows=""
    while IFS=$'\t' read -r IDENTITY_MOID IDENTITY_NAME IDENTITY_OBJECT_TYPE IDENTITY_MODEL; do
        [ -z "$IDENTITY_MOID" ] && continue
        [ -z "$IDENTITY_NAME" ] && continue
        [ -z "$IDENTITY_OBJECT_TYPE" ] && continue

        if name_matches_filter "$IDENTITY_NAME"; then
            filtered_rows+="${IDENTITY_MOID}"$'\t'"${IDENTITY_NAME}"$'\t'"${IDENTITY_OBJECT_TYPE}"$'\t'"${IDENTITY_MODEL}"$'\n'
        fi
    done <<< "$identity_rows"

    if [ -z "$filtered_rows" ]; then
        echo "No decommissioned FI-attached server identities found matching filter '${NAME_FILTER}'."
        return
    fi

    echo "Found decommissioned FI-attached server identities:"
    while IFS=$'\t' read -r IDENTITY_MOID IDENTITY_NAME IDENTITY_OBJECT_TYPE IDENTITY_MODEL; do
        [ -z "$IDENTITY_MOID" ] && continue
        [ -z "$IDENTITY_NAME" ] && continue
        [ -z "$IDENTITY_OBJECT_TYPE" ] && continue
        echo " - ${IDENTITY_NAME} (${IDENTITY_OBJECT_TYPE}, model=${IDENTITY_MODEL}, moid=${IDENTITY_MOID})"
    done <<< "$filtered_rows"

    if [ "$DELETE" != true ]; then
        while IFS=$'\t' read -r IDENTITY_MOID IDENTITY_NAME IDENTITY_OBJECT_TYPE IDENTITY_MODEL; do
            [ -z "$IDENTITY_MOID" ] && continue
            [ -z "$IDENTITY_OBJECT_TYPE" ] && continue

            local resource_name
            case "$IDENTITY_OBJECT_TYPE" in
                compute.BladeIdentity) resource_name="bladeidentity" ;;
                compute.RackUnitIdentity) resource_name="rackunitidentity" ;;
                *) continue ;;
            esac

            echo "(Dry Run) isctl update compute ${resource_name} moid '${IDENTITY_MOID}' --AdminAction Recommission # ${IDENTITY_NAME}"
        done <<< "$filtered_rows"
        return
    fi

    if [ ! -t 0 ]; then
        echo "Non-interactive input detected; skipping recommission prompts."
        echo "Re-run in an interactive shell to confirm recommission actions."
        return
    fi

    local confirm
    read -r -p "Recommission all listed decommissioned servers? [y/N]: " confirm
    case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *)
            echo "Skipping recommission."
            return
            ;;
    esac

    while IFS=$'\t' read -r IDENTITY_MOID IDENTITY_NAME IDENTITY_OBJECT_TYPE IDENTITY_MODEL; do
        [ -z "$IDENTITY_MOID" ] && continue
        [ -z "$IDENTITY_OBJECT_TYPE" ] && continue

        local resource_name
        case "$IDENTITY_OBJECT_TYPE" in
            compute.BladeIdentity) resource_name="bladeidentity" ;;
            compute.RackUnitIdentity) resource_name="rackunitidentity" ;;
            *) continue ;;
        esac

        echo -n "Attempting to recommission identity '${IDENTITY_NAME}' (${IDENTITY_OBJECT_TYPE})... "
        isctl update compute "${resource_name}" moid "$IDENTITY_MOID" --AdminAction Recommission > /dev/null
        if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
    done <<< "$filtered_rows"
}

# Function to clear user labels for all servers in the org
clear_user_labels() {
    echo "--- Clearing Server User Labels ---"

    # Use jq to extract server names
    local server_list
    server_list=$(isctl get compute physicalsummary --filter "PermissionResources.Moid eq '${ORG_MOID}'" -o json 2>/dev/null | \
        jq -r '
            def rows:
                if type == "array" then .[] | rows
                elif type == "object" and (.Results? | type) == "array" then .Results[] | rows
                elif type == "object" and (.Items? | type) == "array" then .Items[] | rows
                else .
                end;
            rows
            | select(type == "object")
            | select(.Name != null)
            | .Name
        ')

    if [ -z "$server_list" ]; then
        echo "No servers found."
        return
    fi

    while read -r SERVER_NAME; do
        [ -z "$SERVER_NAME" ] && continue
        echo -n "Clearing user label for server '${SERVER_NAME}'... "
        isctl update compute serversetting name "$SERVER_NAME" --ServerConfig '{"UserLabel": ""}' > /dev/null
        if [ $? -eq 0 ]; then echo "Success."; else echo "Error." >&2; fi
    done <<< "$server_list"
}

# --- Main Execution ---

# 1. Process Server Profiles
if $CLEAN_SERVER; then
  process_profiles "Server Profile" "server profile"
  process_server_templates
  process_vnic_templates
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

# 4. Process Unused Policies
if $CLEAN_UNUSED_POLICIES; then
  process_unused_policies
  echo ""
fi

# 5. Process Pools
if $CLEAN_POOLS; then
  process_pools
  echo ""
fi

# 6. Clear User Labels
if $CLEAR_USER_LABELS; then
  clear_user_labels
  echo ""
fi

# 7. Process Software Repository Files
if $CLEAN_SOFTWARE_REPO; then
  process_software_repository
  echo ""
fi

# 8. Process Workflows
if $CLEAN_WORKFLOWS; then
  process_workflows
  echo ""
fi

# 9. Recommission Decommissioned FI-Attached Servers
if $RECOMMISSION_DECOMMISSIONED; then
  process_decommissioned_servers
  echo ""
fi

echo "All requested operations completed."

#Way to remove all user profiles
# 
