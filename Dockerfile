# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Philippe Sauter <phsauter@iis.ee.ethz.ch>
#
#
# Digital design image for CIs and headless use based on iic-osic-tools
#
# Includes:
#   EDA tools  : yosys (+ eqy/sby/mcy/yices2 + slang plugin),
#                slang (standalone SV linter), verilator, OpenROAD,
#                KLayout, RISC-V GNU toolchain
#   Lint/format: black, flake8, isort, mypy               (Python)
#                clang-format                             (C++)
#                slang --lint-only, verilator --lint-only (SystemVerilog)
#
# Uses the iic-osic-tools image on Docker Hub as a build-time source
# Only the tool directories we need are copied into a fresh 
# ubuntu:noble runtime layer, so the final image contains 
# none of the GUI/VNC/desktop stack and only necessary tools.
#
# Runtime apt packages are derived automatically: ldd maps each tool
# binary's shared-library dependency tree back to dpkg package names.
# Only interpreters and executables (python3, perl, gcc, …) that the
# tools spawn at runtime still need to be listed explicitly, 
# as they are not shared libraries and ldd cannot see them.

ARG SOURCE_IMAGE=hpretl/iic-osic-tools:2025.12
FROM ${SOURCE_IMAGE} AS source

# Derive the needed apt-managed packages
#   1. Find all executable files and shared libraries of the EDA tools.
#   2. Run ldd on every found file to enumerate the full dependency tree
#      (discard errors for non-ELF files such as scripts).
#   3. Keep only paths under /usr/lib or /lib, these are apt-managed.
#      /usr/local is excluded because we copy those libs separately;
#      /foss is excluded because we copy the tool dirs themselves.
#   4. Map each .so path back to its owning dpkg package and deduplicate.
RUN find \
        /foss/tools/yosys \
        /foss/tools/slang \
        /foss/tools/verilator \
        /foss/tools/openroad \
        /foss/tools/klayout \
        /foss/tools/riscv-gnu-toolchain/bin \
        -type f \( -executable -o -name "*.so*" \) \
    | xargs ldd 2>/dev/null \
    | awk '/=>/ { print $3 }' \
    | grep -E '^/(usr/lib|lib)/' \
    | sort -u \
    | xargs dpkg -S 2>/dev/null \
    | cut -d: -f1 \
    | sort -u \
    > /tmp/apt-packages.txt

# Record all pip-installed packages as a constraints file.
# Used in the final stage with --constraint so that any package we
# choose to install is pinned to exactly the version from this image.
RUN pip3 freeze > /tmp/pip-constraints.txt

# Base image: defaults to ubuntu:noble but can be overridden at build time.
# In CI the base is read from the org.opencontainers.image.base.name label
# of the source image so this image always tracks the same base as iic-osic-tools.
ARG BASE_IMAGE=ubuntu:noble
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Europe/Vienna \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    TOOLS=/foss/tools \
    PDK_ROOT=/foss/pdks \
    DESIGNS=/foss/designs \
    # Disable the PEP 668 "externally managed environment" restriction.
    # In a container this guard is pointless.
    PIP_BREAK_SYSTEM_PACKAGES=1

COPY --from=source /tmp/apt-packages.txt /tmp/
COPY --from=source /tmp/pip-constraints.txt /tmp/

RUN apt-get update \
    # Install the shared-library packages derived from the ldd scan.
    && xargs apt-get install -y --no-install-recommends < /tmp/apt-packages.txt \
    # Install interpreters and tools that the EDA tools invoke at runtime.
    # These are executables (not shared libraries) so ldd cannot find them.
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        locales \
        tzdata \
        git \
        wget \
        curl \
        python3 \
        python3-pip \
        python3-venv \
        perl \
        ruby \
        ruby-irb \
        tcl \
        tcllib \
        gcc \
        g++ \
        make \
        clang-format \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/* /tmp/apt-packages.txt

# OpenROAD depends on several libraries that are not packaged in Ubuntu
# and are built from source in the base image.
COPY --from=source /usr/local/lib /usr/local/lib
RUN ldconfig

ENV HOME=/headless
RUN mkdir -p ${TOOLS} ${PDK_ROOT} ${DESIGNS} ${HOME}

# Copy tools from iic-osic-tools to this image
COPY --from=source ${TOOLS}/yosys               ${TOOLS}/yosys/
COPY --from=source ${TOOLS}/slang               ${TOOLS}/slang/
COPY --from=source ${TOOLS}/verilator           ${TOOLS}/verilator/
COPY --from=source ${TOOLS}/riscv-gnu-toolchain ${TOOLS}/riscv-gnu-toolchain/
COPY --from=source ${TOOLS}/openroad            ${TOOLS}/openroad/
COPY --from=source ${TOOLS}/klayout             ${TOOLS}/klayout/

# Unified bin directory with symlinks to all tools
COPY --from=source ${TOOLS}/bin                 ${TOOLS}/bin/

# profile.d: sourced by login shells
# sets PATH, PYTHONPATH, LD_LIBRARY_PATH.
COPY --from=source /etc/profile.d/iic-osic-tools-setup.sh \
                   /etc/profile.d/iic-osic-tools-setup.sh

# .bashrc: sourced by interactive shells — re-exports the same env vars
# and provides all aliases (ll, gss, k, …) and the custom prompt.
COPY --from=source ${HOME}/.bashrc ${HOME}/.bashrc

# tool version manifest
COPY --from=source /tool_metadata.yml /tool_metadata.yml

# Default environment setup

ENV RISCV=${TOOLS}/riscv-gnu-toolchain
ENV PATH=\
${TOOLS}/bin:\
${TOOLS}/yosys/bin:\
${TOOLS}/slang/bin:\
${TOOLS}/verilator/bin:\
${TOOLS}/riscv-gnu-toolchain/bin:\
${TOOLS}/openroad/bin:\
${TOOLS}/klayout:\
${PATH}

ENV LD_LIBRARY_PATH=${TOOLS}/klayout

# Python paths:
#   - pyosys: the Yosys Python API lives under the yosys share tree
#   - klayout Python module (pymod) for scripting and DRC/LVS
ENV PYTHONPATH=${TOOLS}/yosys/share/yosys/python3:${TOOLS}/klayout/pymod

# Python tools (linter and formatter)
RUN pip3 install --no-cache-dir --constraint /tmp/pip-constraints.txt \
    black \
    flake8 \
    isort \
    mypy \
    && rm /tmp/pip-constraints.txt

RUN chown -R 1000:1000 ${HOME} ${DESIGNS}
USER 1000:1000
WORKDIR ${DESIGNS}
