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
  echo "  deployExtensions.sh -c <config_name> " 1>&2
  echo "  deployExtensions.sh -c <config_name> [-i <extension1_name>] [-e <extension1_name>]" 1>&2
  echo "  deployExtensions.sh -h" 1>&2
}

function usage() {
  printUsage
  exit 1
}

function help() {
  printUsage
  echo "Options:"
  echo "  -c <config_name>      Name of the config to use." 1>&2
  echo "  -i <extension_name>   Names of the extensions to deploy and update. To specify multiple extensions, add additional -i options." 1>&2
  echo "  -e <extension_name>   Names of the extensions to deploy and udapte. To specify multiple extensions, add additional -e options." 1>&2
  echo "  -h                    Display the help." 1>&2
  exit 1
}

while getopts ":c:i:e:h" flag; do
  case "${flag}" in
  c)
    CONFIG_NAME="${OPTARG}"
    ;;
  i)
    INCLUDED_EXTENSIONS+=("$OPTARG")
    ;;
  e)
    EXCLUDED_EXTENSIONS+=("${OPTARG}")
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

if [[ "${INCLUDED_EXTENSIONS[*]}" && "${EXCLUDED_EXTENSIONS[*]}" ]]; then
  printf "\e[31mERROR: Incompatible options: Both (-i) and (-e) were specified.\n" >&2
  printf "\e[0m" >&2
  usage
  exit 1
fi

# Load common functions
source "${ROOT_DIR}/utils/commonFunctions.sh"
source "${ROOT_DIR}/utils/serverFunctions.sh"
source "${ROOT_DIR}/utils/clientFunctions.sh"

# Load common variables
source "${ROOT_DIR}/utils/simulatedExternalVariables.sh"
source "${ROOT_DIR}/utils/commonVariables.sh"
source "${ROOT_DIR}/utils/internalHelperVariables.sh"
source "${ROOT_DIR}/version"

function installJarToMavenLocalIfNecessary() {
  local group_id="${1}"
  local artifact_id="${2}"
  local version="${3}"
  local file_path="${4}"

  if ! mvn dependency:get -Dartifact="${group_id}:${artifact_id}:${version}" >/dev/null; then
    mvn install:install-file -Dfile="${file_path}" -DgroupId="${group_id}" -DartifactId="${artifact_id}" -Dversion="${version}" -Dpackaging=jar
  fi
}

function removeJarFromMavenLocal() {
  local group_id="${1}"
  local artifact_id="${2}"

  mvn dependency:purge-local-repository -DmanualInclude="${group_id}:${artifact_id}"
}

function setupI2AnalyzeMavenLocal() {
  local libPath="${TOOLKIT_APPLICATION_DIR}/targets/opal-services/WEB-INF/lib"
  local sharedPath="${TOOLKIT_APPLICATION_DIR}/shared/lib"

  print "Ensure i2Analyze dependencies are installed..."
  
  installJarToMavenLocalIfNecessary "com.i2group" "apollo-legacy" "${I2ANALYZE_VERSION}" "${libPath}/ApolloLegacy.jar"
  installJarToMavenLocalIfNecessary "com.i2group" "disco-api" "${I2ANALYZE_VERSION}" "${libPath}/disco-api-9.2.jar"
  installJarToMavenLocalIfNecessary "com.i2group" "daod" "${I2ANALYZE_VERSION}" "${libPath}/Daod.jar"
  installJarToMavenLocalIfNecessary "com.i2group" "disco-utils" "${I2ANALYZE_VERSION}" "${sharedPath}/DiscoUtils.jar"

  pushd "${EXTENSIONS_DIR}" > /dev/null
  mvn install
  popd > /dev/null
}

function installArtifact() {
  local artifact_id="${1}"
  local artifact_dir="${ROOT_DIR}/i2a-extensions/${artifact_id}"

  if [[ ! -d "${artifact_dir}" ]]; then
    printErrorAndExit "Artifact ${artifact_id} does NOT exist"
  fi
  print "Deploying artifact: ${artifact_id}"
  cd "${artifact_dir}"
  mvn clean install -Doutput.dir="${LOCAL_LIB_DIR}" -Di2analyze.root.dir="${ROOT_DIR}"
}

function cleanArtifacts() {
  print "Cleaning all deployed artifacts"
  waitForUserReply "Are you sure you want to run the 'clean' task? This will permanently remove data from the deployment."
  rm "${LOCAL_LIB_DIR}"/*

  removeJarFromMavenLocal "com.i2group" "apollo-legacy"
  removeJarFromMavenLocal "com.i2group" "disco-api"
  removeJarFromMavenLocal "com.i2group" "daod"
  removeJarFromMavenLocal "com.i2group" "disco-utils"
}

###############################################################################
# Set up environment                                                          #
###############################################################################
setupI2AnalyzeMavenLocal

###############################################################################
# Build extensions                                                            #
###############################################################################
setListOfExtensionsToUpdate
for extension_name in "${EXTENSION_NAMES[@]}"; do
  installArtifact "${extension_name}"
done