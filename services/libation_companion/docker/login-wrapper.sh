#!/bin/sh
set -eu

: "${SHELFARR_AUDIBLE_ACCOUNT:?Missing Audible account}"
: "${SHELFARR_AUDIBLE_LOCALE:?Missing Audible marketplace locale}"
: "${LIBATION_CLI_PATH:=/libation/LibationCli}"

# login-external refuses redirected stdin. The companion launches this wrapper
# through util-linux `script`, which gives Libation a pseudo-terminal while the
# bridge retains one redirected Process. Disable terminal echo before the user
# supplies the sensitive final browser URL.
stty -echo

exec "${LIBATION_CLI_PATH}" login-external \
  --account "${SHELFARR_AUDIBLE_ACCOUNT}" \
  --locale "${SHELFARR_AUDIBLE_LOCALE}"
