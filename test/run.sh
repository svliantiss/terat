#!/bin/sh
# Fresh-environment tests for terat, in containers.
#
# The point is to run terat the way a new machine would: an empty home, no
# ~/.zshrc, no config, nothing inherited from the machine it was written on.
# Every claim is read back from inside the container rather than assumed.
#
#   sh test/run.sh                  # all distros
#   sh test/run.sh debian alpine    # a subset
#   DISTROS="alpine" sh test/run.sh
#
# Requires docker. Images are built on first use and cached.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
src=$here/.src

# Distro matrix: different libc, awk, zsh versions and package managers.
distros=${DISTROS:-"debian ubuntu fedora alpine amazon bullseye arch"}
[ "$#" -gt 0 ] && distros=$*

build_base() {
	cat <<'EOF'
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git zsh procps coreutils gawk grep sed \
      findutils less tmux \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /usr/bin/zsh testuser
USER testuser
WORKDIR /home/dev
EOF
}

# One image per distro, each with zsh + tmux + the basics terat shells out to.
build_distro() {
	case $1 in
	debian)   base=debian:bookworm-slim; pkgs='apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zsh tmux coreutils procps curl ca-certificates gawk && rm -rf /var/lib/apt/lists/*' ;;
	ubuntu)   base=ubuntu:24.04;    pkgs='apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zsh tmux coreutils procps curl ca-certificates gawk && rm -rf /var/lib/apt/lists/*' ;;
	fedora)   base=fedora:41;       pkgs='dnf install -y zsh tmux procps-ng curl gawk && dnf clean all' ;;
	alpine)   base=alpine:3.20;     pkgs='apk add --no-cache zsh tmux coreutils procps curl gawk util-linux-misc' ;;
	# curl conflicts with the preinstalled curl-minimal; it is only for tracing.
	amazon)   base=amazonlinux:2023; pkgs='dnf install -y zsh tmux procps-ng gawk && dnf clean all' ;;
	# bullseye-security 404s (EOL archive), so that source is dropped: this
	# image exists to test zsh 5.8, the oldest version likely to be met.
	# Use echo, not a printf escape: the \n inside a Dockerfile RUN line is
	# interpreted by the shell writing the file, which splits the instruction.
	bullseye) base=debian:bullseye; pkgs='echo deb http://deb.debian.org/debian bullseye main > /etc/apt/sources.list && apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zsh tmux coreutils procps gawk && rm -rf /var/lib/apt/lists/*' ;;
	# x86_64 only: run with --platform linux/amd64 under emulation.
	arch)     base=archlinux:latest; pkgs='sed -i "s/^#DisableSandbox.*/DisableSandbox/" /etc/pacman.conf 2>/dev/null; pacman -Sy --noconfirm --disable-sandbox zsh tmux procps-ng coreutils gawk' ;;
	*) return 1 ;;
	esac
	plat=''
	[ "$1" = arch ] && plat='--platform linux/amd64'
	{
		echo "FROM $base"
		echo "RUN $pkgs"
		echo 'RUN command -v tmux >/dev/null || echo NO_TMUX'
		echo 'RUN (useradd -m -s /usr/bin/zsh testuser || adduser -D -s /usr/bin/zsh testuser) 2>/dev/null || true'
		echo 'USER testuser'
		echo 'WORKDIR /home/dev'
	} >"$here/.D.$1"
	# Keep the log: a silently skipped distro looks like a pass.
	# shellcheck disable=SC2086
	docker build $plat -f "$here/.D.$1" -t "terat-test-$1:1" "$here" \
		>"$here/.build.log" 2>&1
}

platform() { [ "$1" = arch ] && echo '--platform linux/amd64'; }

fail=0
printf '%-10s %s\n' DISTRO RESULT
mkdir -p "$src"
( cd "$root" && tar cf - --exclude=.git --exclude=.env --exclude=test . 2>/dev/null ) |
	( cd "$src" && tar xf - )

for d in $distros; do
	printf '%-10s ' "$d"
	if ! build_distro "$d"; then
		printf 'SKIP (build failed)\n'
		grep -iE 'error|E: ' "$here/.build.log" 2>/dev/null | head -3 | sed 's/^/           /'
		continue
	fi
	# shellcheck disable=SC2046
	out=$(docker run --rm $(platform "$d") \
		-v "$src":/src:ro \
		-v "$here/check.sh":/check.sh:ro \
		"terat-test-$d:1" sh /check.sh 2>&1)
	if printf '%s' "$out" | grep -q '^RESULT=PASS'; then
		printf 'OK    %s\n' "$(printf '%s' "$out" | sed -n 's/^  zsh=//p')"
	else
		printf 'FAIL\n'
		printf '%s\n' "$out" | grep -E '^  FAIL' | head -4
		fail=1
	fi
done
rm -rf "$src" "$here"/.D.* "$here/.build.log" 2>/dev/null
[ "$fail" -eq 0 ] || exit 1
