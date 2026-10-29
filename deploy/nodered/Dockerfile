# OFM Node-RED image: the official Node-RED image plus the protocol and
# database nodes OFM uses, at pinned versions. Building them into the image
# means a plant installation never installs anything from the internet, and
# every installation runs identical drivers (Architecture Overview §14).
#
# Built automatically by "docker compose up -d --build" (deploy/README.md).
# To change a version: edit it here, raise the image tag in
# docker-compose.yml, rebuild, test, commit.
FROM nodered/node-red:4.1.16-22

# Installed next to Node-RED itself (not in /data), so the /data volume with
# flows and settings never hides or overrides them.
# Libraries used directly by OFM's acquisition flow, each at the version the
# matching palette node already uses, so only one copy is installed:
# node-opcua (OPC UA, ADR-0017), @st-one-io/nodes7 (Siemens S7, ADR-0018).
# st-ethernet-ip: Rockwell Logix controllers over EtherNet/IP (ADR-0018).
# Every package comes from the public npm registry.
WORKDIR /usr/src/node-red
RUN npm install --omit=dev --no-fund --no-audit --no-update-notifier \
      node-opcua@2.160.0 \
      @st-one-io/nodes7@1.1.2 \
      st-ethernet-ip@2.7.5 \
      node-red-contrib-opcua@0.2.355 \
      node-red-contrib-postgresql@0.16.2 \
      node-red-contrib-s7@3.1.3 \
      @flowfuse/node-red-dashboard@1.33.0 \
 && npm cache clean --force

# Modbus: not included yet. Every current node-red-contrib-modbus release
# downloads part of its code from a third-party package server instead of the
# public npm registry; the choice of Modbus driver is made when the first
# Modbus device needs it (docs/STATUS.md).
