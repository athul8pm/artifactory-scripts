#!/bin/bash

CONFIG_FILE=$1

if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: $0 <config.properties>"
  exit 1
fi

ENV=$(grep '^env=' "$CONFIG_FILE" | cut -d'=' -f2)
GENERIC_REPO=$(grep '^generic_repo=' "$CONFIG_FILE" | cut -d'=' -f2)

CREATE_USER=$(grep '^create_user=' "$CONFIG_FILE" | cut -d'=' -f2)
CREATE_GROUP=$(grep '^create_group=' "$CONFIG_FILE" | cut -d'=' -f2)
CREATE_PERMISSION=$(grep '^create_permission=' "$CONFIG_FILE" | cut -d'=' -f2)
CREATE_REPO=$(grep '^create_repo=' "$CONFIG_FILE" | cut -d'=' -f2)
CREATE_FOLDERS=$(grep '^create_folders=' "$CONFIG_FILE" | cut -d'=' -f2)

case "$ENV" in
  dev)
    ARTIFACTORY_URL="https://dev-artifactory.example.com"
    ;;
  prod)
    ARTIFACTORY_URL="https://prod-artifactory.example.com"
    ;;
  trial)
    ARTIFACTORY_URL="https://jfrogtrial2025.jfrog.io"
    ;;
  *)
    echo "Invalid env in config file. Choose dev|prod|trial"
    exit 1
    ;;
esac

read -s -p "Enter Artifactory Bearer Token: " BEARER_TOKEN
echo

# ---------------------------------------------
# Functions
# ---------------------------------------------
handle_response() {
  local HTTP_CODE=$1
  local MSG=$2
  if [[ $HTTP_CODE -ge 200 && $HTTP_CODE -lt 300 ]]; then
    return 0
  elif [[ $HTTP_CODE -ge 300 && $HTTP_CODE -lt 400 ]]; then
    echo "WARNING: $MSG returned HTTP $HTTP_CODE (redirect)"
  else
    echo "ERROR: $MSG failed with HTTP $HTTP_CODE"
    exit 1
  fi
}

create_group() {
  local GROUP=$1
  echo "Creating group: $GROUP ..."
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d "{\"description\":\"Group $GROUP\"}" \
       "$ARTIFACTORY_URL/artifactory/api/security/groups/$GROUP")
  handle_response $RESPONSE "Create group $GROUP"
  echo "Group $GROUP created."
}

create_user() {
  local USERNAME=$1
  local EMAIL=$2
  local PASSWORD=$3
  local GROUP=$4

  echo "Creating user: $USERNAME ($EMAIL) ..."

  EXISTING=$(curl -s -o /dev/null -w "%{http_code}" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       "$ARTIFACTORY_URL/access/api/v2/users/$USERNAME")

  if [[ "$EXISTING" == "200" ]]; then
    echo "User $USERNAME already exists. Skipping."
  else
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d "{
             \"username\": \"$USERNAME\",
             \"email\": \"$EMAIL\",
             \"password\": \"$PASSWORD\",
             \"groups\": [\"$GROUP\"]
           }" \
       "$ARTIFACTORY_URL/access/api/v2/users")
    handle_response $RESPONSE "Create user $USERNAME"
    echo "User $USERNAME setup done."
  fi
}

create_repo() {
  local KEY=$1
  echo "Checking if repo $KEY exists ..."

  EXISTING=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $BEARER_TOKEN" \
    "$ARTIFACTORY_URL/artifactory/api/repositories/$KEY")

  if [[ "$EXISTING" == "200" ]]; then
    echo "Repo $KEY already exists. Skipping."
    return
  fi

  echo "Creating generic repo: $KEY ..."
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d '{
             "rclass": "local",
             "packageType": "generic"
           }' \
       "$ARTIFACTORY_URL/artifactory/api/repositories/$KEY")

  handle_response $RESPONSE "Create repo $KEY"
  echo "Repo $KEY created."
}

create_permission() {
  local PERM_KEY=$1
  local REPO=$2
  local PATTERN=$3
  local GROUP=$4
  local ACCESS=$5

  IFS=',' read -ra ACTIONS <<< "$ACCESS"
  ACTIONS_JSON="["
  for a in "${ACTIONS[@]}"; do
    ACTIONS_JSON+="\"$a\","
  done
  ACTIONS_JSON="${ACTIONS_JSON%,}]"

  echo "Creating permission: $PERM_KEY for $REPO ($PATTERN) for group $GROUP with actions $ACCESS..."

  local PERM_JSON=$(cat <<EOF
{
  "name": "$PERM_KEY",
  "resources": {
    "artifact": {
      "actions": {
        "users": {},
        "groups": {
          "$GROUP": $ACTIONS_JSON
        }
      },
      "targets": {
        "$REPO": {
          "include_patterns": ["$PATTERN"],
          "exclude_patterns": []
        }
      }
    },
    "release_bundle": {
      "actions": {"users": {}, "groups": {}},
      "targets": {}
    },
    "build": {
      "actions": {"users": {}, "groups": {}},
      "targets": {}
    }
  }
}
EOF
)

  RESPONSE=$(curl -s \
       -X POST \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d "$PERM_JSON" \
       "$ARTIFACTORY_URL/access/api/v2/permissions")

  if echo "$RESPONSE" | grep -q '"errors"'; then
    echo "ERROR creating permission $PERM_KEY: $RESPONSE"
  else
    echo "Permission $PERM_KEY created successfully."
  fi
}



create_folder_with_readme() {
  local REPO=$1
  local FOLDER=$2
  echo "Creating folder: $REPO/$FOLDER with README.md ..."

  TMPFILE=$(mktemp)
  echo "# $FOLDER" > "$TMPFILE"
  echo "This folder is reserved for $FOLDER artifacts." >> "$TMPFILE"

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -T "$TMPFILE" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       "$ARTIFACTORY_URL/artifactory/$REPO/$FOLDER/README.md")
  handle_response $RESPONSE "Create folder $FOLDER"
  rm "$TMPFILE"
  echo "Folder $FOLDER created with README.md"
}

# ---------------------------------------------
# Execution
# ---------------------------------------------
echo "Starting Artifactory setup for repo $GENERIC_REPO in $ENV environment..."

# Groups
if [[ "$CREATE_GROUP" == "y" ]]; then
  for g in $(grep '^groups=' "$CONFIG_FILE" | cut -d'=' -f2 | tr ',' ' '); do
    create_group "$g"
  done
fi

# Users
if [[ "$CREATE_USER" == "y" ]]; then
  while IFS= read -r u; do
    IFS='|' read -ra FIELDS <<< "$u"
  create_user "${FIELDS[0]}" "${FIELDS[1]}" "${FIELDS[2]}" "${FIELDS[3]}"
done <<< "$(grep '^users=' "$CONFIG_FILE" | cut -d'=' -f2-)"

fi

# Repo
if [[ "$CREATE_REPO" == "y" ]]; then
  create_repo "$GENERIC_REPO"
fi

# Permissions
if [[ "$CREATE_PERMISSION" == "y" ]]; then
  while IFS= read -r p; do
    IFS='|' read -ra FIELDS <<< "$p"
    create_permission "${FIELDS[0]}" "${FIELDS[1]}" "${FIELDS[2]}" "${FIELDS[3]}" "${FIELDS[4]}"
  done <<< "$(grep '^permissions=' "$CONFIG_FILE" | cut -d'=' -f2-)"
fi

# Folders
if [[ "$CREATE_FOLDERS" == "y" ]]; then
  for f in $(grep '^folders=' "$CONFIG_FILE" | cut -d'=' -f2 | tr ',' ' '); do
    create_folder_with_readme "$GENERIC_REPO" "$f"
  done
fi

echo "Setup completed successfully."
