FROM golang:1-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /panel .

FROM scratch
# No CA bundle and no user database: the panel makes no outbound TLS
# connection, and it runs as root so it can write the mode file into control/
# whoever happens to own that folder on the host.
COPY --from=build /panel /panel
EXPOSE 8080
ENTRYPOINT ["/panel"]
