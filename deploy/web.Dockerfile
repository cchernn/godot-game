# Web client: Godot web export served as static files. Build context: repository root.
FROM debian:12-slim AS web
ARG GODOT_VERSION=4.7.2-stable
ARG SUPABASE_URL
ARG SUPABASE_PUBLISHABLE_KEY
ARG WORLD_ID
# "same-origin" = the page's own address (all-in-one stack). Use absolute URLs when the services are on different hosts.
ARG API_URL=same-origin
ARG SERVER_URL=same-origin
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN B=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION} \
    && F=Godot_v${GODOT_VERSION}_linux.x86_64.zip \
    && curl -fsSLO $B/$F && curl -fsSLO $B/SHA512-SUMS.txt \
    && grep " $F\$" SHA512-SUMS.txt | sha512sum -c - \
    && unzip -q $F && mv Godot_v${GODOT_VERSION}_linux.x86_64 /usr/local/bin/godot
# Export templates are large; only the web ones are kept. This layer is cached between builds.
RUN B=https://github.com/godotengine/godot/releases/download/${GODOT_VERSION} \
    && T=Godot_v${GODOT_VERSION}_export_templates.tpz \
    && curl -fsSLO $B/$T \
    && grep " $T\$" SHA512-SUMS.txt | sha512sum -c - \
    && D=/root/.local/share/godot/export_templates/$(echo ${GODOT_VERSION} | tr '-' '.') \
    && mkdir -p $D && unzip -j -q $T 'templates/web_*' 'templates/version.txt' -d $D && rm $T
WORKDIR /project
COPY project.godot icon.svg export_presets.cfg ./
COPY game ./game
# Only public values go into the browser build; "same-origin" resolves URLs from the page address.
RUN test -n "$SUPABASE_URL" && test -n "$SUPABASE_PUBLISHABLE_KEY" \
    && printf '{"supabase_url":"%s","supabase_publishable_key":"%s","api_url":"%s","server_url":"%s","world_id":"%s"}\n' \
        "$SUPABASE_URL" "$SUPABASE_PUBLISHABLE_KEY" "$API_URL" "$SERVER_URL" "$WORLD_ID" > game/client/client_env.json
RUN godot --headless --path . --import --quit >/dev/null 2>&1; \
    mkdir -p /out && godot --headless --path . --export-release Web /out/index.html && test -f /out/index.html

FROM caddy:2.8-alpine
COPY deploy/web.Caddyfile /etc/caddy/Caddyfile
COPY --from=web /out /srv/www
