#!/usr/bin/env bash

# This script is a part of the main script and is responsible for the utility functions used in the main script.

source src/declarations.sh
source src/exchange.sh
source src/fetcher.sh
source src/verifier.sh

# Function to check and download the dependencies
# This function checks for the required tools and downloads them if not found depending on the configuration done in the declarations file
function check_and_download_dependencies() {
  make_directories

  # Check for Python requirements
  if ! command -v python3 &>/dev/null; then
    echo -e "Python 3 is required to run this script.\nExiting..."
    exit 1
  fi

  # Check if retry config is enabled
  if [[ "${ADDITIONALS[RETRY]}" == "true" ]]; then
    RETRY="true"
  else
    RETRY="false"
  fi

  # Check for required tools
  # If they're present, continue with the script
  # Else, download them by checking version from declarations
  tools=$(supported_tools "cdd") # Call the function and capture its output

  # Convert the space-separated string back into an array
  IFS=' ' read -r -a tools_array <<<"${tools}"

  for tool in "${tools_array[@]}"; do
    local flag=$(flag_check "${tool}")

    if [[ "${flag}" == 'false' ]]; then
      echo -e "\`${tool}\` is **NOT** enabled in the configuration.\nSkipping...\n"
      continue
    fi

    if [ -f "${WORKDIR}/modules/${tool}.zip" ]; then
      echo -e "\`${tool}.zip\` file already exists in \`${WORKDIR}/modules\`."
      continue
    fi

    if [ -d "${WORKDIR}/tools/${tool}" ]; then
      echo -e "\`${tool}\` file already exists in \`${WORKDIR}/tools\`."
      continue
    fi

    RETRY_COUNT=0 # Reset retry count for each tool
    while true; do
      # Download the tool and verify the download
      download_dependencies "${tool}"
      verify_downloads "${tool}"
      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  done

  # Retry logic for magisk
  if [[ "${ADDITIONALS[ROOT]}" == 'true' ]]; then
    RETRY_COUNT=0 # Reset retry count for magisk
    while true; do
      # Magisk is an exception as it is an APK and hence we do the get call directly and verify
      URL="${MAGISK[URL]}/releases/download/${VERSION[MAGISK]}/app-release.apk"
      echo "URL for \`magisk\`: ${URL}"
      get "magisk" "${URL}"
      verify_downloads "magisk"

      [[ "${ADDITIONALS[RETRY]}" == "true" ]] && [[ "${RETRY}" == "true" ]] || break
    done
  fi

  # Build the Hail module (rootless only; no signature verification needed)
  if [[ "${ADDITIONALS[HAIL]}" == 'true' ]]; then
    build_hail_module
  fi

  # Build the App Manager module. Rootless-only: skipped entirely on a rooted
  # (Magisk) build so App Manager is injected as a privileged system app ONLY in
  # the rootless flavor, exactly as required.
  if [[ "${ADDITIONALS[APPMANAGER]}" == 'true' && "${ADDITIONALS[ROOT]}" != 'true' ]]; then
    build_appmanager_module
  fi
}

# Build the Hail privileged-system-app module zip consumed by `--module-hail`.
# Downloads the prebuilt Hail.apk and lays it out at its target system paths
# together with a privapp-permissions allowlist.
function build_hail_module() {
  local module_root="${WORKDIR}/hail-module"
  local apk_dir="${module_root}/system/priv-app/Hail"
  local perm_dir="${module_root}/system/etc/permissions"
  local out_zip="${WORKDIR}/modules/hail.zip"
  # Resolve to an absolute path now, before any `cd`. `zip`'s output path
  # below is evaluated after `cd "${module_root}"`, so a relative WORKDIR
  # (the default ".tmp") would otherwise be resolved against the wrong cwd.
  local abs_out_zip
  abs_out_zip="$(realpath -m "${out_zip}")"

  if [ -f "${out_zip}" ]; then
    echo -e "\`hail.zip\` already exists in \`${WORKDIR}/modules\`."
    return
  fi

  echo -e "Building Hail module from ${HAIL_APK_URL}..."
  rm -rf "${module_root}"
  mkdir -p "${apk_dir}" "${perm_dir}"

  # Fail closed: if the download errors (e.g. 404 on a missing release asset)
  # or produces an empty/missing file, abort rather than ship a hail.zip whose
  # privapp-permissions XML points at an absent package (GrapheneOS enforce
  # mode boot-safety risk).
  if ! curl -sLf "${HAIL_APK_URL}" --output "${apk_dir}/Hail.apk" || [ ! -s "${apk_dir}/Hail.apk" ]; then
    echo -e "Error: failed to download a valid Hail APK from ${HAIL_APK_URL}"
    rm -rf "${module_root}"
    return 1
  fi

  # Privileged-permission allowlist. MUST list exactly the privileged
  # permissions Hail declares, or GrapheneOS
  # (ro.control_privapp_permissions=enforce) can boot-loop.
  cat >"${perm_dir}/privapp-permissions-${HAIL_PACKAGE}.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="${HAIL_PACKAGE}">
        <permission name="android.permission.FORCE_STOP_PACKAGES"/>
        <permission name="android.permission.CHANGE_COMPONENT_ENABLED_STATE"/>
        <permission name="android.permission.MANAGE_APP_OPS_MODES"/>
        <permission name="android.permission.PACKAGE_USAGE_STATS"/>
    </privapp-permissions>
</permissions>
EOF

  ( cd "${module_root}" && zip -qr "${abs_out_zip}" system )
  rm -rf "${module_root}"
  echo -e "\`hail.zip\` built at \`${out_zip}\`."
}

# Build the App Manager privileged-system-app module zip consumed by
# `--module-appmanager`. Mirrors build_hail_module: downloads the prebuilt
# universal (all-ABI) App Manager APK and lays it out at its target system paths
# together with a privapp-permissions allowlist.
#
# BOOT SAFETY (read before editing the allowlist below):
#   GrapheneOS ships ro.control_privapp_permissions=enforce. At boot the system
#   requires that EVERY privileged-protection permission a priv-app *requests* is
#   present in that app's privapp-permissions allowlist; a single missing one
#   makes system_server throw and the device BOOT-LOOPS. The allowlist is purely
#   additive: extra/non-privileged/undefined entries are ignored, so OVER-listing
#   is safe and UNDER-listing is catastrophic. The list below is the complete set
#   of permissions App Manager's manifest marks protected (tools:ignore=
#   "ProtectedPermissions") — a superset of the strictly-privileged subset — so it
#   is guaranteed to cover every privileged permission App Manager requests.
#   It is derived directly from the App Manager APK's manifest, as required.
function build_appmanager_module() {
  local module_root="${WORKDIR}/appmanager-module"
  local apk_dir="${module_root}/system/priv-app/AppManager"
  local perm_dir="${module_root}/system/etc/permissions"
  local out_zip="${WORKDIR}/modules/appmanager.zip"
  # Resolve to an absolute path now, before any `cd` (see build_hail_module).
  local abs_out_zip
  abs_out_zip="$(realpath -m "${out_zip}")"

  if [ -f "${out_zip}" ]; then
    echo -e "\`appmanager.zip\` already exists in \`${WORKDIR}/modules\`."
    return
  fi

  echo -e "Building App Manager module from ${APPMANAGER_APK_URL}..."
  rm -rf "${module_root}"
  mkdir -p "${apk_dir}" "${perm_dir}"

  # Fail closed: if the download errors (e.g. 404 on a missing release asset) or
  # produces an empty/missing file, abort rather than ship an appmanager.zip whose
  # privapp-permissions XML points at an absent package (GrapheneOS enforce-mode
  # boot-safety risk).
  if ! curl -sLf "${APPMANAGER_APK_URL}" --output "${apk_dir}/AppManager.apk" || [ ! -s "${apk_dir}/AppManager.apk" ]; then
    echo -e "Error: failed to download a valid App Manager APK from ${APPMANAGER_APK_URL}"
    rm -rf "${module_root}"
    return 1
  fi

  # Optional integrity pin: a wrong/tampered/truncated APK must never reach the
  # system image. Only enforced when APPMANAGER_APK_SHA256 is non-empty.
  if [ -n "${APPMANAGER_APK_SHA256}" ]; then
    if ! echo "${APPMANAGER_APK_SHA256}  ${apk_dir}/AppManager.apk" | sha256sum -c - >/dev/null 2>&1; then
      echo -e "Error: App Manager APK SHA-256 mismatch (expected ${APPMANAGER_APK_SHA256}). Aborting."
      rm -rf "${module_root}"
      return 1
    fi
  fi

  # Privileged-permission allowlist. See BOOT SAFETY note above before changing.
  cat >"${perm_dir}/privapp-permissions-${APPMANAGER_PACKAGE}.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<permissions>
    <privapp-permissions package="${APPMANAGER_PACKAGE}">
        <permission name="android.permission.ADJUST_RUNTIME_PERMISSIONS_POLICY"/>
        <permission name="android.permission.BACKUP"/>
        <permission name="android.permission.CHANGE_COMPONENT_ENABLED_STATE"/>
        <permission name="android.permission.CHANGE_OVERLAY_PACKAGES"/>
        <permission name="android.permission.CLEAR_APP_CACHE"/>
        <permission name="android.permission.CLEAR_APP_USER_DATA"/>
        <permission name="android.permission.DELETE_CACHE_FILES"/>
        <permission name="android.permission.DELETE_PACKAGES"/>
        <permission name="android.permission.DEVICE_POWER"/>
        <permission name="android.permission.DUMP"/>
        <permission name="android.permission.FORCE_STOP_PACKAGES"/>
        <permission name="android.permission.GET_APP_OPS_STATS"/>
        <permission name="android.permission.GET_RUNTIME_PERMISSIONS"/>
        <permission name="android.permission.GRANT_RUNTIME_PERMISSIONS"/>
        <permission name="android.permission.INJECT_EVENTS"/>
        <permission name="com.android.permission.INSTALL_EXISTING_PACKAGES"/>
        <permission name="android.permission.INSTALL_TEST_ONLY_PACKAGE"/>
        <permission name="android.permission.INSTALL_PACKAGES"/>
        <permission name="android.permission.INTERACT_ACROSS_USERS"/>
        <permission name="android.permission.INTERACT_ACROSS_USERS_FULL"/>
        <permission name="android.permission.INTERNAL_DELETE_CACHE_FILES"/>
        <permission name="android.permission.KILL_UID"/>
        <permission name="android.permission.MANAGE_APP_OPS_MODES"/>
        <permission name="android.permission.MANAGE_APPOPS"/>
        <permission name="android.permission.MANAGE_NETWORK_POLICY"/>
        <permission name="android.permission.MANAGE_NOTIFICATION_LISTENERS"/>
        <permission name="android.permission.MANAGE_USERS"/>
        <permission name="android.permission.MANAGE_SENSORS"/>
        <permission name="android.permission.NETWORK_SETTINGS"/>
        <permission name="android.permission.PACKAGE_USAGE_STATS"/>
        <permission name="android.permission.READ_LOGS"/>
        <permission name="android.permission.REAL_GET_TASKS"/>
        <permission name="android.permission.REVOKE_RUNTIME_PERMISSIONS"/>
        <permission name="android.permission.START_ANY_ACTIVITY"/>
        <permission name="android.permission.SUSPEND_APPS"/>
        <permission name="android.permission.UPDATE_APP_OPS_STATS"/>
        <permission name="android.permission.UPDATE_DOMAIN_VERIFICATION_USER_SELECTION"/>
        <permission name="android.permission.WRITE_SECURE_SETTINGS"/>
    </privapp-permissions>
</permissions>
EOF

  # Installer-conflict fix (GrapheneOS boot-safety): as a privileged system app,
  # App Manager's installer activities also satisfy the platform "required installer"
  # resolution (ACTION_INSTALL_PACKAGE among system apps), which must match EXACTLY ONE
  # app or system_server aborts at boot ("There must be exactly one installer") -> boot
  # loop. Make App Manager's PackageInstallerActivity the sole installer by disabling the
  # stock packageinstaller InstallStart and App Manager's ActivityInterceptor. (To keep
  # the stock installer instead, disable both App Manager installer components here.)
  mkdir -p "${module_root}/system/etc/sysconfig"
  cat >"${module_root}/system/etc/sysconfig/appmanager-installer-override.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<config>
    <component-override package="com.android.packageinstaller">
        <component class="com.android.packageinstaller.InstallStart" enabled="false"/>
    </component-override>
    <component-override package="${APPMANAGER_PACKAGE}">
        <component class="io.github.muntashirakon.AppManager.intercept.ActivityInterceptor" enabled="false"/>
    </component-override>
</config>
EOF

  ( cd "${module_root}" && zip -qr "${abs_out_zip}" system )
  rm -rf "${module_root}"
  echo -e "\`appmanager.zip\` built at \`${out_zip}\`."
}


# Function to check the flag status
# If flag for a tool is disabled, it is not downloaded
function flag_check() {
  local tool="${1}"
  local tool_upper_case=$(echo "${tool}" | tr '[:lower:]' '[:upper:]')

  if [[ "${tool}" == "my-avbroot-setup" ]]; then
    FLAG="${ADDITIONALS[MY_AVBROOT_SETUP]}"
  elif [[ "${tool}" == "custota-tool" ]]; then
    FLAG="${ADDITIONALS[CUSTOTA_TOOL]}"
  else
    FLAG="${ADDITIONALS[$tool_upper_case]}"
  fi

  if [[ "${FLAG}" == 'true' ]]; then
    echo 'true'
  else
    echo 'false'
  fi
}

# Function to create and make the release called by main script
function create_and_make_release() {
  if [[ ! -d $WORKDIR ]]; then
    echo -e "Error: $WORKDIR is non-existent. Downloading the tools..."

    # Check for requirements and download them accordingly
    check_and_download_dependencies
  fi

  # Calls the download_ota function to download the OTA if not found
  download_ota
  # Calls the create_ota function to create the OTA
  create_ota
}

function create_ota() {
  [[ "${CLEANUP}" != 'true' ]] && trap cleanup EXIT ERR

  # Generate output file names
  generate_ota_info
  # Setup environment variables and paths
  env_setup
  # Patch OTA with avbroot and afsr by leveraging my-avbroot-setup
  patch_ota
}

# Function to cleanup the temporary files and unset the keys when not in interactive mode
function cleanup() {
  if [[ "${CLEANUP}" != 'true' ]]; then
    echo -e "Cleanup is disabled. Exiting...\n"
    return
  fi

  echo "Cleaning up..."
  rm -rf "${WORKDIR}"
  unset "${KEYS[@]}"
  echo "Cleanup complete."
}

# Generate the AVB and OTA signing keys.
# Has to be called manually.
function generate_keys() {
  local public_key_metadata='avb_pkmd.bin'

  # Generate the AVB and OTA signing keys
  avbroot key generate-key -o "${KEYS[AVB]}"
  avbroot key generate-key -o "${KEYS[OTA]}"

  # Convert the public key portion of the AVB signing key to the AVB public key metadata format
  # This is the format that the bootloader requires when setting the custom root of trust
  avbroot key extract-avb -k "${KEYS[AVB]}" -o "${public_key_metadata}"

  # Generate a self-signed certificate for the OTA signing key
  # This is used by recovery to verify OTA updates when sideloading
  avbroot key generate-cert -k "${KEYS[OTA]}" -o "${KEYS[CERT_OTA]}"

  # Convert the keys to base64 which can be used in CI/CD pipeline environment
  base64_encode
}

# Function to patch the OTA with the AVB and OTA keys
# Leverages `my-avbroot-setup` to patch the OTA
# This function does a lot of things before patching the OTA
function patch_ota() {
  if [[ "${INTERACTIVE_MODE}" != 'true' ]]; then
    base64_decode
  fi

  # Set the paths
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}"
  local pkmd="${KEYS[PKMD]}"
  local grapheneos_pkmd="${WORKDIR}/extracted/avb_pkmd.bin"
  local grapheneos_otacert="${WORKDIR}/extracted/ota/META-INF/com/android/otacert"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"

  # Activate the virtual environment
  if [ -z "${VIRTUAL_ENV}" ]; then
    enable_venv
  fi

  # Extract the official public keys and certificates if not found
  if [[ ! -e "${grapheneos_pkmd}" || ! -e "${grapheneos_otacert}" ]]; then
    echo "Extracting official keys..."
    extract_official_keys
  fi

  # At present, the script lacks the ability to disable certain modules.
  # Everything is hardcoded to be enabled by default.
  if ls "${ota_zip}.patched*.zip" 1>/dev/null 2>&1; then
    echo -e "File ${ota_zip}.pathed.zip already exists in local. Patch skipped."
  else
    echo -e "Patching OTA..."
    local args=()

    # OTA input and output
    args+=("--input" "${ota_zip}.zip")
    args+=("--output" "${OUTPUTS[PATCHED_OTA]}")

    # GrapheneOS public key metadata and certificate
    args+=("--verify-public-key-avb" "${grapheneos_pkmd}")
    args+=("--verify-cert-ota" "${grapheneos_otacert}")

    # PixeneOS decoded keys and certificates
    args+=("--sign-key-avb" "${KEYS[AVB]}")
    args+=("--sign-key-ota" "${KEYS[OTA]}")
    args+=("--sign-cert-ota" "${KEYS[CERT_OTA]}")

    # Passphrases for AVB and OTA keys
    args+=("--pass-avb-env-var" "PASSPHRASE_AVB")
    args+=("--pass-ota-env-var" "PASSPHRASE_OTA")

    # Modules
    args+=("--module-custota" "${WORKDIR}/modules/custota.zip")
    args+=("--module-msd" "${WORKDIR}/modules/msd.zip")
    args+=("--module-bcr" "${WORKDIR}/modules/bcr.zip")
    args+=("--module-oemunlockonboot" "${WORKDIR}/modules/oemunlockonboot.zip")
    args+=("--module-alterinstaller" "${WORKDIR}/modules/alterinstaller.zip")

    # Module signatures
    args+=("--module-custota-sig" "${WORKDIR}/signatures/custota.zip.sig")
    args+=("--module-msd-sig" "${WORKDIR}/signatures/msd.zip.sig")
    args+=("--module-bcr-sig" "${WORKDIR}/signatures/bcr.zip.sig")
    args+=("--module-oemunlockonboot-sig" "${WORKDIR}/signatures/oemunlockonboot.zip.sig")
    args+=("--module-alterinstaller-sig" "${WORKDIR}/signatures/alterinstaller.zip.sig")

    # Hail privileged system app (rootless freeze/force-stop). No signature:
    # the module is built locally and HailModule skips signature verification.
    if [[ "${ADDITIONALS[HAIL]}" == 'true' ]]; then
      args+=("--module-hail" "${WORKDIR}/modules/hail.zip")
    fi

    # App Manager privileged system app (rootless only). No signature: the module
    # is built locally and AppManagerModule skips signature verification. Guarded
    # on ROOT!=true so it is never injected into a rooted build.
    if [[ "${ADDITIONALS[APPMANAGER]}" == 'true' && "${ADDITIONALS[ROOT]}" != 'true' ]]; then
      args+=("--module-appmanager" "${WORKDIR}/modules/appmanager.zip")
    fi

    # Add support for Magisk if root config is enabled
    if [[ "${ADDITIONALS[ROOT]}" == 'true' ]]; then
      echo -e "Magisk is enabled. Modifying the setup script...\n"
      args+=("--patch-arg=--magisk" "--patch-arg" "${magisk_path}")
      args+=("--patch-arg=--magisk-preinit-device" "--patch-arg" "${MAGISK[PREINIT]}")
    else
      echo -e "Magisk is not enabled. Skipping...\n"
    fi

    # Have to clear storage space because, `csig` results in storage runout
    rm -rf ${WORKDIR}/extracted/extracts/

    # Python command to run the patch script
    python ${my_avbroot_setup}/patch.py "${args[@]}"
  fi

  # Deactivate the virtual environment after patching the OTA
  deactivate
}

# Function to setup the environment for the my-avbroot-setup script
function my_avbroot_setup() {
  # Paths
  local setup_script="${WORKDIR}/tools/my-avbroot-setup/patch.py"
  local magisk_path="${WORKDIR}/modules/magisk.apk"
  local location_path="${DOMAIN}/${USER}/${REPOSITORY}/releases/download/${VERSION[GRAPHENEOS]}/${OUTPUTS[PATCHED_OTA]}"

  # Add support to pass env-vars to the setup script for passphrase in the CI/CD pipeline
  echo -e "Running script modifications..."

  # Update location path to use GitHub releases
  sed -i -e "s|generate_update_info(update_info, args.output.name)|generate_update_info(update_info, '${location_path}')|" "${setup_script}"
}

# Function to setup the environment variables and paths for patching the OTA
function env_setup() {
  # Set up `my-avbroot-setup` environment
  my_avbroot_setup

  # Paths
  local avbroot="${WORKDIR}/tools/avbroot"
  local afsr="${WORKDIR}/tools/afsr"
  local custota_tool="${WORKDIR}/tools/custota-tool"
  local my_avbroot_setup="${WORKDIR}/tools/my-avbroot-setup"
  local requirements_file="${my_avbroot_setup}/requirements.txt"

  # Add the paths to the PATH environment variable just so that the script can find them
  if ! command -v avbroot &>/dev/null && ! command -v afsr &>/dev/null && ! command -v custota-tool &>/dev/null; then
    export PATH="$(realpath ${afsr}):$(realpath ${avbroot}):$(realpath ${custota_tool}):$PATH"
  fi

  # Enabled python virtual environment
  enable_venv

  # Install required Python packages
  if [[ -f "${requirements_file}" ]]; then
    local missing_packages=false
    while read -r package; do
      [[ -z "${package}" ]] && continue
      if ! pip list | grep -i "^${package%%[=><]*}" &>/dev/null; then
        missing_packages=true
        break
      fi
    done <"${requirements_file}"

    if [[ "${missing_packages}" == "true" ]]; then
      echo -e "Installing required Python packages from requirements.txt..."
      pip3 install -r "${requirements_file}"
    fi
  else
    echo -e "Warning: requirements.txt not found at ${requirements_file}"
  fi
}

# Function to enable the python virtual environment
function enable_venv() {
  local dir_path='' # Default value is empty string
  local base_path=$(basename "$(pwd)")
  local venv_path=''

  # Check presence of venv
  # Create a virtual environment if not found
  if [[ "${base_path}" == "my-avbroot-setup" ]]; then
    if [ ! -d "venv" ]; then
      echo -e "Virtual environment not found. Creating..."
      python3 -m venv venv
    fi
  else
    echo -e "The script is not run from the \`my-avbroot-setup\` directory.\nSearching for the directory..."
    dir_path=$(find . -type d -name "my-avbroot-setup" -print -quit)
    if [ ! -d "${dir_path}/venv" ]; then
      echo -e "Virtual environment not found in path \`${dir_path}\`. Creating..."
      python3 -m venv "${dir_path}/venv"
    fi
  fi

  # Set the virtual environment path
  if [ -n "${dir_path}" ]; then
    venv_path="${dir_path}/venv/bin/activate"
  else
    venv_path="venv/bin/activate"
  fi

  # Ensure venv_path is set correctly and activate the virtual environment
  if [ -f "${venv_path}" ]; then
    source "${venv_path}"
  else
    echo -e "Virtual environment activation script not found at \`${venv_path}\`."
  fi
}

# Construct URL for the tools and download them
# This function is called by download_dependencies function when running in non-interactive mode
function url_constructor() {
  local repository="${1}"
  local user='chenxiaolong'
  INTERACTIVE_MODE="${2:-true}"

  local repository_upper_case=$(echo "${repository}" | tr '[:lower:]' '[:upper:]')

  echo -e "Constructing URL for \`${repository}\` as \`${repository}\` is non-existent at \`${WORKDIR}\`..."
  # `my-avbroot-setup` is git repository (use our fork, which carries the Hail module)
  if [[ "${repository}" == "my-avbroot-setup" ]]; then
    URL="${DOMAIN}/mrbathwater/${repository}"
  else
    # Afsr, avbroot, and custota-tool are binaries and are platform dependent. Modules are zipped files.
    if [[ "${repository}" == "afsr" || "${repository}" == "avbroot" || "${repository}" == "custota-tool" ]]; then
      local suffix="${ARCH}"
    else
      local suffix="release"
    fi

    # Custota is a special case
    # Custota is a module and Custota-Tool is a binary
    # Both reside in same repository
    if [[ "${repository}" == "custota-tool" ]]; then
      local download_page="${DOMAIN}/${user}/Custota/releases/download"
      local version="v${VERSION[CUSTOTA]}"
      local application="${repository}-${VERSION[CUSTOTA]}-${suffix}.zip"
    else
      local download_page="${DOMAIN}/${user}/${repository}/releases/download"
      local version="v${VERSION[${repository_upper_case}]}"
      local application="${repository}-${VERSION[${repository_upper_case}]}-${suffix}.zip"
    fi

    URL="${download_page}/${version}/${application}"
    SIGNATURE_URL="${download_page}/${version}/${application}.sig"
  fi

  echo -e "URL for \`${repository}\`: ${URL}"

  # If the script is running in interactive mode, prompt the user to overwrite the existing files
  if [[ "${INTERACTIVE_MODE}" == 'true' ]]; then
    if [[ -e "${WORKDIR}/tools/${repository}" || -e "${WORKDIR}/modules/${repository}.zip" || -e "${WORKDIR}/signatures/${repository}.zip.sig" ]]; then
      echo -n "Warning: \`${repository}\` already exists in \`${WORKDIR}\`\nOverwrite? (y/n) [default: yes]: "
      read -r confirm
      confirm=${confirm:-"yes"}
      if [[ $confirm =~ ^[yY](es|ES)?$ ]]; then
        echo "Removing existing files..."
        rm -rf "${WORKDIR}/tools/${repository}" "${WORKDIR}/modules/${repository}.zip" "${WORKDIR}/signatures/${repository}.zip.sig"
      else
        echo "Aborted."
        exit 1
      fi
    fi
  fi

  # Make the get call to download the tools and modules
  get "${repository}" "${URL}" "${SIGNATURE_URL}"
}

# Function to download the dependencies
# This calls the constructor that constructs the URL for the tools and modules
function download_dependencies() {
  local tool="${1}"
  INTERACTIVE_MODE='false'

  if type url_constructor &>/dev/null; then
    url_constructor "${tool}" "${INTERACTIVE_MODE}"
  else
    echo -e "Error: \`url_constructor\` function is not defined."
    exit 1
  fi
}

# Function to extract the official GrapheneOS keys from the OTA
function extract_official_keys() {
  # https://github.com/chenxiaolong/my-avbroot-setup/issues/1#issuecomment-2270286453
  # AVB: Extract vbmeta.img, run avbroot avb info -i vbmeta.img.
  #   The public_key field is avb_pkmd.bin encoded as hex.
  #   Verify that the key is official by comparing its sha256 checksum with grapheneos.org/articles/attestation-compatibility-guide.
  # OTA: Extract META-INF/com/android/otacert from the OTA.
  #   (Or from otacerts.zip inside system.img or vendor_boot.img. All 3 files are identical.)
  local ota_zip="${WORKDIR}/${GRAPHENEOS[OTA_TARGET]}.zip"

  # Extract OTA
  avbroot ota extract \
    --input "${ota_zip}" \
    --directory "${WORKDIR}/extracted/extracts" \
    --all

  # Extract vbmeta.img
  # To verify, execute sha256sum avb_pkmd.bin in terminal
  # compare the output with base16-encoded verified boot key fingerprints
  # mentioned at https://grapheneos.org/articles/attestation-compatibility-guide for the respective device
  avbroot avb info -i "${WORKDIR}/extracted/extracts/vbmeta.img" |
    grep 'public_key' |
    sed -n 's/.*public_key: "\(.*\)".*/\1/p' |
    tr -d '[:space:]' | xxd -r -p >"${WORKDIR}/extracted/avb_pkmd.bin"

  # Extract META-INF/com/android/otacert from OTA or otacerts.zip from either vendor_boot.img or system.img
  unzip "${ota_zip}" -d "${WORKDIR}/extracted/ota"
}

function dirty_suffix() {
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "-dirty"
  else
    echo ""
  fi
}

# Function to make directories
function make_directories() {
  mkdir -p \
    "${WORKDIR}" \
    "${WORKDIR}/.keys" \
    "${WORKDIR}/extracted/extracts" \
    "${WORKDIR}/extracted/ota" \
    "${WORKDIR}/modules" \
    "${WORKDIR}/signatures" \
    "${WORKDIR}/tools"
}

function generate_ota_info() {
  # Detect build flavor
  local flavor=$([[ ${ADDITIONALS[ROOT]} == 'true' ]] && echo "magisk-${VERSION[MAGISK]}" || echo "rootless")
  # e.g. bluejay-2024082200-rootless-abc12345-dirty.zip
  OUTPUTS[PATCHED_OTA]="${DEVICE_NAME}-${VERSION[GRAPHENEOS]}-${flavor}-$(git rev-parse --short HEAD)$(dirty_suffix).zip"
}

function check_toml_env() {
  declare -A config_vars
  toml_file="env.toml"

  if [ -f "$toml_file" ]; then
    while IFS='=' read -r key value; do
      key=$(echo "$key" | xargs)                                  # Trim whitespace
      value=$(echo "$value" | xargs | sed -E 's/^"([^"]*)"$/\1/') # Trim whitespace and quotes
      if [[ -n "$key" && -n "$value" ]]; then
        config_vars["$key"]="$value"
      fi
    done < <(grep -v '^#' "$toml_file") # Ignore comments

    if [[ ${#config_vars[@]} -gt 0 ]]; then
      echo -e "Found variables in \`${toml_file}\` and will take precedence over other values.\n"
      for key in "${!config_vars[@]}"; do
        echo -e "${key}: ${config_vars[$key]}"
        eval "${key}=${config_vars[$key]}"
      done
    else
      echo -e "Failed to find the required variables in \`${toml_file}\`.\n"
      exit 1
    fi
  fi
}

function supported_tools() {
  local arg="${1:-}"
  local tools=("avbroot" "afsr" "alterinstaller" "custota" "custota-tool" "msd" "bcr" "oemunlockonboot" "my-avbroot-setup")

  if [[ "${arg}" == "cdd" ]]; then
    echo "${tools[@]}"
    return
  fi

  echo -e "Supported tools:"
  for tool in "${tools[@]}"; do
    echo -e "- ${tool}"
  done
  echo -e "- magisk"
}

function help() {
  cat <<EOF
Usage: source src/<file>.sh [functions] [arguments]
functions:
  - url_constructor        Run the URL Constructor function
    - arguments            Supported tool name.
                           Check 'supported_tools' for more info
  - generate_keys          Generate keys
  - help                   Show this help message
  - check_toml_env         Check TOML environment
  - supported_tools        List supported tools
EOF
}
