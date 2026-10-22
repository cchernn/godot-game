#!/bin/sh
# Forward the stack's ports from the Docker host to this container's localhost.
for p in 8080 8081 8082; do
  socat TCP-LISTEN:$p,fork,reuseaddr TCP:${STACK_HOST:-host.docker.internal}:$p &
done
sleep 1
exec python3 /t/run.py "$@"
