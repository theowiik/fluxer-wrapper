# Caddy with the CrowdSec bouncer compiled in, so bans are enforced here
# instead of in the host firewall.
FROM caddy:2-builder AS build
RUN xcaddy build --with github.com/hslatman/caddy-crowdsec-bouncer/http

FROM caddy:2
COPY --from=build /usr/bin/caddy /usr/bin/caddy
