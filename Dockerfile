
# syntax=docker/dockerfile:1.7

# ============================================================
# Stage 1: Download external binaries
# ============================================================
FROM ubuntu:24.04 AS downloads

ARG TARGETARCH=amd64
ARG TURBOVNC_VERSION=3.2.1
ARG HATCH_VERSION=1.16.2
ARG YQ_VERSION=v4.45.1
ARG JQ_VERSION=jq-1.8.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN set -eux; \
    test "${TARGETARCH}" = "amd64"; \
    curl -fL --retry 3 \
      "https://github.com/TurboVNC/turbovnc/releases/download/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_amd64.deb" \
      -o turbovnc.deb; \
    curl -fL --retry 3 \
      "https://github.com/pypa/hatch/releases/download/hatch-v${HATCH_VERSION}/hatch-x86_64-unknown-linux-gnu.tar.gz" \
      -o hatch.tar.gz; \
    tar -xzf hatch.tar.gz hatch; \
    curl -fL --retry 3 \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
      -o yq; \
    curl -fL --retry 3 \
      "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64" \
      -o jq; \
    chmod 755 hatch yq jq


# ============================================================
# Stage 2: Jupyter EO development environment
# ============================================================
# Python 3.13, Ubuntu 24.04 historical Jupyter build.
# Pin the image by digest after validation.
FROM quay.io/jupyter/base-notebook:ac62373f9f60

USER root

ENV DEBIAN_FRONTEND=noninteractive


# ------------------------------------------------------------
# System dependencies and desktop environment
# ------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      dbus-x11 \
      ca-certificates \
      git \
      wget \
      file \
      tree \
      firefox \
      websockify \
      xfce4 \
      xfce4-panel \
      xfce4-session \
      xfce4-settings \
      xorg \
      xubuntu-icon-theme \
      libtbb12 \
      curl \
      vim \
      software-properties-common \
      gnupg; \
    (apt-get remove -y light-locker || true); \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# Nextcloud Desktop CLI
#
# Required upstream version: 35.0.3
#
# Allow Ubuntu packaging suffixes such as:
#   ~noble1
#   ~jammy1
#
# Fail if no matching package exists.
# ------------------------------------------------------------
ARG NEXTCLOUD_VERSION=35.0.3

RUN set -eux; \
    apt-get update -o Acquire::Retries=5; \
    add-apt-repository -y ppa:nextcloud-devs/client; \
    apt-get update \
      -o Acquire::Retries=5 \
      -o APT::Update::Error-Mode=any; \
    apt-cache madison nextcloud-desktop-cmd; \
    VERSION="$(apt-cache madison nextcloud-desktop-cmd \
      | awk -v v="${NEXTCLOUD_VERSION}" \
        '$3 == v || index($3, v ".") == 1 || \
         index($3, v "+") == 1 || \
         index($3, v "~") == 1 || \
         index($3, v "-") == 1 {print $3}' \
      | sort -V \
      | tail -1)"; \
    if [ -z "$VERSION" ]; then \
      echo "ERROR: Nextcloud Desktop ${NEXTCLOUD_VERSION} is unavailable"; \
      apt-cache policy nextcloud-desktop-cmd; \
      exit 1; \
    fi; \
    echo "Installing nextcloud-desktop-cmd=${VERSION}"; \
    apt-get install -y --no-install-recommends \
      "nextcloud-desktop-cmd=${VERSION}"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# TurboVNC
# ------------------------------------------------------------
COPY --from=downloads \
    /artifacts/turbovnc.deb /tmp/turbovnc.deb

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      /tmp/turbovnc.deb; \
    rm -f /tmp/turbovnc.deb; \
    ln -s /opt/TurboVNC/bin/* /usr/local/bin/; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# Hatch, yq and jq
# ------------------------------------------------------------
COPY --from=downloads \
    /artifacts/hatch /usr/local/bin/hatch

COPY --from=downloads \
    /artifacts/yq /usr/local/bin/yq

COPY --from=downloads \
    /artifacts/jq /usr/local/bin/jq


# ------------------------------------------------------------
# Nextcloud synchronization
# ------------------------------------------------------------
COPY nc-sync /usr/local/bin/nc-sync

COPY nc-sync.desktop \
    /etc/xdg/autostart/nc-sync.desktop

RUN chmod 755 /usr/local/bin/nc-sync


# ------------------------------------------------------------
# Python dependencies
#
# requirements-py313.lock must contain pinned versions.
#
# Fix Conda permissions before installing as NB_USER.
# ------------------------------------------------------------
COPY requirements-py313.lock \
    /tmp/requirements-py313.lock

USER root

RUN set -eux; \
    fix-permissions /opt/conda; \
    fix-permissions "${HOME}"

USER ${NB_USER}

RUN set -eux; \
    /opt/conda/bin/python -m pip install \
      --no-cache-dir \
      -r /tmp/requirements-py313.lock; \
    /opt/conda/bin/python -m pip check


# ------------------------------------------------------------
# websockify native rebind.so
#
# Install after pip so that package upgrades cannot
# overwrite the native integration.
#
# Do not hardcode Python 3.11 site-packages.
# ------------------------------------------------------------
USER root

RUN set -eux; \
    rebind="$(find /usr/lib \
      -path '*/websockify/rebind.so' -print -quit)"; \
    test -n "$rebind"; \
    target="$(/opt/conda/bin/python -c \
      'import site; print(site.getsitepackages()[0])')"; \
    mkdir -p "$target/websockify"; \
    cp "$rebind" "$target/websockify/rebind.so"; \
    cp "$rebind" /opt/conda/lib/rebind.so; \
    chmod 644 \
      "$target/websockify/rebind.so" \
      /opt/conda/lib/rebind.so


# ------------------------------------------------------------
# Runtime EO dependency lock
#
# Used by injected init.sh ConfigMap to create
# /workspace/.venv.
# ------------------------------------------------------------
RUN mkdir -p /opt/eo

COPY requirements-runtime-py313.lock \
    /opt/eo/requirements-runtime-py313.lock

RUN chmod 644 \
    /opt/eo/requirements-runtime-py313.lock


# ------------------------------------------------------------
# Cleanup and permissions
# ------------------------------------------------------------
RUN set -eux; \
    rm -f /tmp/requirements-py313.lock; \
    fix-permissions /opt/conda; \
    fix-permissions "${HOME}"


# ------------------------------------------------------------
# User password (legacy compatibility)
# ------------------------------------------------------------
ARG USERPWD=pass

RUN echo "${NB_USER}:${USERPWD}" | chpasswd


# ------------------------------------------------------------
# Build-time smoke checks
# ------------------------------------------------------------
RUN set -eux; \
    /opt/conda/bin/python -c \
      'import sys; assert sys.version_info[:2] == (3, 13)'; \
    /opt/conda/bin/python -m pip check; \
    hatch --version; \
    yq --version; \
    jq --version; \
    nextcloudcmd --version; \
    test -f /opt/conda/lib/rebind.so


# ------------------------------------------------------------
# Restore standard Jupyter user
# ------------------------------------------------------------
USER ${NB_USER}
