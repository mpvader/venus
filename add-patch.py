#!/usr/bin/python3

# Adds a patch to the end of the SRC_URI of a recipe, as one line. recipetool
# setvar can do that as well, but rewrites the SRC_URI to another layout.

import os, re, sys

if len(sys.argv) != 3:
	sys.exit("usage: add-patch.py recipe.bb patch")

bbfile = sys.argv[1]
item = "file://" + os.path.basename(sys.argv[2])

with open(bbfile) as fh:
	lines = fh.read().split("\n")

if any(item in line for line in lines):
	sys.exit(f"{bbfile} already has {item}")

by_hand = f"{bbfile}: add {item} by hand, its SRC_URI is not supported"

assigns = [n for n, line in enumerate(lines) if re.match(r'SRC_URI\b(?!\[)', line)]
if not assigns or not all(re.match(r'SRC_URI \+?= "', lines[n]) for n in assigns):
	sys.exit(by_hand)

last = assigns[-1]
if re.fullmatch(r'[^"]*"[^"\\]*"', lines[last]):
	lines.insert(last + 1, f'SRC_URI += "{item}"')
else:
	# A list: it must end with a " on its own line.
	end = next((n for n in range(last + 1, len(lines)) if '"' in lines[n]), last)
	if lines[end].strip() != '"' or end == last + 1:
		sys.exit(by_hand)
	indent = re.match(r'\s*', lines[end - 1])[0]
	lines.insert(end, f"{indent}{item} \\")

with open(bbfile, "w") as fh:
	fh.write("\n".join(lines))
