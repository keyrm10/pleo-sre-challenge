FROM golang:1.19-alpine3.15

WORKDIR /build/
COPY . .
RUN apk add build-base
RUN go mod download -x
RUN go mod tidy -v
RUN GOOS=linux
RUN go build -o app .

ENTRYPOINT ["./app"]
