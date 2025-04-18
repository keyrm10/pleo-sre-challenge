FROM golang:1.19-alpine3.15

RUN addgroup -g 1001 nonroot
RUN adduser -D -g '' -u 1001 -S nonroot -G nonroot

WORKDIR /build/
COPY . .
RUN apk add build-base
RUN go mod download -x
RUN go mod tidy -v
RUN GOOS=linux
RUN go build -o app .
RUN chown -R nonroot:nonroot /build
USER 1001

ENTRYPOINT ["./app"]
