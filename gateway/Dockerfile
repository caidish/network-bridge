FROM ghcr.io/sagernet/sing-box:v1.13.19

RUN apk add --no-cache nftables iproute2 curl jq socat ethtool

COPY sing-box.json.tmpl nftables.nft.tmpl /opt/clashgw/
COPY entrypoint.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
