FROM golang:1.25 AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /evpn-ui .

FROM registry.access.redhat.com/ubi10/ubi-minimal:latest
RUN microdnf install -y ca-certificates && microdnf clean all
COPY --from=builder /evpn-ui /evpn-ui
COPY static/ /static/
EXPOSE 8080
ENTRYPOINT ["/evpn-ui"]
