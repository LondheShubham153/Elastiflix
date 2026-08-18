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
      origin: "http://localhost:3000",
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
app.post("/api/autocomplete", logged("autocomplete", (s, q) => SearchConnector.onAutocomplete(s, q)));

app.get("/", (req, res) => {
  res.send("Hello from the backend!");
});

app.listen(17700, () => {
  log.info({ event: "startup", port: 17700, index: process.env.ES_INDEX });
});
