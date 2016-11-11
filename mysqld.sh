#!/bin/bash
#
# This script tries to start mysqld with the right parameters to join an existing cluster
# or create a new one if the old one cannot be joined
#

LOG_MESSAGE="mysqld.sh:"
OPT="$@"

function do_install_db {
	if ! test -d /var/lib/mysql/mysql; then
		echo "${LOG_MESSAGE} Initializing MariaDb data directory..."
		if ! mysql_install_db; then
			echo "${LOG_MESSAGE} Failed to initialized data directory. Will hope for the best..."
			return 1
		fi
	fi
	return 0
}

function check_nodes {
	for node in ${1//,/ }; do
		[ "$node" = "$2" ] && continue
		if curl -f -s -o - http://$node:8081 && echo; then
			echo "${LOG_MESSAGE} Node at $node is healthy!"
			return 0
		fi
	done
	return 1
}

if [[ "$OPT" =~ /--wsrep-new-cluster/ ]]
then
	# --wsrep-new-cluster is used for the "seed" command so no recovery used
	echo "${LOG_MESSAGE} Starting a new cluster..."
	do_install_db

elif ! test -f /var/lib/mysql/ibdata1
then
	# Skip recovery on empty data directory
	echo "${LOG_MESSAGE} No ibdata1 found, starting a fresh node..."
	do_install_db

else
	# Try to recover state from grastate.dat or logfile
	POSITION=''
	if ! test -f /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Missing grastate.dat file..."
	elif ! grep -q 'seqno:' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Invalid grastate.dat file..."
	elif grep -q '00000000-0000-0000-0000-000000000000' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} uuid is not known..."
	else
		uuid=$(awk '/^uuid:/{print $2}' /var/lib/mysql/grastate.dat)
		seqno=$(awk '/^seqno:/{print $2}' /var/lib/mysql/grastate.dat)
		if [ "$seqno" = "-1" ]; then
			echo "${LOG_MESSAGE} uuid is known but seqno is not..."
		elif [ -n "$uuid" ] && [ -n "$seqno" ]; then
			POSITION="$uuid:$seqno"
			echo "${LOG_MESSAGE} Recovered position from grastate.dat: $POSITION"
		else
			echo "${LOG_MESSAGE} The grastate.dat file appears to be corrupt:"
			echo "##########################"
			cat /var/lib/mysql/grastate.dat
			echo "##########################"
		fi
	fi

	if [[ -z $POSITION ]]; then
		echo "${LOG_MESSAGE} --------------------------------------------------"
		echo "${LOG_MESSAGE} Attempting to recover GTID positon..."

		tmpfile=$(mktemp -t wsrep_recover.XXXXXX)
		mysqld  --wsrep-on=ON \
				--wsrep_sst_method=skip \
				--wsrep_cluster_address=gcomm:// \
				--skip-networking \
				--wsrep-recover 2> $tmpfile
		if [ $? -ne 0 ]; then cat $tmpfile; else grep 'WSREP' $tmpfile; fi
		echo "${LOG_MESSAGE} --------------------------------------------------"

		POSITION=$(sed -n 's/.*WSREP: Recovered position:\s*//p' $tmpfile)
		rm -f $tmpfile
	fi

	if [[ -f /var/lib/mysql/wsrep-new-cluster ]]
	then
		# Flag file indicating new cluster needed, possibly easier than using "seed" in some cases
		echo "${LOG_MESSAGE} Starting a new cluster (because of flag file)..."
		rm -f /var/lib/mysql/wsrep-new-cluster
		do_install_db
		START="--wsrep-new-cluster"
		[[ -n $POSITION ]] && START="--wsrep_start_position=$POSITION $START"

	elif [[ -z $POSITION ]]
	then
		# If unable to find position then something is really wrong and cluster is possibly corrupt
		echo "${LOG_MESSAGE} We found no wsrep position!"
		echo "${LOG_MESSAGE} Refusing to start since something is seriously wrong.."
		echo "${LOG_MESSAGE} Touch /var/lib/mysql/wsrep-new-cluster to force a node to start a new cluster."
		echo "${LOG_MESSAGE} "
		echo "${LOG_MESSAGE}       VvVvVv         "
		echo "${LOG_MESSAGE}       |-  -|    //   "
		echo "${LOG_MESSAGE}  <----|O  O|---<<<   "
		echo "${LOG_MESSAGE}       |  D |    \\\\ "
		echo "${LOG_MESSAGE}       | () |         "
		echo "${LOG_MESSAGE}        \\__/         "
		echo "${LOG_MESSAGE} "
		exit 1

	else
		# Communicate to other nodes to find if there is a Primary Component and if not
		# figure out who has the highest recovery position to be the bootstrapper
		NODE_ADDRESS=$(<<<$OPT sed -E 's#.*--wsrep_node_address=([0-9\.]+):4567.*#\1#')
		GCOMM=$(<<<$OPT sed -E 's#.*gcomm://([0-9\.,]+)\s+.*#\1#')
		LISTEN_PORT=3309

		# Use the galera-healthcheck server to determine if a healthy node exists
		if check_nodes $GCOMM $NODE_ADDRESS
		then
			echo "${LOG_MESSAGE} Found a healthy node! Attempting to join..."
			START="--wsrep_start_position=$POSITION"
		fi

		EXPECT_NODES=3 # Ideally we have a three-node cluster. This will be adjusted down to 2 later
		VIEW_ID=''
		if [[ -f /var/lib/mysql/gvwstate.dat ]]
		then
			# gvwstate.dat is only useful if all nodes have the same view so we will check
			VIEW_ID=$(</var/lib/mysql/gvwstate.dat awk '/^view_id:/{print $2 " " $3 " " $4}')
			GVW_MEMBERS=$(</var/lib/mysql/gvwstate.dat grep '^member:' | wc -l)
			echo "${LOG_MESSAGE} Found view from gvwstate.dat with ($GVW_MEMBERS) members: $VIEW_ID"
			if [[ $GVW_MEMBERS -gt $EXPECT_NODES ]]; then
				EXPECT_NODES=$GVW_MEMBERS
			fi
		fi
		if [[ $(<<<${GCOMM//,/ } wc -w) -gt $EXPECT_NODES ]]; then
			EXPECT_NODES=$(<<<${GCOMM//,/ } wc -w)
		fi
		EXPECT_NODES=$((EXPECT_NODES - 1)) # Exclude self

		# If no healthy node is running then collect uuid:seqno from other nodes and
		# use them to determine which node should do the bootstrap
		echo "${LOG_MESSAGE} Collecting grastate.dat and gvwstate.dat info from other nodes..."
		set -m
		tmpfile=$(mktemp -t socat.XXXX)
		socat -u TCP-LISTEN:$LISTEN_PORT,bind=$NODE_ADDRESS,fork OPEN:$tmpfile,append &
		PID_SERVER=$!

		# Send uuid:seqno to other nodes - every 5 seconds for 3 minutes or until all nodes reached
		SENT_NODES=''
		for i in {36..0}; do
			for node in ${GCOMM//,/ }; do
				[[ $node = $NODE_ADDRESS ]] && continue
				if socat - TCP:$node:$LISTEN_PORT <<< "seqno:$NODE_ADDRESS:$POSITION"; then
					SENT_NODES="$SENT_NODES,$node"
				fi
				if [[ -n $VIEW_ID ]]; then
					socat - TCP:$node:$LISTEN_PORT <<< "view:$NODE_ADDRESS:$VIEW_ID"
				fi
			done
			if   [[ $EXPECT_NODES -eq $(<$tmpfile awk -F: '/^seqno:/{print $2}' | sort -u | wc -w) ]] \
			  && [[ $EXPECT_NODES -eq $(<<<$SENT_NODES tr ',' '\n' | sort -u | wc -w) ]]
			then
				echo "${LOG_MESSAGE} Completed communication with $EXPECT_NODES other nodes."
				break
			fi
			if check_nodes $GCOMM $NODE_ADDRESS; then
				break
			fi
			if [[ $i -eq 24 ]]; then
				echo "${LOG_MESSAGE} Could not communicate with at least $EXPECT_NODES other nodes and no nodes are up..."
				if [[ $EXPECT_NODES -gt 1 ]]; then
					EXPECT_NODES=$((EXPECT_NODES - 1))
					echo "${LOG_MESSAGE} Reducing expected nodes to $EXPECT_NODES after having waited for one minute..."
				fi
			elif [[ $i -eq 0 ]]; then
				echo "${LOG_MESSAGE} Could not communicate with at least $EXPECT_NODES other nodes and no nodes are up... Giving up!"
				echo "${LOG_MESSAGE} Touch /var/lib/mysql/wsrep-new-cluster to force a node to start a new cluster."
				exit 1
			fi
			sleep 5
		done
		kill $PID_SERVER
		set +m

		# We now have a collection of lines for all running nodes with lines like:
		#   seqno:<ip>:<uuid>:<seqno>
		#   view:<ip>:<view_id>

		if check_nodes $GCOMM $NODE_ADDRESS
		then
			# Check once more for healthy nodes in case one came up while we were waiting
			echo "${LOG_MESSAGE} Found a healthy node, attempting to join..."
			START="--wsrep_start_position=$POSITION"
			if test -f /var/lib/mysql/gvwstate.dat; then
				rm -f /var/lib/mysql/gvwstate.dat
				echo "${LOG_MESSAGE} Deleted gvwstate.dat"
			fi

		elif ! [[ -s $tmpfile ]]
		then
			# Did not receive communication from other nodes, starting a new cluster
			echo "${LOG_MESSAGE} No communication received from other nodes, starting a new cluster..."
			START="--wsrep_start_position=$POSITION --wsrep-new-cluster"

		elif [[ -n $VIEW_ID ]]
		then
			# If all nodes have consistent views then we will maybe use gvwstate.dat to restore previous state
			NUM_VIEWS=$(<$tmpfile awk -F: "BEGIN{print \"$VIEW_ID\"} /^view:/{print \$3}" | sort -u | wc -l)
			if [ $NUM_VIEWS -eq 1 ]
			then
				echo "${LOG_MESSAGE} Cluster has one view, checking presence of all members..."
				LOCAL_MEMBERS=$(grep '^member:' /var/lib/mysql/gvwstate.dat | wc -l)
				TOTAL_MEMBERS=$(grep '^view:' $tmpfile | sort -u | wc -l)
				TOTAL_MEMBERS=$((TOTAL_MEMBERS + 1)) # Add 1 for self
				if [[ $LOCAL_MEMBERS -eq $TOTAL_MEMBERS ]]; then
					# Entire cluster was shut down and restarted at once, will restore old Primary Component
					echo "${LOG_MESSAGE} gvwstate.dat file appears valid on all nodes"
					TOTAL_SEQNOS=$(<$tmpfile awk -F: "BEGIN{print \"$POSITION\"} /^seqno:/{print \$3 \":\" \$4}" | sort -u | wc -l)
					if [[ $TOTAL_SEQNOS -eq 1 ]]; then
						echo "${LOG_MESSAGE} All nodes have same seqno so using gvwstate.dat"
						START="--wsrep_start_position=$POSITION"
					else
						echo "${LOG_MESSAGE} Will not use gvwstate because mis-matching seqnos would cause SST"
					fi
				else
					# Not all members are present so PC cannot be restored
					echo "${LOG_MESSAGE} Not all members are present"
					rm /var/lib/mysql/gvwstate.dat
				fi
			else
				echo "${LOG_MESSAGE} Cluster has more than one view, deleting gvwstate.dat"
				rm /var/lib/mysql/gvwstate.dat
			fi
		fi

		if [[ -z $START ]]
		then
			# Otherwise we will start a new Primary Component with the best node
			MY_SEQNO=${POSITION#*:}
			BEST_SEQNO=$(<$tmpfile awk -F: '/^seqno:/{print $4}' | sort -nu | tail -n 1)
			if [ "$MY_SEQNO" -gt "$BEST_SEQNO" ]; then
				# This node is newer than all the others, start a new cluster
				echo "${LOG_MESSAGE} This node is newer than all the others. Starting a new cluster..."
				START="--wsrep_start_position=$POSITION --wsrep-new-cluster"
			elif [ "$MY_SEQNO" -lt "$BEST_SEQNO" ]; then
				# This node is older than another node, be a joiner
				echo "${LOG_MESSAGE} This node is older than another node. Will be a joiner..."
				START="--wsrep_start_position=$POSITION"
				sleep 30
			else
				# This and another node or nodes are the newest, lowest IP wins
				LOWEST_IP=$(<$tmpfile awk -F: "/:$BEST_SEQNO$/{print \$2}" | sort -u | head -n 1)
				if [ "$NODE_ADDRESS" \< "$LOWEST_IP" ]; then
					echo "${LOG_MESSAGE} This node is equal to the most advanced and has the lowest IP. Starting a new cluster..."
					START="--wsrep_start_position=$POSITION --wsrep-new-cluster"
				else
					echo "${LOG_MESSAGE} This node is the most advanced but another node ($LOWEST_IP) has a lower IP. Will be a joiner..."
					START="--wsrep_start_position=$POSITION"
					sleep 30
				fi
			fi
		fi
	fi
fi

# Start mysqld
echo "${LOG_MESSAGE} ----------------------------------"
echo "${LOG_MESSAGE} Starting with options: $OPT $START"
exec mysqld $OPT $START

