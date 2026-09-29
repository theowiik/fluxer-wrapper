FROM docker:cli
RUN apk add --no-cache curl openssl
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["sh", "/entrypoint.sh"]
