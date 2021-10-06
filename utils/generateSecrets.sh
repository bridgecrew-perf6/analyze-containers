#!/usr/bin/env bash
# MIT License
#
# Copyright (c) 2021, IBM Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -e

# This is to ensure the script can be run from any directory
SCRIPT_DIR="$(dirname "$0")"
cd "$SCRIPT_DIR"

# Determine project root directory
ROOT_DIR=$(pushd . 1> /dev/null ; while [ "$(pwd)" != "/" ]; do test -e .root && grep -q 'Analyze-Containers-Root-Dir' < '.root' && { pwd; break; }; cd .. ; done ; popd 1> /dev/null)

function printUsage() {
  echo "Usage:"
  echo "  generateSecrets.sh -t generate [-c {all|core|connectors[-i <connector1_name>] [-e <connector1_name>]}] [-v]" 1>&2
  echo "  generateSecrets.sh -t clean [-v]" 1>&2
  echo "  generateSecrets.sh -a -t {generate|clean} -l dependency_label [-v]" 1>&2
  echo "  generateSecrets.s -h" 1>&2
}

function usage() {
  printUsage
  exit 1
}

function help() {
  printUsage
  echo "Options:" 1>&2
  echo "  -t <generate>         Generate certificates. " 1>&2
  echo "  -t <clean>            Clean all certificates." 1>&2
  echo "  -c <all>              Generate certificates for all components." 1>&2
  echo "  -c <core>             Generate certificates for core components." 1>&2
  echo "  -c <connectors>       Generate certificates for connectors only." 1>&2
  echo "  -i <connector_name>   Names of the connectors to generate secrets for. To specify multiple connectors, add additional -i options." 1>&2
  echo "  -e <connector_name>   Names of the connectors to not generate secrets for. To specify multiple connectors, add additional -e options." 1>&2
  echo "  -l <dependency_label> Name of dependency image label to use on AWS." 1>&2
  echo "  -v                    Verbose output." 1>&2
  echo "  -a                    Produce or use artefacts on AWS." 1>&2
  echo "  -h                    Display the help." 1>&2
  exit 1
}

while getopts ":t:c:i:e:l:vahy" flag; do
  case "${flag}" in
  t)
    TASK="${OPTARG}"
    [[ "${TASK}" == "clean" ]] || [[ "${TASK}" == "generate" ]] || usage
    ;;
  c)
    COMPONENTS="${OPTARG}"
    [[ "${COMPONENTS}" == "all" || "${COMPONENTS}" == "connectors" || "${COMPONENTS}" == "core" ]] || usage
    ;;
  i)
    INCLUDED_CONNECTORS+=("$OPTARG")
    ;;
  e)
    EXCLUDED_CONNECTORS+=("${OPTARG}")
    ;;
  l)
    I2A_DEPENDENCIES_IMAGES_TAG="${OPTARG}"
    ;;
  v)
    VERBOSE="true"
    ;;
  y)
    YES_FLAG="true"
    ;;
  a)
    AWS_ARTEFACTS="true"
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

###############################################################################
# Defaults                                                                    #
###############################################################################

if [[ -z "${ENVIRONMENT}" ]]; then
  ENVIRONMENT="config-dev"
fi

if [[ "${AWS_ARTEFACTS}" && ( -z "${I2A_DEPENDENCIES_IMAGES_TAG}" ) ]]; then
  usage
fi

if [[ -z "${TASK}" ]]; then
  TASK="generate"
fi

if [[ -z "${COMPONENTS}" ]]; then
  COMPONENTS="all"
fi

if [[ -z "${I2A_DEPENDENCIES_IMAGES_TAG}" ]]; then
  I2A_DEPENDENCIES_IMAGES_TAG="latest"
fi

if [[ "${INCLUDED_CONNECTORS[*]}" && "${EXCLUDED_CONNECTORS[*]}" ]]; then
  printf "\e[31mERROR: Incompatible options: Both (-i) and (-e) were specified.\n" >&2
  printf "\e[0m" >&2
  usage
  exit 1
fi

DEV_ENV_SECRETS_DIR="${ROOT_DIR}/dev-environment-secrets"
JAVA_CONTAINER_VOLUME_DIR="/simulatedKeyStore"
AWS_DEPLOY="false"

###############################################################################
# Loading common functions and variables                                      #
###############################################################################

# Load common functions
source "${ROOT_DIR}/utils/commonFunctions.sh"
source "${ROOT_DIR}/utils/clientFunctions.sh"

# Load common variables
source "${ROOT_DIR}/utils/simulatedExternalVariables.sh"
source "${ROOT_DIR}/utils/commonVariables.sh"
source "${ROOT_DIR}/utils/internalHelperVariables.sh"

checkEnvironmentIsValid

###############################################################################
# Functions                                                                   #
###############################################################################
function runJava() {
  docker run \
    --rm \
    --name "${I2A_TOOL_CONTAINER_NAME}" \
    --user "$(id -u "${USER}"):$(id -u "${USER}")" \
    -v "${GENERATED_SECRETS_DIR}/certificates:/simulatedKeyStore" \
    "${I2A_TOOLS_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}" "$@"
}

function checkSecretAlreadyExists() {
  local secret_name="${1}"
  local file_path="${2}"

  if [[ -d "${file_path}" ]]; then
    echo "Secrets for ${secret_name} already exist."
    echo "If you would like to regenerate the secrets, delete the ${file_path} folder."
    return 1
  fi
}

function createCA() {
  local CONTEXT="$1"
  local CA_CER="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}/CA.cer"
  local CA_KEY="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}/CA.key"
  local TMP="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}/.csr"
  local EXT="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}/x509.ext"

  print "Creating Certificate Authority"

  checkSecretAlreadyExists "${CONTEXT}" "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}" || return 0

  # Invalidate all other certificates
  if [[ "${CONTEXT}" == *"external"* ]]; then
    # Any certificate generated for external
    deleteFolderIfExists "${GENERATED_SECRETS_DIR}/certificates/${I2_ANALYZE_CERT_FOLDER_NAME}"
  else
    find "${GENERATED_SECRETS_DIR}/certificates" -maxdepth 1 -type d | while read -r file_location; do
      deleteFolderIfExists "${file_location}"
    done
  fi

  deleteFolderIfExistsAndCreate "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}"
  cp -p "${ROOT_DIR}/utils/templates/x509.ext.template" "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}/x509.ext.template"
  cp "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}/x509.ext.template" "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}/x509.ext"

  # Generate CA.key
  runJava openssl req -new -nodes -newkey rsa:"${CA_KEY_SIZE}" -keyout "${CA_KEY}" -subj "/CN=i2Analyze-eia" -out "${TMP}"
  # Generate CA.cer
  runJava openssl x509 -req -sha256 -extfile "${EXT}" -extensions ca -in "${TMP}" -signkey "${CA_KEY}" -days "${CA_DURATION}" -out "${CA_CER}"
  # Clean up
  runJava chmod a+r "${CA_CER}" && runJava rm "${TMP}" "${EXT}"
}

function createCertificates() {
  local HOST_NAME="$1"
  local FQDN="$2"
  local TYPE="$3"
  local CONTEXT="$4"

  local KEY="${JAVA_CONTAINER_VOLUME_DIR}/${HOST_NAME}/server.key"
  local CER="${JAVA_CONTAINER_VOLUME_DIR}/${HOST_NAME}/server.cer"
  local TMP="${JAVA_CONTAINER_VOLUME_DIR}/${HOST_NAME}-key.csr"
  local CA_CER="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}CA/CA.cer"
  local CA_KEY="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}CA/CA.key"
  local CA_SRL="${JAVA_CONTAINER_VOLUME_DIR}/CA.srl"
  local EXT="${JAVA_CONTAINER_VOLUME_DIR}/${CONTEXT}CA/x509.ext"

  print "Create Raw Certificates"

  checkSecretAlreadyExists "${HOST_NAME}" "${GENERATED_SECRETS_DIR}/certificates/${HOST_NAME}" || return 0
  deleteFolderIfExistsAndCreate "${GENERATED_SECRETS_DIR}/certificates/${HOST_NAME}"

  if [[ "${CONTEXT}" == external ]]; then
    sed "s/HOST_NAME/${FQDN}/" "${LOCAL_EXTERNAL_CA_CERT_DIR}/x509.ext.template" >"${LOCAL_EXTERNAL_CA_CERT_DIR}/x509.ext"
  else
    sed "s/HOST_NAME/${FQDN}/" "${LOCAL_CA_CERT_DIR}/x509.ext.template" >"${LOCAL_CA_CERT_DIR}/x509.ext"
  fi

  # Generate key
  runJava openssl genrsa -out "${KEY}" "${CERTIFICATE_KEY_SIZE}"
  # Generate certificate signing request
  runJava openssl req -new -key "${KEY}" -subj "/CN=${FQDN}" -out "${TMP}"
  # Generate certificate
  runJava openssl x509 -req -sha256 -CA "${CA_CER}" -CAkey "${CA_KEY}" -days "${CERTFICIATE_DURATION}" -CAcreateserial -CAserial "${CA_SRL}" -extfile "${EXT}" -extensions "${TYPE}" -in "${TMP}" -out "${CER}"
  # Clean up
  runJava chmod a+r "${KEY}" "${CER}" && runJava rm "${TMP}" "${CA_SRL}" "${EXT}"
}

function createSSLCertificates() {
  print "Creating SSL certificates"

  createCertificates "${ZK1_HOST_NAME}" "${ZK1_FQDN}" zk
  createCertificates "${ZK2_HOST_NAME}" "${ZK2_FQDN}" zk
  createCertificates "${ZK3_HOST_NAME}" "${ZK3_FQDN}" zk
  createCertificates "${SOLR1_HOST_NAME}" "${SOLR1_FQDN}" solr
  createCertificates "${SOLR2_HOST_NAME}" "${SOLR2_FQDN}" solr
  createCertificates "${SOLR3_HOST_NAME}" "${SOLR3_FQDN}" solr
  createCertificates "${SOLR_CLIENT_HOST_NAME}" "${SOLR_CLIENT_FQDN}" solr
  createCertificates "${I2A_TOOL_HOST_NAME}" "${I2A_TOOL_FQDN}" solr
  createCertificates "${LIBERTY1_HOST_NAME}" "${LIBERTY1_FQDN}" liberty
  createCertificates "${LIBERTY2_HOST_NAME}" "${LIBERTY2_FQDN}" liberty
  createCertificates "${DB2_SERVER_HOST_NAME}" "${DB2_SERVER_FQDN}" db2
  createCertificates "${SQL_SERVER_HOST_NAME}" "${SQL_SERVER_FQDN}" sqlserver
  createCertificates "${CONNECTOR1_HOST_NAME}" "${CONNECTOR1_FQDN}" connector
  createCertificates "${CONNECTOR2_HOST_NAME}" "${CONNECTOR2_FQDN}" connector
  createCertificates "${GATEWAY_CERT_FOLDER_NAME}" "${I2_GATEWAY_USERNAME}" liberty
  createCertificates "${I2_ANALYZE_CERT_FOLDER_NAME}" "${I2_ANALYZE_FQDN}" liberty external
}

function generateRandomPassword() {
  local PASSWORD_FILE_LOCATION="$1"

  if [[ -f "${PASSWORD_FILE_LOCATION}" ]]; then
    shred -u "${PASSWORD_FILE_LOCATION}"
  fi

  touch "${PASSWORD_FILE_LOCATION}"
  echo -n "$(runJava openssl rand -base64 16)" > "${PASSWORD_FILE_LOCATION}"
}

function generateSolrPasswords() {
  local secrets_dir="${GENERATED_SECRETS_DIR}/solr"
  print "Generating Solr Passwords"

  checkSecretAlreadyExists "Solr" "${secrets_dir}" || return 0
  deleteFolderIfExistsAndCreate "${secrets_dir}"

  generateRandomPassword "${secrets_dir}/SOLR_APPLICATION_DIGEST_PASSWORD"
  generateRandomPassword "${secrets_dir}/SOLR_ADMIN_DIGEST_PASSWORD"
  generateRandomPassword "${secrets_dir}/ZK_DIGEST_PASSWORD"
  generateRandomPassword "${secrets_dir}/ZK_DIGEST_READONLY_PASSWORD"
}

function generateApplicationAdminPassword() {
  local secrets_dir="${GENERATED_SECRETS_DIR}/application"

  print "Generating Application Passwords"
  checkSecretAlreadyExists "Application" "${secrets_dir}" || return 0
  deleteFolderIfExistsAndCreate "${secrets_dir}"

  generateRandomPassword "${secrets_dir}/admin_PASSWORD"
}

function generateSqlserverPasswords() {
  local secrets_dir="${GENERATED_SECRETS_DIR}/sqlserver"

  print "Generating SQL Server Passwords"
  checkSecretAlreadyExists "SQL Server" "${secrets_dir}" || return 0
  deleteFolderIfExistsAndCreate "${secrets_dir}"

  generateRandomPassword "${secrets_dir}/dbb_PASSWORD"
  generateRandomPassword "${secrets_dir}/i2analyze_PASSWORD"
  generateRandomPassword "${secrets_dir}/i2etl_PASSWORD"
  generateRandomPassword "${secrets_dir}/etl_PASSWORD"
  generateRandomPassword "${secrets_dir}/dba_PASSWORD"
  generateRandomPassword "${secrets_dir}/sa_PASSWORD"
  generateRandomPassword "${secrets_dir}/sa_INITIAL_PASSWORD"
}

function generateDb2serverPasswords() {
  local secrets_dir="${GENERATED_SECRETS_DIR}/db2server"

  print "Generating Db2 Server Passwords"
  checkSecretAlreadyExists "Db2" "${secrets_dir}" || return 0
  deleteFolderIfExistsAndCreate "${secrets_dir}"

  generateRandomPassword "${secrets_dir}/db2inst1_PASSWORD"
  generateRandomPassword "${secrets_dir}/db2inst1_INITIAL_PASSWORD"
}

function generateSolrSecurityJson() {
  local SOLR_ADMIN_SALT
  local SOLR_ADMIN_DIGEST
  local SOLR_APPLICATION_SALT
  local SOLR_APPLICATION_DIGEST

  print "Generating Solr security.json file"

  # Generate a random salt
  SOLR_ADMIN_SALT=$(openssl rand -base64 32)

  # Create the solr digest
  SOLR_ADMIN_DIGEST=$( (
    echo -n "${SOLR_ADMIN_SALT}" | base64 -d
    echo -n "$(cat "${GENERATED_SECRETS_DIR}/solr/SOLR_ADMIN_DIGEST_PASSWORD")"
  ) | openssl dgst -sha256 -binary | openssl dgst -sha256 -binary | base64)

  # Generate a random salt
  SOLR_APPLICATION_SALT=$(openssl rand -base64 32)

  # Create the solr digest
  SOLR_APPLICATION_DIGEST=$( (
    echo -n "${SOLR_APPLICATION_SALT}" | base64 -d
    echo -n "$(cat "${GENERATED_SECRETS_DIR}/solr/SOLR_APPLICATION_DIGEST_PASSWORD")"
  ) | openssl dgst -sha256 -binary | openssl dgst -sha256 -binary | base64)

  # Create the security.json file
  cat <"${ROOT_DIR}/utils/templates/security-template.json" | jq '.authentication.credentials +=
  {
    "liberty":"'"${SOLR_APPLICATION_DIGEST} ${SOLR_APPLICATION_SALT}"'",
    "solr": "'"${SOLR_ADMIN_DIGEST} ${SOLR_ADMIN_SALT}"'"
  }' >"${GENERATED_SECRETS_DIR}/solr/security.json"
}

function simulateContainerSecretStoreAccess() {
  local CONTEXT="$1"
  local TYPE="$2"

  print "Simulating Secret Store Access: ${CONTEXT}"

  deleteFolderIfExistsAndCreate "${LOCAL_KEYS_DIR}/${CONTEXT}"
  cp -pr "${GENERATED_SECRETS_DIR}/certificates/${CONTEXT}/." "${LOCAL_KEYS_DIR}/${CONTEXT}/"
  cp "${GENERATED_SECRETS_DIR}/certificates/${TYPE}CA/CA.cer" "${LOCAL_KEYS_DIR}/${CONTEXT}/CA.cer"
}

function simulateLibertySecretStoreAccess() {
  local HOST_NAME="$1"

  simulateContainerSecretStoreAccess "${HOST_NAME}"
  cp "${GENERATED_SECRETS_DIR}/sqlserver/i2analyze_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/DB_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/SOLR_APPLICATION_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/SOLR_APPLICATION_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/ZK_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/certificates/gateway_user/server.cer" "${LOCAL_KEYS_DIR}/${HOST_NAME}/gateway_user.cer"
  cp "${GENERATED_SECRETS_DIR}/certificates/gateway_user/server.key" "${LOCAL_KEYS_DIR}/${HOST_NAME}/gateway_user.key"
  cp "${GENERATED_SECRETS_DIR}/certificates/CA/CA.cer" "${LOCAL_KEYS_DIR}/${HOST_NAME}/outbound_CA.cer"
}

function simulateSolrSecretStoreAccess() {
  local HOST_NAME="$1"

  simulateContainerSecretStoreAccess "${HOST_NAME}"

  cp "${GENERATED_SECRETS_DIR}/solr/SOLR_ADMIN_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/SOLR_ADMIN_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/ZK_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_READONLY_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/ZK_DIGEST_READONLY_PASSWORD"
}

function simulateZkSecretStoreAccess() {
  local HOST_NAME="$1"

  simulateContainerSecretStoreAccess "${HOST_NAME}"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/ZK_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_READONLY_PASSWORD" "${LOCAL_KEYS_DIR}/${HOST_NAME}/ZK_DIGEST_READONLY_PASSWORD"
}

function simulateSqlserverSecretStoreAccess() {
  local HOST_NAME="$1"

  simulateContainerSecretStoreAccess "${HOST_NAME}"
  cp "${GENERATED_SECRETS_DIR}/sqlserver/sa_INITIAL_PASSWORD" "${LOCAL_KEYS_DIR}/sqlserver/SA_PASSWORD"
}

function simulateDb2serverSecretStoreAccess() {
  local HOST_NAME="$1"

  simulateContainerSecretStoreAccess "${HOST_NAME}"
  cp "${GENERATED_SECRETS_DIR}/db2server/db2inst1_INITIAL_PASSWORD" "${LOCAL_KEYS_DIR}/db2server/DB2INST1_PASSWORD"
}

function simulatei2AnalyzeSecretStoreAccess() {
  local HOST_NAME="$1"
  simulateContainerSecretStoreAccess "${HOST_NAME}" external

  # Can be implemented as a load balancer or directly by Liberty. Add Liberty secrets
  cp "${GENERATED_SECRETS_DIR}/sqlserver/i2analyze_PASSWORD" "${LOCAL_KEYS_DIR}/${I2_ANALYZE_CERT_FOLDER_NAME}/DB_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/SOLR_APPLICATION_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${I2_ANALYZE_CERT_FOLDER_NAME}/SOLR_APPLICATION_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/solr/ZK_DIGEST_PASSWORD" "${LOCAL_KEYS_DIR}/${I2_ANALYZE_CERT_FOLDER_NAME}/ZK_DIGEST_PASSWORD"
  cp "${GENERATED_SECRETS_DIR}/certificates/gateway_user/server.cer" "${LOCAL_KEYS_DIR}/${HOST_NAME}/gateway_user.cer"
  cp "${GENERATED_SECRETS_DIR}/certificates/gateway_user/server.key" "${LOCAL_KEYS_DIR}/${HOST_NAME}/gateway_user.key"
  cp "${GENERATED_SECRETS_DIR}/certificates/CA/CA.cer" "${LOCAL_KEYS_DIR}/${HOST_NAME}/outbound_CA.cer"
}

function simulateServerSecretStoreAccess() {
  deleteFolderIfExistsAndCreate "${LOCAL_KEYS_DIR}"
  simulateLibertySecretStoreAccess "${LIBERTY1_HOST_NAME}"
  simulateLibertySecretStoreAccess "${LIBERTY2_HOST_NAME}"
  simulateZkSecretStoreAccess "${ZK1_HOST_NAME}"
  simulateZkSecretStoreAccess "${ZK2_HOST_NAME}"
  simulateZkSecretStoreAccess "${ZK3_HOST_NAME}"
  simulateContainerSecretStoreAccess "${CONNECTOR1_HOST_NAME}"
  simulateContainerSecretStoreAccess "${CONNECTOR2_HOST_NAME}"
  simulateSolrSecretStoreAccess "${SOLR1_HOST_NAME}"
  simulateSolrSecretStoreAccess "${SOLR2_HOST_NAME}"
  simulateSolrSecretStoreAccess "${SOLR3_HOST_NAME}"
  simulateSqlserverSecretStoreAccess "${SQL_SERVER_HOST_NAME}"
  simulateDb2serverSecretStoreAccess "${DB2_SERVER_HOST_NAME}"
  simulatei2AnalyzeSecretStoreAccess "${I2ANALYZE_HOST_NAME}"
}

function generateConnectorSecrets() {
  local connector_image_dir

  for connector_name in "${CONNECTOR_NAMES[@]}"; do
    connector_image_dir=${CONNECTOR_IMAGES_DIR}/${connector_name}
    [[ ! -d "${connector_image_dir}" ]] && continue
    generateConnectorSecret "${connector_image_dir}"
  done
}

function generateConnectorSecret() {
  local connector_image_dir="${1}"
  local connector_image_name
  local connector_secrets_folder
  local connector_type
  local hostname
  local connector_tag base_url

  connector_image_name="${connector_image_dir##*/}"
  connector_secrets_folder="${LOCAL_KEYS_DIR}/${connector_image_name}"
  print "Generating secrets for ${connector_image_name}"

  checkSecretAlreadyExists "${connector_image_name}" "${connector_secrets_folder}" || return 0
  deleteFolderIfExistsAndCreate "${connector_secrets_folder}"

  connector_type=$(jq -r '.type' <"${connector_image_dir}/connector-definition.json")

  if [[ "${connector_type}" == "external" ]]; then
    base_url=$(jq -r '.baseUrl' <"${connector_image_dir}/connector-definition.json")
    hostname=$(echo "${base_url}" | awk -F[/:] '{print $4}')
  else
    connector_tag=$(jq -r '.tag' <"${connector_image_dir}/connector-version.json")
    hostname="${connector_image_name}-${connector_tag}.${DOMAIN_NAME}"
  fi
  createCertificates "${connector_image_name}" "${hostname}" "connector"
  simulateContainerSecretStoreAccess "${connector_image_name}"
}

function generateCoreSecrets()
{
  print "Generating secrets for core components"

  createCA "CA"
  createCA "externalCA"
  createSSLCertificates
  generateApplicationAdminPassword
  generateSolrPasswords
  generateSqlserverPasswords
  generateDb2serverPasswords
  generateSolrSecurityJson
  simulateServerSecretStoreAccess
}

###############################################################################
# Function calls                                                              #
###############################################################################

if [[ "${TASK}" == "generate" ]]; then
  # Set a list of connectors to update
  setListOfConnectorsToUpdate

  if [[ "${COMPONENTS}" == "all" ]]; then
    generateCoreSecrets
    generateConnectorSecrets
  elif [[ "${COMPONENTS}" == "connectors" ]]; then
    generateConnectorSecrets
  elif [[ "${COMPONENTS}" == "core" ]]; then
    generateCoreSecrets
  fi
elif [[ "${TASK}" == "clean" ]]; then
  print "Deleting existing secrets"
  deleteFolderIfExistsAndCreate "${DEV_ENV_SECRETS_DIR}"
  echo "${DEV_ENV_SECRETS_DIR} folder is clean"
fi