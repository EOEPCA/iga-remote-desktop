
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
       ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /artifacts

RUN test "${TARGETARCH}" = "amd64" \
    && curl -fL --retry 3 \
       "https://github.com/TurboVNC/turbovnc/releases/download/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_amd64.deb" \
       -o turbovnc.deb \
    && curl -fL --retry 3 \
       "https://github.com/pypa/hatch/releases/download/hatch-v${HATCH_VERSION}/hatch-x86_64-unknown-linux-gnu.tar.gz" \
       -o hatch.tar.gz \
    && tar -xzf hatch.tar.gz hatch \
    && curl -fL --retry 3 \
       "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
       -o yq \
    && curl -fL --retry 3 \
       "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64" \
       -o jq \
    && chmod 755 hatch yq jq


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
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
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
       gnupg \
    && (apt-get remove -y light-locker || true) \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# Nextcloud Desktop CLI
#
# Preserve upstream build prefix:
#   33.0.7-20260629
#
# Allow Ubuntu packaging suffixes such as:
#   ~noble1
#   ~jammy1
#
# Fail if no matching package exists.
# ------------------------------------------------------------
ARG NEXTCLOUD_VERSION="33.0.7-20260629"

RUN add-apt-repository -y ppa:nextcloud-devs/client \
    && apt-get update \
    && NEXTCLOUD_PACKAGE_VERSION="$( \
         apt-cache madison nextcloud-desktop-cmd \
         | awk -v prefix="${NEXTCLOUD_VERSION}" \
           '$3 == prefix || index($3, prefix ".") == 1 { print $3 }' \
         | sort -V \
         | tail -n 1 \
       )" \
    && test -n "${NEXTCLOUD_PACKAGE_VERSION}" \
    && echo "Installing Nextcloud: ${NEXTCLOUD_PACKAGE_VERSION}" \
    && apt-get install -y --no-install-recommends \
       "nextcloud-desktop-cmd=${NEXTCLOUD_PACKAGE_VERSION}" \
    && apt-mark hold nextcloud-desktop-cmd \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# ------------------------------------------------------------
# TurboVNC
# ------------------------------------------------------------
COPY --from=downloads \
    /artifacts/turbovnc.deb /tmp/turbovnc.deb

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       /tmp/turbovnc.deb \
    && rm /tmp/turbovnc.deb \
    && ln -s /opt/TurboVNC/bin/* /usr/local/bin/ \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


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
# websockify native rebind.so
#
# Preserve existing integration without hardcoding
# Python 3.11 site-packages.
# ------------------------------------------------------------
RUN set -eux; \
    rebind="$(find /usr/lib \
      -path '*/websockify/rebind.so' -print -quit)"; \
    test -n "$rebind"; \
    target="$(/opt/conda/bin/python -c \
      'import site; print(site.getsitepackages()[0])')"; \
    mkdir -p "$target/websockify"; \
    cp "$rebind" "$target/websockify/rebind.so"; \
    cp "$rebind" /opt/conda/lib/rebind.so


# ------------------------------------------------------------
# Python dependencies
#
# requirements-py313.lock must contain pinned versions.
# ------------------------------------------------------------
COPY requirements-py313.lock \
    /tmp/requirements-py313.lock

USER ${NB_USER}

RUN /opt/conda/bin/python -m pip install \
       --no-cache-dir \
       -r /tmp/requirements-py313.lock \
    && /opt/conda/bin/python -m pip check


# ------------------------------------------------------------
# Runtime EO dependency lock
#
# Used by the injected init.sh ConfigMap to create
# /workspace/.venv.
# ------------------------------------------------------------
USER root

RUN mkdir -p /opt/eo

COPY requirements-runtime-py313.lock \
    /opt/eo/requirements-runtime-py313.lock

RUN chmod 644 \
    /opt/eo/requirements-runtime-py313.lock


# ------------------------------------------------------------
# Cleanup and permissions
# ------------------------------------------------------------
RUN rm -f /tmp/requirements-py313.lock \
    && chown -R ${NB_UID}:${NB_GID} "${HOME}"


# ------------------------------------------------------------
# User password (legacy compatibility)
# ------------------------------------------------------------
ARG USERPWD=pass

RUN echo "${NB_USER}:${USERPWD}" | chpasswd


# ------------------------------------------------------------
# Build-time smoke checks
# ------------------------------------------------------------
RUN /opt/conda/bin/python -c \
      'import sys; assert sys.version_info[:2] == (3, 13)' \
    && hatch --version \
    && yq --version \
    && jq --version \
    && nextcloudcmd --version


# ------------------------------------------------------------
# Restore standard Jupyter user
# ------------------------------------------------------------
USER ${NB_USER}
