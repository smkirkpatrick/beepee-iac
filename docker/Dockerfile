FROM ghcr.io/openclaw/openclaw:latest

USER node
RUN mkdir -p /home/node/.openclaw
COPY --chown=node:node openclaw.json /home/node/.openclaw/openclaw.json
