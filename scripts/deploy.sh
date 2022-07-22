#!/usr/bin/env bash
# i2, i2 Group, the i2 Group logo, and i2group.com are trademarks of N.Harris Computer Corporation.
# © N.Harris Computer Corporation (2022)
#
# SPDX short identifier: MIT

echo "BASH_VERSION: $BASH_VERSION"
set -e

if [[ -z "${ANALYZE_CONTAINERS_ROOT_DIR}" ]]; then
  echo "ANALYZE_CONTAINERS_ROOT_DIR variable is not set"
  echo "This project should be run inside a VSCode Dev Container. For more information read, the Getting Started guide at https://i2group.github.io/analyze-containers/content/getting_started.html"
  exit 1
fi

function printUsage() {
  echo "Usage:"
  echo "  deploy.sh -c <config_name> [-t {clean}] [-v] [-y]"
  echo "  deploy.sh -c <config_name> [-t {backup|restore} [-b <backup_name>]] [-v] [-y]"
  echo "  deploy.sh -h" 1>&2
}

function usage() {
  printUsage
  exit 1
}

function help() {
  printUsage
  echo "Options:" 1>&2
  echo "  -c <config_name>                       Name of the config to use." 1>&2
  echo "  -t {clean}                             Clean the deployment. Will permanently remove all containers and data." 1>&2
  echo "  -t {backup}                            Backup the database." 1>&2
  echo "  -t {restore}                           Restore the database." 1>&2
  echo "  -b <backup_name>                       Name of the backup to create or restore. If not specified, the default backup is used." 1>&2
  echo "  -v                                     Verbose output." 1>&2
  echo "  -y                                     Answer 'yes' to all prompts." 1>&2
  echo "  -h                                     Display the help." 1>&2
  exit 1
}

while getopts ":c:t:b:vyh" flag; do
  case "${flag}" in
  c)
    CONFIG_NAME="${OPTARG}"
    ;;
  t)
    TASK="${OPTARG}"
    [[ "${TASK}" == "clean" || "${TASK}" == "backup" || "${TASK}" == "restore" || "${TASK}" == "package" ]] || usage
    ;;
  b)
    BACKUP_NAME="${OPTARG}"
    ;;
  v)
    VERBOSE="true"
    ;;
  y)
    YES_FLAG="true"
    ;;
  h)
    help
    ;;
  \?)
    usage
    ;;
  :)
    echo "Invalid option: ${OPTARG} requires an argument"
    ;;
  esac
done

if [[ -z "${CONFIG_NAME}" ]]; then
  usage
fi

if [[ ! "${CONFIG_NAME}" =~ ^[0-9a-zA-Z_+\-]+$ ]]; then
  printf "\e[31mERROR: Config '%s' name cannot contain special characters or spaces. Allowed characters are 0-9a-zA-Z_+-\n" "${CONFIG_NAME}" >&2
  printf "\e[0m" >&2
  usage
fi

if [[ ! -d "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}" ]]; then
  printf "\e[31mERROR: Config '%s' name does not exist in '%s' directory." "${CONFIG_NAME}" "${ANALYZE_CONTAINERS_ROOT_DIR}/configs\n" >&2
  printf "\e[0m" >&2
  usage
fi

if [[ "${TASK}" == "package" ]]; then
  EXTENSIONS_DEV="false"
else
  EXTENSIONS_DEV="true"
fi

if [[ -z "${YES_FLAG}" ]]; then
  YES_FLAG="false"
fi

# Load common functions
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/commonFunctions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/serverFunctions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/clientFunctions.sh"

# Load common variables
source "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/version"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/utils/variables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/simulatedExternalVariables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/commonVariables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/internalHelperVariables.sh"
warnRootDirNotInPath
checkDockerIsRunning
setDependenciesTagIfNecessary

RELOAD_GATEWAY_REQUIRED="false"

###############################################################################
# Create Helper Functions                                                     #
###############################################################################

#######################################
# Bash Array pretending to be a dict (using Parameter Substitution)
# Note we cannot use Bash Associative Arrays as Mac OSX is stuck on Bash 3.x
# Variable 'configFinalActionCode' defines the action to take, values are:
# 0 = default, no files changed
# 1 = live, web ui reload
# 2 = requires warm restart
# 3 = database schema change, requires warm/cold application restart
# 4 = server changes, requires a server restart
# Arguments:
#   None
#######################################
function compareCurrentConfiguration() {
  declare -A checkFilesArray
  checkFilesArray=(["fmr-match-rules.xml"]=1
    ["system-match-rules.xml"]=1
    ["geospatial-configuration.json"]=1
    ["highlight-queries-configuration.xml"]=1
    ["type-access-configuration.xml"]=1
    ["user.registry.xml"]=1
    ["privacyagreement.html"]=1
    ["mapping-configuration.json"]=2
    ["analyze-settings.properties"]=2
    ["analyze-connect.properties"]=2
    ["connectors-template.json"]=2
    ["extension-references.json"]=2
    ["log4j2.xml"]=2
    ["schema-charting-schemes.xml"]=2
    ["schema-results-configuration.xml"]=2
    ["schema-source-reference-schema.xml"]=2
    ["schema-vq-configuration.xml"]=2
    ["command-access-control.xml"]=2
    ["DiscoSolrConfiguration.properties"]=2
    ["schema.xml"]=3
    ["security-schema.xml"]=3
    ["environment/dsid/dsid.properties"]=3
    ["server.extensions.xml"]=4
    ["server.extensions.dev.xml"]=4)
  #Add gateway schemas
  for gateway_short_name in "${!GATEWAY_SHORT_NAME_SET[@]}"; do
    checkFilesArray+=(["${gateway_short_name}-schema.xml"]=1)
    checkFilesArray+=(["${gateway_short_name}-schema-charting-schemes.xml"]=1)
  done

  # array used to store file changes (if any)
  configFinalActionCode=0
  filesChangedArray=()
  printInfo "Checking configuration for '${CONFIG_NAME}' ..."

  if [ ! -d "${CURRENT_CONFIGURATION_PATH}" ]; then
    printErrorAndExit "Current configuration path '${CURRENT_CONFIGURATION_PATH}' is not valid (no configuration folder present)"
  fi
  if [ ! -d "${PREVIOUS_CONFIGURATION_PATH}" ]; then
    printErrorAndExit "Previous configuration path '${PREVIOUS_CONFIGURATION_PATH}' is not valid (no configuration folder present)"
  fi

  for filename in "${!checkFilesArray[@]}"; do
    # get action code
    configActionCode="${checkFilesArray["${filename}"]}"

    # check if filename exists in previous, if so then calc checksum
    if [ -f "${PREVIOUS_CONFIGURATION_PATH}/${filename}" ]; then
      checksumPrevious=$(shasum "${PREVIOUS_CONFIGURATION_PATH}/${filename}" | cut -d ' ' -f 1)
    else
      continue
    fi
    # check if filename exists in current, if so then calc checksum
    if [ -f "${CURRENT_CONFIGURATION_PATH}/${filename}" ]; then
      checksumCurrent=$(shasum "${CURRENT_CONFIGURATION_PATH}/${filename}" | cut -d ' ' -f 1)
    else
      continue
    fi
    # if checksums different then store filename changed and action
    if [[ "$checksumPrevious" != "$checksumCurrent" ]]; then
      printInfo "Previous checksum '${checksumPrevious}' and current checksum '${checksumCurrent}' do not match for filename '${filename}'"
      filesChangedArray+=("${filename}")
      # set action if higher severity code
      if [[ "${configActionCode}" -gt "${configFinalActionCode}" ]]; then
        configFinalActionCode="${configActionCode}"
      fi
    fi
  done

  # count number of files changed (elements) in the array
  if [ "${#filesChangedArray[@]}" -eq 0 ]; then
    printInfo "No checksum differences found, configuration files are in sync"
  else
    printInfo "File changes detected, action code is '${configFinalActionCode}'"
  fi
  printInfo "Results in array '${filesChangedArray[*]}'"
}

function compareCurrentExtensions() {
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"
  local extension_dependencies_path="${EXTENSIONS_DIR}/extension-dependencies.json"
  local extension_names
  # Any change to extensions require the same action code 2
  local configActionCode=2

  printInfo "Checking extensions for '${CONFIG_NAME}' ..."
  readarray -t extension_names < <(jq -r '.extensions[] | .name' <"${extension_references_file}")
  for extension in "${extension_names[@]}"; do
    IFS=' ' read -ra dependencies <<<"$(jq -r --arg name "${extension}" '.[] | select(.name == $name) | .dependencies[]' "${extension_dependencies_path}" | xargs)"
    for dependency in "${dependencies[@]}"; do
      # shellcheck disable=SC2076
      if [[ ! " ${extension_names[*]} " =~ " ${dependency} " ]]; then
        extension_names+=("${dependencies[@]}")
      fi
    done
  done

  for filename in "${extension_names[@]}"; do
    if [ -f "${PREVIOUS_CONFIGURATION_LIB_PATH}/${filename}.sha512" ]; then
      checksumPrevious=$(cat "${PREVIOUS_CONFIGURATION_LIB_PATH}/${filename}.sha512")
    else
      continue
    fi
    if [ -f "${PREVIOUS_EXTENSIONS_DIR}/${filename}.sha512" ]; then
      checksumCurrent=$(cat "${PREVIOUS_EXTENSIONS_DIR}/${filename}.sha512")
    else
      continue
    fi
    # if checksums different then store filename changed and action
    if [[ "${checksumPrevious}" != "${checksumCurrent}" ]]; then
      printInfo "Previous checksum '${checksumPrevious}' and current checksum '${checksumCurrent}' do not match for filename '${filename}.sha512'"
      filesChangedArray+=("lib/${filename}.sha512")
      # set action if higher severity code
      if [[ "${configActionCode}" -gt "${configFinalActionCode}" ]]; then
        configFinalActionCode="${configActionCode}"
      fi
    fi
  done

  # count number of files changed (elements) in the array
  if [ "${#filesChangedArray[@]}" -eq 0 ]; then
    printInfo "No checksum differences found, extension jars are in sync"
  else
    printInfo "Jar changes detected, action code is '${configFinalActionCode}'"
  fi
  printInfo "Results in array '${filesChangedArray[*]}'"
}

function compareCurrentPrometheusConfig() {
  local prometheus_template_file="prometheus.yml"
  PROMETHEUS_ACTION_CODE=0 # set to 1 if update required

  printInfo "Checking prometheus config for '${CONFIG_NAME}' ..."

  # check if filename exists in previous, if so then calc checksum
  if [ -f "${PREVIOUS_CONFIGURATION_PATH}/prometheus/${prometheus_template_file}" ]; then
    checksumPrevious=$(shasum "${PREVIOUS_CONFIGURATION_PATH}/prometheus/${prometheus_template_file}" | cut -d ' ' -f 1)
  fi
  # check if filename exists in current, if so then calc checksum
  if [ -f "${CURRENT_CONFIGURATION_PATH}/prometheus/${prometheus_template_file}" ]; then
    checksumCurrent=$(shasum "${CURRENT_CONFIGURATION_PATH}/prometheus/${prometheus_template_file}" | cut -d ' ' -f 1)
  fi

  # if checksums different then store filename changed and action
  if [[ "${checksumPrevious}" != "${checksumCurrent}" ]]; then
    printInfo "Previous checksum '${checksumPrevious}' and current checksum '${checksumCurrent}' do not match for filename '${prometheus_template_file}'"
    # set prometheus action to 1
    PROMETHEUS_ACTION_CODE=1
  else
    printInfo "Prometheus config in sync"
  fi
}

function compareCurrentGrafanaDashboards() {
  local dashboards_dir="${LOCAL_USER_CONFIG_DIR}/grafana/dashboards"
  GRAFANA_ACTION_CODE=0 # set to 1 if update required

  printInfo "Checking grafana config for '${CONFIG_NAME}' ..."

  if ! diff "${CURRENT_CONFIGURATION_PATH}/grafana/dashboards" "${PREVIOUS_CONFIGURATION_PATH}/grafana/dashboards" >/dev/null 2>&1; then
    printInfo "Grafana dashboard updates detected"
    GRAFANA_ACTION_CODE=1
    # All  Grafana Dashboards
    for file in "${dashboards_dir}"/*; do
      [[ ! -d "${dashboards_dir}" ]] && continue
      filename="${file##*/}"
      # check if filename exists in previous, if so then calc checksum
      if [ -f "${PREVIOUS_CONFIGURATION_PATH}/grafana/dashboards/${filename}" ]; then
        checksumPrevious=$(shasum "${PREVIOUS_CONFIGURATION_PATH}/grafana/dashboards/${filename}" | cut -d ' ' -f 1)
      else
        continue
      fi
      # check if filename exists in current, if so then calc checksum
      if [ -f "${CURRENT_CONFIGURATION_PATH}/grafana/dashboards/${filename}" ]; then
        checksumCurrent=$(shasum "${CURRENT_CONFIGURATION_PATH}/grafana/dashboards/${filename}" | cut -d ' ' -f 1)
      else
        continue
      fi
      # if checksums different then store filename changed and action
      if [[ "$checksumPrevious" != "$checksumCurrent" ]]; then
        printInfo "Previous checksum '${checksumPrevious}' and current checksum '${checksumCurrent}' do not match for filename '${filename}'"
      fi
    done
  else
    printInfo "Grafana dashboards are in sync"
  fi
}

function deployZKCluster() {
  print "Running ZooKeeper container"
  runZK "${ZK1_CONTAINER_NAME}" "${ZK1_FQDN}" "${ZK1_DATA_VOLUME_NAME}" "${ZK1_DATALOG_VOLUME_NAME}" "${ZK1_LOG_VOLUME_NAME}" "1" "zk1" "${ZK1_SECRETS_VOLUME_NAME}"
}

function deploySolrCluster() {
  print "Running Solr container"
  runSolr "${SOLR1_CONTAINER_NAME}" "${SOLR1_FQDN}" "${SOLR1_VOLUME_NAME}" "${HOST_PORT_SOLR}" "solr1" "${SOLR1_SECRETS_VOLUME_NAME}"
}

function configureZKForSolrCluster() {
  print "Configuring ZooKeeper cluster for Solr"
  runSolrClientCommand solr zk mkroot "/${SOLR_CLUSTER_ID}" -z "${ZK_MEMBERS}"
  if [[ "${SOLR_ZOO_SSL_CONNECTION}" == "true" ]]; then
    runSolrClientCommand "/opt/solr/server/scripts/cloud-scripts/zkcli.sh" -zkhost "${ZK_HOST}" -cmd clusterprop -name urlScheme -val https
  fi
  runSolrClientCommand bash -c "echo \"\${SECURITY_JSON}\" > /tmp/security.json && solr zk cp /tmp/security.json zk:/security.json -z ${ZK_HOST}"
}

function configureSolrCollections() {
  print "Configuring Solr collections"
  deleteFolderIfExists "${LOCAL_CONFIG_DIR}/solr/generated_config"
  runi2AnalyzeTool "/opt/i2-tools/scripts/generateSolrSchemas.sh"
  deleteFolderIfExists "${LOCAL_USER_CONFIG_DIR}/solr/generated_config"
  cp -Rp "${LOCAL_CONFIG_DIR}/solr/generated_config" "${LOCAL_USER_CONFIG_DIR}/solr/generated_config"
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n daod_index -d /opt/configuration/solr/generated_config/daod_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n main_index -d /opt/configuration/solr/generated_config/main_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n chart_index -d /opt/configuration/solr/generated_config/chart_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n highlight_index -d /opt/configuration/solr/generated_config/highlight_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n match_index1 -d /opt/configuration/solr/generated_config/match_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n match_index2 -d /opt/configuration/solr/generated_config/match_index
  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n vq_index -d /opt/configuration/solr/generated_config/vq_index
}

function deleteSolrCollections() {
  print "Deleting Solr collections"
  # The curl command uses the container's local environment variables to obtain the SOLR_ADMIN_DIGEST_USERNAME and SOLR_ADMIN_DIGEST_PASSWORD.
  # To stop the variables being evaluated in this script, the variables are escaped using backslashes (\) and surrounded in double quotes (").
  # Any double quotes in the curl command are also escaped by a leading backslash.
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=main_index\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=match_index1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=match_index2\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=chart_index\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=daod_index\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=highlight_index\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=DELETE&name=vq_index\""

  runSolrClientCommand "/opt/solr/server/scripts/cloud-scripts/zkcli.sh" -zkhost "${ZK_HOST}" -cmd clear "/collections/main_index/collectionprops.json"
  runSolrClientCommand "/opt/solr/server/scripts/cloud-scripts/zkcli.sh" -zkhost "${ZK_HOST}" -cmd clear "/collections/match_index1/collectionprops.json"
  runSolrClientCommand "/opt/solr/server/scripts/cloud-scripts/zkcli.sh" -zkhost "${ZK_HOST}" -cmd clear "/collections/chart_index/collectionprops.json"
}

function createSolrCollections() {
  print "Creating Solr collections"
  # The curl command uses the container's local environment variables to obtain the SOLR_ADMIN_DIGEST_USERNAME and SOLR_ADMIN_DIGEST_PASSWORD.
  # To stop the variables being evaluated in this script, the variables are escaped using backslashes (\) and surrounded in double quotes (").
  # Any double quotes in the curl command are also escaped by a leading backslash.
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=main_index&collection.configName=main_index&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=match_index1&collection.configName=match_index1&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=match_index2&collection.configName=match_index2&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=chart_index&collection.configName=chart_index&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=daod_index&collection.configName=daod_index&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=highlight_index&collection.configName=highlight_index&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=vq_index&collection.configName=vq_index&numShards=1&maxShardsPerNode=4&replicationFactor=1\""
}

function createDatabase() {
  printInfo "Removing existing database container"
  case "${DB_DIALECT}" in
  db2)
    deleteContainer "${DB2_SERVER_CONTAINER_NAME}"
    docker volume rm -f "${DB2_SERVER_VOLUME_NAME}" "${DB2_SERVER_BACKUP_VOLUME_NAME}"
    createFolder "${BACKUP_DIR}"
    initializeDb2Server
    ;;
  sqlserver)
    deleteContainer "${SQL_SERVER_CONTAINER_NAME}"
    docker volume rm -f "${SQL_SERVER_VOLUME_NAME}" "${SQL_SERVER_BACKUP_VOLUME_NAME}"
    createFolder "${BACKUP_DIR}"
    initializeSQLServer
    ;;
  esac
}

function restoreDatabase() {
  case "${DB_DIALECT}" in
  db2)
    printErrorAndExit "Not implemented yet"
    ;;
  sqlserver)
    restoreSQlServer
    ;;
  esac
}

function restoreSQlServer() {
  deploySecureSQLServer
  restoreIstoreDatabase
  recreateSQLServerUsers
}

function restoreIstoreDatabase() {
  if [[ -z "${BACKUP_NAME}" ]]; then
    print "No backup_name provided, using the 'default' name"
    BACKUP_NAME="default"
  fi

  updateVolume "${BACKUP_DIR}" "${SQL_SERVER_BACKUP_VOLUME_NAME}" "${DB_CONTAINER_BACKUP_DIR}"
  print "Restoring the ISTORE database"
  sql_query="\
    RESTORE DATABASE ISTORE FROM DISK = '${DB_CONTAINER_BACKUP_DIR}/${BACKUP_NAME}/${DB_BACKUP_FILE_NAME}';"
  runSQLServerCommandAsSA runSQLQuery "${sql_query}"
}

function recreateSQLServerUsers() {
  print "Dropping ISTORE users"
  sql_query="\
    USE ISTORE;
      DROP USER dba;
        DROP USER i2analyze;
          DROP USER i2etl;
            DROP USER etl;
              DROP USER dbb;"
  runSQLServerCommandAsSA runSQLQuery "${sql_query}"

  print "Creating database logins and users"
  createDbLoginAndUser "dbb" "db_backupoperator"
  createDbLoginAndUser "dba" "DBA_Role"
  createDbLoginAndUser "i2analyze" "i2Analyze_Role"
  createDbLoginAndUser "i2etl" "i2_ETL_Role"
  createDbLoginAndUser "etl" "External_ETL_Role"
  runSQLServerCommandAsSA "/opt/db-scripts/configureDbaRolesAndPermissions.sh"
  runSQLServerCommandAsSA "/opt/db-scripts/addEtlUserToSysAdminRole.sh"
}

function initializeDb2Server() {
  deploySecureDb2Server
  initializeIStoreDatabase
  configureIStoreDatabase
  docker exec "${DB2_SERVER_CONTAINER_NAME}" bash -c "su -p db2inst1 -c \". ${DB_LOCATION_DIR}/sqllib/db2profile && db2 UPDATE DB CFG FOR ${DB_NAME} USING extbl_location '${DB_LOCATION_DIR};/var/i2a-data'\""
}

function deploySecureDb2Server() {
  runDb2Server
  waitForDb2ServerToBeLive "true"
  changeDb2inst1Password
}

function initializeSQLServer() {
  deploySecureSQLServer
  initializeIStoreDatabase
  configureIStoreDatabase
}

function deploySecureSQLServer() {
  runSQLServer

  waitForSQLServerToBeLive "true"
  changeSAPassword
}

function initializeIStoreDatabaseForDb2Server() {
  runDb2ServerCommandAsDb2inst1 "/opt/databaseScripts/generated/runDatabaseCreationScripts.sh"

  print "Initializing ISTORE database tables"
  runDb2ServerCommandAsDb2inst1 "/opt/databaseScripts/generated/runStaticScripts.sh"
}

function initializeIStoreDatabaseForSQLServer() {
  runSQLServerCommandAsSA "/opt/databaseScripts/generated/runDatabaseCreationScripts.sh"

  printInfo "Creating database roles"
  runSQLServerCommandAsSA "/opt/db-scripts/createDbRoles.sh"

  printInfo "Creating database logins and users"
  createDbLoginAndUser "dbb" "db_backupoperator"
  createDbLoginAndUser "dba" "DBA_Role"
  createDbLoginAndUser "i2analyze" "i2Analyze_Role"
  createDbLoginAndUser "i2etl" "i2_ETL_Role"
  createDbLoginAndUser "etl" "External_ETL_Role"
  runSQLServerCommandAsSA "/opt/db-scripts/configureDbaRolesAndPermissions.sh"
  runSQLServerCommandAsSA "/opt/db-scripts/addEtlUserToSysAdminRole.sh"

  print "Initializing ISTORE database tables"
  runSQLServerCommandAsDBA "/opt/databaseScripts/generated/runStaticScripts.sh"
}

function initializeIStoreDatabase() {
  print "Initializing ISTORE database"
  printInfo "Generating ISTORE scripts"
  runi2AnalyzeTool "/opt/i2-tools/scripts/generateInfoStoreToolScripts.sh"
  runi2AnalyzeTool "/opt/i2-tools/scripts/generateStaticInfoStoreCreationScripts.sh"

  printInfo "Running ISTORE static scripts"
  case "${DB_DIALECT}" in
  db2)
    initializeIStoreDatabaseForDb2Server
    ;;
  sqlserver)
    initializeIStoreDatabaseForSQLServer
    ;;
  esac
}

function configureIStoreDatabase() {
  print "Configuring ISTORE database"
  runi2AnalyzeTool "/opt/i2-tools/scripts/generateDynamicInfoStoreCreationScripts.sh"
  case "${DB_DIALECT}" in
  db2)
    runDb2ServerCommandAsDb2inst1 "/opt/databaseScripts/generated/runDynamicScripts.sh"
    ;;
  sqlserver)
    runSQLServerCommandAsDBA "/opt/databaseScripts/generated/runDynamicScripts.sh"
    ;;
  esac
}

function deployLiberty() {
  print "Building Liberty Configured image"
  buildLibertyConfiguredImage
  print "Running Liberty container"
  runLiberty "${LIBERTY1_CONTAINER_NAME}" "${I2_ANALYZE_FQDN}" "${LIBERTY1_VOLUME_NAME}" "${LIBERTY1_SECRETS_VOLUME_NAME}" "${HOST_PORT_I2ANALYZE_SERVICE}" "${I2_ANALYZE_CERT_FOLDER_NAME}" "${LIBERTY1_DEBUG_PORT}"
}

function restartConnectorsForConfig() {
  local connector_references_file="${LOCAL_USER_CONFIG_DIR}/connector-references.json"

  readarray -t all_connector_ids < <(jq -r '.connectors[].name' <"${connector_references_file}")

  for connector_name in "${all_connector_ids[@]}"; do
    container_id=$(docker ps -a -q -f name="^${CONNECTOR_PREFIX}${connector_name}$" -f status=exited)
    if [[ -n ${container_id} ]]; then
      print "Restarting connector container"
      docker start "${CONNECTOR_PREFIX}${connector_name}"
    fi
    RELOAD_GATEWAY_REQUIRED="true"
  done
}

function startConnectorsForConfig() {
  local connector_references_file="${LOCAL_USER_CONFIG_DIR}/connector-references.json"

  readarray -t all_connector_ids < <(jq -r '.connectors[].name' <"${connector_references_file}")

  for connector_name in "${all_connector_ids[@]}"; do
    container_id=$(docker ps -a -q -f name="^${CONNECTOR_PREFIX}${connector_name}$" -f status=running)
    if [[ -z "${container_id}" ]]; then
      print "Starting connector container"
      deployConnector "${connector_name}"
    fi
    RELOAD_GATEWAY_REQUIRED="true"
  done
}

function createDeployment() {
  initializeDeployment

  if [[ "${STATE}" == "0" ]]; then
    # Cleaning up Docker resources
    removeAllContainersForTheConfig "${CONFIG_NAME}"
    removeDockerVolumes

    # Running Solr and ZooKeeper
    deployZKCluster
    configureZKForSolrCluster
    deploySolrCluster

    # Configuring Solr and ZooKeeper
    waitForSolrToBeLive "${SOLR1_FQDN}"
    configureSolrCollections
    createSolrCollections
    updateStateFile "1"
  fi

  buildConnectors
  startConnectorsForConfig

  if [[ "${STATE}" == "0" || "${STATE}" == "1" ]]; then
    # Deploying Prometheus
    deleteContainer "${PROMETHEUS_CONTAINER_NAME}"
    runPrometheus
    waitForPrometheusServerToBeLive

    # Deploying Grafana
    deleteContainer "${GRAFANA_CONTAINER_NAME}"
    runGrafana
    waitForGrafanaServerToBeLive

    # Configuring ISTORE
    if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
      if [[ "${TASK}" == "create" ]]; then
        createDatabase
      elif [[ "${TASK}" == "restore" ]]; then
        restoreDatabase
      else
        printErrorAndExit "Unknown task: ${TASK}"
      fi
    fi
    updateStateFile "2"
  fi

  buildExtensions

  if [[ "${STATE}" -lt 4 ]]; then
    # Configuring i2 Analyze
    if [[ "${STATE}" != "0" ]]; then
      print "Removing Liberty container"
      deleteContainer "${LIBERTY1_CONTAINER_NAME}"
    fi

    deployLiberty
    updateLog4jFile
    addConfigAdmin

    # Creating a copy of the configuration that was deployed originally
    printInfo "Initializing diff tool"
    deleteFolderIfExistsAndCreate "${PREVIOUS_CONFIGURATION_PATH}"
    updatePreviousConfigurationWithCurrent

    # Validate Configuration
    checkLibertyStatus
    if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
      updateMatchRules
    fi

    updateStateFile "4"
  fi

  print "Deployed Successfully"
  echo "This application is configured for access on ${FRONT_END_URI}"
}

###############################################################################
# Upgrade Helper Functions                                                    #
###############################################################################

function updateConfigVersion() {
  local version="$1"
  sed -i "s/^SUPPORTED_I2ANALYZE_VERSION=.*/SUPPORTED_I2ANALYZE_VERSION=${version}/g" \
    "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/version"
}

function upgrade() {
  waitForUserReply "The '${CONFIG_NAME}' config will be upgraded. You cannot revert the upgrade. Are you sure you want to continue?"

  initializeDeployment

  extra_args=()
  if [[ "${VERBOSE}" == "true" ]]; then
    extra_args+=("-v")
  fi

  "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/createChangeSet.sh" -e "${ENVIRONMENT}" -c "${CONFIG_NAME}" -t "upgrade" "${extra_args[@]}"

  updateConfigVersion "${CURRENT_SUPPORTED_I2ANALYZE_VERSION}"

  source "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/version"
  source "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/utils/variables.sh"
  source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/simulatedExternalVariables.sh"
  source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/commonVariables.sh"
  source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/internalHelperVariables.sh"

  # Delete old containers
  stopConfigDevContainers
  removeAllContainersForTheConfig "${CONFIG_NAME}"
  removeDockerVolumes

  # Required to fix text search
  # TODO: Look into what specifically is required  to repeat inside this function
  initializeDeployment

  # Running Solr and ZooKeeper
  deployZKCluster
  configureZKForSolrCluster
  deploySolrCluster

  # Configuring Solr and ZooKeeper
  waitForSolrToBeLive "${SOLR1_FQDN}"
  configureSolrCollections
  createSolrCollections
  updateStateFile "1"

  if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    BACKUP_NAME="global-upgrade"
    restoreDatabase
    upgradeDatabase
  fi

  runPrometheus
  waitForPrometheusServerToBeLive

  runGrafana
  waitForGrafanaServerToBeLive

  updateStateFile "2"

  upgradeConnectors

  # Upgrading extensions need to happen before liberty since they are baked into the image
  upgradeExtensions
  upgradeLiberty
  updateStateFile "4"

  print "Upgraded Successfully"
  echo "This application is configured for access on ${FRONT_END_URI}"
}

function upgradeDatabase() {
  print "Upgrading Database"

  case "${DB_DIALECT}" in
  db2)
    echo "DB2 is not supported"
    ;;
  sqlserver)
    runSQLServerCommandAsDBA "/opt/databaseScripts/generated/runDatabaseScripts.sh" "/opt/databaseScripts/generated/upgrade"
    ;;
  esac
}

function upgradeSolr() {
  print "Upgrading Solr"

  runSolrClientCommand solr zk upconfig -v -z "${ZK_HOST}" -n vq_index -d /opt/configuration/solr/generated_config/vq_index
  runSolrClientCommand bash -c "curl -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert ${CONTAINER_CERTS_DIR}/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CREATE&name=vq_index&collection.configName=vq_index&numShards=1&maxShardsPerNode=4&replicationFactor=2\""
}

function upgradeLiberty() {
  deployLiberty
  updateLog4jFile
  addConfigAdmin
  loginToLiberty
}

function upgradeExtensionPomXML() {
  local pom_path="$1"

  # Rename dependency 'guice-throwing-providers' to 'guice-throwingproviders'
  xmlstarlet edit -L \
    --update "/project/dependencies/dependency[artifactId='guice-throwing-providers']/artifactId" --value "guice-throwingproviders" \
    "${pom_path}"

  # Delete dependency icu4j
  xmlstarlet edit -L \
    --delete "/project/dependencies/dependency[artifactId='icu4j']" \
    "${pom_path}"

  # Delete dependency liberty-apis
  xmlstarlet edit -L \
    --delete "/project/dependencies/dependency[artifactId='liberty-apis']" \
    "${pom_path}"
}

function upgradeExtensions() {
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"

  print "Upgrading Extensions"

  readarray -t extension_names < <(jq -r '.extensions[].name' <"${extension_references_file}")
  for extension_name in "${extension_names[@]}"; do
    upgradeExtensionPomXML "${ANALYZE_CONTAINERS_ROOT_DIR}/i2a-extensions/${extension_name}/pom.xml"
    deleteFileIfExists "${PREVIOUS_EXTENSIONS_DIR}/${extension_name}.sha512"
  done

  buildExtensions
}

function upgradeConnectors() {
  print "Upgrading Connectors"

  # Override Dockerfile with latest template
  for connector_path in "${CONNECTOR_IMAGES_DIR}"/*; do
    if [[ -d "${connector_path}" ]]; then
      connector_type=$(jq -r '.type' <"${connector_path}/connector-definition.json")

      # Upgrade Dockerfile
      if [[ "${connector_type}" == "${I2CONNECT_SERVER_CONNECTOR_TYPE}" ]]; then
        cp "${ANALYZE_CONTAINERS_ROOT_DIR}/templates/i2connect-server-connector-image/Dockerfile" "${connector_path}/Dockerfile"
      elif grep -q "FROM adoptopenjdk/openjdk" "${connector_path}/Dockerfile"; then
        cp "${ANALYZE_CONTAINERS_ROOT_DIR}/templates/springboot-connector-image/Dockerfile" "${connector_path}/Dockerfile"
      elif grep -q "FROM registry.access.redhat.com/ubi8/nodejs" "${connector_path}/Dockerfile"; then
        cp "${ANALYZE_CONTAINERS_ROOT_DIR}/templates/node-connector-image/Dockerfile" "${connector_path}/Dockerfile"
      fi
    fi
  done
  buildConnectors
  startConnectorsForConfig
}

###############################################################################
# Update Helper Functions                                                     #
###############################################################################

function notifyUpdateServerConfiguration() {
  printInfo "Updating server configuration on i2 Analyze Application"
  if curl \
    -L --max-redirs 5 -w "%{http_code}" \
    -s -o "/tmp/response.txt" \
    --cacert "${LOCAL_EXTERNAL_CA_CERT_DIR}/CA.cer" \
    --cookie /tmp/cookie.txt \
    --header 'Content-Type: application/json' \
    --data-raw "{\"params\":[{\"value\" : [\"\"],\"type\" : {\"className\":\"java.util.ArrayList\",\"items\":[\"java.lang.String\"]}},{\"value\" : [\"/opt/ibm/wlp/usr/shared/config/user.registry.xml\", \"/opt/ibm/wlp/usr/servers/defaultServer/server.extensions.dev.xml\", \"/opt/ibm/wlp/usr/servers/defaultServer/server.extensions.xml\"],\"type\" : {\"className\":\"java.util.ArrayList\",\"items\":[\"java.lang.String\",\"java.lang.String\",\"java.lang.String\"]}},{\"value\" : [\"\"],\"type\" : {\"className\":\"java.util.ArrayList\",\"items\":[\"java.lang.String\"]}}],\"signature\":[\"java.util.Collection\",\"java.util.Collection\",\"java.util.Collection\"]}" \
    --request POST "${BASE_URI}/IBMJMXConnectorREST/mbeans/WebSphere%3Aservice%3Dcom.ibm.ws.kernel.filemonitor.FileNotificationMBean/operations/notifyFileChanges" \
    >/tmp/http_code.txt; then
    # Invoking FileNotificationMBean doc: https://www.ibm.com/docs/en/zosconnect/3.0?topic=demand-invoking-filenotificationmbean-from-rest-api
    http_code=$(cat /tmp/http_code.txt)
    if [[ "${http_code}" != 200 ]]; then
      printErrorAndExit "Problem updating server configuration application. Returned:${http_code}"
    else
      printInfo "Response from i2 Analyze Web UI:$(cat /tmp/response.txt)"
    fi
  else
    printErrorAndExit "Problem calling curl:$(cat /tmp/http_code.txt)"
  fi
  checkLibertyStatus
}

function updateLiveConfiguration() {
  local errors_message="Validation errors detected, please review the above message(s)."

  if [[ " ${filesChangedArray[*]} " == *" user.registry.xml "* || " ${filesChangedArray[*]} " == *" server.extensions.xml "* || " ${filesChangedArray[*]} " == *" server.extensions.dev.xml "* ]]; then
    notifyUpdateServerConfiguration
  fi

  print "Calling reload endpoint"
  if curl \
    -L --max-redirs 5 \
    -s -o /tmp/response.txt -w "%{http_code}" \
    --cookie /tmp/cookie.txt \
    --cacert "${LOCAL_EXTERNAL_CA_CERT_DIR}/CA.cer" \
    --header "Origin: ${FRONT_END_URI}" \
    --header 'Content-Type: application/json' \
    --request POST "${FRONT_END_URI}/api/v1/admin/config/reload" >/tmp/http_code.txt; then
    http_code=$(cat /tmp/http_code.txt)
    if [[ "${http_code}" != "200" ]]; then
      jq '.errorMessage' /tmp/response.txt
      printErrorAndExit "${errors_message}"
    else
      echo "No Validation errors detected."
    fi
  else
    printErrorAndExit "Problem calling reload endpoint"
  fi
}

function callGatewayReload() {
  local errors_message="Validation errors detected, please review the above message(s)."

  if [[ "${RELOAD_GATEWAY_REQUIRED}" == "true" ]]; then
    print "Calling gateway reload endpoint"
    loginToLiberty

    if curl \
      -L --max-redirs 5 \
      -s -o /tmp/response.txt -w "%{http_code}" \
      --cookie /tmp/cookie.txt \
      --cacert "${LOCAL_EXTERNAL_CA_CERT_DIR}/CA.cer" \
      --header "Origin: ${FRONT_END_URI}" \
      --header 'Content-Type: application/json' \
      --request POST "${FRONT_END_URI}/api/v1/gateway/reload" >/tmp/http_code.txt; then
      http_code=$(cat /tmp/http_code.txt)
      if [[ "${http_code}" != "200" ]]; then
        jq '.errorMessage' /tmp/response.txt
        printErrorAndExit "${errors_message}"
      else
        echo "No Validation errors detected."
      fi
    else
      printErrorAndExit "Problem calling gateway reload endpoint"
    fi
  fi
}

function loginToLiberty() {
  local MAX_TRIES=30
  local app_admin_password

  app_admin_password=$(getApplicationAdminPassword)

  printInfo "Getting Auth cookie"
  for i in $(seq 1 "${MAX_TRIES}"); do
    # Don't follow redirects on this curl command since we expect login as 302 (redirect status code)
    if curl \
      -s -o /tmp/response.txt -w "%{http_code}" \
      --cookie-jar /tmp/cookie.txt \
      --cacert "${LOCAL_EXTERNAL_CA_CERT_DIR}/CA.cer" \
      --request POST "${BASE_URI}/IBMJMXConnectorREST/j_security_check" \
      --header "Origin: ${BASE_URI}" \
      --header 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "j_username=${I2_ANALYZE_ADMIN}" \
      --data-urlencode "j_password=${app_admin_password}" >/tmp/http_code.txt; then
      http_code=$(cat /tmp/http_code.txt)
      if [[ "${http_code}" == "302" ]]; then
        echo "Logged in to Liberty server" && return 0
      else
        printInfo "Failed login with status code:${http_code}"
      fi
    fi
    echo "Liberty is NOT live (attempt: $i). Waiting..."
    sleep 5
  done
  printInfo "Liberty won't start- resetting"
  updateStateFile "2"
  printErrorAndExit "Could not authenticate with Liberty- please try again"
}

function controlApplication() {
  local operation="$1"
  printInfo "Running '${operation}' on i2 Analyze Application"
  if curl \
    -L --max-redirs 5 \
    -s -o "/tmp/response.txt" -w "%{http_code}" \
    --cacert "${LOCAL_EXTERNAL_CA_CERT_DIR}/CA.cer" \
    --cookie /tmp/cookie.txt \
    --header 'Content-Type: application/json' \
    --data-raw '{}' \
    --request POST "${BASE_URI}/IBMJMXConnectorREST/mbeans/WebSphere%3Aname%3Dopal-services%2Cservice%3Dcom.ibm.websphere.application.ApplicationMBean/operations/${operation}" \
    >/tmp/http_code.txt; then
    http_code=$(cat /tmp/http_code.txt)
    if [[ "${http_code}" != 200 ]]; then
      printErrorAndExit "Problem restarting application. Returned:${http_code}"
    else
      printInfo "Response from i2 Analyze Web UI:$(cat /tmp/response.txt)"
    fi
  else
    printErrorAndExit "Problem calling curl:$(cat /tmp/http_code.txt)"
  fi
}

function restartApplication() {
  controlApplication restart
}

function stopApplication() {
  controlApplication stop
}

function startApplication() {
  controlApplication start
}

function restartServer() {
  # We can't use /opt/ibm/wlp/bin/server stop defaultServer because the container process will stop
  # which will stop the container
  docker restart "${LIBERTY1_CONTAINER_NAME}"
}

function copyLocalConfigToTheLibertyContainer() {
  local liberty_server_path="liberty/wlp/usr/servers/defaultServer"
  local liberty_app_war_path="${liberty_server_path}/apps/opal-services.war"
  printInfo "Copying configuration to the Liberty container (${LIBERTY1_CONTAINER_NAME})"

  # All other configuration is copied to the application WEB-INF/classes directory.
  local tmp_classes_dir="${ANALYZE_CONTAINERS_ROOT_DIR}/tmp_classes"
  createFolder "${tmp_classes_dir}"
  find "${GENERATED_LOCAL_CONFIG_DIR}" -maxdepth 1 -type f ! -name privacyagreement.html ! -name user.registry.xml ! -name extension-references.json ! -name connector-references.json ! -name '*.xsd' ! -name server.extensions.xml ! -name server.extensions.dev.xml -exec cp -t "${tmp_classes_dir}" {} \;

  # In the schema_dev deployment point Gateway schemes to the ISTORE schemes
  if [[ "${DEPLOYMENT_PATTERN}" == "schema_dev" ]]; then
    sed -i 's/^SchemaResource=/Gateway.External.SchemaResource=/' "${tmp_classes_dir}/ApolloServerSettingsMandatory.properties"
    sed -i 's/^ChartingSchemesResource=/Gateway.External.ChartingSchemesResource=/' "${tmp_classes_dir}/ApolloServerSettingsMandatory.properties"
  fi

  docker cp "${tmp_classes_dir}/." "${LIBERTY1_CONTAINER_NAME}:${liberty_app_war_path}/WEB-INF/classes"
  if [[ -f "${GENERATED_LOCAL_CONFIG_DIR}/server.extensions.xml" ]]; then
    docker cp "${GENERATED_LOCAL_CONFIG_DIR}/server.extensions.xml" "${LIBERTY1_CONTAINER_NAME}:${liberty_server_path}"
  fi
  if [[ -f "${GENERATED_LOCAL_CONFIG_DIR}/server.extensions.dev.xml" ]]; then
    docker cp "${GENERATED_LOCAL_CONFIG_DIR}/server.extensions.dev.xml" "${LIBERTY1_CONTAINER_NAME}:${liberty_server_path}"
  fi
  rm -rf "${tmp_classes_dir}"

  docker cp "${GENERATED_LOCAL_CONFIG_DIR}/privacyagreement.html" "${LIBERTY1_CONTAINER_NAME}:${liberty_app_war_path}/privacyagreement.html"
  updateLog4jFile
  addConfigAdmin

  connector_url_map_new=$(cat "${CONNECTOR_IMAGES_DIR}"/connector-url-mappings-file.json)

  docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c "export CONNECTOR_URL_MAP='${connector_url_map_new}'; \
    rm /opt/ibm/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/classes/connectors.json; \
    rm /opt/ibm/wlp/usr/servers/defaultServer/apps/opal-services.war/already_run; \
    /opt/entrypoint.d/create-connector-config.sh"
}

function updatePreviousPrometheusConfigurationWithCurrent() {
  printInfo "Copying Prometheus configuration from (${CURRENT_CONFIGURATION_PATH}) to (${PREVIOUS_CONFIGURATION_PATH})"
  cp -pR "${CURRENT_CONFIGURATION_PATH}/prometheus"/* "${PREVIOUS_CONFIGURATION_PATH}/prometheus"
}

function updatePreviousGrafanaConfigurationWithCurrent() {
  printInfo "Copying Grafana configuration from (${CURRENT_CONFIGURATION_PATH}) to (${PREVIOUS_CONFIGURATION_PATH})"
  cp -pR "${CURRENT_CONFIGURATION_PATH}/grafana/dashboards/"* "${PREVIOUS_CONFIGURATION_PATH}/grafana/dashboards"
}

function updatePreviousConfigurationWithCurrent() {
  printInfo "Copying configuration from (${CURRENT_CONFIGURATION_PATH}) to (${PREVIOUS_CONFIGURATION_PATH})"
  cp -pR "${CURRENT_CONFIGURATION_PATH}"/* "${PREVIOUS_CONFIGURATION_PATH}"
  createFolder "${PREVIOUS_CONFIGURATION_UTILS_PATH}"
  cp -p "${CURRENT_CONFIGURATION_UTILS_PATH}/variables.sh" "${PREVIOUS_CONFIGURATION_UTILS_PATH}/variables.sh"
}

function updateMatchRules() {
  print "Updating system match rules"

  printInfo "Uploading system match rules"
  runi2AnalyzeTool "/opt/i2-tools/scripts/runIndexCommand.sh" update_match_rules

  printInfo "Waiting for the standby match index to complete indexing"
  local stand_by_match_index_ready_file_path="/logs/StandbyMatchIndexReady"
  while docker exec "${LIBERTY1_CONTAINER_NAME}" test ! -f "${stand_by_match_index_ready_file_path}"; do
    printInfo "waiting..."
    sleep 3
  done

  print "Switching standby match index to live"
  runi2AnalyzeTool "/opt/i2-tools/scripts/runIndexCommand.sh" switch_standby_match_index_to_live

  printInfo "Removing StandbyMatchIndexReady file from the liberty container"
  docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c "rm ${stand_by_match_index_ready_file_path} > /dev/null 2>&1"
}

function rebuildDatabase() {
  waitForUserReply "Do you wish to rebuild the ISTORE database? This will permanently remove data from the deployment."
  case "${DB_DIALECT}" in
  db2)
    printInfo "Removing existing Db2 Server container"
    deleteContainer "${DB2_SERVER_CONTAINER_NAME}"
    docker volume rm -f "${DB2_SERVER_VOLUME_NAME}" "${DB2_SERVER_BACKUP_VOLUME_NAME}"
    initializeDb2Server
    ;;
  sqlserver)
    printInfo "Removing existing SQL Server container"
    deleteContainer "${SQL_SERVER_CONTAINER_NAME}"
    docker volume rm -f "${SQL_SERVER_VOLUME_NAME}" "${SQL_SERVER_BACKUP_VOLUME_NAME}"
    initializeSQLServer
    ;;
  esac
}

function updateSchema() {
  local errors_message="Validation errors detected, please review the above message(s)"

  if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    print "Updating the deployed schema"

    printInfo "Stopping Liberty container"
    stopApplication

    "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/createChangeSet.sh" -c "${CONFIG_NAME}" -t "update"

    if ! runi2AnalyzeTool "/opt/i2-tools/scripts/validateSchemaAndSecuritySchema.sh" >'/tmp/result_validate_security_schema'; then
      startApplication
      if grep -q 'ERROR: The new Schema file is not valid, see the summary for more details.' '/tmp/result_validate_security_schema'; then
        destructiveSchemaOrSecuritySchemaChange
      else
        echo "Response from i2 Analyze Tool: $(cat '/tmp/result_validate_security_schema')"
        printErrorAndExit "${errors_message}"
      fi
    elif [ -d "${LOCAL_GENERATED_DIR}/update" ]; then
      if [ "$(ls -A "${LOCAL_GENERATED_DIR}/update")" ]; then
        print "Running the generated scripts"
        case "${DB_DIALECT}" in
        db2)
          runDb2ServerCommandAsDb2inst1 "/opt/databaseScripts/generated/runDatabaseScripts.sh" "/opt/databaseScripts/generated/update"
          ;;
        sqlserver)
          runSQLServerCommandAsDBA "/opt/databaseScripts/generated/runDatabaseScripts.sh" "/opt/databaseScripts/generated/update"
          ;;
        esac
      else
        print "No files present in update schema scripts folder"
      fi
    else
      print "Update schema scripts folder doesn't exist"
    fi
  fi
}

function updateSecuritySchema() {
  local result_update_security_schema
  local result_update_security_schema_exitcode
  local errors_message="Validation errors detected, please review the above message(s)"

  if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    print "Updating the deployed security schema"

    printInfo "Stopping Liberty application"
    stopApplication

    printInfo "Updating security schema"
    if ! runi2AnalyzeTool "/opt/i2-tools/scripts/updateSecuritySchema.sh" >'/tmp/result_update_security_schema'; then
      startApplication
      echo "[INFO] Response from i2 Analyze Tool: $(cat '/tmp/result_update_security_schema')"
      # check i2 Analyze Tool for output indicating a Security Schema change has occurred, if so then prompt user for destructive
      # rebuild of ISTORE database.
      if grep -q 'ILLEGAL STATE: The new security schema has incompatible differences with the existing one' '/tmp/result_update_security_schema'; then
        echo "[WARN] Destructive Security Schema change(s) detected"
        destructiveSchemaOrSecuritySchemaChange
        echo "[INFO] Destructive Security Schema change(s) complete"
      else
        printErrorAndExit "${errors_message}"
      fi
    fi
  fi
}

function destructiveSchemaOrSecuritySchemaChange() {
  rebuildDatabase
  deleteSolrCollections
  createSolrCollections
}

function updateDataSourceIdFile() {
  local tmp_dir="/tmp"
  createDataSourceProperties "${tmp_dir}"

  docker cp "${tmp_dir}/DataSource.properties" "${LIBERTY1_CONTAINER_NAME}:liberty/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/classes"
}

function handleConfigurationChange() {
  compareCurrentConfiguration
  compareCurrentExtensions

  if [[ "${configFinalActionCode}" == "0" ]]; then
    printInfo "No updates to the configuration"
    return
  fi

  # Make sure update will be re-run if anything fails
  updateStateFile "3"
  for fileName in "${filesChangedArray[@]}"; do
    if [[ "${fileName}" == "system-match-rules.xml" ]]; then
      if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
        updateMatchRules
      fi
    elif [[ "${fileName}" == "schema.xml" ]]; then
      updateSchema
    elif [[ "${fileName}" == "security-schema.xml" ]]; then
      updateSecuritySchema
    elif [[ "${fileName}" == "user.registry.xml" ]]; then
      addConfigAdminToUserRegistry
    elif [[ "${fileName}" == "environment/dsid/dsid.properties" ]]; then
      updateDataSourceIdFile
      if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
        destructiveSchemaOrSecuritySchemaChange
      fi
    elif [[ "${fileName}" == "extension-references.json" || "${fileName}" = lib/*.sha512 ]]; then
      handleExtensionChange
    fi
  done

  if [[ "${configFinalActionCode}" == "3" ]] && [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    printInfo "Starting i2 Analyze application"
    startApplication

    printInfo "Validating database consistency"
    runi2AnalyzeTool "/opt/i2-tools/scripts/dbConsistencyCheckScript.sh"
  fi

  copyLocalConfigToTheLibertyContainer
  case "${configFinalActionCode}" in
  "1")
    updateLiveConfiguration
    ;;
  "2") ;&
    # Fallthrough
  "3")
    printInfo "Restarting i2 Analyze application"
    clearLibertyValidationLog
    restartApplication
    checkLibertyStatus

    if [[ " ${filesChangedArray[*]} " == *" user.registry.xml "* || " ${filesChangedArray[*]} " == *" server.extensions.xml "* || " ${filesChangedArray[*]} " == *" server.extensions.dev.xml "* ]]; then
      notifyUpdateServerConfiguration
    fi
    ;;
  "4")
    printInfo "Restarting server"
    clearLibertyValidationLog
    restartServer
    checkLibertyStatus
    ;;
  esac
  updatePreviousConfigurationWithCurrent
}

function handleDeploymentPatternChange() {
  printInfo "Checking if DEPLOYMENT_PATTERN changed"

  if [[ "${CURRENT_DEPLOYMENT_PATTERN}" != "${PREVIOUS_DEPLOYMENT_PATTERN}" ]]; then
    print "DEPLOYMENT_PATTERN is changed"
    echo "Previous DEPLOYMENT_PATTERN: ${PREVIOUS_DEPLOYMENT_PATTERN}"
    echo "New DEPLOYMENT_PATTERN: ${CURRENT_DEPLOYMENT_PATTERN}"

    print "Removing Liberty container"
    deleteContainer "${LIBERTY1_CONTAINER_NAME}"
    deployLiberty
    updateLog4jFile
    addConfigAdmin
    loginToLiberty

    if [[ "${PREVIOUS_DEPLOYMENT_PATTERN}" == *"store"* ]] && [[ "${CURRENT_DEPLOYMENT_PATTERN}" != *"store"* ]]; then
      print "Stopping SQL Server container"
      docker stop "${SQL_SERVER_CONTAINER_NAME}"
    fi

    if [[ "${CURRENT_DEPLOYMENT_PATTERN}" == *"store"* ]] && [[ "${PREVIOUS_DEPLOYMENT_PATTERN}" != *"store"* ]]; then
      sql_server_container_status="$(docker ps -a --format "{{.Status}}" -f network="${DOMAIN_NAME}" -f name="^${SQL_SERVER_CONTAINER_NAME}$")"
      if [[ "${sql_server_container_status%% *}" == "Up" ]]; then
        print "SQl Server container is already running"
        updateSchema
      elif [[ "${sql_server_container_status%% *}" == "Exited" ]]; then
        print "Starting SQL Server container"
        docker start "${SQL_SERVER_CONTAINER_NAME}"
        waitForSQLServerToBeLive
        updateSchema
      else
        print "Removing SQL Server volumes"
        docker volume rm -f "${SQL_SERVER_VOLUME_NAME}" "${SQL_SERVER_BACKUP_VOLUME_NAME}"

        updateStateFile "1"
        initializeSQLServer

        updateStateFile "2"
      fi
    fi
    stopApplication
    clearLibertyValidationLog
    startApplication
    checkLibertyStatus
  else
    printInfo "DEPLOYMENT_PATTERN is unchanged: ${CURRENT_DEPLOYMENT_PATTERN}"
  fi
}

function handleExtensionChange() {
  local jars_liberty_path="liberty/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/lib"
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"
  local old_extension_references_file="${PREVIOUS_CONFIGURATION_PATH}/extension-references.json"
  local extension_dependencies_path="${EXTENSIONS_DIR}/extension-dependencies.json"
  local extension_files old_extension_files deleted_extensions
  local filename

  print "Updating i2Analyze extensions"
  # Remove extensions that were deleted from extension-references.json
  if [[ -d "${PREVIOUS_CONFIGURATION_PATH}" ]]; then
    readarray -t extension_files < <(jq -r '.extensions[] | .name' <"${extension_references_file}")
    readarray -t old_extension_files < <(jq -r '.extensions[] | .name' <"${old_extension_references_file}")
    # Compute deleted extensions
    IFS=' ' read -r -a deleted_extensions <<<"$(subtractArrayFromArray extension_files old_extension_files)"
    # Compute deleted extension dependencies
    for extension_name in "${deleted_extensions[@]}"; do
      IFS=' ' read -ra dependencies <<<"$(jq -r --arg name "${extension_name}" '.[] | select(.name == $name) | .dependencies[]' "${extension_dependencies_path}" | xargs)"
      for dependency in "${dependencies[@]}"; do
        # shellcheck disable=SC2076
        if [[ ! " ${deleted_extensions[*]} " =~ " ${dependency} " ]]; then
          deleted_extensions+=("${dependencies[@]}")
        fi
      done
    done
    for extension_name in "${deleted_extensions[@]}"; do
      printInfo "Delete old library ${jars_liberty_path}/${extension_name}"
      extension_version="$(xmlstarlet sel -t -v "/project/version" "${EXTENSIONS_DIR}/${extension_name}/pom.xml")"
      docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c "rm ${jars_liberty_path}/${extension_name}-${extension_version}.jar > /dev/null" || true
    done
  fi

  # Update extensions
  deleteFolderIfExistsAndCreate "${PREVIOUS_CONFIGURATION_LIB_PATH}"
  readarray -t extension_files < <(jq -r '.extensions[] | .name' <"${extension_references_file}")
  for extension in "${extension_files[@]}"; do
    IFS=' ' read -ra dependencies <<<"$(jq -r --arg name "${extension}" '.[] | select(.name == $name) | .dependencies[]' "${extension_dependencies_path}" | xargs)"
    for dependency in "${dependencies[@]}"; do
      # shellcheck disable=SC2076
      if [[ ! " ${extension_files[*]} " =~ " ${dependency} " ]]; then
        extension_files+=("${dependencies[@]}")
      fi
    done
  done
  for extension_name in "${extension_files[@]}"; do
    # Save current sha in the previous config
    cp -pr "${PREVIOUS_EXTENSIONS_DIR}/${extension_name}.sha512" "${PREVIOUS_CONFIGURATION_LIB_PATH}"
    extension_version="$(xmlstarlet sel -t -v "/project/version" "${EXTENSIONS_DIR}/${extension_name}/pom.xml")"
    # Copy extension to the liberty container
    docker cp "${EXTENSIONS_DIR}/${extension_name}/target/${extension_name}-${extension_version}.jar" "${LIBERTY1_CONTAINER_NAME}:${jars_liberty_path}"
  done
}

function handlePrometheusConfigurationChange() {
  local prometheus_tmp_config_dir="/tmp/prometheus"
  local prometheus_template_file="prometheus.yml"
  local prometheus_config_file="${LOCAL_USER_CONFIG_DIR}/prometheus/${prometheus_template_file}"
  local prometheus_password
  local reload_status_code
  compareCurrentPrometheusConfig

  if [[ "${PROMETHEUS_ACTION_CODE}" != "0" ]]; then
    print "Updating prometheus configuration"
    printInfo "Copy current Prometheus configuration to Prometheus container"
    updateVolume "${LOCAL_PROMETHEUS_CONFIG_DIR}" "${PROMETHEUS_CONFIG_VOLUME_NAME}" "${prometheus_tmp_config_dir}"
    docker exec "${PROMETHEUS_CONTAINER_NAME}" bash -c "/opt/update-prometheus-config.sh"
    updatePreviousPrometheusConfigurationWithCurrent
    prometheus_password=$(getPrometheusAdminPassword)
    reload_status_code=$(runi2AnalyzeToolAsExternalUser bash -c "curl --write-out \"%{http_code}\" --silent --output /dev/null \
      -X POST -u ${PROMETHEUS_USERNAME}:${prometheus_password} \
      --cacert /tmp/i2acerts/CA.cer https://${PROMETHEUS_FQDN}:9090/-/reload")
    if [[ "${reload_status_code}" == "200" ]]; then
      echo "Prometheus configuration is updated successfully"
    else
      printErrorAndExit "Prometheus configuration is NOT updated successfully. Unexpected status code: ${reload_status_code}"
    fi
  else
    printInfo "No updates to the prometheus configuration"
  fi
}

function handleGrafanaDashboardsChange() {
  compareCurrentGrafanaDashboards

  if [[ "${GRAFANA_ACTION_CODE}" != "0" ]]; then
    print "Updating grafana dashboards"
    printInfo "Copy current Grafana dashboards to Grafana container"
    exit_code="$(updateGrafanaDashboardVolume)"
    updatePreviousGrafanaConfigurationWithCurrent
    if [[ "${exit_code}" -eq 0 ]]; then
      echo "Grafana dashboards updated successfully"
    else
      printErrorAndExit "Grafana dashboards NOT updated successfully. Unexpected status code: ${exit_code}"
    fi
  else
    printInfo "No updates to the grafana configuration"
  fi
}

function handleConnectorsChange() {
  buildConnectors
  startConnectorsForConfig
}

function updateDeployment() {
  initializeDeployment

  # Login to Liberty
  loginToLiberty

  # Handling DEPLOYMENT_PATTERN Change
  handleDeploymentPatternChange

  updateStateFile "3"

  buildExtensions

  # Handling Prometheus Configuration Change
  handlePrometheusConfigurationChange

  # Handling Grafana Configuration Change
  handleGrafanaDashboardsChange

  # Handling Connectors Change
  handleConnectorsChange

  # Handling Configuration Change
  handleConfigurationChange

  updateStateFile "4"

  # Update configuration
  updatePreviousConfigurationWithCurrent

  print "Updated Successfully"
  echo "This application is configured for access on ${FRONT_END_URI}"
}

###############################################################################
# Backup Helper Functions                                                     #
###############################################################################

function moveBackupIfExist() {
  print "Checking backup does NOT exist"
  local backup_file_path="${BACKUP_DIR}/${BACKUP_NAME}/${DB_BACKUP_FILE_NAME}"
  if [[ -f "${backup_file_path}" ]]; then
    local old_backup_file_path="${backup_file_path}.bak"
    if [[ "${BACKUP_NAME}" != "default" ]]; then
      waitForUserReply "Backup already exist, are you sure you want to overwrite it?"
    fi
    echo "Backup ${backup_file_path} already exists, moving it to ${old_backup_file_path}"
    mv "${backup_file_path}" "${old_backup_file_path}"
  fi
}

function createBackup() {
  initializeDeployment

  if [[ "${DB_DIALECT}" == "db2" ]]; then
    printErrorAndExit "Not implemented yet"
  fi
  waitForLibertyToBeLive

  # Check for backup file
  if [[ -z "${BACKUP_NAME}" ]]; then
    print "No backup_name provided, using the 'default' name"
    BACKUP_NAME="default"
  fi

  moveBackupIfExist

  createFolder "${BACKUP_DIR}/${BACKUP_NAME}"

  # Create the back up
  print "Backing up the ISTORE database"
  local backup_file_path="${DB_CONTAINER_BACKUP_DIR}/${BACKUP_NAME}/${DB_BACKUP_FILE_NAME}"
  local sql_query="\
    USE ISTORE;
      BACKUP DATABASE ISTORE
      TO DISK = '${backup_file_path}'
      WITH FORMAT;"
  runSQLServerCommandAsDBB runSQLQuery "${sql_query}"

  getVolume "${BACKUP_DIR}" "${SQL_SERVER_BACKUP_VOLUME_NAME}" "${DB_CONTAINER_BACKUP_DIR}"
}

function restoreFromBackup() {
  initializeDeployment

  if [[ -z "${BACKUP_NAME}" ]]; then
    print "No backup_name provided, using the 'default' name"
    BACKUP_NAME="default"
  fi

  # Validate the backup exists and is not zero bytes before continuing.
  if [[ ! -d "${BACKUP_DIR}/${BACKUP_NAME}" ]]; then
    printErrorAndExit "Backup directory ${BACKUP_DIR}/${BACKUP_NAME} does NOT exist"
  fi
  if [[ ! -f "${BACKUP_DIR}/${BACKUP_NAME}/ISTORE.bak" || ! -s "${BACKUP_DIR}/${BACKUP_NAME}/ISTORE.bak" ]]; then
    printErrorAndExit "Backup file ${BACKUP_DIR}/${BACKUP_NAME}/ISTORE.bak does NOT exist or is empty."
  fi

  waitForUserReply "Are you sure you want to run the 'restore' task? This will permanently remove data from the deployment and restore to the specified backup."
  updateStateFile "0"
  STATE="0"
  createDeployment
}

###############################################################################
# Clean Helper Functions                                                      #
###############################################################################

function cleanDeployment() {
  waitForUserReply "Are you sure you want to run the 'clean' task? This will permanently remove data from the deployment."

  local all_container_ids
  IFS=' ' read -ra all_container_ids <<<"$(docker ps -aq -f network="${DOMAIN_NAME}" -f name=".${CONFIG_NAME}_${CONTAINER_VERSION_SUFFIX}$" | xargs)"
  print "Deleting all containers for ${CONFIG_NAME} deployment"
  for container_id in "${all_container_ids[@]}"; do
    printInfo "Deleting container ${container_id}"
    deleteContainer "${container_id}"
  done

  removeDockerVolumes

  printInfo "Deleting previous configuration folder: ${PREVIOUS_CONFIGURATION_DIR}"
  deleteFolderIfExists "${PREVIOUS_CONFIGURATION_DIR}"
}

###############################################################################
# Connector Helper Functions                                                  #
###############################################################################

function buildConnectors() {
  local connector_references_file="${LOCAL_USER_CONFIG_DIR}/connector-references.json"
  local connector_args=()

  if [[ "${YES_FLAG}" == "true" ]]; then
    connector_args+=(-y)
  fi
  if [[ "${VERBOSE}" == "true" ]]; then
    connector_args+=(-v)
  fi

  readarray -t all_connector_names < <(jq -r '.connectors[].name' <"${connector_references_file}")

  if [[ "${#all_connector_names}" -gt 0 ]]; then
    print "Building connector images"

    # Only attempt to rebuild connectors for the current config
    for connector_name in "${all_connector_names[@]}"; do
      connector_args+=("-i" "${connector_name}")
    done

    print "Running generateSecrets.sh"
    "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/generateSecrets.sh" -c connectors "${connector_args[@]}"
    print "Running buildConnectorImages.sh"
    "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/buildConnectorImages.sh" "${connector_args[@]}"
  fi
}

###############################################################################
# Deploy Helper Functions                                                     #
###############################################################################

function initializeDeployment() {
  printInfo "Initializing deployment"

  # Validate Configuration
  validateMandatoryFilesPresent

  # Auto generate dsid into config folder before we create the generated one
  createDataSourceId

  generateArtifacts

  # Add files that could be missing
  readarray -d '' fileList < <(find "${LOCAL_CONFIGURATION_DIR}" -type f -print0)
  for file in "${fileList[@]}"; do
    filename="${file//"${LOCAL_CONFIGURATION_DIR}/"/}"
    if [[ ! -f "${LOCAL_USER_CONFIG_DIR}/${filename}" ]]; then
      cp "${file}" "${LOCAL_USER_CONFIG_DIR}/${filename}"
    fi
  done

  addConfigAdminToSecuritySchema
  createMountedConfigStructure

  if [[ ! -f "${PREVIOUS_STATE_FILE_PATH}" ]]; then
    createInitialStateFile
  fi
}

function validateMandatoryFilesPresent() {
  local mandatory_files=(
    "schema.xml"
    "schema-charting-schemes.xml"
    "security-schema.xml"
    "schema-results-configuration.xml"
    "command-access-control.xml"
    "schema-source-reference-schema.xml"
    "schema-vq-configuration.xml"
  )

  for mandatory_file in "${mandatory_files[@]}"; do
    if [[ ! -f "${LOCAL_USER_CONFIG_DIR}/${mandatory_file}" ]]; then
      printErrorAndExit "Mandatory file ${mandatory_file} missing from ${LOCAL_USER_CONFIG_DIR}, correct this problem then run deploy.sh again."
    fi
  done

  for xml_file in "${LOCAL_USER_CONFIG_DIR}"/*.xml; do
    if [[ $(head "${xml_file}") == *"<!-- Replace this"* ]]; then
      file_name=$(basename "$xml_file")
      printErrorAndExit "Placeholder text found in ${LOCAL_USER_CONFIG_DIR}/${file_name}, check file contents then run deploy.sh again."
    fi
  done
}

function createInitialStateFile() {
  local template_state_file_path="${ANALYZE_CONTAINERS_ROOT_DIR}/utils/templates/.state.sh"
  printInfo "Creating initial ${PREVIOUS_STATE_FILE_PATH} file"
  createFolder "${PREVIOUS_CONFIGURATION_DIR}"
  cp -p "${template_state_file_path}" "${PREVIOUS_STATE_FILE_PATH}"
  STATE="0"
}

function workOutTaskToRun() {
  if [[ -f "${PREVIOUS_STATE_FILE_PATH}" ]]; then
    source "${PREVIOUS_STATE_FILE_PATH}"
  else
    STATE=0
  fi
  printInfo "STATE: ${STATE}"

  if [[ "${STATE}" == "0" ]]; then
    print "Creating initial deployment"
    TASK="create"
  elif [[ "${STATE}" == "1" ]] || [[ "${STATE}" == "2" ]]; then
    print "Previous deployment did not complete - retrying"
    TASK="create"
  elif [[ "${STATE}" == "3" ]]; then
    print "Current Deployment is NOT healthy"
    TASK="update"
  elif [[ "${STATE}" == "4" ]]; then
    source "${ANALYZE_CONTAINERS_ROOT_DIR}/configs/${CONFIG_NAME}/version"
    CONFIG_SUPPORTED_I2ANALYZE_VERSION="${SUPPORTED_I2ANALYZE_VERSION}"
    source "${ANALYZE_CONTAINERS_ROOT_DIR}/version"
    CURRENT_SUPPORTED_I2ANALYZE_VERSION="${SUPPORTED_I2ANALYZE_VERSION}"
    if [[ "${CONFIG_SUPPORTED_I2ANALYZE_VERSION}" != "${CURRENT_SUPPORTED_I2ANALYZE_VERSION}" ]]; then
      print "Upgrading deployment"
      if [[ "${CONFIG_SUPPORTED_I2ANALYZE_VERSION}" < "4.3.4.0" ]]; then
        printErrorAndExit "Upgrade from i2 Analyze version ${CONFIG_SUPPORTED_I2ANALYZE_VERSION} is not supported"
      fi
      TASK="upgrade"
    else
      print "Updating deployment"
      TASK="update"
    fi
  fi

  if [[ "${TASK}" == "update" ]]; then
    if ! checkContainersExist; then
      print "Some containers are missing, the deployment is NOT healthy."
      waitForUserReply "Do you want to clean and recreate the deployment? This will permanently remove data from the deployment."
      # Reset state
      STATE="0"
      TASK="create"
    fi
    if ! checkConnectorContainersExist; then
      # Reset state
      STATE="3"
      printWarn "Some connector containers are missing, the deployment is NOT healthy."
    fi
  fi
}

function runTopLevelChecks() {
  checkEnvironmentIsValid
  checkDeploymentPatternIsValid
  checkClientFunctionsEnvironmentVariablesAreSet
  checkVariableIsSet "${HOST_PORT_SOLR}" "HOST_PORT_SOLR environment variable is not set"
  checkVariableIsSet "${HOST_PORT_I2ANALYZE_SERVICE}" "HOST_PORT_I2ANALYZE_SERVICE environment variable is not set"
  checkVariableIsSet "${HOST_PORT_DB}" "HOST_PORT_DB environment variable is not set"
  checkVariableIsSet "${HOST_PORT_PROMETHEUS}" "HOST_PORT_PROMETHEUS environment variable is not set"
  checkVariableIsSet "${HOST_PORT_GRAFANA}" "HOST_PORT_GRAFANA environment variable is not set"
}

function printDeploymentInformation() {
  local toolkit_version
  print "Deployment Information:"
  echo "ANALYZE_CONTAINERS_ROOT_DIR: ${ANALYZE_CONTAINERS_ROOT_DIR}"
  echo "CONFIG_NAME: ${CONFIG_NAME}"
  echo "DEPLOYMENT_PATTERN: ${DEPLOYMENT_PATTERN}"
  echo "I2A_DEPENDENCIES_IMAGES_TAG: ${I2A_DEPENDENCIES_IMAGES_TAG}"
}

function runTask() {
  case "${TASK}" in
  "create")
    createDeployment
    ;;
  "update")
    updateDeployment
    ;;
  "clean")
    cleanDeployment
    ;;
  "backup")
    createBackup
    ;;
  "restore")
    restoreFromBackup
    ;;
  "upgrade")
    upgrade
    ;;
  "package")
    package
    ;;
  esac
}

function runNormalDeployment() {
  workOutTaskToRun
  runTask
}

function package() {
  initializeDeployment
  buildExtensions
  buildLibertyConfiguredImage
}

###############################################################################
# Function Calls                                                              #
###############################################################################

runTopLevelChecks
printDeploymentInformation

checkLicensesAcceptedIfRequired "${ENVIRONMENT}" "${DEPLOYMENT_PATTERN}" "${DB_DIALECT}"

# If you would like to call a specific function you should do it after this line

# Cleaning up Docker resources
cleanUpDockerResources
createDockerNetwork "${DOMAIN_NAME}"

if [[ "${TASK}" != "clean" && "${TASK}" != "package" ]]; then
  # Restart exited Docker containers
  restartDockerContainersForConfig "${CONFIG_NAME}"
  restartConnectorsForConfig
fi

if [[ -z "${TASK}" ]]; then
  runNormalDeployment
else
  runTask
fi
