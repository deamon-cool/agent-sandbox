ARG BASE_IMAGE=agent-base
ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE} AS node
FROM ${BASE_IMAGE}

COPY --from=node /usr/local/bin/ /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules/ /usr/local/lib/node_modules/
COPY --from=node /opt/ /opt/

RUN node --version && npm --version
