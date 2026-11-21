#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/sign-veylor-apk.sh --unsigned PATH [options]

Signs the attested unsigned APK of a Veylor Android direct release on this Mac
with Veylor's APK-only key, and checks the result (AGENTS.md, "Android direct
APK (verifiable)"):

  1. The unsigned APK is com.veylor.app with all three ABIs, unsigned,
     aligned, and attested by .github/workflows/veylor-android.yml.
  2. apksigner signs a copy with APK Signature Schemes v2 and v3 only, keeping
     the build's alignment, so it adds the signature and nothing else.
  3. apksigner verifies it, and its certificate must be the one in
     scripts/release-config/veylor-android-certificate-sha256.txt.
  4. apksigcopier compare: the signed APK is the unsigned one plus the
     signature, as F-Droid checks. apksigcopier copy rebuilds the signed APK,
     byte for byte, from the unsigned one and the signature.
  5. SHA256SUMS for veylor-<version>-<build>.apk and
     veylor-<version>-<build>-unsigned.apk, in the output directory.

Options:
  --unsigned PATH          the unsigned APK from the workflow run's artifact
  --output-dir DIR         default dist/veylor-android/v<version>
  --keystore PATH          default ~/keys/veylor/veylor-apk.jks (PKCS12)
  --alias NAME             default apk
  --keychain-service NAME  default "Veylor Android APK keystore"
  --keychain-account NAME  default veylor-apk
  --repo OWNER/NAME        the attestation's repository
                           (default ChinmayGopal931/vizor-fork)

The keystore's password, which is also the key's, is read from the login
Keychain and reaches apksigner through its environment, never a command line.
Needs the Android SDK's build-tools 36.0.0 (ANDROID_HOME, default
~/Library/Android/sdk), a JDK (JAVA_HOME, or /usr/libexec/java_home), gh and
Python 3.8 or later.
EOF
}

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_PIN_FILE="${ROOT_DIR}/scripts/release-config/veylor-android-certificate-sha256.txt"
REQUIREMENTS="${ROOT_DIR}/scripts/veylor-android-release/requirements.txt"
WORKFLOW=".github/workflows/veylor-android.yml"
PACKAGE_NAME="com.veylor.app"
BUILD_TOOLS_VERSION="36.0.0"
ABIS=(arm64-v8a armeabi-v7a x86_64)
NATIVE_LIBS=(libapp.so libflutter.so librust_lib_zcash_wallet.so)

unsigned_input=""
output_dir=""
keystore="${HOME}/keys/veylor/veylor-apk.jks"
key_alias="apk"
keychain_service="Veylor Android APK keystore"
keychain_account="veylor-apk"
repo="ChinmayGopal931/vizor-fork"

while (($# > 0)); do
  case "$1" in
    --unsigned) unsigned_input="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --keystore) keystore="${2:-}"; shift 2 ;;
    --alias) key_alias="${2:-}"; shift 2 ;;
    --keychain-service) keychain_service="${2:-}"; shift 2 ;;
    --keychain-account) keychain_account="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

die() {
  echo "sign-veylor-apk: $*" >&2
  exit 1
}
log() {
  printf '\n==> %s\n' "$*"
}

find_python() {
  local candidate
  for candidate in "${VEYLOR_PYTHON:-}" python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    [[ -n "${candidate}" ]] || continue
    command -v "${candidate}" >/dev/null 2>&1 || continue
    if "${candidate}" -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      command -v "${candidate}"
      return 0
    fi
  done
  return 1
}

[[ -n "${unsigned_input}" ]] || { usage >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || die "this signs on macOS, with the password from the login Keychain"
[[ -f "${unsigned_input}" && -s "${unsigned_input}" ]] || die "no APK at ${unsigned_input}"
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME: ${repo}"
cert_pin="$(tr -d ' \n' <"${CERT_PIN_FILE}" | tr 'A-F' 'a-f')"
[[ "${cert_pin}" =~ ^[0-9a-f]{64}$ ]] || die "${CERT_PIN_FILE} must hold one SHA-256 fingerprint"

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
build_tools="${sdk}/build-tools/${BUILD_TOOLS_VERSION}"
apksigner="${build_tools}/apksigner"
zipalign="${build_tools}/zipalign"
aapt2="${build_tools}/aapt2"
for tool in "${apksigner}" "${zipalign}" "${aapt2}"; do
  [[ -x "${tool}" ]] || die "missing ${tool} (install build-tools;${BUILD_TOOLS_VERSION})"
done
if [[ -z "${JAVA_HOME:-}" ]]; then
  JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
[[ -n "${JAVA_HOME}" && -x "${JAVA_HOME}/bin/java" ]] || die "apksigner needs a JDK; set JAVA_HOME"
export JAVA_HOME
# apksigcopier runs `apksigner verify` from PATH.
export PATH="${JAVA_HOME}/bin:${build_tools}:${PATH}"
command -v gh >/dev/null 2>&1 || die "gh is needed to check the build's attestation"
python="$(find_python)" || die "Python 3.8 or later is needed (set VEYLOR_PYTHON)"

tools_dir="${ROOT_DIR}/build/veylor-android-signing"
signed_part=""
rebuilt=""
cleanup() {
  [[ -z "${signed_part}" ]] || rm -f -- "${signed_part}"
  [[ -z "${rebuilt}" ]] || rm -f -- "${rebuilt}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "Checking the unsigned APK"
badging="$("${aapt2}" dump badging "${unsigned_input}" | sed -n '1p')" ||
  die "aapt2 cannot read ${unsigned_input}"
package_name="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"${badging}")"
version_code="$(sed -n "s/.* versionCode='\([0-9]*\)'.*/\1/p" <<<"${badging}")"
version_name="$(sed -n "s/.* versionName='\([^']*\)'.*/\1/p" <<<"${badging}")"
[[ "${package_name}" == "${PACKAGE_NAME}" ]] || die "the APK is ${package_name:-unknown}, not ${PACKAGE_NAME}"
[[ "${version_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected versionName: ${version_name:-none}"
[[ "${version_code}" =~ ^[1-9][0-9]*$ ]] || die "unexpected versionCode: ${version_code:-none}"
echo "${package_name} ${version_name} (${version_code})"

entries="$(unzip -Z1 "${unsigned_input}")" || die "cannot list ${unsigned_input}"
for abi in "${ABIS[@]}"; do
  for library in "${NATIVE_LIBS[@]}"; do
    grep -qx "lib/${abi}/${library}" <<<"${entries}" || die "the APK lacks lib/${abi}/${library}"
  done
done
abis="$(sed -n 's#^lib/\([^/]*\)/.*#\1#p' <<<"${entries}" | LC_ALL=C sort -u | tr '\n' ' ')"
[[ "${abis}" == "arm64-v8a armeabi-v7a x86_64 " ]] || die "unexpected ABIs: ${abis}"
# apksigcopier copies entries as they are; a v1 signature, a JAR manifest or a
# directory entry would not survive its copy.
if grep -Eq '^META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))$|/$' <<<"${entries}"; then
  die "the APK carries a JAR manifest, a v1 signature or a directory entry"
fi
if "${apksigner}" verify "${unsigned_input}" >/dev/null 2>&1; then
  die "${unsigned_input} is already signed"
fi
"${zipalign}" -c -P 16 4 "${unsigned_input}" >/dev/null ||
  die "the APK's native libraries are not 16 KB aligned"

log "Checking the build's attestation"
attestation="$(gh attestation verify "${unsigned_input}" --repo "${repo}" \
  --signer-workflow "${repo}/${WORKFLOW}" --format json)" ||
  die "no attestation from ${repo}'s ${WORKFLOW} for this APK"
build_source="$("${python}" -I -c '
import json, sys
try:
    statement = json.loads(sys.stdin.read())[0]["verificationResult"]["statement"]
    definition = statement["predicate"]["buildDefinition"]
    workflow = definition["externalParameters"]["workflow"]
    commit = definition["resolvedDependencies"][0]["digest"]["gitCommit"]
    run = statement["predicate"]["runDetails"]["metadata"]["invocationId"]
    print(commit, workflow["ref"], run)
except (KeyError, IndexError, TypeError, ValueError):
    print("unknown unknown unknown")
' <<<"${attestation}")"
read -r source_commit source_ref source_run <<<"${build_source}"
echo "attested: built from ${source_commit} (${source_ref}) by ${source_run}"

# ---------------------------------------------------------------------------
base="veylor-${version_name}-${version_code}"
output_dir="${output_dir:-${ROOT_DIR}/dist/veylor-android/v${version_name}}"
mkdir -p -- "${output_dir}"
output_dir="$(cd -- "${output_dir}" && pwd)"
signed="${output_dir}/${base}.apk"
unsigned="${output_dir}/${base}-unsigned.apk"
[[ ! -e "${signed}" ]] || die "${signed} already exists; move it aside to sign again"
if [[ ! "${unsigned_input}" -ef "${unsigned}" ]]; then
  cp -f -- "${unsigned_input}" "${unsigned}"
fi
cmp -s -- "${unsigned_input}" "${unsigned}" || die "could not copy the unsigned APK to ${unsigned}"

log "Installing apksigcopier"
venv="${tools_dir}/venv"
mkdir -p -- "${tools_dir}"
"${python}" -I -m venv "${venv}" >/dev/null 2>&1 || true
[[ -x "${venv}/bin/python" ]] || die "could not create ${venv}"
"${venv}/bin/python" -I -m pip install --disable-pip-version-check --quiet \
  --require-hashes --only-binary=:all: --no-deps -r "${REQUIREMENTS}" \
  >"${tools_dir}/pip.log" 2>&1 || die "installing apksigcopier failed (see ${tools_dir}/pip.log)"
# Its environment switches (realignment, metadata) stay at their defaults.
apksigcopier=(env -u APKSIGCOPIER_EXCLUDE_ALL_META -u APKSIGCOPIER_COPY_EXTRA_BYTES
  -u APKSIGCOPIER_SKIP_REALIGNMENT -u APKSIGCOPIER_V1_ONLY
  "${venv}/bin/python" -I -c 'import apksigcopier; apksigcopier.main()')

# ---------------------------------------------------------------------------
log "Signing with ${key_alias} from ${keystore}"
[[ -f "${keystore}" ]] || die "no keystore at ${keystore}"
{ set +x; } 2>/dev/null
keystore_password="$(security find-generic-password -a "${keychain_account}" -s "${keychain_service}" -w 2>/dev/null)" ||
  die "the login Keychain has no password for \"${keychain_service}\" (account ${keychain_account})"
[[ -n "${keystore_password}" ]] || die "the Keychain's password for \"${keychain_service}\" is empty"
signed_part="${signed}.part"
VEYLOR_APK_KEYSTORE_PASSWORD="${keystore_password}" "${apksigner}" sign \
  --ks "${keystore}" --ks-type PKCS12 --ks-key-alias "${key_alias}" \
  --ks-pass env:VEYLOR_APK_KEYSTORE_PASSWORD --key-pass env:VEYLOR_APK_KEYSTORE_PASSWORD \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
  --v4-signing-enabled false --alignment-preserved \
  --out "${signed_part}" "${unsigned}" || die "apksigner could not sign"
unset keystore_password

log "Verifying the signature"
verification="$("${apksigner}" verify --verbose --print-certs "${signed_part}")" ||
  die "apksigner rejects the signed APK"
for line in \
  "Verified using v1 scheme (JAR signing): false" \
  "Verified using v2 scheme (APK Signature Scheme v2): true" \
  "Verified using v3 scheme (APK Signature Scheme v3): true" \
  "Number of signers: 1"; do
  grep -qxF "${line}" <<<"${verification}" || die "apksigner did not report: ${line}"
done
certificate="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"${verification}")"
[[ "${certificate}" == "${cert_pin}" ]] ||
  die "the APK is signed by ${certificate:-an unknown certificate}, not the pinned ${cert_pin}; it was not kept"
"${zipalign}" -c -P 16 4 "${signed_part}" >/dev/null || die "the signed APK lost its alignment"
mv -f -- "${signed_part}" "${signed}"
signed_part=""

log "Checking the signed APK is the unsigned build plus its signature"
"${apksigcopier[@]}" compare "${signed}" --unsigned "${unsigned}" ||
  die "apksigcopier compare: the signature does not carry over to the unsigned build"
rebuilt="${tools_dir}/rebuilt.apk"
rm -f -- "${rebuilt}"
"${apksigcopier[@]}" copy "${signed}" "${unsigned}" "${rebuilt}" ||
  die "apksigcopier could not copy the signature onto the unsigned build"
cmp -s -- "${rebuilt}" "${signed}" ||
  die "the signed APK differs from the unsigned build plus its signature"
rm -f -- "${rebuilt}"
rebuilt=""

(cd "${output_dir}" && shasum -a 256 "${base}.apk" "${base}-unsigned.apk" >SHA256SUMS)

fingerprint="$(tr 'a-f' 'A-F' <<<"${certificate}" | sed 's/../&:/g; s/:$//')"
log "Done"
cat <<EOF
Certificate SHA-256: ${fingerprint}
Signed:    ${signed} ($(stat -f %z "${signed}") bytes)
Unsigned:  ${unsigned}
Checksums: ${output_dir}/SHA256SUMS
$(cat "${output_dir}/SHA256SUMS")
Built from ${source_commit} (${source_ref}), ${source_run}

Publish the three files as a release that is never marked latest, e.g.:
  gh release create veylor-android/v${version_name} --repo ${repo} \\
    --target ${source_commit} --title "Veylor ${version_name} for Android" \\
    --notes-file release_notes/veylor-android-v${version_name}.md --latest=false \\
    "${signed}" "${unsigned}" "${output_dir}/SHA256SUMS"
EOF
