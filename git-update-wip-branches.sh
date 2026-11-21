#!/bin/sh

branch=`git rev-parse --abbrev-ref HEAD`

if [ "$branch" != "$checkout_branch" ]; then
	src="sources/$(basename $PWD)"

	# The builder reads a private fork with its ssh key, hence an ssh url.
	url=
	pushed=`git for-each-ref --points-at HEAD --format=' %(refname:lstrip=2)' "refs/remotes/*/$branch"`
	case "$pushed" in
	"") echo "WARNING: $src: $branch is not pushed" ;;
	*" origin/$branch"*) ;;
	*) url=`git remote get-url ${pushed%%/*} | sed -e 's,^[a-z]*://,,' -e 's,^[^/@]*@,,' -e 's,[:/],:,' -e 's,^,git@,'` ;;
	esac

	echo "branch changed $src $checkout_branch => $branch $url"
	for conf in $(find ../../configs -name repos.conf); do
		# change the branch to the current WIP branches, but only if the checkout-branches where equal in the first place
		awk -v src=$src -v checkout_branch=$checkout_branch -v branch=$branch -v url=$url '$1==src && $5==checkout_branch {if (url) $2=url; $5=branch}1' $conf > tmp && mv tmp $conf
	done
fi


