#!/bin/bash
# =======================================================
# Artifactory Setup Script (Generic Repo with Teams)
# Users via /access/api/v2/users using Bearer token
# Others via Artifactory API
# =======================================================

CONFIG_FILE=$1

if [ -z "$CONFIG_FILE" ]; then
  echo "Usage: $0 <config.properties>"
  exit 1
fi

# ---------------------------------------------
# Load properties
# ---------------------------------------------
GENERIC_REPO=$(grep '^generic_repo=' "$CONFIG_FILE" | cut -d'=' -f2)
ENV=$(grep '^env=' "$CONFIG_FILE" | cut -d'=' -f2)

# Map env to Artifactory URL
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

# Prompt for Bearer token
read -s -p "Enter Artifactory Bearer Token: " BEARER_TOKEN
echo

# ---------------------------------------------
# Function to handle curl response
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

# ---------------------------------------------
# Functions
# ---------------------------------------------
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
  echo "Creating user: $USERNAME ($EMAIL) ..."

  # Check if user exists
  EXISTING=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $BEARER_TOKEN" \
       "$ARTIFACTORY_URL/access/api/v2/users/$USERNAME")

  if [[ "$EXISTING" == "200" ]]; then
    echo "User $USERNAME already exists. Skipping."
  else
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d "{\"username\":\"$USERNAME\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
       "$ARTIFACTORY_URL/access/api/v2/users")
    handle_response $RESPONSE "Create user $USERNAME"
    echo "User $USERNAME setup done."
  fi
}

create_repo() {
  local KEY=$1
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
  local GROUPS=$4
  echo "Creating permission: $PERM_KEY for $REPO ($PATTERN)..."

  local PERM_JSON="{\"name\":\"$PERM_KEY\",\"repositories\":[\"$REPO\"],\"principals\":{\"groups\":{"
  for g in ${GROUPS//,/ }; do
    PERM_JSON="$PERM_JSON\"$g\":[{\"actions\":[\"read\",\"deploy\"]}],"
  done
  PERM_JSON="${PERM_JSON%,*}}}}"

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
       -H "Content-Type: application/json" \
       -H "Authorization: Bearer $BEARER_TOKEN" \
       -d "$PERM_JSON" \
       "$ARTIFACTORY_URL/artifactory/api/v2/security/permissions/$PERM_KEY")
  handle_response $RESPONSE "Create permission $PERM_KEY"
  echo "Permission $PERM_KEY created."
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
for g in $(grep '^groups=' "$CONFIG_FILE" | cut -d'=' -f2 | tr ',' ' '); do
  create_group "$g"
done

# Users
while IFS= read -r u; do
  IFS='|' read -ra FIELDS <<< "$u"
  create_user "${FIELDS[0]}" "${FIELDS[1]}" "${FIELDS[2]}"
done <<< "$(grep '^users=' "$CONFIG_FILE" | cut -d'=' -f2-)"

# Repo
create_repo "$GENERIC_REPO"

# Permissions
#while IFS= read -r p; do
#  IFS='|' read -ra FIELDS <<< "$p"
#  create_permission "${FIELDS[0]}" "${FIELDS[1]}" "${FIELDS[2]}" "${FIELDS[3]}"
#done <<< "$(grep '^permissions=' "$CONFIG_FILE" | cut -d'=' -f2-)"

# Folders
for f in $(grep '^folders=' "$CONFIG_FILE" | cut -d'=' -f2 | tr ',' ' '); do
  create_folder_with_readme "$GENERIC_REPO" "$f"
done

echo "Setup completed successfully."
