#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Wim-Bart van der Waals
#
# Learn junk mail (folder 0x17) as spam for all mailboxes, and optionally
# delete the messages afterwards.
#
# Delete behavior is controlled by, in order of priority (highest first):
#   1. -n / --no-delete   : never delete, overrides everything below
#   2. -d / --delete      : always delete
#   3. SPAMRUN_DELETE in /etc/gromox/spamrun.cfg (true/1 -> delete)
#   4. default            : do not delete
#
# SPAMRUN_DELETE accepts (case-insensitive): true, 1, false, 0.
# If the config file is missing, the parameter is missing, or the value is
# invalid, it is treated as false.

# --- Program info -----------------------------------------------------------
PROGNAME=$(basename "$0")
VERSION="1.1.0"

# --- Config block -------------------------------------------------------
SPAMRUN_CFG="/etc/gromox/spamrun.cfg"
MYSQL_CFG="/etc/gromox/mysql_adaptor.cfg"

usage() {
  cat <<EOF
${PROGNAME} ${VERSION}

Learn junk mail (folder 0x17, "Junk Email") as spam for every mailbox
via rspamd, and optionally delete the learned messages afterwards.

Usage:
  ${PROGNAME} [-d|--delete] [-n|--no-delete]
  ${PROGNAME} -?|--help
  ${PROGNAME} --version

Options:
  -d, --delete       Delete junk messages after they have been learned.
  -n, --no-delete    Never delete junk messages, regardless of -d/--delete
                     or SPAMRUN_DELETE in the config file. This option
                     always takes precedence.
  -?, --help         Show this help text and exit.
      --version      Show version information and exit.

Delete behavior priority (highest to lowest):
  1. -n / --no-delete            -> never delete
  2. -d / --delete               -> always delete
  3. SPAMRUN_DELETE in config    -> delete if true/1
  4. default                     -> do not delete

Configuration file: ${SPAMRUN_CFG}
  This optional file may contain a single parameter:

    SPAMRUN_DELETE = true|1|false|0

  - Matching is case-insensitive (e.g. True, TRUE, 1 are all accepted).
  - If the file does not exist, the parameter is absent, or its value is
    anything other than true/1/false/0, it is treated as SPAMRUN_DELETE=false.
  - Example:
      # ${SPAMRUN_CFG}
      SPAMRUN_DELETE = true

Also uses the MySQL/MariaDB connection details from:
  ${MYSQL_CFG}
  (parameters: mysql_username, mysql_password, mysql_host, mysql_dbname)
EOF
}

ARG_DELETE=0
ARG_NO_DELETE=0

for arg in "$@"; do
  case "$arg" in
    -d|--delete)
      ARG_DELETE=1
      ;;
    -n|--no-delete)
      ARG_NO_DELETE=1
      ;;
    -\?|--help)
      usage
      exit 0
      ;;
    --version)
      echo "${PROGNAME} ${VERSION}"
      exit 0
      ;;
    *)
      echo "Unknown parameter: $arg"
      echo "Try '${PROGNAME} --help' for more information."
      exit 1
      ;;
  esac
done

# --- Read SPAMRUN_DELETE from the spamrun config file --------------------
SPAMRUN_DELETE_CFG=0

if [ -e "${SPAMRUN_CFG}" ]; then
  SPAMRUN_DELETE_VALUE=$(sed -ne 's/^[[:space:]]*SPAMRUN_DELETE[[:space:]]*=[[:space:]]*\(.*\)[[:space:]]*$/\1/pI' "${SPAMRUN_CFG}" | tail -n1)
  SPAMRUN_DELETE_VALUE=$(echo "${SPAMRUN_DELETE_VALUE}" | tr -d '[:space:]')
  case "${SPAMRUN_DELETE_VALUE,,}" in
    true|1)
      SPAMRUN_DELETE_CFG=1
      ;;
    *)
      SPAMRUN_DELETE_CFG=0
      ;;
  esac
fi

# --- Determine final delete behavior --------------------------------------
if [ ${ARG_NO_DELETE} -eq 1 ]; then
  DO_DEL=0
elif [ ${ARG_DELETE} -eq 1 ]; then
  DO_DEL=1
elif [ ${SPAMRUN_DELETE_CFG} -eq 1 ]; then
  DO_DEL=1
else
  DO_DEL=0
fi

if [ ! -e "${MYSQL_CFG}" ] ; then
  echo "MySQL configuration not found. (${MYSQL_CFG})"
  exit 1
fi
MYSQL_PARAMS="--skip-column-names --skip-line-numbers"
MYSQL_USERNAME=$(sed -ne 's/mysql_username\s*=\s*\(.*\)\s*/-u\1/pI' ${MYSQL_CFG})
MYSQL_PASSWORD=$(sed -ne 's/mysql_password\s*=\s*\(.*\)\s*/-p\1/pI' ${MYSQL_CFG})
MYSQL_DBNAME=$(sed -ne 's/mysql_dbname\s*=\s*\(.*\)\s*/\1/pI' ${MYSQL_CFG})
MYSQL_HOST=$(sed -ne 's/mysql_host\s*=\s*\(.*\)\s*/-h\1/pI' ${MYSQL_CFG})
MYSQL_QUERY="SELECT username,maildir from users where id <> 0 and maildir <> \"\";"
MYSQL_CMD=("mysql" "${MYSQL_PARAMS}" "${MYSQL_USERNAME:=-uroot}" "${MYSQL_PASSWORD:=}" "${MYSQL_HOST:=-hlocalhost}" "${MYSQL_DBNAME:=grommunio}")
SQLITE_QUERY='select message_id,mid_string from messages where parent_fid=0x17;'
# shellcheck disable=SC2068
if ${MYSQL_CMD[@]}<<<"exit"&>/dev/null; then
  echo "${MYSQL_QUERY}" | ${MYSQL_CMD[@]} | while read -r USERNAME MAILDIR ; do
    SPAMLIST=$(mktemp)
    echo "${SQLITE_QUERY}" | sqlite3 "${MAILDIR}/exmdb/exchange.sqlite3" -tabs -noheader > ${SPAMLIST}
    cat ${SPAMLIST} | while read -r MESSAGEID MIDSTRING; do
      echo "Learning spam for user ${USERNAME}" | systemd-cat -t grommunio-spam-run
      MSGFILE="$MAILDIR/eml/$MIDSTRING"
      if [[ ! -f "$MSGFILE" ]]; then
        gromox-exm2eml -u "${USERNAME}" "${MESSAGEID}" 2>/dev/null | rspamc learn_spam | systemd-cat -t grommunio-spam-run
      else
        rspamc learn_spam --header 'Learn-Type: bulk' "$MSGFILE" | systemd-cat -t grommunio-spam-run
      fi
      if [ ${DO_DEL} -eq 1 ]; then
        /usr/sbin/gromox-mbop -u "${USERNAME}" delmsg -f 0x17 "${MESSAGEID}" | systemd-cat -t grommunio-spam-run
      fi
    done
    rm -f "${SPAMLIST}"
  done
else
  echo "MySQL-Connection couldn't be established, please check your configuration." | systemd-cat -t grommunio-spam-run -p err
fi