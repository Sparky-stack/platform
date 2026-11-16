# syntax=docker/dockerfile:1
# Quarkus service (JVM mode, fast-jar layout) on distroless Java 25, non-root (uid 65532). `mvn verify` runs the
# @QuarkusTest suite, which gates the image. Builds natively per architecture (koorikla/ci native runners). Base images
# pinned by multi-arch index digest (Renovate). Native (Mandrel) builds are opt-in: docs/project-templates.md.

FROM docker.io/library/maven:3.9.16-eclipse-temurin-25@sha256:93b8a14ea2f412782e4e842651273b4d903e35cc496284f178fbbe2d67d00976 AS build
WORKDIR /src
COPY pom.xml ./
COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B -ntp verify

FROM gcr.io/distroless/java25-debian13:nonroot@sha256:1c4ced761d17961c900cba60c33c8c3c46edbdadaa9d5ef9806eb5a6824fd406
WORKDIR /app
# fast-jar layers, least to most frequently changing
COPY --from=build /src/target/quarkus-app/lib/ ./lib/
COPY --from=build /src/target/quarkus-app/*.jar ./
COPY --from=build /src/target/quarkus-app/app/ ./app/
COPY --from=build /src/target/quarkus-app/quarkus/ ./quarkus/
ARG VERSION=dev
ENV APP_VERSION=${VERSION} \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/bin/java", "-jar", "/app/quarkus-run.jar"]
