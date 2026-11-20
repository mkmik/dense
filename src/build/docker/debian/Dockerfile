ARG DISTRO_VERSION="13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6"
FROM docker.io/library/debian:${DISTRO_VERSION}

# Install Dependencies
RUN DEBIAN_FRONTEND="noninteractive" apt-get -qq update && \
    apt-get -qq -y --no-install-recommends install \
    # Build Tools
    blueprint-compiler \
    build-essential \
    curl \
    libbz2-dev \
    libonig-dev \
    libxml2-utils \
    lintian \
    lsb-release \
    libxml2-utils \
    pandoc \
    # Ghostty Dependencies
    libadwaita-1-dev \
    libgtk-4-dev \
    libgtk4-layer-shell-dev && \
    # Clean up for better caching
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY ./build.zig ./build.zig.zon /src/

# Install zig
# https://ziglang.org/download/

RUN export ZIG_VERSION=$(sed -n -E 's/^\s*\.?minimum_zig_version\s*=\s*"([^"]+)".*/\1/p' build.zig.zon) && curl -L -o /tmp/zig.tar.xz "https://ziglang.org/download/$ZIG_VERSION/zig-$(uname -m)-linux-$ZIG_VERSION.tar.xz" && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    rm /tmp/zig.tar.xz && \
    ln -s "/opt/zig-$(uname -m)-linux-$ZIG_VERSION/zig" /usr/local/bin/zig

COPY . /src

RUN zig build \
    -Doptimize=Debug \
    -Dcpu=baseline

RUN ./zig-out/bin/ghostty +version
