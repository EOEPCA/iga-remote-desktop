# Interactive Jupyter-based EO development environment.
# Includes desktop UI and browser.
# Not intended as a minimal runtime image.
FROM jupyter/base-notebook:python-3.11.6

USER root
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -y update \
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
   libtbb2 \
   curl \
   vim

# Remove light-locker to prevent screen lock
ARG TURBOVNC_VERSION=2.2.5
RUN wget -q https://github.com/TurboVNC/turbovnc/releases/download/${TURBOVNC_VERSION}/turbovnc_${TURBOVNC_VERSION}_amd64.deb -O turbovnc_${TURBOVNC_VERSION}_amd64.deb && \
   apt-get install -y -q ./turbovnc_${TURBOVNC_VERSION}_amd64.deb && \
   apt-get remove -y -q light-locker && \
   rm ./turbovnc_${TURBOVNC_VERSION}_amd64.deb && \
   ln -s /opt/TurboVNC/bin/* /usr/local/bin/  \
   && apt-get clean \
   && rm -rf /var/lib/apt/lists/*




# apt-get may result in root-owned directories/files under $HOME
RUN chown -R $NB_UID:$NB_GID $HOME

# ADD . /opt/install
# RUN fix-permissions /opt/install

ARG USERPWD=pass
RUN echo "${NB_USER}:${USERPWD}" | chpasswd

# -------------------------------------------------------------------
# hatch
# -------------------------------------------------------------------
ARG HATCH_VERSION=1.16.2
RUN curl -fsSL \
    "https://github.com/pypa/hatch/releases/download/hatch-v${HATCH_VERSION}/hatch-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C /usr/local/bin hatch && chmod +x /usr/local/bin/hatch

# -------------------------------------------------------------------
# yq / jq
# -------------------------------------------------------------------
ARG YQ_VERSION=v4.45.1
RUN curl -fsSL \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

ARG JQ_VERSION=jq-1.8.1
RUN curl -fsSL \
    "https://github.com/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-amd64" \
    -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq

USER ${NB_USER}

COPY environment.yaml /tmp/environment.yaml
RUN conda env update -n base -f /tmp/environment.yaml && \
    conda clean -afy

USER root
RUN cp /usr/lib/websockify/rebind.so \
  /opt/conda/lib/python3.11/site-packages/websockify/ && \
  cp /usr/lib/websockify/rebind.so \
  /opt/conda/lib/rebind.so
USER ${NB_USER}