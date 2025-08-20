# Artifactory Setup Script

This repository contains a bash automation script (`setup-artifactory.sh`) that provisions users, groups, repositories in JFrog Artifactory based on a given configuration file.

## Prerequisites

1. Access to Artifactory
   - A valid JFrog Artifactory instance URL.
   - A token with `admin` privileges.

2. Bearer Token
   - The script requires a Bearer Token to authenticate API calls.

## Configuration File

The script expects a `.properties` file as input.  
Example: `team-config.properties`
