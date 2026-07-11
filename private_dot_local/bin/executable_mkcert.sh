#!/usr/bin/env bash
set -euo pipefail

PROGRAM="${0##*/}"

DEFAULT_DAYS=825
DAYS="$DEFAULT_DAYS"
EXPIRES=""
OUTDIR="$PWD"

usage() {
    cat <<EOF
Usage:
  $PROGRAM [options] NAME [NAME...]

Examples:
  $PROGRAM example.com "*.example.com" "*.another.doma.in"
  $PROGRAM --days 3650 example.com "*.example.com"
  $PROGRAM --expires 2035-12-31 example.com "*.example.com"

Options:
  --days N              Certificate validity in days
  --expires YYYY-MM-DD  Exact certificate expiry date, UTC
  --out DIR             Output directory
  --caroot DIR          Override mkcert CAROOT
  -h, --help            Show help
EOF
}

###############################################################################
# Find mkcert CAROOT
###############################################################################

CAROOT=""

if command -v mkcert >/dev/null 2>&1; then
    CAROOT="$(mkcert -CAROOT)"
else
    case "$(uname -s 2>/dev/null || true)" in
        Darwin)
            CAROOT="$HOME/Library/Application Support/mkcert"
            ;;
        Linux)
            CAROOT="${XDG_DATA_HOME:-$HOME/.local/share}/mkcert"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            CAROOT="${LOCALAPPDATA}/mkcert"
            ;;
        *)
            echo "error: could not determine mkcert CAROOT" >&2
            echo "install mkcert or specify --caroot DIR" >&2
            exit 1
            ;;
    esac
fi

NAMES=()

while (($#)); do
    case "$1" in
        --days)
            [[ $# -ge 2 ]] || {
                echo "error: --days requires a value" >&2
                exit 1
            }
            DAYS="$2"
            shift 2
            ;;

        --expires)
            [[ $# -ge 2 ]] || {
                echo "error: --expires requires YYYY-MM-DD" >&2
                exit 1
            }
            EXPIRES="$2"
            shift 2
            ;;

        --out)
            [[ $# -ge 2 ]] || {
                echo "error: --out requires a directory" >&2
                exit 1
            }
            OUTDIR="$2"
            shift 2
            ;;

        --caroot)
            [[ $# -ge 2 ]] || {
                echo "error: --caroot requires a directory" >&2
                exit 1
            }
            CAROOT="$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        --)
            shift
            while (($#)); do
                NAMES+=("$1")
                shift
            done
            ;;

        -*)
            echo "error: unknown option: $1" >&2
            exit 1
            ;;

        *)
            # Tolerate accidental trailing comma:
            # "*.another.doma.in",
            NAMES+=("${1%,}")
            shift
            ;;
    esac
done

###############################################################################
# Validation
###############################################################################

if ((${#NAMES[@]} == 0)); then
    usage >&2
    exit 1
fi

if [[ -n "$EXPIRES" && "$DAYS" != "$DEFAULT_DAYS" ]]; then
    echo "error: use either --days or --expires, not both" >&2
    exit 1
fi

if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: --days must be a positive integer" >&2
    exit 1
fi

command -v openssl >/dev/null 2>&1 || {
    echo "error: openssl is required" >&2
    exit 1
}

CA_CERT="$CAROOT/rootCA.pem"
CA_KEY="$CAROOT/rootCA-key.pem"

if [[ ! -f "$CA_CERT" ]]; then
    echo "error: mkcert root CA certificate not found:" >&2
    echo "  $CA_CERT" >&2
    echo >&2
    echo "Run:" >&2
    echo "  mkcert -install" >&2
    exit 1
fi

if [[ ! -f "$CA_KEY" ]]; then
    echo "error: mkcert root CA private key not found:" >&2
    echo "  $CA_KEY" >&2
    echo >&2
    echo "The private key is required to issue certificates." >&2
    exit 1
fi

mkdir -p "$OUTDIR"

###############################################################################
# Temporary working directory
###############################################################################

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CSR="$TMPDIR/request.csr"
EXTFILE="$TMPDIR/extensions.cnf"

###############################################################################
# Build SAN configuration
###############################################################################

{
    echo "[server_cert]"
    echo "basicConstraints = critical,CA:FALSE"
    echo "keyUsage = critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectKeyIdentifier = hash"
    echo "authorityKeyIdentifier = keyid,issuer"
    echo "subjectAltName = @alt_names"
    echo
    echo "[alt_names]"
} > "$EXTFILE"

DNS_INDEX=1
IP_INDEX=1

for name in "${NAMES[@]}"; do
    if [[ "$name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "IP.${IP_INDEX} = ${name}" >> "$EXTFILE"
        ((IP_INDEX += 1))

    elif [[ "$name" == *:* ]]; then
        echo "IP.${IP_INDEX} = ${name}" >> "$EXTFILE"
        ((IP_INDEX += 1))

    else
        echo "DNS.${DNS_INDEX} = ${name}" >> "$EXTFILE"
        ((DNS_INDEX += 1))
    fi
done

###############################################################################
# Output filenames
###############################################################################

FIRST_NAME="${NAMES[0]}"

SAFE_NAME="$FIRST_NAME"
SAFE_NAME="${SAFE_NAME//\*/_wildcard}"
SAFE_NAME="${SAFE_NAME//:/_}"
SAFE_NAME="${SAFE_NAME//\//_}"

CERT_FILE="$OUTDIR/${SAFE_NAME}.pem"
KEY_FILE="$OUTDIR/${SAFE_NAME}-key.pem"
SERIAL_FILE="$CAROOT/serial"

###############################################################################
# Generate private key
###############################################################################

openssl genrsa \
    -out "$KEY_FILE" \
    2048

chmod 600 "$KEY_FILE"

###############################################################################
# Generate CSR
###############################################################################

openssl req \
    -new \
    -sha256 \
    -key "$KEY_FILE" \
    -subj "/CN=${FIRST_NAME}" \
    -out "$CSR"

###############################################################################
# Determine validity
###############################################################################

VALIDITY_ARGS=()

if [[ -n "$EXPIRES" ]]; then
    command -v python3 >/dev/null 2>&1 || {
        echo "error: python3 is required with --expires" >&2
        exit 1
    }

    END_DATE="$(
        python3 - "$EXPIRES" <<'PY'
import datetime
import sys

try:
    requested = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d")
except ValueError:
    print(
        "error: --expires must be a valid YYYY-MM-DD date",
        file=sys.stderr,
    )
    sys.exit(1)

now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

if requested <= now:
    print(
        "error: expiration date must be in the future",
        file=sys.stderr,
    )
    sys.exit(1)

delta = requested - now

# openssl x509 -days accepts whole days.
# Add one day to include the requested expiration date.
print(delta.days + 1)
PY
    )"

    VALIDITY_ARGS=(-days "$END_DATE")
else
    VALIDITY_ARGS=(-days "$DAYS")
fi

###############################################################################
# Sign directly with mkcert root CA
###############################################################################

openssl x509 \
    -req \
    -sha256 \
    -in "$CSR" \
    -CA "$CA_CERT" \
    -CAkey "$CA_KEY" \
    -CAserial "$SERIAL_FILE" \
    -CAcreateserial \
    "${VALIDITY_ARGS[@]}" \
    -extfile "$EXTFILE" \
    -extensions server_cert \
    -out "$CERT_FILE"

###############################################################################
# Verification
###############################################################################

openssl verify \
    -CAfile "$CA_CERT" \
    "$CERT_FILE"

echo
echo "Created certificate valid for:"

for name in "${NAMES[@]}"; do
    echo "  - $name"
done

echo
echo "Certificate:"
echo "  $CERT_FILE"

echo
echo "Private key:"
echo "  $KEY_FILE"

echo
echo "Signed by mkcert CA:"
echo "  $CA_CERT"

echo
echo "Certificate details:"

openssl x509 \
    -in "$CERT_FILE" \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext subjectAltName
