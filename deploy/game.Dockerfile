# Dedicated headless battle server. Build context: repository root.
FROM debian:12-slim AS godot
ARG GODOT_VERSION=4.7.2-stable
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN B=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION} \
    && F=Godot_v${GODOT_VERSION}_linux.x86_64.zip \
    && curl -fsSLO $B/$F && curl -fsSLO $B/SHA512-SUMS.txt \
    && grep " $F\$" SHA512-SUMS.txt | sha512sum -c - \
    && unzip -q $F && mv Godot_v${GODOT_VERSION}_linux.x86_64 /godot

FROM debian:12-slim
ARG GODOT_VERSION=4.7.2-stable
RUN apt-get update && apt-get install -y --no-install-recommends libfontconfig1 libstdc++6 ca-certificates \
    && rm -rf /var/lib/apt/lists/* && useradd --create-home game
COPY --from=godot /godot /usr/local/bin/godot
WORKDIR /srv/game
COPY project.godot icon.svg ./
COPY game ./game
RUN rm -f game/client/client_env.json && chown -R game:game /srv/game
USER game
# Builds the class/script cache the project needs before it can run.
RUN godot --headless --path . --import --quit >/dev/null 2>&1; test -f .godot/global_script_class_cache.cfg
COPY --chmod=755 deploy/game-entrypoint.sh /usr/local/bin/game-entrypoint
EXPOSE 9080
ENTRYPOINT ["game-entrypoint"]
