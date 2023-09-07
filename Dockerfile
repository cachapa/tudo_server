FROM dart:3@sha256:f5ce3ec89ac32a5e6ddb05a5110a5f235d4f36908ef1614b728fe7bcab9bb201 as build

WORKDIR /build
COPY pubspec.* .
RUN dart pub get

COPY . .
RUN dart pub get --offline
RUN dart compile exe bin/main.dart -o tudo_server

FROM debian:bookworm-slim@sha256:050f00e86cc4d928b21de66096126fac52c2ea47885c232932b2e4c00f0c116d

WORKDIR /app/bin
COPY --from=build /build/tudo_server .

EXPOSE 8080
ENTRYPOINT ["/app/bin/tudo_server"]