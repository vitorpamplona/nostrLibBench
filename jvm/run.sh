#!/usr/bin/env bash
#
# nostrLibBench JVM harness: builds the Gradle project in jvm/ from the pinned versions
# (gradle/libs.versions.toml + gradle.lockfile) and runs it with the HARNESS.md flags.
#
#   ./jvm/run.sh --relay ws://127.0.0.1:7777          # every client -> results/jvm.json
#   ./jvm/run.sh --quick                              # smoke run
#   ./jvm/run.sh --clients quartz-nostrclient --workloads all,notes
#   ./jvm/run.sh --list
#
# The installed `libbench` script carries the JVM flags (-Xmx2g -XX:+UseG1GC); the parent
# process forks one child JVM per client with those same flags. Extra JVM flags can be
# passed through JAVA_OPTS.
#
# Gradle itself runs on JDK 21 (JAVA_HOME, or the `java` on PATH); the code is compiled to
# Java 27 bytecode with a JDK 27 toolchain and runs on JDK 27: JDK27_HOME=<jdk>, else the first
# JDK 27 found below. BENCH_JAVA_HOME=<jdk> runs the benchmark on another JDK (27 or newer).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [[ -z "${JAVA_HOME:-}" ]]; then
    for jdk in /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/temurin-21-jdk-amd64; do
        if [[ -x "$jdk/bin/java" ]]; then
            export JAVA_HOME="$jdk"
            break
        fi
    done
fi

if [[ -z "${JDK27_HOME:-}" ]]; then
    for jdk in /usr/lib/jvm/java-27-openjdk-amd64 /usr/lib/jvm/java-27-openjdk /usr/lib/jvm/temurin-27-jdk-amd64 "$HOME/.jdks/jdk-27"; do
        if [[ -x "$jdk/bin/java" ]]; then
            JDK27_HOME="$jdk"
            break
        fi
    done
fi
if [[ -z "${JDK27_HOME:-}" ]]; then
    echo "jvm: needs a JDK 27 (set JDK27_HOME)" >&2
    exit 1
fi

# QUARTZ_DIR=<vitorpamplona/quartz checkout> benchmarks that checkout's Quartz instead of the release.
QUARTZ_ARGS=()
if [[ -n "${QUARTZ_DIR:-}" ]]; then
    QUARTZ_ARGS=("-PquartzDir=$(cd "$QUARTZ_DIR" && pwd)")
fi
if ! (cd "$HERE" && ./gradlew -q installDist "-Porg.gradle.java.installations.paths=$JDK27_HOME" "${QUARTZ_ARGS[@]+"${QUARTZ_ARGS[@]}"}"); then
    echo "jvm: build failed" >&2
    exit 1
fi
BIN="$HERE/build/install/libbench/bin/libbench"

export JAVA_HOME="${BENCH_JAVA_HOME:-$JDK27_HOME}"
# Child JVMs' stdout (libraries that print) lands here.
export JAVA_OPTS="${JAVA_OPTS:-} -Dlibbench.logDir=$HERE/build/logs"

# Defaults are absolute so the launcher works from any directory; flags given on the
# command line come later and win.
cd "$ROOT"
exec "$BIN" \
    --corpus "$ROOT/.corpus" \
    --out "$ROOT/results/jvm.json" \
    "$@"
