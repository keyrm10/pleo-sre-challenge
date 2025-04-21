# syntax=docker/dockerfile:1

# build stage

ARG GO_VERSION=1.19
ARG ALPINE_VERSION=3.15
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS build
WORKDIR /src

RUN --mount=type=cache,target=/go/pkg/mod/ \
    --mount=type=bind,source=go.sum,target=go.sum \
    --mount=type=bind,source=go.mod,target=go.mod \
    go mod download -x

ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod/ \
    --mount=type=bind,target=. \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /bin/app .

# final stage

FROM gcr.io/distroless/static-debian12:nonroot AS final

COPY --from=build /bin/app /bin/

EXPOSE 8081

ENTRYPOINT [ "/bin/app" ]
