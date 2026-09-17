#!/usr/bin/env bash
#shellcheck disable=SC2086,SC2001,SC2154
#shellcheck source=/dev/null

. "$(dirname $0)"/env offline # source env in offline mode to get basic variables, sourced in online mode later in cncliInit()

######################################
# Do NOT modify code below           #
######################################

if renice_cmd="$(command -v renice)"; then ${renice_cmd} -n 19 $$ >/dev/null; fi

PARENT="$(dirname $0)"
if [[ ! -f "${PARENT}"/env ]]; then
  echo "ERROR: could not find common env file, please run prereqs.sh or manually download"
  exit 1
fi
#if ! . "${PARENT}"/env; then exit 1; fi

# get cardano-tracer log file from TraceOptionNodeName
if ! node_name=$(jq -er '.TraceOptionNodeName | select(type == "string" and length > 0)' "${CONFIG}"); then
  echo -e "${FG_RED}ERROR:${NC} failed to locate TraceOptionNodeName in node configuration file"
  exit 1
fi

logfile="${CNODE_HOME}/logs/${node_name}/node.json"

[[ ! -f "${logfile}" ]] && echo -e "${FG_RED}ERROR:${NC} failed to locate cardano-tracer json logfile\nexpected: ${logfile}" && exit 1

[[ ! -f ${BLOCKLOG_DB} ]] && echo "${FG_RED}ERROR:${NC} blocklog db missing, please run 'cncli.sh init' to create and initialize it" && exit 1

  # source common env variables in case it was updated
  until . "${PARENT}"/env; do
    echo "sleeping for 10s and testing again..."
    sleep 10
  done

echo "~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "~~ LOG MONITOR STARTED ~~"
echo "monitoring ${logfile} for traces"

# Continuously parse cardano-tracer json log file for traces
while read -r logentry; do
  # Traces monitored: TraceNodeIsLeader, TraceAdoptedBlock, TraceForgedInvalidBlock
  case "${logentry}" in
    *TraceNodeIsLeader* )
      if ! at="$(jq -er '.at' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.at' not found" && continue; else at="$(sed -E 's/\.[0-9]+Z$/+00:00/' <<< ${at})"; fi
      if ! slot="$(jq -er '.data.slot' <<< ${logentry})"; then echo "ERROR[TraceNodeIsLeader]: invalid json schema, '.data.slot' not found" && continue; fi
      getNodeMetrics
      [[ ${epochnum} -le 0 ]] && echo "ERROR[TraceNodeIsLeader]: failed to grab current epoch number from node metrics" && continue
      echo "LEADER: epoch[${epochnum}] slot[${slot}] at[${at}]"
      sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (slot,at,epoch,status) values (${slot},'${at}',${epochnum},'leader');"
      ;;
    *TraceAdoptedBlock* )
      if ! slot="$(jq -er '.data.slot' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.slot' not found" && continue; fi
      if ! hash="$(jq -er '.data.blockHash' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.blockHash' not found" && continue; fi
      if ! size="$(jq -er '.data.blockSize' <<< ${logentry})"; then echo "ERROR[TraceAdoptedBlock]: invalid json schema, '.data.blockSize' not found" && continue; fi
      echo "ADOPTED: slot[${slot}] size=${size} hash=${hash}"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'adopted', size = ${size}, hash = '${hash}' WHERE slot = ${slot};"
      ;;
    *TraceForgedInvalidBlock* )
      if ! slot="$(jq -er '.data.slot' <<< ${logentry})"; then echo "ERROR[TraceForgedInvalidBlock]: invalid json schema, '.data.slot' not found" && continue; fi
      json_trace="$(jq -c -r '. | @base64' <<< ${logentry})"
      echo "INVALID: slot[${slot}] - base 64 encoded json trace, run this command to decode:"
      echo "echo ${json_trace} | base64 -d | jq -r"
      sqlite3 "${BLOCKLOG_DB}" "UPDATE blocklog SET status = 'invalid', hash = '${json_trace}' WHERE slot = ${slot};"
      ;;
    * ) : ;; # ignore
  esac
done < <(tail -F -n0 "${logfile}")