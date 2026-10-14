DEPLOY=deploy/venus
REMOTE=victron_www@updates-origin.victronenergy.com
D=/var/www/victron_www/feeds/venus/
FEED="$REMOTE:$OPKG"

if [ $# -eq 0 ]; then
	echo "Usage: $0 release|candidate|testing"
	exit 1
fi

call() {
	# call ssh to run on a remotely
	ssh $REMOTE "$@"

	# run it locally instead for testing
	# eval "$@"
}

function release ()
{
	from="$D$1"
	to="$D$2"
	exclude=""
	# Set this to only release large images. Note: it will rsync all packages.
	# exclude="--include=images/* --include='images/*/venus-swu-*large-*' --include='images/*/venus-image-*large-*' --exclude=images/*/*"
	args="-v"

	echo $from $to
	call "if [ ! -d $to ]; then mkdir $to; fi"

	if [ "$2" = "release" ]; then
		exclude="$exclude --exclude=images/ccgx/venus-swu-ccgx.swu"
	fi

	# upload the files
	call "rsync $args $exclude -rpt --no-links $from/ $to"

	# thereafter update the symlinks and in the end delete the old files
	call "rsync $args $exclude -rptl $from/ $to"

	# keep all released images
	if [ "$2" = "release" ]; then
		exclude="$exclude --exclude=images/"
	fi

	call "rsync $args $exclude -rpt --delete $from/ $to"
}

# publish the containers in a feed to the registries, see container_release.sh; do
# this before promoting the feed, so the GUI never offers an image that the
# registries don't have yet
function publish_containers ()
{
	(
		set -e
		mkdir -p deploy
		dir=$(mktemp -d deploy/containers-$1.XXXXXX)
		trap 'rm -r $dir' EXIT
		for machine in container-amd64 container-arm64 container-armv7; do
			mkdir $dir/$machine
			rsync -L $REMOTE:$D$1/images/$machine/venus-container-version $dir/$machine/
			rsync -L $REMOTE:$D$1/images/$machine/venus-$machine.tar $dir/$machine/
		done
		./container_release.sh $2 $dir
	) || {
		echo "ERROR: containers not published, feeds not changed"
		exit 1
	}
}

case $1 in
	release )
		echo "Candidate -> Release"
		publish_containers candidate release
		release candidate release
		;;
	backup )
		echo "Candidate -> Backup"
		release candidate backup
		;;
	candidate )
		echo "Testing -> Candidate"
		publish_containers testing beta
		release testing candidate
		;;
	testing )
		echo "Develop -> Testing"
		release develop testing
		;;
	skip-candidate )
		echo "Testing -> Release (skips candidate!)"
		read -n1 -r -p "Press any key to continue... Or CTRL-C to abort"
		publish_containers testing release
		release testing release
		;;
	skip-testing )
		echo "Develop -> Candidate (skips testing!)"
		read -n1 -r -p "Press any key to continue... Or CTRL-C to abort"
		publish_containers develop beta
		release develop candidate
		;;
	*)
		echo "Not a valid parameter"
		;;
esac
