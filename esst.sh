#!/bin/bash

#Copyright (c) 2020 bpintea
#
#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:
#
#The above copyright notice and this permission notice shall be included in all
#copies or substantial portions of the Software.
#
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#SOFTWARE.

set -e

MY_NAME="Elasticsearch backed Speedtest probe"
CONFIG_LOCATIONS="/opt/esst/etc/ ."
CONFIG_FILE_NAME=esst.conf
CNT_START=000001

function log()
{
	if [ -t 1 ]; then
		echo "$*"
	else
		logger ${0##*/} ": " "$*"
	fi
}

function die()
{
	log "ERROR: $*"
	exit 1
}

function usage() {
	log $MY_NAME
	log
	log "Usage: $0 <command>"
	log
	log "Commands:"
	log "  install   : install as application."
	log "  uninstall : uninstall this 'application'."
	log "  init      : create the Elasticsearch resources to index measurements"
	log "              into."
	log "  drop      : remove all Elasticsearch resources created to index"
	log "              measurements."
	log "  probe     : run a speedtest measurement and upload it."
	log "  speedtest : run a speedtest measurement and store it temporarily."
	log "  push      : upload any pending measurement into Elasticsearch."
	log

	exit 1
}

# sets CFG_DIR
function load_config()
{
	self_path=$(dirname $(realpath $0))
	locations="$CONFIG_LOCATIONS $self_path/../etc  $self_path"
	for location in $locations; do
		if [ -r $location/$CONFIG_FILE_NAME ]; then
			CFG_DIR=$(realpath $location)
			log "Using config file $CFG_DIR/$CONFIG_FILE_NAME"
			source $CFG_DIR/$CONFIG_FILE_NAME
			return
		fi
	done

	die "no config file found under any of these paths: $CONFIG_LOCATIONS"\
		" (running under: `pwd`)"
}

function check_deps()
{
	function check() {
		if ! which $1 1>/dev/null; then
			die "missing dependency: $1. Is it installed?"
		fi
	}

	which_speedtest
	if ! $SPEEDTEST --help | grep -q -- --json ; then
		die "Speedtest under $SPEEDTEST doesn't support JSON output."
	fi
	log "Will probe with: $($SPEEDTEST --version | grep -v Python)"

	check curl
	check jq
	check bc
	check crontab
}

function timer()
{
	if [ $# -lt 1 ]; then
		return
	fi
	NOW=$(date +%s.%N)
	if [ "$1" == "start" ]; then
		if [ -z "$STARTED_AT" ]; then
			STARTED_AT=$NOW
		fi
	else
		delta=$(bc <<< "$NOW - $STARTED_AT")
		log "Operation run time: $delta sec"
	fi
}

function setup()
{
	load_config
	timer "start"
	trap 'timer "stop"' EXIT
}

function c_url()
{
	url=$1
	verb=$2
	json="$3"

	answer=$(curl -X $verb $url -u $ES_CREDENTIALS -s -S \
			-H 'Content-Type: application/json' \
			--data-binary "$json"  )
	ret_code=$?
	if [ $ret_code -ne 0 ]; then
		log "ERROR: curl'ing failed: $answer"
		return $ret_code
	else
		ack=$(jq '.acknowledged' <<< $answer)
		if [ "$ack" != "true" ]; then
			log "ERROR: $verb operation failed: $answer"
			return 1
		fi
	fi
}

function do_init()
{
	setup
	log "Initializing indexing"

	#
	# PUT pipeline
	#
	url=$ES_HOST_URL/_ingest/pipeline/$ES_PIPELINE_NAME
	json=$(cat $CFG_DIR/pipeline.json | \
			sed  -e '/"""/,/"""/{ s/"\([[:alnum:]]\+\)"/\\"\1\\"/ }' \
				-e 's/"""/"/' | \
			tr '\n' ' ')
	c_url $url PUT "$json" || exit $?

	#
	# PUT ILM policy
	#
	url=$ES_HOST_URL/_ilm/policy/$ES_ILM_POLICY_NAME
	json=$(cat $CFG_DIR/ilm.json | \
			sed -e "s/_ROLL_AFTER_/$ES_ILM_ROLL_AFTER/" \
				-e "s/_DEL_AFTER_/$ES_ILM_DEL_AFTER/")
	c_url $url PUT "$json" || exit $?

	#
	# PUT template
	#
	url=$ES_HOST_URL/_template/$ES_TEMPLATE_NAME
	json=$(cat $CFG_DIR/template.json | \
			sed -e "s/_INDEX_ALIAS_/$ES_ALIAS_NAME/" \
				-e "s/_ILM_POLICY_NAME_/$ES_ILM_POLICY_NAME/")
	c_url $url PUT "$json" || exit $?

	#
	# PUT ILM bootstrapping index
	#
	url=$ES_HOST_URL/$ES_ALIAS_NAME-$CNT_START
	json="{\"aliases\": {\"$ES_ALIAS_NAME\": {\"is_write_index\": true}}}"
	c_url $url PUT "$json" || exit $?
}

function do_drop()
{
	setup
	log "Dropping index data"

	#
	# DELETE pipeline
	#
	url=$ES_HOST_URL/_ingest/pipeline/$ES_PIPELINE_NAME
	c_url $url DELETE || echo "Deleting pipeline $ES_PIPELINE_NAME failed"

	#
	# DELETE template
	#
	url=$ES_HOST_URL/_template/$ES_TEMPLATE_NAME
	c_url $url DELETE || echo "Deleting template $ES_TEMPLATE_NAME failed"

	#
	# DELETE indices
	#
	url=$ES_HOST_URL/$ES_ALIAS_NAME*
	c_url $url DELETE || echo "Deleting aliases $ES_ALIAS_NAME* failed"

	#
	# DELETE ILM policy
	#
	url=$ES_HOST_URL/_ilm/policy/$ES_ILM_POLICY_NAME
	c_url $url DELETE || echo "Deleting ILM policy $ES_ILM_POLICY_NAME failed"
}

function which_speedtest()
{
	# assumes 'load_config' had been called

	if [ -x $SPEEDTEST_BIN_PATH/$SPEEDTEST_BIN_NAME ]; then
		SPEEDTEST=$SPEEDTEST_BIN_PATH/$SPEEDTEST_BIN_NAME
	elif $(which $SPEEDTEST_BIN_NAME 1>/dev/null) ; then
		SPEEDTEST=$(which $SPEEDTEST_BIN_NAME)
	else
		die "No Speedtest executable found. Neither SPEEDTEST_BIN config"\
			"defined, nor '$SPEEDTEST_BIN_NAME' found in path."
	fi
}

function do_speedtest()
{
	setup
	log "Probing started."

	log_file=$(mktemp -u --suffix $LOG_SUFFIX)
	temp_dir=$(dirname $log_file)
	log "logging into file: $log_file"

	which_speedtest

	st_args="--json $SPEEDTEST_ARGS"
	output=$($SPEEDTEST $st_args > $log_file)
	ret_code=$?
	if [ $ret_code -eq 0 ]; then
		echo "{\"index\": {\"_index\" : \"$ES_ALIAS_NAME\"}}" >> \
			$temp_dir/$LOG_SPOOL
		cat $log_file >> $temp_dir/$LOG_SPOOL && rm $log_file
	else
		log "probing failed: $output"
		exit $ret_code
	fi
}

function do_push()
{
	setup
	log "Pushing logs to $ES_HOST_URL"

	temp_file=$(mktemp -u)
	temp_dir=$(dirname $temp_file)
	if [ ! -r $temp_dir/$LOG_SPOOL ]; then
		log "ERROR: no spool file found under '$temp_dir/$LOG_SPOOL'."
		return 1
	fi

	url=$ES_HOST_URL/_bulk?pipeline=$ES_PIPELINE_NAME
	answer=$(curl -X POST $url -u $ES_CREDENTIALS -s -S \
			-H 'Content-Type: application/x-ndjson' \
			--data-binary "@$temp_dir/$LOG_SPOOL")
	ret_code=$?

	if [ $ret_code -ne 0 ]; then
		log "upload failed: $answer"
		exit $ret_code
	fi

	errors=$(jq '.errors' <<< $answer)
	if [ "$errors" != "false" ]; then
		log "ERROR: ingesting failure(s); server answer: '$answer'."
		cat $temp_dir/$LOG_SPOOL >> $temp_dir/$LOG_FAILURES
		echo $answer >> $temp_dir/$LOG_FAILURES
	fi
	rm $temp_dir/$LOG_SPOOL
}

function do_install_files()
{
	pushd . 1>/dev/null
	trap 'popd 1>/dev/null' EXIT
	cd $(dirname $0)

	mkdir -p $INSTALL_DIR/etc
	install -m 0644 *.conf $INSTALL_DIR/etc
	install -m 0644 *.json $INSTALL_DIR/etc

	mkdir -p $INSTALL_DIR/bin
	install $0 $INSTALL_DIR/bin/$(basename ${0/%.sh/})
	
	log "$MY_NAME has been installed under $INSTALL_DIR."
}

function do_uninstall_files()
{
	rm $INSTALL_DIR/etc/*.conf || log "No conf file under $INSTALL_DIR/etc/"
	rm $INSTALL_DIR/etc/*.json || log "No JSON files under $INSTALL_DIR/etc/"
	rmdir $INSTALL_DIR/etc/ || log "No $INSTALL_DIR/etc/ dir found"

	bin_name=$(basename ${0/%.sh/})
	rm $INSTALL_DIR/bin/$bin_name || log "No bin file under $INSTALL_DIR/bin/"
	rmdir $INSTALL_DIR/bin/ || log "No $INSTALL_DIR/bin/ dir found"
	rmdir $INSTALL_DIR || log "No $INSTALL_DIR/ dir found"
	
	log "$MY_NAME has been uninstalled from $INSTALL_DIR."
}

function do_install_cron_job()
{
	esst_bin="$(basename ${0/%.sh/})"
	esst_bin_path="$INSTALL_DIR/bin/$(basename ${0/%.sh/})"

	if crontab -l | grep $esst_bin | grep -q probe ; then
		die "$esst_bin already present in $USER user's cron."
	fi

	cron_line="$CRON_TIMING $esst_bin_path probe"
	(crontab -l 2>/dev/null; echo "$cron_line") | \
		crontab - || die "failed to execute crontab"
	
	log "$MY_NAME has been added to $USER user's cron."
}

function do_uninstall_cron_job()
{
	esst_bin="$(basename ${0/%.sh/})"

	if ! crontab -l | grep $esst_bin | grep -q probe ; then
		log "WARNING: $esst_bin not found in $USER user's cron."
		return
	fi

	(crontab -l 2>/dev/null | sed -e "/.*$esst_bin[[:blank:]]probe.*/d") | \
		crontab - || die "failed to execute crontab"

	log "$MY_NAME has been removed from $USER user's cron."
}

function do_install()
{
	load_config
	check_deps

	if [ -d $INSTALL_DIR ]; then
		die "Install target directory $INSTALL_DIR already present. "\
			"Uninstall first, if this is a re-installation attempt."
	fi

	do_install_files
	do_install_cron_job

	log "$MY_NAME has been succesfully installed."
}

function do_uninstall()
{
	load_config

	if [ ! -d $INSTALL_DIR ]; then
		die "No installation found under $INSTALL_DIR."
	fi

	do_uninstall_files
	do_uninstall_cron_job

	log "$MY_NAME has been succesfully uninstalled."
}


if [ $# -lt 1 ]; then
	usage
fi

case $1 in
	"install")
		do_install
		;;
	"uninstall")
		do_uninstall
		;;
	"init")
		do_init
		;;
	"drop")
		do_drop
		;;
	"probe")
		do_speedtest
		do_push
		;;
	"speedtest")
		do_speedtest
		;;
	"push")
		do_push
		;;
	*)
		usage
		;;
esac

