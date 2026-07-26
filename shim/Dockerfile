FROM golang:alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /shim

FROM scratch
COPY --from=build /shim /shim
EXPOSE 8080
ENTRYPOINT ["/shim"]
