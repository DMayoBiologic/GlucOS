# GlucOS push relay. Build from the repository root (the relay compiles the shared sources):
#   docker build -f Relay/Dockerfile -t glucos-relay .
FROM swift:6.1-jammy AS build
WORKDIR /src
COPY Sources ./Sources
COPY Relay ./Relay
WORKDIR /src/Relay
RUN swift build -c release --static-swift-stdlib \
 && cp "$(swift build -c release --show-bin-path)/glucos-relay" /usr/local/bin/glucos-relay

FROM ubuntu:jammy
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libcurl4 libxml2 tzdata \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/glucos-relay /usr/local/bin/glucos-relay
ENV DATA_DIR=/data PORT=8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/glucos-relay"]
