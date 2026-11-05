# Self-contained MOD Dwarf cross-build environment.
#
# Thin vendoring of mod-plugin-builder's docker/Dockerfile, hard-locked to
# the moddwarf-new platform. The image internally clones mod-plugin-builder
# and runs its bootstrap, which builds a buildroot-based aarch64 cross-
# toolchain targeting glibc 2.27 + gcc 9.4.0 — matching the Dwarf firmware.
#
# First-time `docker build` takes ~30-60 min (most of it bootstrapping the
# cross-toolchain via crosstool-ng). After that the image is cached and
# every `dwarf-build` is ~10 s.
#
# This file is deliberately a near-verbatim copy of upstream MPB's
# Dockerfile, so resyncing with future upstream changes is just `diff +
# cherry-pick`. Do not refactor cosmetically.
#
# Upstream:
#   https://github.com/moddevices/mod-plugin-builder/blob/main/docker/Dockerfile
FROM debian:bookworm
ENV DEBIAN_FRONTEND=noninteractive

# Hard-locked to moddwarf-new (current Dwarf hardware). If you ever need
# modduo / modduox / etc., the upstream Dockerfile is parameterised — copy
# more of its conditional logic.
ARG platform=moddwarf-new
ARG target=full

# Enable foreign architectures used during the buildroot bootstrap
RUN dpkg --add-architecture i386 && \
    dpkg --add-architecture armhf && \
    dpkg --add-architecture arm64

# System upgrade
RUN apt-get update && apt-get upgrade -qqy && apt-get clean

# All packages buildroot + the MPB bootstrap need
RUN apt-get install -qqy qemu-user-static && \
    apt-get install -qqy libc6:i386 libstdc++6:i386 zlib1g:i386 && \
    apt-get install -qqy libc6:armhf libstdc++6:armhf zlib1g:armhf && \
    apt-get install -qqy libc6:arm64 libstdc++6:arm64 zlib1g:arm64 && \
    apt-get install -qqy locales acl bash bash-completion bc curl cvs git mercurial rsync subversion sudo wget dosfstools && \
    apt-get install -qqy bison bundler bzip2 cpio flex gawk gperf gzip help2man nano perl patch tar texinfo unzip && \
    apt-get install -qqy python-is-python3 python3-dev python3-setuptools && \
    apt-get install -qqy automake binutils build-essential device-tree-compiler premake4 sunxi-tools libtool-bin ncurses-dev jq && \
    apt-get install -qqy libfreetype6-dev libx11-dev libxcursor-dev libxinerama-dev libxrandr-dev pkg-config && \
    apt-get clean

# Old premake required by some buildroot recipes
RUN if test "$(dpkg-architecture -qDEB_TARGET_ARCH)" = "arm64"; then \
        wget http://ports.ubuntu.com/ubuntu-ports/pool/universe/p/premake/premake_3.7-1_arm64.deb && \
        dpkg -i premake_3.7-1_arm64.deb && \
        rm premake_3.7-1_arm64.deb; \
    else \
        wget http://archive.ubuntu.com/ubuntu/pool/universe/p/premake/premake_3.7-1_amd64.deb && \
        dpkg -i premake_3.7-1_amd64.deb && \
        rm premake_3.7-1_amd64.deb; \
    fi

RUN locale-gen en_US.UTF-8
RUN echo "source /etc/bash_completion" >> /root/.bashrc

# Rust toolchain — not used by most plugins (assume pure C++/DPF) but
# kept because the MPB bootstrap script touches rustc for some packages
# and diverging here breaks resync.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | bash -s -- -y --no-modify-path --profile minimal
RUN ~/.cargo/bin/rustup target add aarch64-unknown-linux-gnu
RUN ~/.cargo/bin/rustup install nightly
RUN ~/.cargo/bin/rustup target add aarch64-unknown-linux-gnu --toolchain nightly

ENV MPB_GIT_URL=https://github.com/moddevices/mod-plugin-builder
ENV CT_ALLOW_BUILD_AS_ROOT_SURE=y

# Clone MPB and build the cross-toolchain. After this step the image
# contains a fully-built aarch64 toolchain at
#   /root/mod-workdir/moddwarf-new/host/usr/bin/aarch64-modaudio-linux-gnu-*
# along with the matching sysroot at
#   /root/mod-workdir/moddwarf-new/host/usr/aarch64-buildroot-linux-gnu/sysroot/
# — that's the part we actually care about; the rest of buildroot's output
# is just collateral.
WORKDIR /root
RUN git clone $MPB_GIT_URL
WORKDIR mod-plugin-builder
RUN ./bootstrap.sh $platform $target && ./.clean-install.sh $platform

# Default WORKDIR for the `docker run` invocations done by our Makefile
WORKDIR /work

CMD ["bash"]
