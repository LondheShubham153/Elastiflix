import express from "express";
import cors from "cors";
import SearchConnector from "./SearchConnector.js";
import RerankConnector from "./RerankConnector.js";
import SemanticConnector from "./SemanticConnector.js";
import HybridConnector from "./HybridConnector.js";
import { log, logged } from "./logger.js";

const app = express();
if (process.env.LOCAL) {
  app.use(
    cors({
      origin: `http://${process.env.PUBLIC_HOST || "localhost"}:3000`,
      credentials: true
    })
  );
}
app.use(express.json());

// Each route is wrapped so it emits one structured JSON log line per request:
// method, path, status, duration_ms, the search term, and the result count.
// That is what makes the Kibana dashboard possible.
app.post("/api/search", logged("lexical", (s, q) => SearchConnector.onSearch(s, q)));
app.post("/api/rerank/search", logged("rerank", (s, q) => RerankConnector.onSearch(s, q)));
app.post("/api/semantic/search", logged("semantic", (s, q) => SemanticConnector.onSearch(s, q)));
app.post("/api/hybrid/search", logged("hybrid", (s, q) => HybridConnector.onSearch(s, q)));
// Autocomplete is deliberately NOT wrapped in logged(). It returns
// {autocompletedResults, autocompletedSuggestions} -- no totalResults -- so
// every call would log result_count: 0, and the search bar fires one request
// per keystroke. That would bury the "top search terms" and "zero-result
// searches" panels under half-typed prefixes that always look like misses.
app.post("/api/autocomplete", async (req, res) => {
  const { state = {}, queryConfig = {} } = req.body ?? {};
  try {
    res.json(await SearchConnector.onAutocomplete(state, queryConfig));
  } catch (err) {
    log.error({ event: "autocomplete_failed", error: err?.message ?? String(err) });
    res.status(500).json({ error: "autocomplete_failed" });
  }
});

app.get("/", (req, res) => {
  res.send("Hello from the backend!");
});

app.listen(17700, () => {
  log.info({ event: "startup", port: 17700, index: process.env.ES_INDEX });
});
