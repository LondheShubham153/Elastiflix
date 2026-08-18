// Structured JSON logging for Elastiflix.
//
// Upstream logs `console.info("Search request:", state, queryConfig)`, which
// prints a pretty-printed JS object across multiple lines. That is fine for a
// human watching a terminal and useless for a log pipeline: no HTTP method, no
// status, no latency, and nothing a Filebeat -> Logstash -> Elasticsearch path
// can turn into a field you aggregate on.
//
// Everything here writes ONE JSON object per line, which is exactly what a log
// shipper wants. No dependencies -- keeps `npm install` unchanged.

function emit(level, fields) {
  process.stdout.write(
    JSON.stringify({
      "@timestamp": new Date().toISOString(),
      level,
      service: "elastiflix-backend",
      ...fields
    }) + "\n"
  );
}

export const log = {
  info: (fields) => emit("info", fields),
  error: (fields) => emit("error", fields)
};

// Wraps a search handler so every request produces exactly one log line,
// whether it succeeds or blows up.
export function logged(searchType, handler) {
  return async (req, res) => {
    const started = Date.now();
    const { state = {}, queryConfig = {} } = req.body ?? {};
    const query = state.searchTerm ?? "";

    try {
      const response = await handler(state, queryConfig);

      log.info({
        method: req.method,
        path: req.path,
        status: 200,
        duration_ms: Date.now() - started,
        search_type: searchType,
        query,
        results: response?.totalResults ?? response?.results?.length ?? 0,
        page: state.current ?? 1
      });

      res.json(response);
    } catch (err) {
      log.error({
        method: req.method,
        path: req.path,
        status: 500,
        duration_ms: Date.now() - started,
        search_type: searchType,
        query,
        error: err?.message ?? String(err),
        // Elasticsearch client errors carry the useful detail down here.
        es_error: err?.meta?.body?.error?.type ?? null
      });

      // Upstream has no try/catch at all, so an ES failure becomes an
      // unhandled rejection and the client just hangs.
      res.status(500).json({ error: "search_failed", message: err?.message });
    }
  };
}
