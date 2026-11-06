FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

WORKDIR /app
COPY . .

# Build the browser bundle into the backend's static directory, then export
# the backend and all of its Erlang dependencies as a runnable shipment.
RUN cd common && gleam build \
    && cd ../frontend \
    && gleam run -m lustre/dev build --outdir=dist \
    && cp dist/imposztor_front.js ../backend/priv/static/imposztor_front.mjs \
    && cd ../backend \
    && gleam export erlang-shipment

FROM erlang:28-alpine

ENV PORT=3000
WORKDIR /app

RUN addgroup -S webapp && adduser -S webapp -G webapp
COPY --from=build /app/backend/build/erlang-shipment/ /app/

USER webapp
EXPOSE 3000
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
