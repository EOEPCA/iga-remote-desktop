
# syntax=docker/dockerfile:1.7

# ============================================================
# Stage 1: Download verified external binaries
# ============================================================
FROM ubuntu:24.04 AS downloads

ARG TARGETARCH=amd64

ARG TURBOVNC_VERSION=3.2.1
#TODO evaluate turbovc 3.3.1
ARG YQ_VERSION=v4.54.3
ARG JQ_VERSION=jq-1.8.2

# Verified yq Linux amd64 release SHA256
ARG YQ_SHA256=129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN set -eux; \
    test "${TARGETARCH}" = "amd64"; \
    curl -fL --retry 5 --retry-delay 2 \
      "https://github.com/TurboVNC/turbovnc/releases/download/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_amd64.deb" \
      -o turbovnc.deb; \
    curl -fL --retry 5 --retry-delay 2 \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
      -o yq; \
    echo "${YQ_SHA256}  yq" | sha256sum -c -; \
    curl -fL --retry 5 --retry-delay 2 \
      "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64" \
      -o jq; \
    chmod 755 yq jq


# ============================================================
# Stage 2: Jupyter EO development environment
# ============================================================
# Ubuntu 24.04 LTS / Python 3.13
#
# Retained for compatibility with:
# - Nextcloud Ubuntu PPA
# - XFCE
# - Existing Jupyter environment
#
# Pin by digest after successful validation.
# ============================================================
FROM quay.io/jupyter/base-notebook:ac62373f9f60

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

# ------------------------------------------------------------
# System packages and desktop environment
# ------------------------------------------------------------
RUN set -eux; \
    apt-get update -o Acquire::Retries=5; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      dbus-x11 \
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
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# Nextcloud Desktop CLI
#
# Preserve version 35.0.3.
# Fail if no matching version is available.
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
      echo "ERROR: Nextcloud ${NEXTCLOUD_VERSION} unavailable"; \
      apt-cache policy nextcloud-desktop-cmd; \
      exit 1; \
    fi; \
    apt-get install -y --no-install-recommends \
      "nextcloud-desktop-cmd=${VERSION}"; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# TurboVNC
#
# Keep verified existing package URL.
# Upgrade to 3.3.1 after validating the .deb asset.
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
# Verified yq and jq binaries
# ------------------------------------------------------------
COPY --from=downloads \
    --chmod=755 \
    /artifacts/yq /usr/local/bin/yq

COPY --from=downloads \
    --chmod=755 \
    /artifacts/jq /usr/local/bin/jq


# ------------------------------------------------------------
# Nextcloud synchronization
# ------------------------------------------------------------
COPY --chmod=755 nc-sync \
    /usr/local/bin/nc-sync

COPY --chmod=644 nc-sync.desktop \
    /etc/xdg/autostart/nc-sync.desktop


# ------------------------------------------------------------
# Python dependencies
#
# Preserve pinned project dependency lock.
# Install as NB_USER after fixing Conda permissions.
# ------------------------------------------------------------
COPY --chmod=644 requirements-py313.lock \
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
# Hatch 1.18.2
#
# Use Python package distribution rather than an
# unverified standalone executable.
#
# This may update shared Python dependencies, so
# run pip check and test Jupyter compatibility.
# ------------------------------------------------------------
ARG HATCH_VERSION=1.18.2

RUN set -eux; \
    /opt/conda/bin/python -m pip install \
      --no-cache-dir \
      "hatch==${HATCH_VERSION}"; \
    /opt/conda/bin/python -m pip check; \
    hatch --version


# ------------------------------------------------------------
# websockify native rebind.so
#
# Copy after pip installations.
# Do not hardcode Python site-packages version.
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
# Used by injected init.sh ConfigMap to create:
# /workspace/.venv
# ------------------------------------------------------------
RUN mkdir -p /opt/eo

COPY --chmod=644 requirements-runtime-py313.lock \
    /opt/eo/requirements-runtime-py313.lock


# ------------------------------------------------------------
# Cleanup and permissions
# ------------------------------------------------------------
RUN set -eux; \
    rm -f /tmp/requirements-py313.lock; \
    fix-permissions /opt/conda; \
    fix-permissions "${HOME}"


# ------------------------------------------------------------
# Security hardening
#
# No hardcoded system password.
# Disable root account password authentication.
# Preserve Jupyter runtime user.
# ------------------------------------------------------------
RUN set -eux; \
    passwd -l root; \
    chmod 755 /usr/local/bin/nc-sync; \
    chmod 644 /etc/xdg/autostart/nc-sync.desktop


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
    test -f /opt/conda/lib/rebind.so; \
    test -f /opt/eo/requirements-runtime-py313.lock


# ------------------------------------------------------------
# Restore standard Jupyter user
# ------------------------------------------------------------
USER ${NB_USER}
