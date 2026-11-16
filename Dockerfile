# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build

WORKDIR /app

COPY package.json package-lock.json ./
# No dependency runs install scripts. node-pty loads its prebuilt linux-x64 and linux-arm64
# binaries without them, and the root postinstall only fixes macOS binaries.
RUN npm ci --ignore-scripts

COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build
# What the npm package holds, as `files` in package.json: no build cache, no dev dependencies.
RUN rm -rf .next/cache && find .next -name '*.js.map' -delete && npm prune --omit=dev

FROM debian:trixie-slim AS runtime
ENV NODE_ENV=production \
    HOME=/home/node \
    PORT=30141 \
    PI_WEB_HOSTNAME=0.0.0.0 \
    PI_WEB_NO_OPEN=1 \
    PATH="${PATH}:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin"

# Keep Node and npm for the app and its plugin tools.
COPY --from=build /usr/local/bin/node /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
COPY --from=build /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl file git libatomic1 libstdc++6 procps \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s node /usr/local/bin/nodejs \
    && ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && groupadd --gid 1000 node \
    && useradd --uid 1000 --gid node --shell /bin/bash --create-home node \
    && mkdir -p /home/node/.pi/agent /home/node/.agents/skills /home/node/pi-cwd \
    && chown -R node:node /home/node/.pi /home/node/.agents /home/node/pi-cwd \
    && install -d -o node -g node /home/linuxbrew/.linuxbrew \
    && printf '%s\n' "export PATH=\$PATH:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin" > /etc/profile.d/homebrew.sh

WORKDIR /app
USER node
# Install to Homebrew's default Linux prefix so node can use prebuilt packages.
RUN curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/homebrew-install.sh \
    && NONINTERACTIVE=1 bash /tmp/homebrew-install.sh \
    && brew --version && node --version && npm --version \
    && rm -rf /tmp/homebrew-install.sh "$HOME/.cache/Homebrew"

COPY --from=build --chown=node:node /app/bin ./bin
COPY --from=build --chown=node:node /app/.next ./.next
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/public ./public
COPY --from=build --chown=node:node /app/next.config.ts /app/package.json ./

EXPOSE 30141
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node", "-e", "fetch(`http://127.0.0.1:${process.env.PORT}`).then(r => process.exit(r.status < 500 ? 0 : 1)).catch(() => process.exit(1))"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["node", "bin/pi-web.js"]
