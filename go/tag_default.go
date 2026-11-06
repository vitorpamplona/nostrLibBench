//go:build !libsecp256k1

package main

// buildTag names the binary this build is: "" for the default build, otherwise the
// suffix of libbench-<buildTag> (see the tag_secp_*.go files and run.sh).
const buildTag = ""
